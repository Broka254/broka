"""Email OTP: request, verify, and the handoff into /auth/register.

Email stays optional at signup. What these cover is that when an address IS
given, proving it actually means something — a verified address lands on the
user as verified, an unverified one does not, and a token for one address can
never register another.
"""

from dataclasses import replace

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

import api.core.email as email_mod
from api.core.email import ConsoleEmail, ResendEmail, build_otp_email, get_email_provider
from api.core.config import settings
from api.database import init_db, reset_engine
from api.domains.auth.service import _normalize_email
from api.security import create_email_verify_token, decode_email_verify_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    mp.setenv("ENV", "test")
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


def _with_settings(monkeypatch, **overrides):
    """Settings is a frozen dataclass, so swap the whole object in."""
    monkeypatch.setattr(email_mod, "settings", replace(settings, **overrides))


class TestNormalizeEmail:
    @pytest.mark.parametrize(
        "raw,expected",
        [
            ("  Person@Example.COM ", "person@example.com"),
            ("a@b.co", "a@b.co"),
        ],
    )
    def test_trims_and_lowercases(self, raw, expected):
        assert _normalize_email(raw) == expected

    @pytest.mark.parametrize(
        "raw", ["", "   ", "no-at-sign", "no@domain", "two@@at.com", "sp ace@x.com", None]
    )
    def test_rejects_non_addresses(self, raw):
        assert _normalize_email(raw) == ""


class TestVerifyToken:
    def test_round_trips_the_address(self):
        tok = create_email_verify_token("person@example.com")
        assert decode_email_verify_token(tok) == "person@example.com"

    def test_rejects_a_phone_token(self):
        # The two token types must not be interchangeable, or a proven phone
        # could stand in for a proven email.
        from api.security import create_phone_verify_token

        assert decode_email_verify_token(create_phone_verify_token("+254700000000")) is None

    def test_rejects_garbage(self):
        assert decode_email_verify_token("not-a-jwt") is None


class TestProviderSelection:
    def test_falls_back_to_console_without_a_key(self, monkeypatch):
        _with_settings(monkeypatch, resend_api_key="")
        assert isinstance(get_email_provider(), ConsoleEmail)

    def test_uses_resend_when_fully_configured(self, monkeypatch):
        _with_settings(
            monkeypatch, resend_api_key="re_test_key", resend_from="BROKA <no@broka.app>"
        )
        assert isinstance(get_email_provider(), ResendEmail)

    def test_a_key_without_a_from_address_is_not_enough(self, monkeypatch):
        # Resend refuses a send with no verified from-address, so treating
        # this as configured would mean silently dropping every code.
        _with_settings(monkeypatch, resend_api_key="re_test_key", resend_from="")
        assert isinstance(get_email_provider(), ConsoleEmail)


class TestOtpEmailBody:
    def test_carries_the_code_in_subject_html_and_text(self):
        subject, html, text = build_otp_email("482913", 5)
        assert "482913" in subject
        assert "482913" in html
        assert "482913" in text

    def test_always_has_a_plain_text_alternative(self):
        _, _, text = build_otp_email("482913", 5)
        assert text.strip()
        assert "<" not in text

    def test_states_the_expiry(self):
        _, html, text = build_otp_email("482913", 7)
        assert "7 minutes" in text
        assert "7 minutes" in html


