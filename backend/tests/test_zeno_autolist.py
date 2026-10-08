"""
BROKA - Zeno listing an item from its photo (zeno_assistant/autolist.py)
Run: pytest backend/tests/test_zeno_autolist.py -v

  * POST /zeno/listing-draft/autolist: Zeno fills the listing in from the
    first photo - filed under one of BROKA's own categories (a made-up one
    is no category, the right type under the wrong category moves to its
    own), the details kept only in the shape the category's fields take,
    one AI description spent and given back when nothing came of it. A
    seller without a plan gets the first one free.
  * POST /zeno/listing-draft/autolist/turn: the seller answers or corrects,
    and the whole listing changes with it - free, text only, and a model
    that loses the thread keeps the listing as it was.
  * POST /zeno/listing-draft/autolist/price: a range and one number - on
    BROKA's own listings for a plan with price checks (one spent), an
    estimate said to be one for any other.

The model is stubbed throughout.
"""
import base64
import dataclasses
import io
import json
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport
from PIL import Image

from main import app
from api.core.config import settings
from api.database import init_db, reset_engine, AsyncSessionLocal, Category, Listing, User
from api.domains.zeno_assistant import autolist
from api.models.subscription import Subscription
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_autolist.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


IDS: dict[str, str] = {}


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()
    async with AsyncSessionLocal() as db:
        for name, subs in {
            "Electronics": ["Phones", "Laptops & Computers"],
            "Land": ["Residential Plots"],
            "Automobiles": ["Cars"],
            "Other": [],
        }.items():
            top = Category(name=name)
            db.add(top)
            await db.flush()
            IDS[name] = top.id
            for sub in subs:
                row = Category(name=sub, parent_id=top.id)
                db.add(row)
                await db.flush()
                IDS[f"{name}/{sub}"] = row.id
        await db.commit()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


@pytest.fixture
def premium_on(monkeypatch):
    monkeypatch.setattr("api.domains.premium.entitlements.settings",
                        dataclasses.replace(settings, premium_enabled=True))


async def _user(plan=None) -> tuple[User, dict]:
    u = User(name="Achieng Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.flush()
        if plan:
            now = datetime.utcnow()
            db.add(Subscription(user_id=u.id, plan_id=plan, started_at=now,
                                paid_until=now + timedelta(days=30)))
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(seller: User, name: str, price: float, category="Electronics") -> Listing:
    listing = Listing(seller_id=seller.id, name=name, category=category, price=price,
                      condition="used", lat=-1.29, lng=36.82)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


def _photo_b64() -> str:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (40, 40, 180)).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _model(monkeypatch, *, raw="", replies=None, fail=False, prompts=None, images=None):
    """The model answers [raw] - or each of [replies] in turn."""
    from api.domains.ai_broker.service import AIBrokerService
    queue = list(replies or [])

    async def fake_call(self, messages, cache_key=None, image_base64=None, require_sight=False):
        if prompts is not None:
            prompts.append(messages[0]["content"])
        if images is not None:
            images.append((image_base64, require_sight))
        if fail:
            raise HTTPException(status_code=503, detail="AI service temporarily unavailable.")
        return queue.pop(0) if queue else raw

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)


