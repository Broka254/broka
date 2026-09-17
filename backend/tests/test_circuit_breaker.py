"""Tests for the circuit breaker (new in v4.0)."""
import asyncio
import pytest
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError, CircuitState

class TestCircuitBreaker:
    @pytest.mark.asyncio
    async def test_closed_allows_calls(self):
        b = CircuitBreaker("t", failure_threshold=3, recovery_timeout=1)
        async def ok():
            return "ok"
        assert await b.call(ok) == "ok"

    @pytest.mark.asyncio
    async def test_opens_after_threshold(self):
        b = CircuitBreaker("t", failure_threshold=3, recovery_timeout=60)
        async def fail(): raise ValueError("x")
        for _ in range(3):
            with pytest.raises(ValueError):
                await b.call(fail)
        assert b.state == CircuitState.OPEN

    @pytest.mark.asyncio
    async def test_open_rejects_immediately(self):
        b = CircuitBreaker("t", failure_threshold=1, recovery_timeout=60)
        async def fail(): raise ValueError("x")
        with pytest.raises(ValueError):
            await b.call(fail)
        with pytest.raises(CircuitOpenError):
            await b.call(fail)

    @pytest.mark.asyncio
    async def test_success_resets_failure_count(self):
        b = CircuitBreaker("t", failure_threshold=5, recovery_timeout=60)
        async def fail(): raise ValueError("x")
        async def ok(): return "ok"
        for _ in range(2):
            with pytest.raises(ValueError):
                await b.call(fail)
        await b.call(ok)
        assert b._failure_count == 0

    @pytest.mark.asyncio
    async def test_half_open_after_timeout(self):
        b = CircuitBreaker("t", failure_threshold=1, recovery_timeout=0.05)
        async def fail(): raise ValueError("x")
        with pytest.raises(ValueError):
            await b.call(fail)
        await asyncio.sleep(0.1)
        await b._maybe_transition()
        assert b.state == CircuitState.HALF_OPEN

    def test_manual_reset(self):
        b = CircuitBreaker("t", failure_threshold=5, recovery_timeout=60)
        b._state = CircuitState.OPEN
        b.reset()
        assert b.state == CircuitState.CLOSED

    def test_stats_keys(self):
        b = CircuitBreaker("mybreaker")
        s = b.stats()
        assert {"name", "state", "failure_count", "success_count", "opened_at"} <= s.keys()
