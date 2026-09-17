"""Tests for the upgraded durable event bus (v4.0)."""
import asyncio
import pytest
from api.core.events import (
    BrokaEvent, subscribe, publish, _handlers,
    DealFinalized, EscrowFunded, ReviewSubmitted,
)

@pytest.fixture(autouse=True)
def clear_handlers(monkeypatch):
    # Force the in-process path: these are unit tests for the local
    # handler dispatch, not for Redis Streams delivery.
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))
    orig = dict(_handlers)
    _handlers.clear()
    yield
    _handlers.clear()
    _handlers.update(orig)

class TestInProcessEventBus:
    @pytest.mark.asyncio
    async def test_subscribe_and_receive(self):
        received = []
        @subscribe(DealFinalized)
        async def h(e): received.append(e.deal_id)
        await publish(DealFinalized(deal_id="d-1"))
        await asyncio.sleep(0.05)
        assert "d-1" in received

    @pytest.mark.asyncio
    async def test_no_handlers_no_error(self):
        await publish(EscrowFunded(deal_id="x"))

    @pytest.mark.asyncio
    async def test_multiple_handlers_both_run(self):
        calls = []
        @subscribe(ReviewSubmitted)
        async def h1(e): calls.append("h1")
        @subscribe(ReviewSubmitted)
        async def h2(e): calls.append("h2")
        await publish(ReviewSubmitted())
        await asyncio.sleep(0.05)
        assert "h1" in calls and "h2" in calls

    @pytest.mark.asyncio
    async def test_failing_handler_isolates(self):
        ok = []
        @subscribe(DealFinalized)
        async def bad(e): raise RuntimeError("boom")
        @subscribe(DealFinalized)
        async def good(e): ok.append(True)
        await publish(DealFinalized(deal_id="d"))
        await asyncio.sleep(0.1)
        assert ok

    @pytest.mark.asyncio
    async def test_type_routing(self):
        deal_r, review_r = [], []
        @subscribe(DealFinalized)
        async def d(e): deal_r.append(e)
        @subscribe(ReviewSubmitted)
        async def r(e): review_r.append(e)
        await publish(DealFinalized(deal_id="d"))
        await publish(ReviewSubmitted(deal_id="r"))
        await asyncio.sleep(0.05)
        assert len(deal_r) == 1 and len(review_r) == 1
