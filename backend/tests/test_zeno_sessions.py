"""Zeno's daily sessions for free accounts (premium/zeno_sessions.py).

What must hold:
  * a session is a conversation, not a message: every question about one
    listing that day is one listing session, and a Buying Agent hunt is one
    agent session however many turns it takes;
  * "Find me something similar" on a listing hands its hunt to the Buying
    Agent as part of that listing's session - the whole process is one use;
  * a free account gets two of each a day, refused before the model is
    paid for, renewing at midnight in Kenya; a plan holder is never counted;
  * the user's own listing and the escrow walkthrough are never a session,
    and a turn no model answered gives its session back;
  * two first questions at the same moment cannot overrun the limit.
"""
import asyncio
import dataclasses
import json
import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient

from main import app
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.domains.premium import zeno_sessions
from api.models.subscription import Subscription
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_sessions.db"
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
def two_a_day():
    """The production numbers - the rest of the suite runs with them lifted
    (conftest.py)."""
    before = (settings.zeno_free_listing_sessions_per_day, settings.zeno_free_agent_sessions_per_day)
    object.__setattr__(settings, "zeno_free_listing_sessions_per_day", 2)
    object.__setattr__(settings, "zeno_free_agent_sessions_per_day", 2)
    yield
    object.__setattr__(settings, "zeno_free_listing_sessions_per_day", before[0])
    object.__setattr__(settings, "zeno_free_agent_sessions_per_day", before[1])


@pytest.fixture
def model(monkeypatch):
    """The one LLM entry point, answering every turn; its calls are counted."""
    from api.domains.ai_broker.service import AIBrokerService
    calls = []

    async def fake_call(self, messages, cache_key=None, image_base64=None):
        calls.append(messages[0]["content"])
        return json.dumps({"reply": "Fair enough for that one.", "action": {"type": "NONE"}})

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)
    return calls


@pytest.fixture
def agent(monkeypatch):
    """The Buying Agent's conversation, stubbed: what is under test is who
    may start a hunt, not the hunt."""
    converse = AsyncMock(return_value={"phase": "ASKING", "reply": "Which one?", "slots": {},
                                       "questions_asked": 1, "matches": []})
    monkeypatch.setattr("api.domains.buy_agent.conversation.converse", converse)
    return converse


