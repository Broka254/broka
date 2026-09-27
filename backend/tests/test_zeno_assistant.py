"""
BROKA - Zeno as the user's assistant (POST /zeno/assistant/turn)
Run: pytest backend/tests/test_zeno_assistant.py -v

What is under test is everything that is not the model: the commands
answered without one, the closed vocabulary the model's proposals are cut
down to, and - the part that matters most - that "call Jane" can only ever
mean someone the user is already talking to on BROKA. The model is stubbed
throughout, as in the Buying Agent's tests.
"""
import json
import uuid

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, User, Listing, NegotiationMessage
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_assistant.db"
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


async def _user(name: str) -> User:
    user = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _listing(seller: User, name: str) -> Listing:
    listing = Listing(seller_id=seller.id, name=name, category="Electronics",
                      price=1000.0, lat=-1.29, lng=36.82)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


async def _thread(listing: Listing, buyer: User) -> None:
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer.id, role="buyer",
                                  buyer_id=buyer.id, content="Is this still available?"))
        await db.commit()


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


def _model(monkeypatch, *, reply="", action=None, raw=None, fail=False, prompts=None):
    """Stub the one LLM entry point. raw= returns that text as-is."""
    from api.domains.ai_broker.service import AIBrokerService

    async def fake_call(self, messages, cache_key=None):
        if prompts is not None:
            prompts.append(messages[0]["content"])
        if fail:
            raise HTTPException(status_code=503, detail="AI service temporarily unavailable.")
        if raw is not None:
            return raw
        return json.dumps({"reply": reply, "action": action or {"type": "NONE"}})

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)


def _no_model(monkeypatch):
    """Fail the test if the model is asked at all."""
    from api.domains.ai_broker.service import AIBrokerService

    async def boom(self, messages, cache_key=None):
        raise AssertionError("the model was called for a plain command")

    monkeypatch.setattr(AIBrokerService, "_call_ai", boom)


async def _turn(client, user, message, **extra):
    resp = await client.post("/zeno/assistant/turn", headers=_auth(user),
                             json={"message": message, **extra})
    assert resp.status_code == 200, resp.text
    return resp.json()


class TestPlainCommandsNeedNoModel:
    @pytest.mark.asyncio
    async def test_opening_a_screen(self, client, monkeypatch):
        me = await _user("Amina Otieno")
        _no_model(monkeypatch)
        out = await _turn(client, me, "Hey Zeno, open my inbox")
        assert out["action"] == {"type": "NAVIGATE", "destination": "inbox"}
        assert out["reply"] == "Opening your inbox."
        assert out["source"] == "rules"

    @pytest.mark.asyncio
    async def test_in_kiswahili(self, client, monkeypatch):
        me = await _user("Baraka Mwangi")
        _no_model(monkeypatch)
        out = await _turn(client, me, "fungua mipangilio", language="swahili")
        assert out["action"] == {"type": "NAVIGATE", "destination": "settings"}
        assert out["reply"].startswith("Nafungua")

    @pytest.mark.asyncio
    async def test_search_and_finding_for_me(self, client, monkeypatch):
        me = await _user("Chebet Kiprop")
        _no_model(monkeypatch)
        out = await _turn(client, me, "search for toyota axio")
        assert out["action"] == {"type": "SEARCH", "query": "toyota axio"}
        out = await _turn(client, me, "find me a laptop under 50k")
        assert out["action"] == {"type": "FIND_FOR_ME", "query": "a laptop under 50k"}

    @pytest.mark.asyncio
    async def test_a_sentence_that_only_mentions_a_screen_goes_to_the_model(self, client, monkeypatch):
        me = await _user("Dan Kamau")
        prompts = []
        _model(monkeypatch, reply="A 2014 Axio goes for 850K-950K.", prompts=prompts)
        out = await _turn(client, me, "I want to sell my car, what is it worth?")
        assert out["action"] is None
        assert out["reply"] == "A 2014 Axio goes for 850K-950K."
        assert len(prompts) == 1


