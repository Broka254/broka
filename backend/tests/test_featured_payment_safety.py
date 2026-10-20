"""Historical featured-payment callbacks still move real listings."""
from __future__ import annotations

import uuid
from datetime import datetime

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, FeaturedPayment, Listing, ListingStatus, MpesaStatus, User, init_db, reset_engine
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_featured_safety.db"
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


async def _payment() -> tuple[FeaturedPayment, Listing]:
    tag = uuid.uuid4().hex[:10]
    async with AsyncSessionLocal() as db:
        user = User(name="Seller", phone=f"+2547{tag}", email=f"{tag}@f.test", password_hash="x")
        db.add(user)
        await db.flush()
        listing = Listing(
            seller_id=user.id, name=f"Boosted {tag}", category="Electronics",
            price=1000, lat=-1.2, lng=36.8, status=ListingStatus.active,
        )
        db.add(listing)
        await db.flush()
        payment = FeaturedPayment(
            user_id=user.id, listing_id=listing.id, plan="week",
            phone="254711111111", amount=99,
            checkout_request_id=f"ws_CO_{tag}", status=MpesaStatus.pending,
        )
        db.add(payment)
        await db.commit()
        await db.refresh(payment)
        await db.refresh(listing)
        return payment, listing


def _callback(checkout: str, amount: float = 99, code: int = 0, receipt: str | None = None) -> dict:
    return {"Body": {"stkCallback": {
        "CheckoutRequestID": checkout, "ResultCode": code, "ResultDesc": "ok",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": amount},
            {"Name": "MpesaReceiptNumber", "Value": receipt or f"F{uuid.uuid4().hex[:10].upper()}"},
        ]},
    }}}


@pytest.mark.asyncio
async def test_wrong_amount_does_not_feature_the_listing(client):
    payment, listing = await _payment()
    response = await client.post(
        "/featured/callback", json=_callback(payment.checkout_request_id, amount=1),
    )
    assert response.status_code == 200
    async with AsyncSessionLocal() as db:
        payment = (await db.execute(select(FeaturedPayment).where(
            FeaturedPayment.id == payment.id))).scalar_one()
        listing = (await db.execute(select(Listing).where(Listing.id == listing.id))).scalar_one()
    assert payment.status == MpesaStatus.failed
    assert listing.is_featured is not True


@pytest.mark.asyncio
async def test_duplicate_success_and_late_failure_are_one_settlement(client):
    payment, listing = await _payment()
    body = _callback(payment.checkout_request_id)
    assert (await client.post("/featured/callback", json=body)).status_code == 200
    async with AsyncSessionLocal() as db:
        first = (await db.execute(select(Listing).where(Listing.id == listing.id))).scalar_one()
        first_until = first.featured_until
    assert first_until is not None
    assert (await client.post("/featured/callback", json=body)).status_code == 200
    assert (await client.post(
        "/featured/callback", json=_callback(payment.checkout_request_id, code=1032),
    )).status_code == 200
    async with AsyncSessionLocal() as db:
        stored = (await db.execute(select(FeaturedPayment).where(
            FeaturedPayment.id == payment.id))).scalar_one()
        listing = (await db.execute(select(Listing).where(Listing.id == listing.id))).scalar_one()
    assert stored.status == MpesaStatus.success
    assert listing.is_featured is True
    assert listing.featured_until == first_until


@pytest.mark.asyncio
async def test_incomplete_callback_is_rejected(client):
    payment, _ = await _payment()
    body = {"Body": {"stkCallback": {"CheckoutRequestID": payment.checkout_request_id}}}
    assert (await client.post("/featured/callback", json=body)).status_code == 400