class TestEmailOtpEndpoints:
    async def test_request_then_verify_yields_a_token(self, client):
        email = "new.trader@example.com"
        r = await client.post("/auth/email/otp/request", json={"email": email})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["email"] == email
        assert body["expires_in_seconds"] > 0

        # Outside production the code comes back so the flow is testable
        # without a live Resend account.
        code = body["debug_code"]

        r2 = await client.post("/auth/email/otp/verify", json={"email": email, "code": code})
        assert r2.status_code == 200, r2.text
        assert decode_email_verify_token(r2.json()["email_verify_token"]) == email

    async def test_address_is_normalised_on_the_way_in(self, client):
        r = await client.post("/auth/email/otp/request", json={"email": "  MiXeD@Example.COM "})
        assert r.status_code == 200
        assert r.json()["email"] == "mixed@example.com"

    async def test_malformed_address_is_rejected(self, client):
        r = await client.post("/auth/email/otp/request", json={"email": "not-an-email"})
        assert r.status_code == 400

    async def test_wrong_code_is_rejected(self, client):
        email = "wrongcode@example.com"
        await client.post("/auth/email/otp/request", json={"email": email})
        r = await client.post("/auth/email/otp/verify", json={"email": email, "code": "000000"})
        assert r.status_code == 400

    async def test_verify_without_a_request_is_rejected(self, client):
        r = await client.post(
            "/auth/email/otp/verify",
            json={"email": "never.asked@example.com", "code": "123456"},
        )
        assert r.status_code == 400

    async def test_a_code_cannot_be_used_twice(self, client):
        email = "replay@example.com"
        req = await client.post("/auth/email/otp/request", json={"email": email})
        code = req.json()["debug_code"]
        first = await client.post("/auth/email/otp/verify", json={"email": email, "code": code})
        assert first.status_code == 200
        second = await client.post("/auth/email/otp/verify", json={"email": email, "code": code})
        assert second.status_code == 400


class TestRegisterHandoff:
    """The point of verifying: it has to reach the stored user."""

    async def _verified_phone_token(self, client, phone: str) -> str:
        req = await client.post("/auth/otp/request", json={"phone": phone})
        code = req.json()["debug_code"]
        v = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
        return v.json()["phone_verify_token"]

    async def _email_token(self, client, email: str) -> str:
        req = await client.post("/auth/email/otp/request", json={"email": email})
        code = req.json()["debug_code"]
        v = await client.post("/auth/email/otp/verify", json={"email": email, "code": code})
        return v.json()["email_verify_token"]

    async def _register(self, client, **extra):
        body = {
            "name": "Test Trader",
            "password": "secret123",
            "lat": -1.29,
            "lng": 36.82,
            **extra,
        }
        return await client.post("/auth/register", json=body)

    async def test_a_verified_email_lands_on_the_user_as_verified(self, client):
        phone = "+254700111001"
        email = "verified.signup@example.com"
        r = await self._register(
            client,
            phone_verify_token=await self._verified_phone_token(client, phone),
            email_verify_token=await self._email_token(client, email),
        )
        assert r.status_code == 201, r.text

        me = await client.get(
            "/auth/me",
            headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        )
        assert me.status_code == 200, me.text
        assert me.json()["email"] == email
        assert me.json()["email_verified"] is True

    async def test_a_typed_email_is_stored_but_not_verified(self, client):
        phone = "+254700111002"
        email = "typed.only@example.com"
        r = await self._register(
            client,
            phone_verify_token=await self._verified_phone_token(client, phone),
            email=email,
        )
        assert r.status_code == 201, r.text

        me = await client.get(
            "/auth/me",
            headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        )
        assert me.json()["email"] == email
        assert me.json()["email_verified"] is False

    async def test_email_remains_optional(self, client):
        phone = "+254700111003"
        r = await self._register(
            client,
            phone_verify_token=await self._verified_phone_token(client, phone),
        )
        assert r.status_code == 201, r.text

    async def test_the_token_wins_over_a_different_typed_address(self, client):
        # Otherwise someone could prove one address and register another,
        # which would make "verified" meaningless.
        phone = "+254700111004"
        proven = "proven@example.com"
        r = await self._register(
            client,
            phone_verify_token=await self._verified_phone_token(client, phone),
            email_verify_token=await self._email_token(client, proven),
            email="someone.else@example.com",
        )
        assert r.status_code == 201, r.text

        me = await client.get(
            "/auth/me",
            headers={"Authorization": f"Bearer {r.json()['access_token']}"},
        )
        assert me.json()["email"] == proven

    async def test_a_forged_email_token_is_rejected(self, client):
        r = await self._register(
            client,
            phone_verify_token=await self._verified_phone_token(client, "+254700111005"),
            email_verify_token="not-a-real-token",
        )
        assert r.status_code == 400