class TestCallsOnlyReachPeopleYouTalkTo:
    @pytest.mark.asyncio
    async def test_buyer_calls_the_seller_they_messaged(self, client, monkeypatch):
        seller = await _user("Jane Wanjiru")
        me = await _user("Eric Buyer")
        axio = await _listing(seller, "Toyota Axio 2014")
        await _thread(axio, me)
        _no_model(monkeypatch)

        out = await _turn(client, me, "video call Jane")
        action = out["action"]
        assert action["type"] == "CALL" and action["call_type"] == "video"
        assert action["requires_confirmation"] is True
        assert action["target"] == {
            "listing_id": axio.id, "listing_name": "Toyota Axio 2014",
            "peer_id": seller.id, "peer_name": "Jane Wanjiru",
            "role": "buyer", "buyer_id": me.id,
        }
        assert out["reply"] == "Video calling Jane - just confirm."

    @pytest.mark.asyncio
    async def test_seller_calls_the_buyer_who_messaged(self, client, monkeypatch):
        me = await _user("Faith Seller")
        buyer = await _user("George Omondi")
        chair = await _listing(me, "Office chair")
        await _thread(chair, buyer)
        _no_model(monkeypatch)

        out = await _turn(client, me, "call george")
        target = out["action"]["target"]
        assert target["role"] == "seller"
        assert target["buyer_id"] == buyer.id
        assert target["peer_id"] == buyer.id

    @pytest.mark.asyncio
    async def test_a_stranger_with_the_same_name_is_never_offered(self, client, monkeypatch):
        # Some other user is called Hassan; the caller has never talked to
        # them. "call Hassan" must not resolve to them - with or without
        # the model's help.
        stranger = await _user("Hassan Stranger")
        other_seller = await _user("Ivy Unrelated")
        stranger_listing = await _listing(stranger, "Hassan's bike")
        await _thread(stranger_listing, other_seller)
        me = await _user("Juma Caller")
        _model(monkeypatch, reply="Calling Hassan - just confirm.",
               action={"type": "CALL", "contact": "Hassan", "call_type": "audio"})

        out = await _turn(client, me, "call hassan")
        assert out["action"] is None
        assert "couldn't find" in out["reply"]
        assert stranger.id not in json.dumps(out)

    @pytest.mark.asyncio
    async def test_the_model_cannot_name_an_id(self, client, monkeypatch):
        # Whatever the model writes into the action, the target comes from
        # the user's own threads - an id it made up is simply ignored.
        victim = await _user("Kevin Target")
        me = await _user("Lucy Asker")
        _model(monkeypatch, reply="Sure.", action={
            "type": "CALL", "contact": "Kevin", "call_type": "audio",
            "target": {"peer_id": victim.id, "listing_id": "x", "role": "buyer"},
        })
        out = await _turn(client, me, "can you get kevin on the phone")
        assert out["action"] is None
        assert victim.id not in json.dumps(out)

    @pytest.mark.asyncio
    async def test_two_people_with_one_name_are_asked_about(self, client, monkeypatch):
        mary_a = await _user("Mary Achieng")
        mary_b = await _user("Mary Njeri")
        me = await _user("Nick Buyer")
        sofa = await _listing(mary_a, "Leather sofa")
        tv = await _listing(mary_b, "Samsung TV")
        await _thread(sofa, me)
        await _thread(tv, me)
        _no_model(monkeypatch)

        out = await _turn(client, me, "call mary")
        action = out["action"]
        assert action["type"] == "CALL"
        assert "target" not in action
        assert {c["peer_id"] for c in action["choices"]} == {mary_a.id, mary_b.id}
        assert out["reply"].startswith("Which one - ")
        # Naming the listing settles it.
        out = await _turn(client, me, "call mary about the sofa")
        assert out["action"]["target"]["listing_id"] == sofa.id

    @pytest.mark.asyncio
    async def test_the_same_person_over_two_listings_is_one_person(self, client, monkeypatch):
        seller = await _user("Otieno Two")
        me = await _user("Pat Buyer")
        first = await _listing(seller, "Fridge")
        second = await _listing(seller, "Cooker")
        await _thread(first, me)
        await _thread(second, me)
        _no_model(monkeypatch)
        out = await _turn(client, me, "message otieno")
        assert out["action"]["type"] == "OPEN_CHAT"
        assert out["action"]["target"]["peer_id"] == seller.id
        # Opening a chat is not a call: nothing to confirm.
        assert out["action"]["requires_confirmation"] is False

    @pytest.mark.asyncio
    async def test_call_it_a_day_is_not_a_call(self, client, monkeypatch):
        me = await _user("Quinn Tired")
        _model(monkeypatch, reply="Rest well - I'll be here.")
        out = await _turn(client, me, "call it a day")
        assert out["action"] is None
        assert out["reply"] == "Rest well - I'll be here."


