"""The founding-seller offer (PRICING.md §2; pricing/service.founding_discount).

Sellers are numbered by their first listing and each band gets its discount
for FOUNDING_DISCOUNT_DAYS. What must hold:
  * the order is by first listing - a buyer who signed up early takes no place;
  * 100% off posts the listing live, paid up to the end of the offer;
  * a partial discount never prices a listing under what it costs to serve;
  * the offer ends, and discounted time can't be bought past its end.

Its own database: places are handed out in order, so other files' sellers
would shift them.
"""
import dataclasses
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.core.config import settings, _parse_tiers
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.domains.pricing import costs, service
from api.domains.pricing.categories import CATEGORIES
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_founding_sellers.db"
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


@pytest.fixture(autouse=True)
def founding_on(monkeypatch):
    """First seller free, second 80% off, then full price; fees on, payments off."""
    patched = dataclasses.replace(
        settings, listing_fees_enabled=True, in_app_payments_enabled=False,
        free_listings_per_seller=0, founding_seller_tiers=((1, 100), (1, 80)),
        founding_discount_days=90,
    )
    for module in ("api.domains.listings.service", "api.domains.pricing.payments",
                   "api.domains.pricing.service", "api.domains.pricing.router"):
        monkeypatch.setattr(f"{module}.settings", patched)


async def _user() -> tuple[str, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers, price=20000) -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
        "price": price, "lat": -1.28, "lng": 36.82})
    assert r.status_code == 201, r.text
    return r.json()


async def _quote(client, headers, price=20000) -> dict:
    return (await client.get("/pricing/listing-fee/quote", headers=headers,
                             params={"category": "Electronics", "price": price})).json()


def test_tiers_are_read_in_order():
    tiers = _parse_tiers("50:100,50:80,100:60")
    assert tiers == ((50, 100), (50, 80), (100, 60))
    assert [service.tier_percent(r, tiers) for r in (1, 50, 51, 100, 101, 200, 201)] == \
        [100, 100, 80, 80, 60, 60, 0]
    with pytest.raises(ValueError):
        _parse_tiers("50:120")


@pytest.mark.asyncio
async def test_sellers_are_numbered_by_first_listing_and_banded(client):
    # Signed up first, never sells: takes no place.
    await _user()

    _, first = await _user()
    q = await _quote(client, first)
    assert q["founding"]["rank"] == 1 and q["founding"]["percent"] == 100
    assert q["free_listing"] is True and q["fees_enabled"] is False
    listing = await _listing(client, first)
    assert listing["listing_fee"]["status"] in ("live", "ending")
    async with AsyncSessionLocal() as db:
        paid_until = (await db.get(Listing, listing["id"])).paid_until
    assert abs(paid_until - (datetime.utcnow() + timedelta(days=90))) < timedelta(minutes=1)

    _, second = await _user()
    q = await _quote(client, second)
    assert q["founding"]["rank"] == 2 and q["founding"]["percent"] == 80
    # 80% off KES 70 is 14 - and never under what the listing costs to serve.
    cost = costs.listing_month_cost(CATEGORIES["Electronics"].chats_per_month)
    assert costs.net_of_vat(q["monthly_fee"]) >= cost
    assert q["monthly_fee"] < q["list_price"] == 70
    assert (await _listing(client, second))["listing_fee"]["status"] == "unpaid"

    _, third = await _user()
    q = await _quote(client, third)
    assert q["founding"]["percent"] == 0 and q["monthly_fee"] == q["list_price"]

    # The first seller keeps their place for later listings.
    assert (await _quote(client, first))["founding"]["rank"] == 1


@pytest.mark.asyncio
async def test_the_offer_ends_and_cannot_be_bought_past_its_end(client, monkeypatch):
    patched = dataclasses.replace(
        settings, listing_fees_enabled=True, in_app_payments_enabled=False,
        free_listings_per_seller=0, founding_seller_tiers=((1000, 80),), founding_discount_days=90,
    )
    for module in ("api.domains.listings.service", "api.domains.pricing.payments",
                   "api.domains.pricing.service", "api.domains.pricing.router"):
        monkeypatch.setattr(f"{module}.settings", patched)
    seller_id, h = await _user()
    listing = await _listing(client, h)
    # Their first listing was 80 days ago: 10 days of offer left.
    async with AsyncSessionLocal() as db:
        row = await db.get(Listing, listing["id"])
        row.created_at = row.paid_until = datetime.utcnow() - timedelta(days=80)
        await db.commit()
    assert (await _founding(seller_id)).percent == 80
    q = await _quote(client, h)
    assert [o["months"] for o in q["options"]] == [1]
    r = await client.post("/pricing/listing-fee/pay", headers={**h, "X-Idempotency-Key": uuid.uuid4().hex},
                          json={"listing_id": listing["id"], "months": 3, "phone_number": "0712345678"})
    assert r.status_code == 409 and "founding" in r.text

    async with AsyncSessionLocal() as db:
        row = await db.get(Listing, listing["id"])
        row.created_at = datetime.utcnow() - timedelta(days=91)
        await db.commit()
    assert (await _founding(seller_id)).percent == 0


async def _founding(seller_id):
    async with AsyncSessionLocal() as db:
        return await service.founding_discount(db, seller_id)
