"""Admin endpoints that answered wrongly, each with the case that exposed it.

  * flagging a user whose trust score was 0 raised it to 70;
  * the flag's -30 disappeared at the next trust recomputation;
  * recompute-trust on an unknown id returned 200 and wrote an audit row;
  * the open fraud queue (?resolved=false) hid rows whose `resolved` is NULL;
  * the M-Pesa health line said "configured" about credentials that were not;
  * a media backfill run left no audit row;
  * the "deals agreed" series counted cancelled and negotiating deals;
  * ranges longer than 500 buckets were cut short without a word.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text

from api.core.config import settings
from api.core.fraud import FLAG_PENALTY, compute_trust_score
from api.database import (
    AsyncSessionLocal, AuditLog, Deal, DealStatus, FraudEvent, Listing, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_admin_hardening_{uuid.uuid4().hex}.db"
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


async def _user(*, admin=False, trust_score=None) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(name=f"U {tag}", phone=f"+2547{tag[:8]}", email=f"{tag}@hardening.test",
                password_hash="x", is_admin=admin, trust_score=trust_score)
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _h(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


@pytest.mark.asyncio
async def test_flagging_a_zero_score_user_does_not_raise_their_score(client):
    admin, risky = await _user(admin=True), await _user(trust_score=0)
    r = await client.post(f"/admin/users/{risky.id}/flag", json={"reason": "confirmed scam"},
                          headers=_h(admin))
    assert r.status_code == 200, r.text
    assert r.json()["trust_score"] == 0


@pytest.mark.asyncio
async def test_a_recomputed_score_keeps_the_flag_penalty():
    user = await _user()
    async with AsyncSessionLocal() as db:
        unflagged = await compute_trust_score(user.id, db)
        row = (await db.execute(select(User).where(User.id == user.id))).scalar_one()
        row.is_flagged = True
        await db.flush()
        flagged = await compute_trust_score(user.id, db)
        await db.rollback()
    assert flagged == max(0, unflagged - FLAG_PENALTY)
    assert flagged < unflagged


@pytest.mark.asyncio
async def test_recompute_trust_for_an_unknown_user_is_a_404(client):
    admin = await _user(admin=True)
    r = await client.post("/admin/users/no-such-user/recompute-trust", headers=_h(admin))
    assert r.status_code == 404
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(AuditLog).where(
            AuditLog.action == "user_trust_recomputed", AuditLog.resource_id == "no-such-user",
        ))).scalars().all()
    assert rows == []


@pytest.mark.asyncio
async def test_the_open_fraud_queue_includes_unset_resolution(client):
    admin, subject = await _user(admin=True), await _user()
    async with AsyncSessionLocal() as db:
        event = FraudEvent(user_id=subject.id, reason="velocity", triggered_by="engine")
        db.add(event)
        await db.commit()
        event_id = event.id
    async with AsyncSessionLocal() as db:
        await db.execute(text("UPDATE fraud_events SET resolved = NULL WHERE id = :id"), {"id": event_id})
        await db.commit()
    open_queue = await client.get("/admin/fraud-events?resolved=false", headers=_h(admin))
    assert event_id in [e["id"] for e in open_queue.json()]
    resolved_queue = await client.get("/admin/fraud-events?resolved=true", headers=_h(admin))
    assert event_id not in [e["id"] for e in resolved_queue.json()]


@pytest.mark.asyncio
async def test_mpesa_health_describes_what_is_actually_configured(client):
    admin = await _user(admin=True)
    before = (settings.mpesa_consumer_key, settings.mpesa_consumer_secret, settings.mpesa_callback_secret)
    object.__setattr__(settings, "mpesa_consumer_key", "")
    object.__setattr__(settings, "mpesa_consumer_secret", "")
    object.__setattr__(settings, "mpesa_callback_secret", "callback-secret")
    try:
        r = await client.get("/admin/health/services", headers=_h(admin))
    finally:
        object.__setattr__(settings, "mpesa_consumer_key", before[0])
        object.__setattr__(settings, "mpesa_consumer_secret", before[1])
        object.__setattr__(settings, "mpesa_callback_secret", before[2])
    assert r.status_code == 200, r.text
    mpesa = next(p for p in r.json()["providers"] if p["name"] == "mpesa")
    assert mpesa["status"] == "not_configured"
    assert mpesa["detail"] == (
        "Daraja consumer key or secret is not configured; callback secret is configured")


@pytest.mark.asyncio
async def test_a_media_backfill_run_is_audited(client, monkeypatch):
    from api.domains.media import backfill

    async def fake_pass(rows_per_kind=50, time_budget=60.0):
        return {"listings": 0, "stores": 0, "users": 0}

    async def fake_pending():
        return {"listings": 0}

    monkeypatch.setattr(backfill, "run_backfill_pass", fake_pass)
    monkeypatch.setattr(backfill, "pending_counts", fake_pending)
    admin = await _user(admin=True)
    r = await client.post("/admin/media/backfill?rows_per_kind=5", headers=_h(admin))
    assert r.status_code == 200, r.text
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(AuditLog).where(
            AuditLog.action == "media_backfill_run", AuditLog.actor_id == admin.id,
        ))).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_deals_agreed_series_leaves_out_unagreed_deals(client):
    admin, seller, buyer = await _user(admin=True), await _user(), await _user()
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller.id, name="Sofa", category="Furniture", price=9000.0,
                          lat=-1.29, lng=36.82)
        db.add(listing)
        await db.flush()
        for status in (DealStatus.agreed, DealStatus.cancelled, DealStatus.negotiating):
            db.add(Deal(listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
                        agreed_price=9000.0, commission=0.0, status=status))
        await db.commit()
    now = datetime.utcnow() + timedelta(minutes=1)
    r = await client.get("/admin/analytics/timeseries", headers=_h(admin), params={
        "from": (now - timedelta(days=2)).isoformat() + "Z", "to": now.isoformat() + "Z",
        "bucket": "day"})
    assert r.status_code == 200, r.text
    series = r.json()["series"]
    assert sum(p["v"] for p in series["deals_agreed"]) == 1
    assert sum(p["v"] for p in series["gmv_minor"]) == 900_000


@pytest.mark.asyncio
@pytest.mark.parametrize("path", ["/admin/analytics/timeseries", "/admin/revenue"])
async def test_a_range_too_long_for_its_buckets_is_refused(client, path):
    admin = await _user(admin=True)
    r = await client.get(path, headers=_h(admin), params={
        "from": "2020-01-01T00:00:00Z", "to": "2023-01-01T00:00:00Z", "bucket": "day"})
    assert r.status_code == 422
    assert "buckets" in r.json()["detail"]
    ok = await client.get(path, headers=_h(admin), params={
        "from": "2020-01-01T00:00:00Z", "to": "2023-01-01T00:00:00Z", "bucket": "month"})
    assert ok.status_code == 200
