"""Browsing a subcategory by brand (2026-10-08): the app's subcategory
screens ("Phones") lead with brand filters - Samsung, Apple, Tecno...

Each fix here has a test that failed on the code before it:

  * a subcategory's brand field was a bare text box with nothing to choose
    from, so there was no list of brands to filter by - the seed now gives
    every brand/make field its suggestions, and brings a database seeded
    before them up to date.
  * a typed brand was stored as typed: "Samsung Galaxy A54" or "iPhone 13"
    was in no brand at all, so the Samsung and Apple filters never found it.
"""
import json
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, Category, CategoryFilter, User, init_db, reset_engine,
)
from api.domains.categories import seed
from api.domains.listings import validation as rules
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_brand_filters.db"
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
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def _user() -> dict:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _sub(top_name: str, sub_name: str) -> Category:
    async with AsyncSessionLocal() as db:
        top = (await db.execute(select(Category).where(
            Category.name == top_name, Category.parent_id.is_(None)))).scalars().first()
        return (await db.execute(select(Category).where(
            Category.parent_id == top.id, Category.name == sub_name))).scalars().first()


def _body(sub: Category, **extra) -> dict:
    return {"name": f"Item {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "subcategory_id": sub.id, "price": 25000, "lat": -1.28, "lng": 36.82,
            "description": "Barely used, with the box and the charger.", **extra}


class TestSuggestionsAreSeeded:
    @pytest.mark.asyncio
    async def test_a_subcategory_serves_its_brands(self, client):
        phones = await _sub("Electronics", "Phones")
        fields = {f["field_name"]: f for f in
                  (await client.get(f"/categories/{phones.id}/filters")).json()}
        # Still a text field: older app builds keep showing the box they did.
        assert fields["brand"]["field_type"] == "text"
        assert fields["brand"]["options"][:3] == ["Samsung", "Apple", "Tecno"]

    @pytest.mark.asyncio
    async def test_vehicles_get_makes(self, client):
        cars = await _sub("Automobiles", "Cars")
        fields = {f["field_name"]: f for f in
                  (await client.get(f"/categories/{cars.id}/filters")).json()}
        assert "Toyota" in fields["make"]["options"]

    def test_every_list_fills_a_real_field(self):
        for (top, sub), brands in seed.BRAND_SUGGESTIONS.items():
            assert sub in seed.SUBCATEGORIES[top], (top, sub)
            assert seed.suggestion_field(top, sub) is not None, (top, sub)
            assert len(set(brands)) == len(brands), (top, sub)

    @pytest.mark.asyncio
    async def test_a_database_seeded_before_them_is_brought_up_to_date(self):
        phones = await _sub("Electronics", "Phones")
        audio = await _sub("Electronics", "Audio")
        async with AsyncSessionLocal() as db:
            brand = (await db.execute(select(CategoryFilter).where(
                CategoryFilter.category_id == phones.id,
                CategoryFilter.field_name == "brand"))).scalars().first()
            brand.options = None           # as every database seeded before today
            kind = (await db.execute(select(CategoryFilter).where(
                CategoryFilter.category_id == audio.id,
                CategoryFilter.field_name == "type"))).scalars().first()
            closed = kind.options
            await db.commit()

        counts = await seed.seed_categories()
        assert counts["suggestions_updated"] == 1

        async with AsyncSessionLocal() as db:
            brand = (await db.execute(select(CategoryFilter).where(
                CategoryFilter.category_id == phones.id,
                CategoryFilter.field_name == "brand"))).scalars().first()
            assert json.loads(brand.options) == seed.BRAND_SUGGESTIONS[("Electronics", "Phones")]
            kind = (await db.execute(select(CategoryFilter).where(
                CategoryFilter.category_id == audio.id,
                CategoryFilter.field_name == "type"))).scalars().first()
            assert kind.options == closed, "a select's closed list is not the seed's to change"

        again = await seed.seed_categories()
        assert not any(again.values()), again


class TestBrandsAreFiled:
    @pytest.mark.parametrize("typed, filed", [
        ("samsung", "Samsung"),
        ("Samsung Galaxy A54", "Samsung"),
        ("iPhone 13 Pro", "Apple"),
        ("Redmi Note 12", "Xiaomi"),
        ("One Plus", "OnePlus"),
        ("Oukitel", "Oukitel"),            # not one BROKA lists: kept as typed
    ])
    def test_a_typed_phone_brand(self, typed, filed):
        phones = seed.BRAND_SUGGESTIONS[("Electronics", "Phones")]
        assert rules.canonical_suggestion(typed, phones, seed.BRAND_ALIASES) == filed

    def test_the_longest_brand_wins_and_aliases_stay_in_their_field(self):
        trucks = seed.BRAND_SUGGESTIONS[("Automobiles", "Trucks")]
        assert rules.canonical_suggestion("Mitsubishi Fuso Canter", trucks, seed.BRAND_ALIASES) \
            == "Mitsubishi Fuso"
        cars = seed.BRAND_SUGGESTIONS[("Automobiles", "Cars")]
        assert rules.canonical_suggestion("Mercedes Benz C200", cars, seed.BRAND_ALIASES) \
            == "Mercedes-Benz"
        # "mi" is Xiaomi only where Xiaomi is a brand on offer.
        assert rules.canonical_suggestion("Mi", cars, seed.BRAND_ALIASES) == "Mi"

    @pytest.mark.asyncio
    async def test_the_brand_filter_finds_what_sellers_typed(self, client):
        h = await _user()
        phones = await _sub("Electronics", "Phones")
        typed = ["samsung galaxy a14", "SAMSUNG", "iPhone 12", "Tecno"]
        for brand in typed:
            r = await client.post("/listings/", json=_body(phones, attributes={"brand": brand}),
                                  headers=h)
            assert r.status_code == 201, r.text
        assert r.json()["attributes"]["brand"] == "Tecno"

        async def brand_count(brand: str) -> int:
            page = (await client.get("/listings/", params={
                "subcategory_id": phones.id, "with_total": "true",
                "attributes": json.dumps({"brand": brand}),
            })).json()
            return page["total"]

        assert await brand_count("Samsung") == 2
        assert await brand_count("Apple") == 1
        assert await brand_count("Tecno") == 1

    @pytest.mark.asyncio
    async def test_a_field_without_suggestions_is_left_as_typed(self, client):
        h = await _user()
        phones = await _sub("Electronics", "Phones")
        r = await client.post("/listings/", json=_body(
            phones, attributes={"brand": "apple", "model": "iphone 12 pro"}), headers=h)
        assert r.status_code == 201, r.text
        assert r.json()["attributes"] == {"brand": "Apple", "model": "iphone 12 pro"}
