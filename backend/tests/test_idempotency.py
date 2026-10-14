"""Tests for the idempotency key guard.

Unit tests mock Redis to pin the protocol (reserve with SET NX, replay a
stored response, 409 while in flight, fail open on errors). The last class
runs against a REAL Redis when REDIS_URL points at one - CI provides a Redis
service - because "two concurrent requests, one execution" is a property of
the actual SET NX, not of a mock.
"""
import asyncio
import json
import os
import uuid
from unittest.mock import AsyncMock, patch

import pytest
from fastapi import HTTPException

from api.core.idempotency import _IN_FLIGHT, IdempotencyResult, reserve_idempotency_key


class TestIdempotencyResult:
    @pytest.mark.asyncio
    async def test_store_no_client_noop(self):
        r = IdempotencyResult(key="k", cached=False, response=None, redis_client=None)
        await r.store({"ok": True})  # should not raise

    @pytest.mark.asyncio
    async def test_store_calls_setex(self):
        client = AsyncMock()
        r = IdempotencyResult(key="k", cached=False, response=None, redis_client=client)
        await r.store({"status": "ok"})
        client.setex.assert_called_once()
        client.aclose.assert_called_once()

    @pytest.mark.asyncio
    async def test_release_deletes_only_our_reservation(self):
        client = AsyncMock()
        client.get = AsyncMock(return_value=_IN_FLIGHT)
        r = IdempotencyResult(key="k", cached=False, response=None, redis_client=client)
        await r.release()
        client.delete.assert_called_once()
        client.aclose.assert_called_once()

    @pytest.mark.asyncio
    async def test_release_leaves_a_stored_response_alone(self):
        client = AsyncMock()
        client.get = AsyncMock(return_value=json.dumps({"deal": "d1"}))
        r = IdempotencyResult(key="k", cached=False, response=None, redis_client=client)
        await r.release()
        client.delete.assert_not_called()


class TestIdempotencyGuard:
    @pytest.mark.asyncio
    async def test_no_key_passthrough(self):
        r = await reserve_idempotency_key(None)
        assert r.key is None and not r.cached

    @pytest.mark.asyncio
    async def test_redis_disabled_miss(self):
        with patch("api.core.config.settings") as s:
            s.redis_enabled = False
            r = await reserve_idempotency_key("k1")
        assert not r.cached

    @pytest.mark.asyncio
    async def test_cache_hit(self):
        client = AsyncMock()
        client.set = AsyncMock(return_value=None)  # SET NX refused: key exists
        client.get = AsyncMock(return_value=json.dumps({"deal": "d1"}))
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", return_value=client):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await reserve_idempotency_key("hit-key")
        assert r.cached and r.response == {"deal": "d1"}

    @pytest.mark.asyncio
    async def test_cache_miss_reserves_the_key(self):
        client = AsyncMock()
        client.set = AsyncMock(return_value=True)
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", return_value=client):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await reserve_idempotency_key("miss-key")
        assert not r.cached
        args, kwargs = client.set.call_args
        assert args[1] == _IN_FLIGHT and kwargs.get("nx") is True and kwargs.get("ex")

    @pytest.mark.asyncio
    async def test_in_flight_is_a_409(self):
        client = AsyncMock()
        client.set = AsyncMock(return_value=None)
        client.get = AsyncMock(return_value=_IN_FLIGHT)
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", return_value=client):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            with pytest.raises(HTTPException) as exc:
                await reserve_idempotency_key("busy-key")
        assert exc.value.status_code == 409

    @pytest.mark.asyncio
    async def test_redis_error_fails_open(self):
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", side_effect=ConnectionError):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await reserve_idempotency_key("any")
        assert not r.cached  # fail-open


# ── Against a real Redis ─────────────────────────────────────────────────────

def _real_redis_url():
    url = os.getenv("REDIS_URL", "")
    if not url:
        return None
    try:
        import redis
        redis.Redis.from_url(url, socket_connect_timeout=1).ping()
        return url
    except Exception:
        return None


REAL_REDIS = _real_redis_url()


