"""Auth hardening: what a token may be used for, who may claim admin, how OTP
attempts are counted, and what the console providers do in production.

Each class pins one rule that used to be weaker than the code around it
claimed:

  * only an ACCESS token authenticates a route or a WebSocket - the call,
    refresh and verify tokens are all signed with the same key and used to
    slip through anything that only checked the signature;
  * the ADMIN_BOOTSTRAP_EMAIL seat goes to a PROVEN address, not a typed one;
  * rate-limit buckets follow the normalised phone/email, so re-spelling one
    number does not multiply its attempt budget;
  * with no SMS/email provider in production, sends FAIL rather than logging
    one-time codes and reporting success.
"""
from dataclasses import replace
from unittest.mock import patch
import uuid

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from api.core.config import settings
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.security import (
    create_access_token,
    create_call_token,
    create_email_verify_token,
    create_password_reset_token,
    create_phone_verify_token,
    create_refresh_token,
    decode_access_token,
    get_current_user,
)
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_auth_hardening.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _phone() -> str:
    return "+2547" + str(uuid.uuid4().int)[:8]


# Every token type this codebase issues that is NOT an access token.
def _non_access_tokens(user_id: str = "user-123") -> dict[str, str]:
    refresh, _exp, _jti = create_refresh_token(user_id)
    return {
        "call": create_call_token(user_id, "room-abc"),
        "refresh": refresh,
        "phone_verify": create_phone_verify_token("+254700000000"),
        "email_verify": create_email_verify_token("person@example.com"),
        "password_reset": create_password_reset_token("+254700000000", None),
    }


# ── Token scoping ────────────────────────────────────────────────────────────

class TestOnlyAccessTokensAuthenticate:
    def test_access_token_resolves_to_its_user(self):
        tok = create_access_token({"sub": "user-123"})
        assert get_current_user(tok) == {"id": "user-123"}
        assert decode_access_token(tok)["sub"] == "user-123"

    @pytest.mark.parametrize("kind", ["call", "refresh", "phone_verify", "email_verify", "password_reset"])
    def test_other_token_types_are_refused_by_http_auth(self, kind):
        tok = _non_access_tokens()[kind]
        with pytest.raises(HTTPException) as exc:
            get_current_user(tok)
        assert exc.value.status_code == 401

    @pytest.mark.parametrize("kind", ["call", "refresh", "phone_verify", "email_verify", "password_reset"])
    def test_other_token_types_are_refused_by_the_ws_decoder(self, kind):
        assert decode_access_token(_non_access_tokens()[kind]) is None

    def test_garbage_is_refused(self):
        assert decode_access_token("not-a-jwt") is None

    @pytest.mark.asyncio
    async def test_a_call_token_cannot_call_an_http_route(self, client):
        """The concrete leak: a call token travels in a WebSocket URL, so it
        must not be a key to the rest of the account."""
        call_tok = create_call_token("user-123", "room-abc")
        r = await client.get("/auth/me", headers={"Authorization": f"Bearer {call_tok}"})
        assert r.status_code == 401


class TestWebSocketsRequireAccessTokens:
    """Real socket handshakes through Starlette's TestClient: each endpoint
    must close before accepting when handed anything but an access token."""

    @pytest.mark.parametrize("kind", ["call", "refresh", "phone_verify", "email_verify", "password_reset"])
    def test_auction_ws_refuses_non_access_tokens(self, kind):
        tok = _non_access_tokens()[kind]
        with TestClient(app) as tc:
            with pytest.raises(WebSocketDisconnect) as exc:
                with tc.websocket_connect(f"/auction-ws/ws/any-listing?token={tok}") as ws:
                    ws.receive_text()
        assert exc.value.code == 4401

    def test_auction_ws_accepts_an_access_token(self):
        tok = create_access_token({"sub": "user-123"})
        with TestClient(app) as tc:
            with tc.websocket_connect(f"/auction-ws/ws/any-listing?token={tok}") as ws:
                ws.send_text("ping")  # accepted: the socket is open

    @pytest.mark.parametrize("kind", ["call", "refresh"])
    def test_deal_ws_refuses_non_access_tokens(self, kind):
        tok = _non_access_tokens()[kind]
        with TestClient(app) as tc:
            with pytest.raises(WebSocketDisconnect) as exc:
                with tc.websocket_connect(f"/deal-ws/ws/any-deal?token={tok}") as ws:
                    ws.receive_text()
        assert exc.value.code == 4001

    def test_deal_ws_passes_auth_with_an_access_token(self):
        # Gets past auth and fails on the (nonexistent) deal instead - the
        # close code proves which check stopped it.
        tok = create_access_token({"sub": "user-123"})
        with TestClient(app) as tc:
            with pytest.raises(WebSocketDisconnect) as exc:
                with tc.websocket_connect(f"/deal-ws/ws/no-such-deal?token={tok}") as ws:
                    ws.receive_text()
        assert exc.value.code == 4004

    @pytest.mark.parametrize("kind", ["call", "refresh"])
    def test_media_ws_refuses_non_access_tokens(self, kind):
        tok = _non_access_tokens()[kind]
        with TestClient(app) as tc:
            with pytest.raises(WebSocketDisconnect) as exc:
                with tc.websocket_connect(f"/media/ws/any-listing?token={tok}") as ws:
                    ws.receive_text()
        assert exc.value.code == 4001


