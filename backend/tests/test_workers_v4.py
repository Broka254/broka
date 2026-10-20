"""Tests for ARQ + in-process worker infrastructure (v4.0)."""
import asyncio
import uuid
import pytest
from api.core.workers import BackgroundWorker, scheduler_lease

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


class TestSchedulerLease:
    @pytest.mark.asyncio
    async def test_only_one_replica_runs_a_named_sweep_and_releases_on_exit(self):
        name = f"broka:test:scheduler:{uuid.uuid4()}"
        async with scheduler_lease(name) as first:
            assert first is True
            async with scheduler_lease(name) as overlapping:
                assert overlapping is False

        # The lease is released by leaving the first context (or by the
        # database closing a crashed process's connection).
        async with scheduler_lease(name) as after_release:
            assert after_release is True
