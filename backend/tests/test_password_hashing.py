"""Password hashing: what bcrypt is given, and what it costs the event loop.

Three faults, each pinned by a class below:

  * Passwords were cut at 72 CHARACTERS. bcrypt reads 72 BYTES, and bcrypt 5
    raises instead of truncating, so a password with emoji or other non-ASCII
    text past that length was a 500 at signup - and could never log in.
  * hashpw/checkpw ran directly in async handlers: ~250 ms of CPU during
    which the worker's event loop served no one. Every login stalled every
    other request, WebSockets and M-Pesa callbacks included.
  * A login for a phone with no account answered without hashing anything,
    in about a millisecond; a wrong password took ~250 ms. The difference
    told anyone with a list of numbers which of them are on BROKA.
"""
import asyncio
import time
import uuid
from unittest.mock import patch

import bcrypt
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import init_db, reset_engine
from api.security import (
    hash_password,
    hash_password_async,
    verify_login_password,
    verify_password,
)
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_password_hashing.db"
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


async def _register(client, phone: str, password: str):
    req = await client.post("/auth/otp/request", json={"phone": phone})
    assert req.status_code == 200, req.text
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": req.json()["debug_code"]})
    assert verify.status_code == 200, verify.text
    return await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"],
        "name": "Wanjiru Test",
        "password": password,
        "lat": -1.2864,
        "lng": 36.8172,
    })


# 30 emoji: 30 characters, 120 bytes.
EMOJI_PASSWORD = "\U0001F600" * 30


class TestPasswordsAreCutInBytes:
    @pytest.mark.asyncio
    async def test_long_non_ascii_password_can_sign_up_and_log_in(self, client):
        phone = _phone()
        reg = await _register(client, phone, EMOJI_PASSWORD)
        assert reg.status_code == 201, reg.text
        login = await client.post("/auth/login", json={"phone": phone, "password": EMOJI_PASSWORD})
        assert login.status_code == 200, login.text

    def test_hashes_made_before_the_fix_still_verify(self):
        ascii_short = "Passw0rd!x"
        ascii_long = "p" * 100                 # old code cut it at 72 chars = 72 bytes
        swahili = "Nenosiri-la-siri-" * 6      # ASCII, > 72 characters
        # What the old code stored, byte for byte: plain[:72].encode(). For
        # non-ASCII passwords bcrypt < 5 truncated the result to 72 bytes.
        for pw in (ascii_short, ascii_long, swahili):
            old = bcrypt.hashpw(pw[:72].encode(), bcrypt.gensalt(4)).decode()
            assert verify_password(pw, old), pw
            assert not verify_password("q" + pw[1:], old), pw
        old_emoji = bcrypt.hashpw(EMOJI_PASSWORD[:72].encode()[:72], bcrypt.gensalt(4)).decode()
        assert verify_password(EMOJI_PASSWORD, old_emoji)

    def test_the_cut_is_never_more_than_72_bytes(self):
        for pw in (EMOJI_PASSWORD, "é" * 100, "a" * 10_000, "\ud800" * 5):
            hashed = hash_password(pw)
            assert verify_password(pw, hashed)

    def test_unreadable_hash_is_a_mismatch_not_an_error(self):
        assert verify_password("anything", "not-a-bcrypt-hash") is False
        assert verify_password("anything", "") is False


class TestHashingLeavesTheEventLoopFree:
    @staticmethod
    async def _longest_stall_during(work) -> tuple[float, float]:
        """Run `work` alongside a coroutine that wakes every 5 ms; return
        (longest gap between its wake-ups, how long `work` took)."""
        gaps: list[float] = []
        done = asyncio.Event()

        async def ticker():
            last = time.perf_counter()
            while not done.is_set():
                await asyncio.sleep(0.005)
                now = time.perf_counter()
                gaps.append(now - last)
                last = now

        tick = asyncio.create_task(ticker())
        await asyncio.sleep(0.02)                 # ticker is running
        started = time.perf_counter()
        await work()
        took = time.perf_counter() - started
        done.set()
        await tick
        return max(gaps), took

    @pytest.mark.asyncio
    async def test_login_does_not_stall_other_requests(self, client):
        phone, password = _phone(), "SecurePass123!"
        assert (await _register(client, phone, password)).status_code == 201

        async def login():
            resp = await client.post("/auth/login", json={"phone": phone, "password": password})
            assert resp.status_code == 200, resp.text

        stall, took = await self._longest_stall_during(login)
        # A login is dominated by one bcrypt check. On the event loop the
        # ticker would stall for all of it; in a thread it barely notices.
        assert stall < took / 2, f"event loop stalled {stall * 1000:.0f} ms of a {took * 1000:.0f} ms login"

    @pytest.mark.asyncio
    async def test_hash_password_async_runs_off_the_loop(self):
        stall, took = await self._longest_stall_during(lambda: hash_password_async("SecurePass123!"))
        assert stall < took / 2, f"event loop stalled {stall * 1000:.0f} ms of a {took * 1000:.0f} ms hash"


class TestUnknownPhoneCostsTheSameAsAWrongPassword:
    @pytest.mark.asyncio
    async def test_login_for_a_phone_with_no_account_still_checks_a_hash(self, client):
        with patch("api.security.bcrypt.checkpw", wraps=bcrypt.checkpw) as checkpw:
            resp = await client.post("/auth/login", json={"phone": _phone(), "password": "whatever123"})
        assert resp.status_code == 401
        assert checkpw.call_count == 1

    @pytest.mark.asyncio
    async def test_unknown_and_wrong_password_answer_alike(self, client):
        phone = _phone()
        assert (await _register(client, phone, "SecurePass123!")).status_code == 201
        wrong = await client.post("/auth/login", json={"phone": phone, "password": "WrongPass123!"})
        unknown = await client.post("/auth/login", json={"phone": _phone(), "password": "WrongPass123!"})
        assert wrong.status_code == unknown.status_code == 401
        assert wrong.json() == unknown.json()

    @pytest.mark.asyncio
    async def test_verify_login_password_without_account_is_false(self):
        assert await verify_login_password("anything", None) is False