@pytest.mark.skipif(REAL_REDIS is None, reason="needs a reachable REDIS_URL (CI provides one)")
class TestAgainstRealRedis:
    @pytest.fixture(autouse=True)
    def _redis_settings(self):
        with patch("api.core.config.settings") as s:
            s.redis_enabled = True
            s.redis_url = REAL_REDIS
            yield

    @pytest.mark.asyncio
    async def test_a_double_tap_runs_the_handler_once(self):
        key = f"double-tap-{uuid.uuid4().hex}"
        ran = 0

        async def request():
            nonlocal ran
            try:
                guard = await reserve_idempotency_key(key)
            except HTTPException as exc:
                return exc.status_code
            if guard.cached:
                return "replayed"
            ran += 1
            await asyncio.sleep(0.05)  # the handler is still running...
            await guard.store({"ok": True})
            return "ran"

        results = await asyncio.gather(request(), request())
        assert ran == 1
        assert sorted(map(str, results)) == ["409", "ran"]

        # Once stored, a retry replays instead of running.
        assert await request() == "replayed"
        assert ran == 1

    @pytest.mark.asyncio
    async def test_a_failed_request_frees_its_key(self):
        key = f"failed-{uuid.uuid4().hex}"
        first = await reserve_idempotency_key(key)
        await first.release()  # the handler raised
        again = await reserve_idempotency_key(key)
        assert not again.cached  # reserved afresh, not a 409
        await again.release()

    @pytest.mark.asyncio
    async def test_through_fastapi_every_way_a_request_can_end_frees_the_key(self):
        """The release has to happen in FastAPI's own dependency lifecycle,
        including for a body that fails validation - which FastAPI reports
        only after the dependencies have already run."""
        from fastapi import Depends, FastAPI
        from httpx import ASGITransport, AsyncClient
        from pydantic import BaseModel

        from api.core.idempotency import idempotency_guard

        calls = {"n": 0}

        class Body(BaseModel):
            amount: int
            fail: bool = False

        mini = FastAPI()

        @mini.post("/pay")
        async def pay(body: Body, guard=Depends(idempotency_guard)):
            if guard.cached:
                return guard.response
            calls["n"] += 1
            if body.fail:
                raise HTTPException(status_code=422, detail="rejected upstream")
            result = {"paid": body.amount}
            await guard.store(result)
            return result

        key = {"X-Idempotency-Key": f"http-{uuid.uuid4().hex}"}
        async with AsyncClient(transport=ASGITransport(app=mini), base_url="http://t") as c:
            # 1. Malformed body: rejected before the handler, key released.
            r = await c.post("/pay", json={"amount": "not-a-number"}, headers=key)
            assert r.status_code == 422
            # 2. Handler raises: key released.
            r = await c.post("/pay", json={"amount": 5, "fail": True}, headers=key)
            assert r.status_code == 422
            # 3. The corrected retry with the SAME key runs - not a 409.
            r = await c.post("/pay", json={"amount": 5}, headers=key)
            assert r.status_code == 200 and r.json() == {"paid": 5}
            # 4. And from then on it replays instead of paying again.
            r = await c.post("/pay", json={"amount": 5}, headers=key)
            assert r.status_code == 200 and r.json() == {"paid": 5}
        assert calls["n"] == 2  # the failing call and the one success


# ── Scope ────────────────────────────────────────────────────────────────────

class TestScope:
    def test_the_same_key_differs_by_user_and_path(self):
        from api.core.idempotency import redis_key
        base = redis_key("k", "user:a\nPOST\n/deal/d1/fund")
        assert base == redis_key("k", "user:a\nPOST\n/deal/d1/fund")
        assert base != redis_key("k", "user:b\nPOST\n/deal/d1/fund")
        assert base != redis_key("k", "user:a\nPOST\n/deal/d2/fund")
        # Fixed length whatever the client sent: a hex digest after the prefix.
        digest = base.removeprefix("broka:idempotency:")
        assert len(digest) == 64 and all(ch in "0123456789abcdef" for ch in digest)

    @pytest.mark.asyncio
    async def test_an_absurdly_long_key_is_refused(self):
        with pytest.raises(HTTPException) as exc:
            await reserve_idempotency_key("x" * 5000)
        assert exc.value.status_code == 400


@pytest.mark.skipif(REAL_REDIS is None, reason="needs a reachable REDIS_URL (CI provides one)")
class TestScopeAgainstRealRedis:
    """A key used to be global: the same key from another user, or for
    another deal, replayed the earlier request's response and the handler
    never ran - no STK push for the second deal."""

    @pytest.fixture(autouse=True)
    def _redis_settings(self):
        with patch("api.core.config.settings") as s:
            s.redis_enabled = True
            s.redis_url = REAL_REDIS
            yield

    @pytest.mark.asyncio
    async def test_users_and_paths_never_share_a_response(self):
        from fastapi import Depends, FastAPI
        from httpx import ASGITransport, AsyncClient

        from api.core.idempotency import idempotency_guard
        from api.security import create_access_token

        ran: list[tuple[str, str]] = []
        mini = FastAPI()

        @mini.post("/deal/{deal_id}/fund")
        async def fund(deal_id: str, guard=Depends(idempotency_guard)):
            if guard.cached:
                return guard.response
            ran.append((deal_id, guard.key))
            result = {"deal": deal_id}
            await guard.store(result)
            return result

        def auth(user: str) -> dict:
            return {"Authorization": f"Bearer {create_access_token({'sub': user})}"}

        key = {"X-Idempotency-Key": "key-A"}      # deliberately reused everywhere
        alice, bob = f"alice-{uuid.uuid4().hex}", f"bob-{uuid.uuid4().hex}"
        d1, d2 = uuid.uuid4().hex, uuid.uuid4().hex
        async with AsyncClient(transport=ASGITransport(app=mini), base_url="http://t") as c:
            r = await c.post(f"/deal/{d1}/fund", headers={**key, **auth(alice)})
            assert r.json() == {"deal": d1}
            # Alice, same key, another deal: runs, answers for THAT deal.
            r = await c.post(f"/deal/{d2}/fund", headers={**key, **auth(alice)})
            assert r.json() == {"deal": d2}
            # Bob, same key, Alice's first deal's path: runs for Bob.
            r = await c.post(f"/deal/{d1}/fund", headers={**key, **auth(bob)})
            assert r.json() == {"deal": d1}
            # Alice retrying her first request: replayed, not run again.
            r = await c.post(f"/deal/{d1}/fund", headers={**key, **auth(alice)})
            assert r.json() == {"deal": d1}
        assert len(ran) == 3