# ── Admin bootstrap ──────────────────────────────────────────────────────────

class TestAdminBootstrapNeedsAProvenEmail:
    BOOTSTRAP = "founder@broka.test"

    @pytest.fixture(autouse=True)
    def _bootstrap_email(self, monkeypatch):
        from api.domains.auth import service as auth_service
        monkeypatch.setattr(
            auth_service, "settings", replace(settings, admin_bootstrap_email=self.BOOTSTRAP),
        )

    async def _register(self, **kwargs) -> User:
        from api.domains.auth.service import AuthService
        async with AsyncSessionLocal() as db:
            out = await AuthService(db).register(
                name="Someone", phone=_phone(), password="Passw0rd!long",
                lat=-1.29, lng=36.82, **kwargs,
            )
        async with AsyncSessionLocal() as db:
            return (await db.execute(select(User).where(User.id == out["user_id"]))).scalar_one()

    @pytest.mark.asyncio
    async def test_a_typed_bootstrap_email_does_not_grant_admin(self):
        user = await self._register(email=self.BOOTSTRAP)
        assert user.email == self.BOOTSTRAP
        assert user.email_verified is False
        assert user.is_admin is False

    @pytest.mark.asyncio
    async def test_a_verified_bootstrap_email_grants_admin(self):
        # The previous test's user holds the typed address; clear it so the
        # verified registration is not a 409.
        async with AsyncSessionLocal() as db:
            for u in (await db.execute(select(User).where(User.email == self.BOOTSTRAP))).scalars():
                u.email = None
            await db.commit()

        user = await self._register(email_verify_token=create_email_verify_token(self.BOOTSTRAP))
        assert user.email_verified is True
        assert user.is_admin is True

    @pytest.mark.asyncio
    async def test_a_verified_other_email_does_not_grant_admin(self):
        user = await self._register(
            email_verify_token=create_email_verify_token(f"{uuid.uuid4().hex[:8]}@x.test"),
        )
        assert user.is_admin is False


# ── Rate-limit keys ──────────────────────────────────────────────────────────

class TestRateLimitKeysAreNormalised:
    def test_every_spelling_of_one_number_shares_a_bucket(self):
        from api.domains.auth.router import _phone_key
        keys = {_phone_key(p) for p in ("0712345678", "+254712345678", "254712345678", " 0712 345 678 ")}
        assert keys == {"phone:+254712345678"}

    def test_email_case_and_whitespace_share_a_bucket(self):
        from api.domains.auth.router import _email_key
        assert _email_key("  Person@Example.COM ") == _email_key("person@example.com")

    @pytest.mark.asyncio
    async def test_otp_verify_limit_holds_across_spellings(self, client):
        """Five wrong guesses under three spellings exhaust one budget."""
        from api.core.rate_limit import RateLimiter
        limiter = RateLimiter("otp_verify_test", limit=5, window_seconds=300)
        with patch("api.domains.auth.router.otp_verify_limiter", limiter):
            spellings = ["0799111222", "+254799111222", "254799111222"]
            codes = []
            for i in range(6):
                r = await client.post(
                    "/auth/otp/verify",
                    json={"phone": spellings[i % 3], "code": "000000"},
                )
                codes.append(r.status_code)
        assert codes[:5].count(429) == 0
        assert codes[5] == 429


# ── Console providers in production ──────────────────────────────────────────

class TestConsoleProvidersRefuseInProduction:
    @pytest.mark.asyncio
    async def test_console_sms_fails_and_does_not_log_the_body(self, caplog):
        from api.core.sms import ConsoleSMS
        with patch("api.core.sms.settings", replace(settings, env="production")):
            ok = await ConsoleSMS().send("+254712345678", "482913 is your BROKA code")
        assert ok is False
        assert "482913" not in caplog.text

    @pytest.mark.asyncio
    async def test_console_email_fails_and_does_not_log_the_body(self, caplog):
        from api.core.email import ConsoleEmail
        with patch("api.core.email.settings", replace(settings, env="production")):
            ok = await ConsoleEmail().send("a@b.co", "Code 482913", "<p>482913</p>", "482913")
        assert ok is False
        assert "482913" not in caplog.text

    @pytest.mark.asyncio
    async def test_email_otp_request_is_503_in_production_without_a_provider(self, client):
        prod = replace(settings, env="production", resend_api_key="")
        with patch("api.core.email.settings", prod), \
             patch("api.domains.auth.service.settings", prod):
            r = await client.post(
                "/auth/email/otp/request", json={"email": f"{uuid.uuid4().hex[:8]}@x.test"},
            )
        assert r.status_code == 503
        assert "debug_code" not in r.text

    @pytest.mark.asyncio
    async def test_console_providers_still_log_outside_production(self):
        from api.core.email import ConsoleEmail
        from api.core.sms import ConsoleSMS
        assert await ConsoleSMS().send("+254712345678", "hi") is True
        assert await ConsoleEmail().send("a@b.co", "s", "<p>h</p>", "t") is True
