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


class TestTheSweepOutlivesAFailedPass:
    @pytest.mark.asyncio
    async def test_a_pass_that_cannot_take_its_lease_does_not_end_the_sweep(self, monkeypatch):
        """The lease's database connection failing (the advisory lock, a
        pool timeout) used to raise out of the loop: the sweep task ended
        for good, and orders past their deadline held their units until
        the next deploy. Now that pass is skipped and the next one runs."""
        from contextlib import asynccontextmanager
        from api.core import workers

        leases = []

        @asynccontextmanager
        async def flaky_lease(name):
            leases.append(name)
            if len(leases) == 1:
                raise ConnectionRefusedError("database unreachable")
            yield True

        async def noop(*args, **kwargs):
            return None

        ran = []

        async def store_order_sweep(*args, **kwargs):
            ran.append("store_orders")

        for name in (
            "task_check_deal_timers", "task_reconcile_econfirm_escrows",
            "task_reconcile_zetupay_payments", "task_reconcile_mpesa", "task_check_dispute_timers",
            "task_refresh_dispute_summary_cache", "task_recompute_dcr_and_leaks",
            "task_refresh_store_ratings", "task_retrain_ml_models", "task_check_call_expiry",
            "task_backfill_media", "task_collect_abandoned_media", "task_expire_buy_agent_watches",
            "task_sync_listing_stock", "task_notify_expiry_alerts",
        ):
            monkeypatch.setattr(workers, name, noop)
        monkeypatch.setattr("api.domains.service_costs.service.run_cost_maintenance", noop)
        monkeypatch.setattr("api.core.admin_reports.generate_due_reports", noop)
        monkeypatch.setattr(workers, "task_store_order_sweep", store_order_sweep)
        monkeypatch.setattr(workers, "scheduler_lease", flaky_lease)

        sleeps = []

        async def two_passes(seconds):
            sleeps.append(seconds)
            if len(sleeps) == 2:
                workers._sweep_running = False

        monkeypatch.setattr(workers.asyncio, "sleep", two_passes)
        await workers._periodic_sweep_loop(300)

        assert leases == ["broka:scheduler:periodic"] * 2
        assert sleeps == [300, 300]
        assert ran == ["store_orders"]
