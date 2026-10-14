"""Forgotten and changed passwords.

There was no way back into an account whose password was forgotten - the
login screen's "Forgot password?" was a label that did nothing - and no way
to change a password at all. Now:

  * forgot -> forgot/verify -> reset: an SMS code to the account's number,
    then a new password, and the phone is signed in again;
  * change: the current password, then a new one, from Settings.

Both sign every other phone out. What these pin is that each step proves
what it claims: a reset code is only good for a reset (and a registration
code never is), a reset token is spent by its first use, and the token is
no key to anything else.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, RefreshToken, User, init_db, reset_engine
from api.security import (
    create_password_reset_token,
    create_phone_verify_token,
    decode_access_token,
    hash_password,
)
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_password_reset.db"
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


OLD = "OldPassw0rd"
NEW = "NewPassw0rd"


def _phone() -> str:
    return "+2547" + str(uuid.uuid4().int)[:8]


async def _account(client, phone: str | None = None, password: str = OLD) -> dict:
    """A fresh account, signed in through the real login: its phone, id and
    tokens."""
    phone = phone or _phone()
    async with AsyncSessionLocal() as db:
        user = User(name="Reset Tester", phone=phone, password_hash=hash_password(password))
        db.add(user)
        await db.commit()
    r = await client.post("/auth/login", json={"phone": phone, "password": password})
    assert r.status_code == 200, r.text
    return {"phone": phone, **r.json()}


async def _login(client, phone: str, password: str) -> int:
    r = await client.post("/auth/login", json={"phone": phone, "password": password})
    return r.status_code


async def _reset_token(client, phone: str) -> str:
    r = await client.post("/auth/password/forgot", json={"phone": phone})
    assert r.status_code == 200, r.text
    code = r.json()["debug_code"]
    r = await client.post("/auth/password/forgot/verify", json={"phone": phone, "code": code})
    assert r.status_code == 200, r.text
    return r.json()["reset_token"]


async def _live_refresh_tokens(user_id: str) -> int:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(RefreshToken).where(
            RefreshToken.user_id == user_id, RefreshToken.revoked_at.is_(None),
        ))).scalars().all()
    return len(rows)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ── Forgot -> verify -> reset ────────────────────────────────────────────────

class TestForgottenPassword:
    async def test_the_whole_way_back_in(self, client):
        acct = await _account(client)
        token = await _reset_token(client, acct["phone"])

        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": NEW})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["user_id"] == acct["user_id"]
        assert decode_access_token(body["access_token"])["sub"] == acct["user_id"]
        assert body["refresh_token"]

        assert await _login(client, acct["phone"], NEW) == 200
        assert await _login(client, acct["phone"], OLD) == 401

    async def test_every_other_phone_is_signed_out(self, client):
        acct = await _account(client)
        token = await _reset_token(client, acct["phone"])
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": NEW})
        assert r.status_code == 200

        # The refresh token from before the reset no longer renews anything;
        # the one the reset handed back does.
        r = await client.post("/auth/token/refresh", json={"refresh_token": acct["refresh_token"]})
        assert r.status_code == 401
        assert await _live_refresh_tokens(acct["user_id"]) == 1
        r = await client.post("/auth/token/refresh",
                              json={"refresh_token": (await client.post(
                                  "/auth/login", json={"phone": acct["phone"], "password": NEW},
                              )).json()["refresh_token"]})
        assert r.status_code == 200

    async def test_the_number_is_verified_by_the_code(self, client):
        acct = await _account(client)
        token = await _reset_token(client, acct["phone"])
        await client.post("/auth/password/reset", json={"reset_token": token, "new_password": NEW})
        async with AsyncSessionLocal() as db:
            user = await db.get(User, acct["user_id"])
        assert user.phone_verified is True

    async def test_a_local_spelling_of_the_number_works(self, client):
        phone = "+2547" + str(uuid.uuid4().int)[:8]
        await _account(client, phone=phone)
        local = "0" + phone[4:]
        token = await _reset_token(client, local)
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": NEW})
        assert r.status_code == 200
        assert await _login(client, phone, NEW) == 200

    async def test_an_unknown_number_gets_no_code(self, client):
        r = await client.post("/auth/password/forgot", json={"phone": _phone()})
        assert r.status_code == 404
        assert "debug_code" not in r.json()

    async def test_a_wrong_code_is_refused(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/forgot", json={"phone": acct["phone"]})
        code = r.json()["debug_code"]
        wrong = "0" * len(code) if code != "0" * len(code) else "1" * len(code)
        r = await client.post("/auth/password/forgot/verify",
                              json={"phone": acct["phone"], "code": wrong})
        assert r.status_code == 400
        assert "reset_token" not in r.json()

    async def test_a_reset_token_works_once(self, client):
        acct = await _account(client)
        token = await _reset_token(client, acct["phone"])
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": NEW})
        assert r.status_code == 200
        # Replayed - by whoever saw it go past - to set a password of theirs.
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": "Attack3r!"})
        assert r.status_code == 400
        assert await _login(client, acct["phone"], NEW) == 200
        assert await _login(client, acct["phone"], "Attack3r!") == 401

    async def test_a_too_short_password_is_refused_and_the_token_kept(self, client):
        acct = await _account(client)
        token = await _reset_token(client, acct["phone"])
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": "abc"})
        assert r.status_code == 422
        # Nothing changed, so the same token still goes through.
        r = await client.post("/auth/password/reset",
                              json={"reset_token": token, "new_password": NEW})
        assert r.status_code == 200


class TestCodesAndTokensKeepToTheirPurpose:
    async def test_a_registration_code_cannot_reset_a_password(self, client):
        """Signup codes go to numbers with no account behind them yet; a
        number that already has one is refused there (409). So the only
        registration code a number can hold is one asked for before its
        account existed - and it must not unlock that account."""
        phone = _phone()
        r = await client.post("/auth/otp/request", json={"phone": phone})
        assert r.status_code == 200
        signup_code = r.json()["debug_code"]
        await _account(client, phone=phone)

        r = await client.post("/auth/password/forgot/verify",
                              json={"phone": phone, "code": signup_code})
        assert r.status_code == 400

    async def test_a_reset_code_cannot_verify_a_signup(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/forgot", json={"phone": acct["phone"]})
        code = r.json()["debug_code"]
        r = await client.post("/auth/otp/verify", json={"phone": acct["phone"], "code": code})
        assert r.status_code == 400
        assert "phone_verify_token" not in r.json()

    async def test_a_phone_verify_token_cannot_reset_a_password(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/reset", json={
            "reset_token": create_phone_verify_token(acct["phone"]), "new_password": NEW,
        })
        assert r.status_code == 400
        assert await _login(client, acct["phone"], OLD) == 200

    async def test_a_reset_token_is_not_an_access_token(self, client):
        acct = await _account(client)
        token = create_password_reset_token(acct["phone"], None)
        r = await client.get("/auth/me", headers=_auth(token))
        assert r.status_code == 401


# ── Change (signed in) ───────────────────────────────────────────────────────

class TestChangePassword:
    async def test_changes_it_and_signs_other_phones_out(self, client):
        acct = await _account(client)
        other_phone = await client.post("/auth/login",
                                        json={"phone": acct["phone"], "password": OLD})
        r = await client.post("/auth/password/change",
                              json={"current_password": OLD, "new_password": NEW},
                              headers=_auth(acct["access_token"]))
        assert r.status_code == 200, r.text
        assert r.json()["refresh_token"]

        assert await _login(client, acct["phone"], NEW) == 200
        assert await _login(client, acct["phone"], OLD) == 401
        r = await client.post("/auth/token/refresh",
                              json={"refresh_token": other_phone.json()["refresh_token"]})
        assert r.status_code == 401

    async def test_the_current_password_must_be_right(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/change",
                              json={"current_password": "not-it", "new_password": NEW},
                              headers=_auth(acct["access_token"]))
        # Not 401: the app would take that for an expired session.
        assert r.status_code == 400
        assert await _login(client, acct["phone"], OLD) == 200
        assert await _live_refresh_tokens(acct["user_id"]) >= 1

    async def test_the_new_password_must_differ(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/change",
                              json={"current_password": OLD, "new_password": OLD},
                              headers=_auth(acct["access_token"]))
        assert r.status_code == 400

    async def test_a_too_short_password_is_refused(self, client):
        acct = await _account(client)
        r = await client.post("/auth/password/change",
                              json={"current_password": OLD, "new_password": "abc"},
                              headers=_auth(acct["access_token"]))
        assert r.status_code == 422
        assert await _login(client, acct["phone"], OLD) == 200

    async def test_needs_a_signed_in_account(self, client):
        r = await client.post("/auth/password/change",
                              json={"current_password": OLD, "new_password": NEW})
        assert r.status_code == 401
