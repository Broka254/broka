"""
BROKA - Zeno helping a seller write a listing (zeno_assistant/selling.py)
Run: pytest backend/tests/test_zeno_selling.py -v

  * POST /zeno/listing-draft/describe: a description from the first photo,
    on every plan - one AI description spent per success, given back when
    the model fails. "Label: value" lines, and questions for what the photo
    can't show; builds from before the questions get them as blank lines.
  * POST /zeno/listing-draft/describe/turn: the seller answers, Zeno folds
    the answers in - free once the plan has descriptions, and text only.
  * POST /zeno/listing-draft/price/turn: Zeno pricing the draft, Pro and
    Elite only; research=true runs the Buying Agent's search over live
    listings and spends one price check.

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
from api.database import init_db, reset_engine, AsyncSessionLocal, Category, Listing, ListingType, User
from api.domains.pricing import plans
from api.models.subscription import Subscription
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_selling.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()
    async with AsyncSessionLocal() as db:
        db.add(Category(name="Electronics"))
        db.add(Category(name="Furniture"))
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
    u = User(name="Wanjiru Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
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


async def _listing(seller: User, name: str, price: float, category="Electronics", **extra) -> Listing:
    listing = Listing(seller_id=seller.id, name=name, category=category, price=price,
                      condition="used", lat=-1.29, lng=36.82, **extra)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


def _photo_b64() -> str:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (180, 40, 40)).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def _model(monkeypatch, *, raw="", fail=False, prompts=None, images=None):
    from api.domains.ai_broker.service import AIBrokerService

    async def fake_call(self, messages, cache_key=None, image_base64=None, require_sight=False):
        if prompts is not None:
            prompts.append(messages[0]["content"])
        if images is not None:
            images.append((image_base64, require_sight))
        if fail:
            raise HTTPException(status_code=503, detail="AI service temporarily unavailable.")
        return raw

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)


async def _used(client, headers, feature) -> int:
    r = await client.get("/premium/me", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()["usage"][feature]["used"]


DRAFT = {"name": "Samsung Galaxy A54", "category": "Electronics", "condition": "used",
         "attributes": {"storage": "128GB"}}


class TestPlans:
    def test_descriptions_on_every_plan_and_price_checks_from_pro(self):
        by_id = plans.PREMIUM_BY_ID
        assert all(p.ai_descriptions > 0 for p in plans.PREMIUM_PLANS)
        assert by_id["plus"].price_checks == 0
        assert by_id["pro"].price_checks > 0 and by_id["elite"].price_checks > by_id["pro"].price_checks

    def test_plans_list_the_new_allowances(self):
        a = plans.PREMIUM_BY_ID["pro"].to_dict()["allowances"]
        assert a["ai_descriptions"] == 100 and a["price_checks"] == 40


class TestDescribe:
    async def test_without_a_plan_it_says_why_it_is_worth_it(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="should not be called", fail=True)
        _, headers = await _user()
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64()})
        assert r.status_code == 402
        detail = r.json()["detail"]
        assert detail["code"] == "PREMIUM_REQUIRED" and detail["upgrade_to"] == "plus"
        assert "sell faster" in detail["message"]

    async def test_a_plan_gets_a_description_from_the_photo(self, client, premium_on, monkeypatch):
        prompts, images = [], []
        _model(monkeypatch, raw=json.dumps({
            "reply": "A clean Galaxy A54.",
            "description": "**Brand:** Samsung\n- Model: Galaxy A54\n- Storage : 128 GB\n"
                           "Condition: Used - light scratches on the back",
            "questions": [{"label": "Battery health", "question": "What's the battery health?"}],
        }), prompts=prompts, images=images)
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": {**DRAFT, "description": "Barely used"},
                                    "image_base64": _photo_b64(), "conversation": True})
        assert r.status_code == 200, r.text
        body = r.json()
        # Lines a buyer scans, with the model's markdown and bullets gone.
        assert body["description"] == ("Brand: Samsung\nModel: Galaxy A54\nStorage: 128 GB\n"
                                       "Condition: Used - light scratches on the back")
        assert body["questions"] == [{"label": "Battery health", "question": "What's the battery health?"}]
        assert body["reply"] == "A clean Galaxy A54."
        # The photo went to a model that must see it, and the seller's own
        # words went with it.
        assert images[0][0] and images[0][1] is True
        assert "Samsung Galaxy A54" in prompts[0] and "Barely used" in prompts[0]
        assert await _used(client, headers, "ai_descriptions") == 1

    async def test_it_asks_for_lines_not_a_report(self, client, premium_on, monkeypatch):
        """The seller's complaint (2026-10-06): "It has a RAM of 4 GB and
        storage of 128 GB" reads like a report - a buyer wants "RAM: 4 GB".
        And it asks for what buyers of this kind of item filter on."""
        prompts = []
        _model(monkeypatch, raw=json.dumps({"description": "Brand: Samsung", "questions": []}),
               prompts=prompts)
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": {**DRAFT, "subcategory": "Phones"},
                                    "image_base64": _photo_b64(), "conversation": True})
        assert r.status_code == 200, r.text
        assert '"RAM: 4 GB", not "It has a RAM of 4 GB"' in prompts[0]
        assert "No introduction, summary paragraph" in prompts[0]
        # The phone's own fields, from the same list the wizard asked in.
        assert "battery health" in prompts[0] and "ram" in prompts[0]
        assert '"questions"' in prompts[0]
        assert r.json()["questions"] == [] and r.json()["reply"]

    async def test_it_does_not_ask_for_what_it_wrote_and_asks_for_what_it_left_blank(
            self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({
            "description": "Storage: 128 GB\nRAM:\nOpen 8:00-17:00",
            "questions": [{"label": "Storage", "question": "How much storage?"}] +
                         [{"label": f"Thing {i}", "question": f"Thing {i}?"} for i in range(8)],
        }))
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64(), "conversation": True})
        body = r.json()
        # A colon inside a value is not a label.
        assert body["description"] == "Storage: 128 GB\nOpen 8:00-17:00"
        labels = [q["label"] for q in body["questions"]]
        assert "Storage" not in labels
        assert len(labels) == 5 and "Thing 0" in labels

    async def test_an_older_build_gets_the_questions_as_lines_to_fill(self, client, premium_on, monkeypatch):
        """A build from before the conversation shows only the description,
        and tells the seller to fill in what Zeno left blank."""
        _model(monkeypatch, raw=json.dumps({
            "description": "Brand: Samsung",
            "questions": [{"label": "Battery health", "question": "What's the battery health?"},
                          {"label": "RAM", "question": "How much RAM?"}],
        }))
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64()})
        assert r.status_code == 200, r.text
        assert r.json()["description"] == "Brand: Samsung\nBattery health: \nRAM: "

    async def test_prose_is_still_a_description(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="**Samsung Galaxy A54** in clean condition.\nBattery health: ")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64(), "conversation": True})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["description"] == "Samsung Galaxy A54 in clean condition."
        assert body["questions"] == [{"label": "Battery health", "question": "Battery health?"}]

    async def test_nothing_usable_gives_the_description_back(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"reply": "Hmm.", "description": "", "questions": []}))
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64(), "conversation": True})
        assert r.status_code == 502
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_a_failed_model_gives_the_description_back(self, client, premium_on, monkeypatch):
        _model(monkeypatch, fail=True)
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers,
                              json={"draft": DRAFT, "image_base64": _photo_b64()})
        assert r.status_code == 503
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_no_photo_costs_nothing(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="x")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe", headers=headers, json={"draft": DRAFT})
        assert r.status_code == 400
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_no_vision_provider_is_a_refusal_not_a_guess(self, monkeypatch):
        """Without a model that can see, the description is not written
        from the title: the seller would post invented details as theirs."""
        from api.domains.ai_broker.service import AIBrokerService
        svc = AIBrokerService()
        svc.gemini_key = svc.deepseek_key = None

        async def text_only(*a, **kw):
            raise AssertionError("a text model was asked to describe a photo it can't see")

        monkeypatch.setattr(AIBrokerService, "_call_groq", text_only)
        monkeypatch.setattr(AIBrokerService, "_call_openrouter", text_only)
        with pytest.raises(HTTPException) as exc:
            await svc.write_listing_description("aGk=", ["Title: x"], "", "English")
        assert exc.value.status_code == 503


TURN = {
    "draft": DRAFT,
    "description": "Brand: Samsung\nModel: Galaxy A54",
    "questions": [{"label": "Battery health", "question": "What's the battery health?"},
                  {"label": "RAM", "question": "How much RAM?"}],
    "message": "Battery is 87%, RAM I don't know",
    "history": [{"role": "assistant", "content": "A clean Galaxy A54."}],
}


class TestDescribeTurn:
    async def test_the_answers_go_in_as_lines_for_free(self, client, premium_on, monkeypatch):
        prompts, images = [], []
        _model(monkeypatch, prompts=prompts, images=images, raw=json.dumps({
            "reply": "Added the battery health. That covers it.",
            "description": "Brand: Samsung\nModel: Galaxy A54\nBattery health: 87%",
            "questions": [],
        }))
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe/turn", headers=headers, json=TURN)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["description"] == "Brand: Samsung\nModel: Galaxy A54\nBattery health: 87%"
        assert body["questions"] == [] and body["reply"].startswith("Added the battery health")
        # Zeno read the description so far, what it asked and the answer -
        # and no photo: the answer is the seller's, not something to see.
        assert "Model: Galaxy A54" in prompts[0]
        assert "Battery health: What's the battery health?" in prompts[0]
        assert "Battery is 87%, RAM I don't know" in prompts[0]
        assert images[0] == (None, False)
        assert await _used(client, headers, "ai_descriptions") == 0

    async def test_a_spent_month_still_finishes_the_description(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"description": "Brand: Samsung", "questions": []}))
        me, headers = await _user("plus")
        from api.domains.premium import entitlements
        async with AsyncSessionLocal() as db:
            await entitlements.consume(db, me.id, entitlements.Feature.AI_DESCRIPTION,
                                       n=plans.PREMIUM_BY_ID["plus"].ai_descriptions)
            await db.commit()
        r = await client.post("/zeno/listing-draft/describe/turn", headers=headers, json=TURN)
        assert r.status_code == 200, r.text

    async def test_without_a_plan_it_is_refused(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="should not be called", fail=True)
        _, headers = await _user()
        r = await client.post("/zeno/listing-draft/describe/turn", headers=headers, json=TURN)
        assert r.status_code == 402

    async def test_a_lost_model_keeps_the_description(self, client, premium_on, monkeypatch):
        """A model that answers in prose must not replace the seller's
        description with whatever it said."""
        _model(monkeypatch, raw="Sorry, could you say that again?")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe/turn", headers=headers, json=TURN)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["description"] == TURN["description"]
        assert [q["label"] for q in body["questions"]] == ["Battery health", "RAM"]
        assert body["reply"] == "Sorry, could you say that again?"

    async def test_an_answer_needs_words(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="{}")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/describe/turn", headers=headers,
                              json={**TURN, "message": "  "})
        assert r.status_code == 422


class TestPrice:
    async def test_plus_is_offered_pro(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw="{}")
        _, headers = await _user("plus")
        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": DRAFT, "message": "What should I charge?"})
        assert r.status_code == 402
        detail = r.json()["detail"]
        assert detail["code"] == "PREMIUM_REQUIRED" and detail["upgrade_to"] == "pro"
        assert "sells faster" in detail["message"]

    async def test_talking_is_free_and_offers_the_check(self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps(
            {"reply": "Around KES 32,000.", "suggested_price": 32000.4, "offer_research": True}))
        _, headers = await _user("pro")
        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": {**DRAFT, "asking_price": 40000},
                                    "message": "What should I charge?"})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["suggested_price"] == 32000 and body["offer_research"] is True
        assert body["comparables"] is None
        assert "Their price so far: KES 40,000" in prompts[0]
        assert await _used(client, headers, "price_checks") == 0

    async def test_the_check_prices_against_similar_live_listings(self, client, premium_on, monkeypatch):
        prompts = []
        _model(monkeypatch, prompts=prompts, raw=json.dumps(
            {"reply": "Most ask about 30K.", "suggested_price": 31000, "offer_research": True}))
        me, headers = await _user("pro")
        other, _ = await _user()
        for price in (28000, 30000, 33000):
            await _listing(other, "Samsung Galaxy A54 128GB", price, attributes='{"storage": "128GB"}')
        # None of these is a comparable: the seller's own, an auction's
        # opening bid, a price per something else, and another category.
        await _listing(me, "Samsung Galaxy A54", 1000)
        await _listing(other, "Samsung Galaxy A54", 500, listing_type=ListingType.auction)
        await _listing(other, "Samsung Galaxy A54", 900, price_unit="month")
        await _listing(other, "Samsung Galaxy A54 sofa", 2000, category="Furniture")

        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": DRAFT, "research": True})
        assert r.status_code == 200, r.text
        body = r.json()
        found = body["comparables"]
        assert found["count"] == 3
        assert (found["low"], found["median"], found["high"]) == (28000, 30000, 33000)
        assert {item["price"] for item in found["listings"]} == {28000, 30000, 33000}
        assert body["offer_research"] is False  # never offered twice
        assert "<<<COMPARABLES" in prompts[0] and "median KES 30,000" in prompts[0]
        assert await _used(client, headers, "price_checks") == 1

    async def test_a_price_it_could_not_list_is_dropped(self, client, premium_on, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"reply": "Ask a lot.", "suggested_price": 99_000_000}))
        _, headers = await _user("elite")
        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": DRAFT, "message": "Price?"})
        assert r.json()["suggested_price"] is None

    async def test_the_numbers_survive_a_failed_model(self, client, premium_on, monkeypatch):
        _model(monkeypatch, fail=True)
        _, headers = await _user("pro")
        other, _ = await _user()
        await _listing(other, "Nokia G42 phone", 15000, attributes='{"storage": "64GB"}')
        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": {"name": "Nokia G42 phone", "category": "Electronics"},
                                    "research": True})
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["comparables"]["count"] >= 1 and body["suggested_price"] == 15000
        assert "similar listing" in body["reply"]

    async def test_with_premium_off_it_is_free(self, client, monkeypatch):
        _model(monkeypatch, raw=json.dumps({"reply": "About 30K.", "suggested_price": 30000}))
        _, headers = await _user()
        r = await client.post("/zeno/listing-draft/price/turn", headers=headers,
                              json={"draft": DRAFT, "message": "Price?"})
        assert r.status_code == 200, r.text
