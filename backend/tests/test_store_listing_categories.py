"""What an online store may hold (stores/categories.may_hold).

What must hold:
  * an online (goods) store takes no Automobiles, Land, Property, Services
    or Other listing - posted into it, moved into it, or quoted as covered
    by it - and says why in words the app shows. A land listing posted
    "into" a phone shop used to be accepted, covered by the shop's plan;
  * the same listing posts fine as the seller's own;
  * a car yard holds Automobiles and an agent Property and Land - the
    trades of their own cards - and neither holds the other's;
  * every other category goes into any store;
  * the owner's store payload lists what the store may not hold: the sell
    wizard and "Move listings in" read it to offer the store at all.
"""
import itertools
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AccountType, AsyncSessionLocal, Category, Listing, SellerTier, User, init_db, reset_engine
from api.domains.stores import categories as store_categories
from api.security import create_access_token
from sqlalchemy import select

LAND = {"land_size": "2", "land_size_unit": "acres"}


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_listing_categories.db"
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


_n = itertools.count(1000)


async def _owner(business_category: str = "Electronics") -> dict:
    """A long-term seller with headers. The store's trade follows its
    category, which a store opened without one takes from this."""
    n = next(_n)
    u = User(name=f"Owner {n}", phone=f"+254797{n:06d}", password_hash="x",
             account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term,
             business_name=f"Biz {n}", business_category=business_category)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _store(client, headers) -> dict:
    r = await client.post("/stores", headers=headers, json={
        "name": f"Shop {next(_n)}", "store_type": "virtual",
        "slug": f"shop-{uuid.uuid4().hex[:8]}"})
    assert r.status_code == 201, r.text
    return r.json()


async def _subcategory(top: str) -> str:
    async with AsyncSessionLocal() as db:
        parent = (await db.execute(select(Category).where(
            Category.name == top, Category.parent_id.is_(None)))).scalar_one()
        return (await db.execute(select(Category.id).where(
            Category.parent_id == parent.id).limit(1))).scalar_one()


async def _post(client, headers, category, store_id=None, attributes=None):
    body = {"description": "Selling it as it is.", "name": f"Item {uuid.uuid4().hex[:6]}",
            "category": category, "price": 50000, "lat": -1.28, "lng": 36.82}
    if store_id:
        body["store_id"] = store_id
    if attributes:
        body["attributes"] = attributes
    return await client.post("/listings/", headers=headers, json=body)


def _refused(r):
    assert r.status_code == 400, r.text
    detail = r.json()["detail"]
    assert detail["code"] == "STORE_CATEGORY_NOT_ALLOWED"
    assert "own listing" in detail["message"]


class TestOnlineStore:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("category, attributes", [
        ("Land", LAND), ("Automobiles", None), ("Property", None),
        ("Services", None), ("Other", None), ("land", LAND),
    ])
    async def test_a_trade_it_does_not_sell_is_refused(self, client, category, attributes):
        h = await _owner()
        store = await _store(client, h)
        _refused(await _post(client, h, category, store["id"], attributes))
        # As the seller's own listing it posts as before.
        own = await _post(client, h, category, attributes=attributes)
        assert own.status_code == 201, own.text
        assert own.json()["store_id"] is None

    @pytest.mark.asyncio
    async def test_filed_under_a_subcategory_the_parent_decides(self, client):
        # The server files a listing under its subcategory's parent, whatever
        # name the request carried: "Electronics" with a plot's subcategory
        # is a Land listing, and refused.
        h = await _owner()
        store = await _store(client, h)
        r = await client.post("/listings/", headers=h, json={
            "description": "A plot.", "name": "Plot", "category": "Electronics",
            "subcategory_id": await _subcategory("Land"), "attributes": LAND,
            "price": 900000, "lat": -1.28, "lng": 36.82, "store_id": store["id"]})
        _refused(r)

    @pytest.mark.asyncio
    async def test_a_listing_of_another_trade_cannot_be_moved_in(self, client):
        h = await _owner()
        store = await _store(client, h)
        plot = await _post(client, h, "Land", attributes=LAND)
        assert plot.status_code == 201
        _refused(await client.post(f"/listings/{plot.json()['id']}/store", headers=h,
                                   json={"store_id": store["id"]}))
        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, plot.json()["id"])).store_id is None

        phone = await _post(client, h, "Electronics")
        moved = await client.post(f"/listings/{phone.json()['id']}/store", headers=h,
                                  json={"store_id": store["id"]})
        assert moved.status_code == 200 and moved.json()["store_id"] == store["id"]

    @pytest.mark.asyncio
    async def test_the_quote_does_not_call_it_covered(self, client):
        h = await _owner()
        store = await _store(client, h)
        refused = await client.get("/pricing/listing-fee/quote", headers=h, params={
            "category": "Land", "price": 900000, "store_id": store["id"]})
        _refused(refused)
        covered = (await client.get("/pricing/listing-fee/quote", headers=h, params={
            "category": "Electronics", "price": 20000, "store_id": store["id"]})).json()
        assert covered["store_covered"] is True

    @pytest.mark.asyncio
    async def test_every_other_category_goes_in(self, client):
        h = await _owner()
        store = await _store(client, h)
        for category in ("Electronics", "Fashion", "Home & Furniture", "Agriculture"):
            r = await _post(client, h, category, store["id"])
            assert r.status_code == 201, (category, r.text)
            assert r.json()["store_id"] == store["id"]

    @pytest.mark.asyncio
    async def test_the_owner_payload_says_what_it_may_not_hold(self, client):
        h = await _owner()
        await _store(client, h)
        mine = (await client.get("/stores/mine", headers=h)).json()
        assert mine["excluded_listing_categories"] == [
            "Automobiles", "Land", "Other", "Property", "Services"]


class TestDealerAndAgentStores:
    @pytest.mark.asyncio
    async def test_a_car_yard_holds_cars_not_land(self, client):
        h = await _owner("Automobiles")
        store = await _store(client, h)
        assert store["category"] == "Automobiles"
        assert (await _post(client, h, "Automobiles", store["id"])).status_code == 201
        assert (await _post(client, h, "Electronics", store["id"])).status_code == 201
        _refused(await _post(client, h, "Land", store["id"], LAND))
        _refused(await _post(client, h, "Property", store["id"]))
        mine = (await client.get("/stores/mine", headers=h)).json()
        assert mine["excluded_listing_categories"] == ["Land", "Other", "Property", "Services"]

    @pytest.mark.asyncio
    async def test_an_agent_holds_property_and_land_not_cars(self, client):
        h = await _owner("Property")
        store = await _store(client, h)
        assert store["category"] == "Property"
        assert (await _post(client, h, "Land", store["id"], LAND)).status_code == 201
        assert (await _post(client, h, "Property", store["id"])).status_code == 201
        _refused(await _post(client, h, "Automobiles", store["id"]))
        _refused(await _post(client, h, "Services", store["id"]))
        mine = (await client.get("/stores/mine", headers=h)).json()
        assert mine["excluded_listing_categories"] == ["Automobiles", "Other", "Services"]


class TestTheRule:
    def test_may_hold(self):
        assert store_categories.may_hold("Electronics", "Electronics")
        assert store_categories.may_hold(None, "Fashion")
        assert not store_categories.may_hold("Electronics", "land")
        assert not store_categories.may_hold("Electronics", "Vehicles")  # renamed: Automobiles
        assert not store_categories.may_hold("Electronics", "furniture")  # free text: Other
        assert store_categories.may_hold("Automobiles", "Automobiles")
        assert store_categories.may_hold("Land", "Property")
        assert not store_categories.may_hold("Automobiles", "Other")
