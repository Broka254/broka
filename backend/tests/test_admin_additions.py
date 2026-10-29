"""Admin additions: SMS cost hook, timeseries, detail reads, users search.

Covers the smaller contracts: exactly one cost row per provider handoff,
the timeseries shape/bucketing, the three detail endpoints (200 + 404),
and the users search filter.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.core import sms as sms_module
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.models.dispute import CaseBranch, CaseState, DisputeCase
from api.models.platform_cost import CostKind, PlatformCost
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_additions.db"
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
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def _mkuser(*, admin=False, name="U", phone=None, email=None) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name=name,
        phone=phone or f"+2547{tag}",
        email=email or f"{tag}@add.test",
        password_hash="x",
        is_admin=admin,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _h(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


@pytest.mark.asyncio
async def test_sms_send_records_exactly_one_cost_row():
    async with AsyncSessionLocal() as db:
        before = int(
            (await db.execute(select(func.count(PlatformCost.id)))).scalar()
            or 0
        )
    provider = sms_module.MobitechSMS()
    with patch.object(
        provider, "_send_once", new=AsyncMock(return_value=True)
    ):
        assert await provider.send("+254700000001", "code 123") is True
    async with AsyncSessionLocal() as db:
        rows = (
            await db.execute(
                select(PlatformCost).order_by(PlatformCost.id.desc()).limit(2)
            )
        ).scalars().all()
        assert len(rows) >= 1
        assert rows[0].kind == CostKind.SMS
        assert rows[0].provider == "mobitech"
        assert rows[0].estimated is False
        after = int(
            (await db.execute(select(func.count(PlatformCost.id)))).scalar()
            or 0
        )
    assert after == before + 1
    # A failed send records nothing.
    with patch.object(
        provider, "_send_once", new=AsyncMock(return_value=False)
    ):
        assert await provider.send("+254700000001", "code 123") is False
    async with AsyncSessionLocal() as db:
        after2 = int(
            (await db.execute(select(func.count(PlatformCost.id)))).scalar()
            or 0
        )
    assert after2 == after


@pytest.mark.asyncio
async def test_timeseries_shape_and_bucketing(client):
    admin = await _mkuser(admin=True)
    # `to` carries a forward buffer: the admin row was just inserted with a
    # microsecond timestamp, and a truncated `now` captured afterwards can
    # still sort before it, excluding the row from [from, to).
    now = datetime.utcnow() + timedelta(minutes=1)
    r = await client.get(
        "/admin/analytics/timeseries",
        params={
            "from": (now - timedelta(days=3)).isoformat() + "Z",
            "to": now.isoformat() + "Z",
            "bucket": "day",
        },
        headers=_h(admin),
    )
    assert r.status_code == 200
    body = r.json()
    assert set(body["series"]) == {
        "signups",
        "listings_created",
        "deals_agreed",
        "gmv_minor",
        "disputes_opened",
        "revenue_minor",
    }
    for key, points in body["series"].items():
        assert len(points) >= 3, key
        assert all(set(p) == {"t", "v"} for p in points)
        assert all(isinstance(p["v"], int) for p in points)
    # Signups counted today include the admin just created.
    assert sum(p["v"] for p in body["series"]["signups"]) >= 1


@pytest.mark.asyncio
async def test_detail_endpoints_200_and_404(client):
    admin = await _mkuser(admin=True)
    h = _h(admin)
    seller = await _mkuser(name="Seller")
    async with AsyncSessionLocal() as db:
        listing = Listing(
            seller_id=seller.id,
            name="Test phone",
            description="A phone",
            category="Electronics",
            price=20000.0,
            lat=0.0,
            lng=0.0,
        )
        db.add(listing)
        store = Store(
            owner_id=seller.id, name="Test store", slug=f"store-{uuid.uuid4().hex[:8]}"
        )
        db.add(store)
        await db.commit()
        await db.refresh(listing)
        await db.refresh(store)
        listing_id, store_id = listing.id, store.id

    r = await client.get(f"/admin/listings/{listing_id}", headers=h)
    assert r.status_code == 200
    assert r.json()["id"] == listing_id
    assert r.json()["name"] == "Test phone"
    assert "description" in r.json()

    r = await client.get("/admin/listings/no-such-id", headers=h)
    assert r.status_code == 404

    r = await client.get(f"/admin/stores/{store_id}", headers=h)
    assert r.status_code == 200
    assert r.json()["id"] == store_id

    r = await client.get("/admin/stores/no-such-id", headers=h)
    assert r.status_code == 404

    r = await client.get("/admin/disputes/no-such-id", headers=h)
    assert r.status_code == 404


@pytest.mark.asyncio
async def test_users_search_filters(client):
    admin = await _mkuser(admin=True)
    h = _h(admin)
    unique = f"Zeddy-{uuid.uuid4().hex[:6]}"
    await _mkuser(name=unique)
    r = await client.get("/admin/users", params={"search": unique}, headers=h)
    assert r.status_code == 200
    assert any(unique in (u["name"] or "") for u in r.json())
    r2 = await client.get(
        "/admin/users", params={"search": "no-such-person-xyz"}, headers=h
    )
    assert r2.status_code == 200
    assert r2.json() == []
