"""The Payment Receipts screen's data: GET /listings/seller/{id}/receipts.

What must hold:
  * listing fees and premium plans the seller paid show up as `charges`,
    each with its M-Pesa receipt, newest first;
  * only settled ones - a pending or failed prompt is not a receipt;
  * they never count toward `total`, the money released to the seller;
  * nobody else's receipts, and no one may read another seller's.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, Listing, ListingStatus, User, init_db, reset_engine
from api.models.listing_payment import ListingPayment
from api.models.subscription import SubscriptionPayment
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_seller_receipts.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


async def _seller() -> tuple[User, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(seller: User, name: str) -> Listing:
    listing = Listing(seller_id=seller.id, name=name, description="Works well.", category="Electronics",
                      price=1500, lat=-1.28, lng=36.82, status=ListingStatus.active)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


def _fee(seller: User, listing: Listing, status: str, paid_at: datetime | None, **extra) -> ListingPayment:
    fields = dict(user_id=seller.id, listing_id=listing.id, months=1, monthly_fee=300,
                  listing_amount=300, featured_amount=0, amount=300, phone="254712345678",
                  status=status, paid_at=paid_at,
                  mpesa_receipt="FEE123" if status == "success" else None)
    fields.update(extra)
    return ListingPayment(**fields)


@pytest.mark.asyncio
async def test_listing_fees_and_plans_are_listed_apart_from_sales(client):
    seller, headers = await _seller()
    calculator = await _listing(seller, "Calculator")
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        db.add_all([
            _fee(seller, calculator, "success", now - timedelta(days=2), months=3, amount=950,
                 featured_plan="week", featured_amount=99),
            _fee(seller, calculator, "pending", None),
            _fee(seller, calculator, "failed", None),
            SubscriptionPayment(user_id=seller.id, plan_id="pro", months=1, amount=599,
                                phone="254712345678", status="success", paid_at=now - timedelta(days=1),
                                mpesa_receipt="PLAN456"),
            SubscriptionPayment(user_id=seller.id, plan_id="plus", months=1, amount=199,
                                phone="254712345678", status="failed"),
        ])
        await db.commit()

    r = await client.get(f"/listings/seller/{seller.id}/receipts", headers=headers)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["total"] == 0, "what the seller paid BROKA is not money released to them"
    assert [c["kind"] for c in body["charges"]] == ["premium", "listing_fee"], "newest first, settled only"
    plan, fee = body["charges"]
    assert (plan["subject"], plan["amount"], plan["reference"]) == ("BROKA Pro", 599, "PLAN456")
    assert (fee["subject"], fee["amount"], fee["reference"]) == ("Calculator", 950, "FEE123")
    assert fee["detail"] == "3 months + featured (KES 99)"
    assert body["charges_total"] == 1549


@pytest.mark.asyncio
async def test_only_your_own(client):
    seller, headers = await _seller()
    other, other_headers = await _seller()
    listing = await _listing(other, "Bedsitter")
    async with AsyncSessionLocal() as db:
        db.add(_fee(other, listing, "success", datetime.utcnow()))
        await db.commit()

    mine = (await client.get(f"/listings/seller/{seller.id}/receipts", headers=headers)).json()
    assert mine["charges"] == [] and mine["charges_total"] == 0
    r = await client.get(f"/listings/seller/{other.id}/receipts", headers=headers)
    assert r.status_code == 403
