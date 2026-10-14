"""GET /disputes/v2/stats/summary is public, so its aggregate must never run
per request - with Redis or without it.

It used to be gated only by its own Redis cache; with Redis unset (a
supported configuration) every anonymous request missed and loaded every
closed case in 90 days. See core.workers.get_dispute_summary.
"""
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

import api.core.workers as workers
from api.core.config import settings
from api.database import AsyncSessionLocal, Deal, DealStatus, Listing, User, init_db, reset_engine
from api.models.dispute import CaseState, DisputeCase
from main import app


@pytest.fixture(autouse=True)
def _no_redis_and_a_cold_memo(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))
    monkeypatch.setattr(workers, "_dispute_summary_memo", None)


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_dispute_summary.db"
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


@pytest.fixture
def counting_compute(monkeypatch):
    calls = {"n": 0}
    real = workers._compute_dispute_summary

    async def counted():
        calls["n"] += 1
        await asyncio.sleep(0.01)  # long enough for concurrent callers to pile up
        return await real()

    monkeypatch.setattr(workers, "_compute_dispute_summary", counted)
    return calls


class TestGate:
    @pytest.mark.asyncio
    async def test_many_requests_without_redis_compute_once(self, client, counting_compute):
        for _ in range(20):
            r = await client.get("/disputes/v2/stats/summary")
            assert r.status_code == 200
        assert counting_compute["n"] == 1

    @pytest.mark.asyncio
    async def test_a_cold_burst_computes_once(self, client, counting_compute):
        responses = await asyncio.gather(
            *[client.get("/disputes/v2/stats/summary") for _ in range(15)]
        )
        assert all(r.status_code == 200 for r in responses)
        assert counting_compute["n"] == 1

    @pytest.mark.asyncio
    async def test_a_failing_database_is_not_retried_per_request(self, client, monkeypatch):
        calls = {"n": 0}

        async def broken():
            calls["n"] += 1
            raise RuntimeError("database down")

        monkeypatch.setattr(workers, "_compute_dispute_summary", broken)
        for _ in range(5):
            r = await client.get("/disputes/v2/stats/summary")
            assert r.status_code == 200
            assert r.json()["sample_size"] == 0  # the null payload, not a 500
        assert calls["n"] == 1

    @pytest.mark.asyncio
    async def test_a_stale_memo_recomputes(self, client, counting_compute, monkeypatch):
        await client.get("/disputes/v2/stats/summary")
        monkeypatch.setattr(workers, "_dispute_summary_memo", (0.0, {"stale": True}))
        await client.get("/disputes/v2/stats/summary")
        assert counting_compute["n"] == 2

    @pytest.mark.asyncio
    async def test_read_only_callers_never_compute(self, counting_compute):
        assert await workers.get_dispute_summary(compute_if_stale=False) is None
        assert counting_compute["n"] == 0


class TestFigures:
    @pytest.mark.asyncio
    async def test_empty_window_is_nulls_not_zeroes(self):
        async with AsyncSessionLocal() as db:
            from sqlalchemy import delete
            await db.execute(delete(DisputeCase))
            await db.commit()
        payload = await workers._compute_dispute_summary()
        assert payload["sample_size"] == 0
        assert payload["resolved_within_24h_pct"] is None
        assert payload["computed_at"] is not None

    @pytest.mark.asyncio
    async def test_figures_from_closed_cases(self):
        tag = uuid.uuid4().hex[:8]
        now = datetime.utcnow()
        async with AsyncSessionLocal() as db:
            from sqlalchemy import delete
            await db.execute(delete(DisputeCase))
            s = User(name="s", phone=f"+2547{tag}1", password_hash="x")
            b = User(name="b", phone=f"+2547{tag}2", password_hash="x")
            db.add_all([s, b])
            await db.commit()
            listing = Listing(seller_id=s.id, name="n", category="Electronics", price=10, lat=0, lng=0)
            db.add(listing)
            await db.commit()
            deal = Deal(listing_id=listing.id, buyer_id=b.id, seller_id=s.id,
                        agreed_price=10, commission=0.3, status=DealStatus.refunded)
            db.add(deal)
            await db.commit()
            for hours, state, action in [
                (10, CaseState.closed_refunded, "refunded"),
                (20, CaseState.closed_released, "released"),
                (48, CaseState.closed_refunded, None),
            ]:
                db.add(DisputeCase(
                    deal_id=deal.id, opener_id=b.id, state=state, fund_action=action,
                    created_at=now - timedelta(hours=hours + 1),
                    closed_at=now - timedelta(hours=1),
                ))
            # Outside the 90-day window, and an open case: both ignored.
            db.add(DisputeCase(deal_id=deal.id, opener_id=b.id, state=CaseState.closed_refunded,
                               created_at=now - timedelta(days=120), closed_at=now - timedelta(days=100)))
            db.add(DisputeCase(deal_id=deal.id, opener_id=b.id, state=CaseState.open))
            await db.commit()

        payload = await workers._compute_dispute_summary()
        assert payload["sample_size"] == 3
        assert payload["resolved_within_24h_pct"] == round(100 * 2 / 3, 1)
        assert payload["median_resolution_hours"] == 20.0
        assert payload["escrow_success_rate_pct"] == round(100 * 2 / 3, 1)