async def _used(client, headers, feature) -> int:
    r = await client.get("/premium/me", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()["usage"][feature]["used"]


PHONE = json.dumps({
    "reply": "A Samsung Galaxy A54 - filed under Electronics › Phones.",
    "listing": {
        "name": "Samsung Galaxy A54 128GB",
        "category": "electronics",
        "subcategory": "phones",
        "condition": "used",
        "attributes": {"Brand": "Samsung", "storage": "128 GB", "ram": "8 GB",
                       "colour": "Black", "battery_health": "about 87%"},
        "description": "**Brand:** Samsung\n- Model: Galaxy A54\nStorage: 128 GB\nCondition: Used - light scratches",
    },
    "questions": [{"label": "Battery health", "question": "What's the battery health?"},
                  {"label": "Storage", "question": "How much storage?"}],
})


async def _look(client, headers, **body):
    return await client.post("/zeno/listing-draft/autolist", headers=headers,
                             json={"image_base64": _photo_b64(), **body})


class TestLook:
    async def test_it_files_the_photo_under_brokas_own_categories(self, client, premium_on, monkeypatch):
        prompts, images = [], []
        _model(monkeypatch, raw=PHONE, prompts=prompts, images=images)
        _, headers = await _user("plus")
        r = await _look(client, headers)
        assert r.status_code == 200, r.text
        body = r.json()
        listing = body["listing"]
        assert listing["name"] == "Samsung Galaxy A54 128GB"
        # Matched to the taxonomy whatever the case, with the ids the
        # wizard publishes under.
        assert (listing["category"], listing["subcategory"]) == ("Electronics", "Phones")
        assert listing["category_id"] == IDS["Electronics"]
        assert listing["subcategory_id"] == IDS["Electronics/Phones"]
        assert listing["condition"] == "used"
        # Details only under the category's own field names, in their
        # shape: "128 GB" is the 128GB option, "about 87%" the number 87,
        # and a colour - no Phones field - stays in the description.
        assert listing["attributes"] == {"brand": "Samsung", "storage": "128GB", "ram": "8GB",
                                         "battery_health": "87"}
        assert listing["description"].startswith("Brand: Samsung\nModel: Galaxy A54")
        # A question about a line the description already has is dropped.
        assert [q["label"] for q in body["questions"]] == ["Battery health"]
        assert body["reply"].startswith("A Samsung Galaxy A54")
        # The model had to see the photo, and was shown BROKA's categories.
        assert images[0][0] and images[0][1] is True
        assert "- Electronics: Phones, Laptops & Computers" in prompts[0]
        assert await _used(client, headers, "ai_descriptions") == 1

    async def test_a_made_up_category_is_no_category(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"listing": {
            "name": "Wireless router", "category": "Networking Gear", "subcategory": "Routers",
            "description": "Brand: Airtel\nType: 4G router"}, "questions": []}))
        _, headers = await _user("plus")
        listing = (await _look(client, headers)).json()["listing"]
        assert listing["category"] is None and listing["category_id"] is None
        assert listing["subcategory"] is None

    async def test_the_right_type_under_the_wrong_category_moves_to_its_own(
            self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"listing": {
            "name": "Toyota Axio 2015", "category": "Vehicles & Parts", "subcategory": "Cars",
            "condition": "used", "attributes": {"year": "2015", "mileage": "85,000 km"},
            "description": "Make: Toyota\nModel: Axio"}, "questions": []}))
        _, headers = await _user("plus")
        listing = (await _look(client, headers)).json()["listing"]
        assert (listing["category"], listing["subcategory"]) == ("Automobiles", "Cars")
        assert listing["attributes"]["mileage"] == "85000"

    async def test_land_keeps_a_size_only_with_its_unit_and_has_no_condition(
            self, client, premium_on, monkeypatch):
        _model(monkeypatch, replies=[
            json.dumps({"listing": {"name": "Eighth acre plot in Juja", "category": "Land",
                                    "subcategory": "Residential Plots", "condition": "used",
                                    "attributes": {"land_size": "0.125", "land_size_unit": "acre",
                                                   "title_deed": "yes"},
                                    "description": "Size: 1/8 acre\nTitle deed: Yes"}}),
            json.dumps({"listing": {"name": "Plot in Juja", "category": "Land",
                                    "attributes": {"land_size": "big"},
                                    "description": "Location: Juja"}}),
        ])
        _, headers = await _user("plus")
        listing = (await _look(client, headers)).json()["listing"]
        assert listing["condition"] is None
        assert listing["attributes"]["land_size"] == "0.125"
        assert listing["attributes"]["land_size_unit"] == "acres"
        assert listing["attributes"]["title_deed"] == "Yes"
        listing = (await _look(client, headers)).json()["listing"]
        assert "land_size" not in listing["attributes"]

    async def test_without_a_plan_the_first_is_free_and_then_it_says_why_to_pay(
            self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=PHONE)
        _, headers = await _user()
        assert (await _look(client, headers)).status_code == 200
        r = await _look(client, headers)
        assert r.status_code == 402
        detail = r.json()["detail"]
        assert detail["code"] == "ALLOWANCE_USED" and detail["upgrade_to"] == "plus"
        assert "sell faster" in detail["message"]

    async def test_a_failed_model_gives_the_description_back(self, client, premium_on, monkeypatch):
        _model(monkeypatch, fail=True)
        _, headers = await _user("plus")
        r = await _look(client, headers)
        assert r.status_code == 503
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_prose_is_nothing_to_build_on(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="I think it's a phone of some kind.")
        _, headers = await _user("plus")
        r = await _look(client, headers)
        assert r.status_code == 502
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_no_photo_costs_nothing(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=PHONE)
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/autolist", headers=headers, json={})
        assert r.status_code == 400
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_what_the_seller_entered_stands(self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps({"listing": {
            "name": "Phone", "category": "Nonsense", "description": "Brand: Samsung"}}))
        _, headers = await _user("plus")
        r = await _look(client, headers, draft={"name": "Galaxy A54 for sale", "category": "Electronics",
                                                "subcategory": "Phones"})
        listing = r.json()["listing"]
        assert "Galaxy A54 for sale" in prompts[0]
        assert (listing["category"], listing["subcategory"]) == ("Electronics", "Phones")


LISTING = {"name": "Samsung Galaxy A54", "category": "Electronics", "subcategory": "Phones",
           "condition": "used", "attributes": {"storage": "128GB"},
           "description": "Brand: Samsung\nModel: Galaxy A54"}
OPEN = [{"label": "Battery health", "question": "What's the battery health?"}]


async def _turn(client, headers, message="It's the 256GB one, battery 91%", **body):
    return await client.post("/zeno/listing-draft/autolist/turn", headers=headers, json={
        "listing": LISTING, "questions": OPEN, "message": message, **body})


