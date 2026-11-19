"""A listing's details in its description (listings/details_text.py).

What must hold:
  * a listing posted with no description says what its details say - a
    phone's condition, brand, storage and RAM as "Label: value" lines - so
    a seller who skips the description has not left buyers asking the
    basics, and never types the details twice;
  * a description the seller wrote is kept exactly as written;
  * a land listing's size reads as one line, and the server's own derived
    fields never appear;
  * a draft refreshed by its Go live retry follows the same rule.
"""
import itertools
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import AsyncSessionLocal, Category, User, init_db, reset_engine
from api.domains.listings import details_text
from api.domains.listings.validation import MAX_DESCRIPTION_LEN
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_details_text.db"
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


_phones = itertools.count()


async def _headers() -> dict:
    async with AsyncSessionLocal() as db:
        u = User(name="Seller", phone=f"07{next(_phones):08d}", password_hash="x")
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _subcategory(top: str, name: str) -> str:
    async with AsyncSessionLocal() as db:
        parent = (await db.execute(select(Category.id).where(
            Category.name == top, Category.parent_id.is_(None)))).scalar_one()
        return (await db.execute(select(Category.id).where(
            Category.parent_id == parent, Category.name == name))).scalar_one()


def _phone(**extra) -> dict:
    return {"name": f"Samsung A54 {uuid.uuid4().hex[:4]}", "category": "Electronics",
            "price": 32000, "lat": -1.28, "lng": 36.82, "condition": "used",
            "attributes": {"brand": "Samsung", "storage": "128GB", "ram": "8GB",
                           "battery_health": 91, "warranty": "No"},
            **extra}


class TestPosted:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("description", [None, "", "   "])
    async def test_no_description_says_the_details(self, client, description):
        body = _phone(subcategory_id=await _subcategory("Electronics", "Phones"))
        if description is None:
            body.pop("description", None)
        else:
            body["description"] = description
        r = await client.post("/listings/", headers=await _headers(), json=body)
        assert r.status_code == 201, r.text
        assert r.json()["description"] == (
            "Condition: Used\nBrand: Samsung\nStorage: 128GB\nRAM: 8GB\n"
            "Battery health: 91\nWarranty: No")

    @pytest.mark.asyncio
    async def test_a_written_description_is_kept(self, client):
        written = "Screen has one small scratch. Comes with the box and charger."
        r = await client.post("/listings/", headers=await _headers(),
                              json=_phone(description=written))
        assert r.status_code == 201, r.text
        assert r.json()["description"] == written

    @pytest.mark.asyncio
    async def test_nothing_to_say_stays_empty(self, client):
        r = await client.post("/listings/", headers=await _headers(), json={
            "name": "Mystery box", "category": "Other", "price": 500,
            "lat": -1.28, "lng": 36.82, "description": ""})
        assert r.status_code == 201, r.text
        assert r.json()["description"] == ""

    @pytest.mark.asyncio
    async def test_land_reads_its_size_once(self, client):
        r = await client.post("/listings/", headers=await _headers(), json={
            "name": "Plot in Kitengela", "category": "Land", "price": 900000,
            "lat": -1.28, "lng": 36.82, "description": "",
            "subcategory_id": await _subcategory("Land", "Residential Plots"),
            "attributes": {"land_size": "2", "land_size_unit": "Acres", "title_deed": "Yes"}})
        assert r.status_code == 201, r.text
        text = r.json()["description"]
        assert text.splitlines()[0] == "Size: 2 acres"
        assert "Title deed: Yes" in text
        assert "land_size" not in text.lower() and "acres (" not in text

    @pytest.mark.asyncio
    async def test_the_go_live_retry_keeps_the_details(self, client):
        # Fees on: the listing is created unpaid, and Go live pressed again
        # with the same key refreshes the draft (_refresh_unpaid_draft).
        from api.core.config import settings
        before = settings.listing_fees_enabled, settings.free_listing_offer_limit
        object.__setattr__(settings, "listing_fees_enabled", True)
        object.__setattr__(settings, "free_listing_offer_limit", 0)
        try:
            h = {**await _headers(), "X-Idempotency-Key": uuid.uuid4().hex}
            first = await client.post("/listings/", headers=h, json=_phone(description=""))
            assert first.status_code == 201, first.text
            assert first.json()["listing_fee"]["status"] == "unpaid"
            again = await client.post("/listings/", headers=h,
                                      json=_phone(description="", condition="refurbished"))
            assert again.status_code in (200, 201), again.text
            assert again.json()["id"] == first.json()["id"]
            assert again.json()["description"].startswith("Condition: Refurbished\nBrand: Samsung")
        finally:
            object.__setattr__(settings, "listing_fees_enabled", before[0])
            object.__setattr__(settings, "free_listing_offer_limit", before[1])


class TestLines:
    def test_labels_read_as_words(self):
        assert details_text.label("ram") == "RAM"
        assert details_text.label("storage") == "Storage"
        assert details_text.label("battery_health") == "Battery health"
        assert details_text.label("smart_tv") == "Smart TV"
        assert details_text.label("bale_weight_kg") == "Bale weight (kg)"
        assert details_text.label("power_rating_watts") == "Power rating (watts)"
        assert details_text.label("storage_type") == "Storage type"

    def test_values(self):
        text = details_text.describe(None, {
            "mileage": 45000.0, "imported": True, "colours": ["Black", " ", "Red"],
            "nested": {"a": 1}, "empty": "  ", "fuel": "Petrol"})
        assert text == "Mileage: 45000\nImported: Yes\nColours: Black, Red\nFuel: Petrol"

    def test_land_and_plots(self):
        assert details_text.describe(None, {
            "land_size": 2, "land_size_unit": "50x100 plots", "land_size_acres": 0.25,
        }) == "Size: 2 plots (50x100)"
        assert details_text.describe(None, {"acreage": "3"}) == "Size: 3 acres"

    def test_never_longer_than_a_description(self):
        many = {f"field_{i}": "x" * 190 for i in range(30)}
        text = details_text.describe("new", many)
        assert 0 < len(text) <= MAX_DESCRIPTION_LEN
        assert text.startswith("Condition: New\n")
        assert all(line.endswith("x" * 190) for line in text.splitlines()[1:])

    def test_nothing(self):
        assert details_text.describe(None, None) == ""
        assert details_text.describe("  ", {}) == ""
