"""
Sold out with payments outside BROKA: agreed deals no longer take a
listing off sale (listings/stock.py), buyers report an item gone and its
seller can revoke the report (listings/sold_out.py).
Run: pytest backend/tests/test_sold_out_reports.py -v
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from main import app
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, ListingStatus, User, init_db, reset_engine,
)
from api.domains.listings.stock import sync_listing_stock
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_sold_out_reports.db"
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
def no_push(monkeypatch):
    async def nothing(*a, **k):
        return 0
    monkeypatch.setattr("api.core.push_devices.push_user", nothing)


async def _user() -> tuple[str, dict]:
    u = User(name="Someone", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers) -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
        "price": 20000, "lat": -1.28, "lng": 36.82})
    assert r.status_code == 201, r.text
    return r.json()


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


class TestAgreedDealsDoNotSellOut:
    @pytest.mark.asyncio
    async def test_an_agreed_deal_leaves_the_listing_on_sale(self, client, payments_off):
        # With payments off nothing is paid in the app, so an agreement
        # never released its unit: the listing went "Sold out" and stayed.
        seller_id, h = await _user()
        buyer_id, _ = await _user()
        listing = await _listing(client, h)
        async with AsyncSessionLocal() as db:
            db.add(Deal(listing_id=listing["id"], seller_id=seller_id, buyer_id=buyer_id,
                        agreed_price=19000, commission=0, status=DealStatus.agreed))
            row = await db.get(Listing, listing["id"])
            row.status = ListingStatus.pending      # what the old code left behind
            await db.commit()
        async with AsyncSessionLocal() as db:
            await sync_listing_stock(db)
        page = (await client.get(f"/listings/{listing['id']}")).json()
        assert page["status"] == "active" and page["sold_out"] is False
        assert await _in_feed(client, listing["id"])


class TestReporting:
    @pytest.mark.asyncio
    async def test_a_report_hides_it_and_the_seller_brings_it_back(self, client):
        _, seller = await _user()
        _, buyer = await _user()
        listing = await _listing(client, seller)
        r = await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert r.status_code == 200 and r.json()["reported_sold_out"] is True
        assert not await _in_feed(client, listing["id"])
        page = (await client.get(f"/listings/{listing['id']}")).json()
        assert page["sold_out"] is True and page["reported_sold_out"] is True

        # Only the seller can say it's still there.
        assert (await client.delete(f"/listings/{listing['id']}/sold-out", headers=buyer)).status_code == 404
        r = await client.delete(f"/listings/{listing['id']}/sold-out", headers=seller)
        assert r.status_code == 200 and r.json()["reported_sold_out"] is False
        assert await _in_feed(client, listing["id"])

        # The same buyer can't take it down again once the seller said no.
        again = await client.post(f"/listings/{listing['id']}/sold-out", headers=buyer)
        assert again.status_code == 409
        assert await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_a_seller_cannot_report_their_own(self, client):
        _, seller = await _user()
        listing = await _listing(client, seller)
        assert (await client.post(f"/listings/{listing['id']}/sold-out", headers=seller)).status_code == 400