class TestTurn:
    async def test_a_correction_changes_the_whole_listing_for_free(self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps({
            "reply": "Updated - it's ready for a price.",
            "listing": {"name": "Samsung Galaxy A54 256GB", "category": "Electronics",
                        "subcategory": "Phones", "condition": "used",
                        "attributes": {"storage": "256GB", "battery_health": "91"},
                        "description": "Brand: Samsung\nModel: Galaxy A54\nStorage: 256 GB\nBattery health: 91%"},
            "questions": []}))
        _, headers = await _user("plus")
        r = await _turn(client, headers)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["listing"]["name"] == "Samsung Galaxy A54 256GB"
        assert body["listing"]["attributes"] == {"storage": "256GB+", "battery_health": "91"}
        assert "Battery health: 91%" in body["listing"]["description"]
        assert body["questions"] == []
        # The listing so far and what was asked went to the model, as text.
        assert "Name: Samsung Galaxy A54" in prompts[0] and "Battery health" in prompts[0]
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_a_lost_model_keeps_the_listing(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="Sorry, say that again?")
        _, headers = await _user("plus")
        body = (await _turn(client, headers)).json()
        assert body["listing"]["name"] == "Samsung Galaxy A54"
        assert body["listing"]["category_id"] == IDS["Electronics"]
        assert body["listing"]["description"] == "Brand: Samsung\nModel: Galaxy A54"
        assert [q["label"] for q in body["questions"]] == ["Battery health"]
        assert body["reply"] == "Sorry, say that again?"

    async def test_a_category_the_app_sends_is_checked_again(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="{}")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/autolist/turn", headers=headers, json={
            "listing": {**LISTING, "category": "Made Up", "subcategory": None}, "message": "ok"})
        assert r.json()["listing"]["category"] is None
        # A known type of item under a wrong category is filed where it belongs.
        r = await client.post("/zeno/listing-draft/autolist/turn", headers=headers, json={
            "listing": {**LISTING, "category": "Made Up"}, "message": "ok"})
        assert r.json()["listing"]["category"] == "Electronics"

    async def test_without_a_plan_or_trial_it_is_refused(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="{}")
        _, headers = await _user()
        monkeypatch.setattr("api.domains.premium.entitlements.FREE_TRIAL", {"ai_covers": 1})
        assert (await _turn(client, headers)).status_code == 402

    async def test_an_answer_needs_words(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="{}")
        _, headers = await _user("plus")
        assert (await _turn(client, headers, message="   ")).status_code == 422


DRAFT = {"name": "Samsung Galaxy A54", "category": "Electronics", "condition": "used"}


async def _price(client, headers, draft=DRAFT):
    return await client.post("/zeno/listing-draft/autolist/price", headers=headers,
                             json={"draft": draft})


class TestPrice:
    async def test_without_price_checks_it_is_an_estimate_said_to_be_one(
            self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps({
            "reply": "My estimate is 30-36K; I'd ask 34,000.",
            "low": 36000, "high": 30000, "suggested_price": 40000}))
        _, headers = await _user("plus")
        r = await _price(client, headers)
        assert r.status_code == 200, r.text
        body = r.json()
        # In order, and the number inside its own range.
        assert (body["low"], body["high"], body["suggested_price"]) == (30000, 36000, 36000)
        assert body["basis"] == "estimate" and body["can_check_broka"] is False
        assert body["comparables"] is None
        assert "NOT seen BROKA's listings" in prompts[0]
        assert await _used(client, headers, "price_checks") == 0

    async def test_pro_prices_on_brokas_own_listings(self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps({
            "reply": "Three like it ask 28-33K. Ask 45,000.", "low": 10000, "high": 90000,
            "suggested_price": 45000}))
        me, headers = await _user("pro")
        other, _ = await _user()
        for price in (28000, 30000, 33000):
            await _listing(other, "Samsung Galaxy A54", price)
        body = (await _price(client, headers)).json()
        assert body["basis"] == "broka" and body["can_check_broka"] is True
        assert body["comparables"]["count"] == 3
        # BROKA's numbers are the range; the model's number only inside it.
        assert (body["low"], body["high"], body["suggested_price"]) == (28000, 33000, 33000)
        assert "<<<COMPARABLES" in prompts[0]
        assert await _used(client, headers, "price_checks") == 1

    async def test_brokas_numbers_survive_a_failed_model(self, client, premium_on, monkeypatch):
        _model(monkeypatch, fail=True)
        _, headers = await _user("pro")
        other, _ = await _user()
        await _listing(other, "Toyota Axio 2015", 1_250_000, category="Automobiles")
        body = (await _price(client, headers, draft={"name": "Toyota Axio 2015",
                                                      "category": "Automobiles"})).json()
        assert body["basis"] == "broka" and body["suggested_price"] == 1_250_000
        assert "KES 1,250,000" in body["reply"]

    async def test_no_numbers_at_all_is_a_502(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"reply": "No idea.", "low": None, "high": None}))
        _, headers = await _user("plus")
        assert (await _price(client, headers)).status_code == 502


class TestRange:
    def test_a_range_is_put_in_order_around_its_number(self):
        assert autolist._clean_range(5000, 3000, None) == (3000, 5000, 4000)
        assert autolist._clean_range(None, None, 2500) == (2500, 2500, 2500)
        assert autolist._clean_range(None, None, None) is None
        assert autolist._clean_range(-5, 99_000_000, None) is None