async def _user(plan: str | None = None) -> tuple[User, dict]:
    u = User(name="Amina Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
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


async def _listing(seller: User, name: str = "Oraimo Spacebuds") -> Listing:
    listing = Listing(seller_id=seller.id, name=name, category="Electronics", price=1500.0,
                      lat=-1.29, lng=36.82)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


async def _ask(client, headers, listing_id, message="Is this a fair price?", **extra):
    return await client.post("/zeno/assistant/turn", headers=headers,
                             json={"message": message, "listing_id": listing_id, **extra})


async def _hunt(client, headers, message="I need a laptop", history=(), **extra):
    return await client.post("/buy-agent-requests/converse", headers=headers,
                             json={"message": message, "history": list(history), **extra})


async def _today(client, headers) -> dict:
    r = await client.get("/zeno/sessions/today", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


_EARLIER = [{"role": "user", "content": "I need a laptop"}, {"role": "assistant", "content": "Which one?"}]


class TestListingSessions:
    @pytest.mark.asyncio
    async def test_every_question_about_one_listing_is_one_session(self, client, model):
        seller, _ = await _user()
        _, buyer = await _user()
        listing = await _listing(seller)
        for q in ("Is this a fair price?", "Is this seller reliable?", "What should I check?"):
            assert (await _ask(client, buyer, listing.id, q)).status_code == 200
        today = await _today(client, buyer)
        assert today["limited"] is True
        assert today["listing"] == {"limit": 2, "used": 1, "left": 1, "listing_ids": [listing.id]}

    @pytest.mark.asyncio
    async def test_the_third_listing_of_the_day_is_refused_before_the_model(self, client, model):
        seller, _ = await _user()
        _, buyer = await _user()
        a = await _listing(seller, "Item A")
        b = await _listing(seller, "Item B")
        c = await _listing(seller, "Item C")
        assert (await _ask(client, buyer, a.id)).status_code == 200
        assert (await _ask(client, buyer, b.id)).status_code == 200
        calls = len(model)
        refused = await _ask(client, buyer, c.id)
        assert refused.status_code == 402
        detail = refused.json()["detail"]
        assert detail["code"] == "ZENO_SESSIONS_USED"
        assert detail["feature"] == "zeno_listing_sessions" and detail["limit"] == 2
        assert detail["upgrade_to"] is None, "no plan is on sale while PREMIUM_ENABLED is off"
        assert "renew at midnight" in detail["message"]
        assert len(model) == calls, "refused before the model was paid for"
        # A listing already asked about today is still open.
        assert (await _ask(client, buyer, a.id, "and delivery?")).status_code == 200

    @pytest.mark.asyncio
    async def test_with_plans_on_sale_the_refusal_offers_one(self, client, model, monkeypatch):
        monkeypatch.setattr("api.domains.premium.zeno_sessions.settings",
                            dataclasses.replace(settings, premium_enabled=True,
                                                zeno_free_listing_sessions_per_day=2,
                                                zeno_free_agent_sessions_per_day=2))
        seller, _ = await _user()
        _, buyer = await _user()
        listings = [await _listing(seller, f"Thing {i}") for i in range(3)]
        for l in listings[:2]:
            assert (await _ask(client, buyer, l.id)).status_code == 200
        detail = (await _ask(client, buyer, listings[2].id)).json()["detail"]
        assert detail["upgrade_to"] == "plus" and "BROKA Plus" in detail["message"]

    @pytest.mark.asyncio
    async def test_a_plan_holder_is_never_counted(self, client, model):
        seller, _ = await _user()
        _, member = await _user(plan="plus")
        for i in range(4):
            listing = await _listing(seller, f"Plan item {i}")
            assert (await _ask(client, member, listing.id)).status_code == 200
        today = await _today(client, member)
        assert today["limited"] is False and today["listing"]["left"] is None

    @pytest.mark.asyncio
    async def test_the_sellers_own_listing_and_the_escrow_walkthrough_are_free(self, client, model):
        seller, seller_h = await _user()
        _, buyer = await _user()
        own = await _listing(seller, "Mine")
        other = await _listing(seller, "Theirs")
        for _ in range(3):
            assert (await _ask(client, seller_h, own.id, "How can I sell this faster?")).status_code == 200
        assert (await _ask(client, buyer, other.id, "Help me pay with escrow")).status_code == 200
        assert (await _today(client, seller_h))["listing"]["used"] == 0
        assert (await _today(client, buyer))["listing"]["used"] == 0

    @pytest.mark.asyncio
    async def test_a_turn_no_model_answered_gives_its_session_back(self, client, monkeypatch):
        from api.domains.ai_broker.service import AIBrokerService

        async def down(self, messages, cache_key=None, image_base64=None):
            raise HTTPException(status_code=503, detail="AI service temporarily unavailable.")
        monkeypatch.setattr(AIBrokerService, "_call_ai", down)
        seller, _ = await _user()
        _, buyer = await _user()
        listing = await _listing(seller)
        r = await _ask(client, buyer, listing.id)
        assert r.status_code == 200 and r.json()["source"] == "fallback"
        assert (await _today(client, buyer))["listing"]["used"] == 0

    @pytest.mark.asyncio
    async def test_a_new_day_in_kenya_brings_them_back(self, client, model, monkeypatch):
        seller, _ = await _user()
        _, buyer = await _user()
        listings = [await _listing(seller, f"Day item {i}") for i in range(3)]
        for l in listings[:2]:
            assert (await _ask(client, buyer, l.id)).status_code == 200
        assert (await _ask(client, buyer, listings[2].id)).status_code == 402
        tomorrow = datetime.utcnow() + timedelta(days=1)
        monkeypatch.setattr(zeno_sessions, "_now", lambda: tomorrow)
        assert (await _ask(client, buyer, listings[2].id)).status_code == 200

    def test_the_day_turns_at_midnight_in_kenya(self):
        # 21:30 UTC is 00:30 the next day in Nairobi.
        assert zeno_sessions.kenya_day(datetime(2026, 11, 12, 20, 59)) == "2026-11-12"
        assert zeno_sessions.kenya_day(datetime(2026, 11, 12, 21, 30)) == "2026-11-13"
        assert zeno_sessions.renews_at(datetime(2026, 11, 12, 10, 0)) == datetime(2026, 11, 12, 21, 0)

    @pytest.mark.asyncio
    async def test_two_first_questions_at_once_cannot_overrun_the_limit(self):
        seller, _ = await _user()
        buyer, _ = await _user()
        listings = [await _listing(seller, f"Race item {i}") for i in range(4)]

        async def admit(listing_id):
            async with AsyncSessionLocal() as db:
                try:
                    await zeno_sessions.admit_listing(db, buyer.id, listing_id)
                    return True
                except HTTPException as exc:
                    assert exc.status_code == 402
                    return False

        results = await asyncio.gather(*(admit(l.id) for l in listings))
        assert sorted(results) == [False, False, True, True]


class TestBuyingAgentSessions:
    @pytest.mark.asyncio
    async def test_a_hunt_is_one_session_however_many_turns(self, client, agent):
        _, buyer = await _user()
        assert (await _hunt(client, buyer)).status_code == 200
        for _ in range(3):
            assert (await _hunt(client, buyer, "with 16GB", history=_EARLIER)).status_code == 200
        assert (await _today(client, buyer))["agent"] == {"limit": 2, "used": 1, "left": 1}

    @pytest.mark.asyncio
    async def test_the_third_hunt_of_the_day_is_refused_before_the_model_runs(self, client, agent):
        _, buyer = await _user()
        assert (await _hunt(client, buyer, "a laptop")).status_code == 200
        assert (await _hunt(client, buyer, "a fridge")).status_code == 200
        calls = agent.await_count
        refused = await _hunt(client, buyer, "a sofa")
        assert refused.status_code == 402
        assert refused.json()["detail"]["feature"] == "zeno_agent_sessions"
        assert agent.await_count == calls
        # The hunt already under way carries on.
        assert (await _hunt(client, buyer, "cheaper", history=_EARLIER)).status_code == 200

    @pytest.mark.asyncio
    async def test_find_me_something_similar_is_part_of_the_listings_session(self, client, model, agent):
        seller, _ = await _user()
        _, buyer = await _user()
        listing = await _listing(seller)
        asked = (await _ask(client, buyer, listing.id, "Find me something similar")).json()
        action = asked["action"]
        assert action["type"] == "FIND_FOR_ME" and action["from_listing_id"] == listing.id

        handed = await _hunt(client, buyer, action["query"], slots=action["slots"],
                             from_listing_id=action["from_listing_id"])
        assert handed.status_code == 200
        kwargs = agent.await_args.kwargs
        assert kwargs["exclude_listing_id"] == listing.id and kwargs["search_now"] is True
        assert (await _hunt(client, buyer, "cheaper", history=_EARLIER,
                            from_listing_id=listing.id)).status_code == 200
        today = await _today(client, buyer)
        assert today["listing"]["used"] == 1 and today["agent"]["used"] == 0, \
            "the listing's questions and the hunt they handed over are one use"
        # Both of the day's own hunts are still there.
        assert (await _hunt(client, buyer, "a laptop")).status_code == 200
        assert (await _hunt(client, buyer, "a fridge")).status_code == 200
        assert (await _hunt(client, buyer, "a sofa")).status_code == 402

    @pytest.mark.asyncio
    async def test_a_listing_never_asked_about_does_not_make_a_hunt_free(self, client, agent):
        seller, _ = await _user()
        _, buyer = await _user()
        listing = await _listing(seller)
        for _ in range(2):
            assert (await _hunt(client, buyer, "earbuds", from_listing_id=listing.id)).status_code == 200
        assert (await _hunt(client, buyer, "earbuds", from_listing_id=listing.id)).status_code == 402

    @pytest.mark.asyncio
    async def test_a_plan_holder_hunts_as_often_as_they_like(self, client, agent):
        _, member = await _user(plan="pro")
        for _ in range(4):
            assert (await _hunt(client, member, "a laptop")).status_code == 200
