"""Revenue endpoint: income/cost/profit math, grouping, buckets, no double count.

Pins the income-source contract (domain rows XOR zetupay_payments rows),
the estimated-cost split, and the bucket series sums.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.models.listing_payment import ListingPayment
from api.models.platform_cost import CostKind, PlatformCost
from api.models.subscription import SubscriptionPayment
from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayStatus
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_revenue.db"
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


async def _admin() -> tuple[dict, str]:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin",
        phone=f"+2547{tag}",
        email=f"{tag}@revenue.test",
        password_hash="x",
        is_admin=True,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}, user.id


def _ref() -> str:
    return "LF" + uuid.uuid4().hex[:10].upper()


@pytest_asyncio.fixture(scope="module")
async def seed():
    headers, user_id = await _admin()
    now = datetime.utcnow().replace(microsecond=0)
    async with AsyncSessionLocal() as db:
        # Succeeded Daraja listing payment: KES 200 → 20000 minor.
        db.add(
            ListingPayment(
                user_id=user_id,
                listing_id=f"listing-{uuid.uuid4().hex[:8]}",
                months=2,
                monthly_fee=100,
                listing_amount=200,
                amount=200,
                phone="+254700000001",
                status="success",
                provider="daraja",
                created_at=now - timedelta(days=2),
            )
        )
        # Failed payment: must not count.
        db.add(
            ListingPayment(
                user_id=user_id,
                listing_id=f"listing-{uuid.uuid4().hex[:8]}",
                months=2,
                monthly_fee=100,
                listing_amount=200,
                amount=500,
                phone="+254700000002",
                status="failed",
                provider="daraja",
                created_at=now - timedelta(days=2),
            )
        )
        # Succeeded Daraja subscription: KES 599.
        db.add(
            SubscriptionPayment(
                user_id=user_id,
                plan_id="pro",
                months=1,
                amount=599,
                phone="+254700000003",
                status="success",
                provider="daraja",
                created_at=now - timedelta(days=1),
            )
        )
        # ZetuPay success: KES 200 listing fee + its domain row with
        # provider='zetupay' (the same payment — must count exactly once).
        ref = _ref()
        domain = ListingPayment(
            user_id=user_id,
            listing_id=f"listing-{uuid.uuid4().hex[:8]}",
            months=2,
            monthly_fee=100,
            listing_amount=200,
            amount=200,
            phone="+254700000004",
            status="success",
            provider="zetupay",
            created_at=now - timedelta(days=1),
        )
        db.add(domain)
        await db.flush()
        db.add(
            ZetuPayPayment(
                reference=ref,
                user_id=user_id,
                purpose=Purpose.LISTING_FEE,
                amount=200,
                phone="+254700000004",
                target_id=domain.id,
                status=ZetuPayStatus.SUCCESS,
                created_at=now - timedelta(days=1),
            )
        )
        # Costs: one actual SMS row, one estimated AI row.
        db.add(
            PlatformCost(
                kind=CostKind.SMS,
                amount_minor=35,
                currency="KES",
                provider="mobitech",
                estimated=False,
                created_at=now - timedelta(days=1),
            )
        )
        db.add(
            PlatformCost(
                kind=CostKind.AI,
                amount_minor=12,
                currency="KES",
                provider="deepseek",
                estimated=True,
                created_at=now - timedelta(days=1),
            )
        )
        await db.commit()
    return headers


@pytest.mark.asyncio
async def test_income_costs_profit_math(client, seed):
    headers = seed
    now = datetime.utcnow()
    r = await client.get(
        "/admin/revenue",
        params={
            "from": (now - timedelta(days=7)).isoformat() + "Z",
            "to": (now + timedelta(days=1)).isoformat() + "Z",
            "bucket": "day",
        },
        headers=headers,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["currency"] == "KES"
    # Income: 200 (daraja listing) + 599 (daraja sub) + 200 (zetupay once)
    # = KES 999 → 99900 minor.
    assert body["income"]["total_minor"] == 99900
    by_key = {s["key"]: s for s in body["income"]["streams"]}
    assert by_key["listing_fee"]["amount_minor"] == 40000
    assert by_key["listing_fee"]["count"] == 2
    assert by_key["subscription"]["amount_minor"] == 59900
    # Costs: 35 actual SMS + 12 estimated AI + derived collection fees:
    # Daraja KES 200 → KES 3 band (300, actual), Daraja KES 599 → KES 5
    # band (500, actual), ZetuPay KES 200 → 1.5% (300, estimated).
    assert body["costs"]["total_minor"] == 47 + 300 + 500 + 300
    assert body["costs"]["estimated_minor"] == 12 + 300
    kinds = {k["key"]: k for k in body["costs"]["kinds"]}
    assert kinds["sms"]["estimated"] is False
    assert kinds["ai"]["estimated"] is True
    assert kinds["payment_fee"]["amount_minor"] == 1100
    assert kinds["payment_fee"]["count"] == 3
    assert kinds["payment_fee"]["estimated"] is True  # ZetuPay leg
    assert body["profit_minor"] == 99900 - 1147
    assert body["margin_pct"] == round((99900 - 1147) / 99900 * 100, 2)
    # Series sums reconcile with totals.
    assert sum(p["income_minor"] for p in body["series"]) == 99900
    assert sum(p["costs_minor"] for p in body["series"]) == 1147
    assert any("estimated" in n.lower() for n in body["notes"])
    assert any("derived" in n.lower() for n in body["notes"])


@pytest.mark.asyncio
async def test_empty_range_zeros(client, seed):
    headers = seed
    r = await client.get(
        "/admin/revenue",
        params={
            "from": "2020-01-01T00:00:00Z",
            "to": "2020-01-05T00:00:00Z",
            "bucket": "week",
        },
        headers=headers,
    )
    assert r.status_code == 200
    body = r.json()
    assert body["income"]["total_minor"] == 0
    assert body["costs"]["total_minor"] == 0
    assert body["profit_minor"] == 0
    assert body["margin_pct"] == 0.0
    assert body["income"]["streams"] == []
    assert all(p["income_minor"] == 0 for p in body["series"])


@pytest.mark.asyncio
async def test_revenue_requires_admin(client):
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="U",
        phone=f"+2547{tag}",
        email=f"{tag}@revenue.test",
        password_hash="x",
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    h = {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}
    r = await client.get("/admin/revenue", headers=h)
    assert r.status_code == 403
    r2 = await client.get("/admin/revenue?bucket=fortnight", headers={
        "Authorization": f"Bearer {create_access_token({'sub': user.id})}"
    })
    assert r2.status_code in (403, 422)
