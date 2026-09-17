"""Tests for ARQ + in-process worker infrastructure (v4.0)."""
import asyncio
import pytest
from api.core.workers import BackgroundWorker

class TestBackgroundWorker:
    @pytest.mark.asyncio
    async def test_enqueue_and_execute(self):
        results = []
        w = BackgroundWorker("t", concurrency=1, max_queue=10)
        await w.start()
        async def task(**kw): results.append(kw["v"])
        await w.enqueue(task, v="hello")
        await asyncio.sleep(0.1)
        await w.stop()
        assert "hello" in results

    @pytest.mark.asyncio
    async def test_failure_isolation(self):
        ok = []
        w = BackgroundWorker("t", concurrency=1, max_queue=10)
        await w.start()
        async def bad(**kw): raise RuntimeError("x")
        async def good(**kw): ok.append(True)
        await w.enqueue(bad)
        await w.enqueue(good)
        await asyncio.sleep(0.2)
        await w.stop()
        assert ok

    @pytest.mark.asyncio
    async def test_multiple_concurrent_tasks(self):
        results = []
        w = BackgroundWorker("t", concurrency=4, max_queue=50)
        await w.start()
        async def collect(**kw):
            await asyncio.sleep(0.01)
            results.append(kw["n"])
        for i in range(10):
            await w.enqueue(collect, n=i)
        await asyncio.sleep(0.5)
        await w.stop()
        assert sorted(results) == list(range(10))