class TestTheModelProposesThisModuleDecides:
    @pytest.mark.asyncio
    async def test_an_invented_action_is_just_talk(self, client, monkeypatch):
        me = await _user("Rose Test")
        _model(monkeypatch, reply="Done!", action={"type": "TRANSFER_MONEY", "amount": 5000})
        out = await _turn(client, me, "send 5000 to my friend")
        assert out["action"] is None
        assert out["reply"] == "Done!"

    @pytest.mark.asyncio
    async def test_an_unknown_screen_is_just_talk(self, client, monkeypatch):
        me = await _user("Sam Test")
        _model(monkeypatch, reply="Opening admin.", action={"type": "NAVIGATE", "destination": "admin"})
        out = await _turn(client, me, "take me to the admin panel")
        assert out["action"] is None

    @pytest.mark.asyncio
    async def test_a_screen_the_model_picks(self, client, monkeypatch):
        me = await _user("Tom Test")
        _model(monkeypatch, reply="Here are your deals.",
               action={"type": "NAVIGATE", "destination": "deal_history"})
        out = await _turn(client, me, "where can I see what I bought last month?")
        assert out["action"] == {"type": "NAVIGATE", "destination": "deal_history"}
        assert out["reply"] == "Here are your deals."

    @pytest.mark.asyncio
    async def test_prose_instead_of_json_still_answers(self, client, monkeypatch):
        me = await _user("Uma Test")
        _model(monkeypatch, raw="Escrow holds your money until you confirm delivery.")
        out = await _turn(client, me, "how does escrow work?")
        assert out["reply"] == "Escrow holds your money until you confirm delivery."
        assert out["action"] is None

    @pytest.mark.asyncio
    async def test_every_provider_down_still_answers(self, client, monkeypatch):
        me = await _user("Vera Test")
        _model(monkeypatch, fail=True)
        out = await _turn(client, me, "what's a fair price for a used iPhone 12?")
        assert out["action"] is None
        assert out["source"] == "fallback"
        assert "open my inbox" in out["reply"]
        # ...and the plain commands still work while it is down.
        out = await _turn(client, me, "open settings")
        assert out["action"] == {"type": "NAVIGATE", "destination": "settings"}

    @pytest.mark.asyncio
    async def test_voice_asks_for_speakable_replies(self, client, monkeypatch):
        me = await _user("Wanja Test")
        prompts = []
        _model(monkeypatch, reply="Sure.", prompts=prompts)
        await _turn(client, me, "tell me about escrow", mode="voice")
        await _turn(client, me, "tell me about escrow")
        assert "hear your reply spoken aloud" in prompts[0]
        assert "hear your reply spoken aloud" not in prompts[1]


class TestTheRequest:
    @pytest.mark.asyncio
    async def test_signed_out_is_refused(self, client):
        resp = await client.post("/zeno/assistant/turn", json={"message": "open inbox"})
        assert resp.status_code in (401, 403)

    @pytest.mark.asyncio
    async def test_a_long_conversation_is_trimmed_not_refused(self, client, monkeypatch):
        me = await _user("Xena Long")
        prompts = []
        _model(monkeypatch, reply="Still here.", prompts=prompts)
        history = [{"role": "user" if i % 2 == 0 else "assistant", "content": f"turn {i} " + "x" * 3000}
                   for i in range(120)]
        out = await _turn(client, me, "and now?", history=history)
        assert out["reply"] == "Still here."
        assert "turn 119" in prompts[0] and "turn 90 " not in prompts[0]

    @pytest.mark.asyncio
    async def test_the_message_is_bounded(self, client):
        me = await _user("Yusuf Long")
        resp = await client.post("/zeno/assistant/turn", headers=_auth(me),
                                 json={"message": "x" * 1001})
        assert resp.status_code == 422
