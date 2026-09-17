"""Tests for idempotency key middleware (new in v4.0)."""
import json
import pytest
from unittest.mock import AsyncMock, patch
from api.core.idempotency import idempotency_guard, IdempotencyResult

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

class TestIdempotencyGuard:
    @pytest.mark.asyncio
    async def test_no_key_passthrough(self):
        r = await idempotency_guard(x_idempotency_key=None)
        assert r.key is None and not r.cached

    @pytest.mark.asyncio
    async def test_redis_disabled_miss(self):
        with patch("api.core.config.settings") as s:
            s.redis_enabled = False
            r = await idempotency_guard(x_idempotency_key="k1")
        assert not r.cached

    @pytest.mark.asyncio
    async def test_cache_hit(self):
        client = AsyncMock()
        client.get = AsyncMock(return_value=json.dumps({"deal": "d1"}))
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", return_value=client):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await idempotency_guard(x_idempotency_key="hit-key")
        assert r.cached and r.response == {"deal": "d1"}

    @pytest.mark.asyncio
    async def test_cache_miss(self):
        client = AsyncMock()
        client.get = AsyncMock(return_value=None)
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", return_value=client):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await idempotency_guard(x_idempotency_key="miss-key")
        assert not r.cached

    @pytest.mark.asyncio
    async def test_redis_error_fails_open(self):
        with patch("api.core.config.settings") as s, patch("redis.asyncio.from_url", side_effect=ConnectionError):
            s.redis_enabled = True
            s.redis_url = "redis://localhost"
            r = await idempotency_guard(x_idempotency_key="any")
        assert not r.cached  # fail-open
