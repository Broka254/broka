"""The Redis sliding-window limiter - the one production actually runs.

Pins three fixes:
  * a rejected request is not recorded, so a client retrying through its
    429s recovers once the window passes instead of extending its lockout;
  * a burst of concurrent requests lets exactly `limit` through;
  * a Redis failure falls back to in-process limiting rather than letting
    every request through (the old fail-open dropped login/OTP brute-force
    protection for the length of any Redis blip).

Real-Redis cases run when REDIS_URL is reachable (CI provides a service).
"""
import asyncio
import os
import uuid

import pytest
from fastapi import HTTPException

from api.core.rate_limit import RedisRateLimiter


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
needs_redis = pytest.mark.skipif(REAL_REDIS is None, reason="needs a reachable REDIS_URL")


def _limiter(limit: int, window: int = 60) -> RedisRateLimiter:
    return RedisRateLimiter(f"test_{uuid.uuid4().hex[:8]}", limit, window, REAL_REDIS or "redis://127.0.0.1:1/0")


async def _passes(limiter, ident) -> bool:
    try:
        await limiter.check_and_record(ident)
        return True
    except HTTPException as exc:
        assert exc.status_code == 429
        return False


@needs_redis
class TestAgainstRealRedis:
    @pytest.mark.asyncio
    async def test_allows_exactly_the_limit(self):
        lim = _limiter(3)
        assert [await _passes(lim, "u") for _ in range(5)] == [True, True, True, False, False]

    @pytest.mark.asyncio
    async def test_rejected_requests_do_not_extend_the_window(self):
        """A client that keeps retrying through its 429s must recover once
        the window since its last ACCEPTED request has passed. When rejected
        requests were recorded, each retry refilled the window and the
        lockout never ended."""
        lim = _limiter(2, window=1)
        assert await _passes(lim, "u") and await _passes(lim, "u")
        # Keep retrying for longer than the window, spread across it.
        for _ in range(5):
            await asyncio.sleep(0.3)
            if await _passes(lim, "u"):
                break  # recovered - the accepted pair aged out
        else:
            pytest.fail("still locked out 1.5s into a 1s window")

    @pytest.mark.asyncio
    async def test_a_concurrent_burst_lets_exactly_limit_through(self):
        lim = _limiter(5)
        results = await asyncio.gather(*[_passes(lim, "burst") for _ in range(20)])
        assert results.count(True) == 5

    @pytest.mark.asyncio
    async def test_identifiers_are_independent(self):
        lim = _limiter(1)
        assert await _passes(lim, "a")
        assert await _passes(lim, "b")
        assert not await _passes(lim, "a")


class TestRedisFailure:
    @pytest.mark.asyncio
    async def test_an_unreachable_redis_still_limits(self):
        # Port 1 refuses connections: every Redis call fails.
        lim = RedisRateLimiter(f"down_{uuid.uuid4().hex[:8]}", 2, 60, "redis://127.0.0.1:1/0")
        assert await _passes(lim, "u")
        assert await _passes(lim, "u")
        assert not await _passes(lim, "u"), "fell back to in-process limiting, not fail-open"
