"""
BROKA - Fraud Engine Unit Tests (v3.0)
Tests trust score computation and trust band classification.
Run: pytest backend/tests/test_fraud.py -v
"""

import pytest
from api.core.fraud import trust_band


class TestTrustBand:
    def test_trusted(self):
        assert trust_band(100) == "trusted"
        assert trust_band(80)  == "trusted"

    def test_standard(self):
        assert trust_band(79)  == "standard"
        assert trust_band(50)  == "standard"

    def test_at_risk(self):
        assert trust_band(49)  == "at_risk"
        assert trust_band(20)  == "at_risk"

    def test_high_risk(self):
        assert trust_band(19)  == "high_risk"
        assert trust_band(0)   == "high_risk"


class TestRateLimiter:
    @pytest.mark.asyncio
    async def test_rate_limiter_allows_within_limit(self):
        from api.core.rate_limit import RateLimiter
        limiter = RateLimiter("test_allow", limit=3, window_seconds=60)
        for i in range(3):
            await limiter.check_and_record(f"user_test_{i}")  # different users

    @pytest.mark.asyncio
    async def test_rate_limiter_blocks_excess(self):
        from api.core.rate_limit import RateLimiter
        from fastapi import HTTPException
        limiter = RateLimiter("test_block", limit=2, window_seconds=60)
        await limiter.check_and_record("user_block")
        await limiter.check_and_record("user_block")
        with pytest.raises(HTTPException) as exc_info:
            await limiter.check_and_record("user_block")
        assert exc_info.value.status_code == 429


class TestEventBus:
    @pytest.mark.asyncio
    async def test_event_published_to_handler(self, monkeypatch):
        from api.core.events import publish, UserRegistered, subscribe
        from api.core.config import settings
        monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))
        results = []

        @subscribe(UserRegistered)
        async def handler(event: UserRegistered):
            results.append(event.user_id)

        await publish(UserRegistered(user_id="test-123", email="t@t.ke", name="Test"))
        import asyncio
        await asyncio.sleep(0.05)  # let background task run
        assert "test-123" in results
