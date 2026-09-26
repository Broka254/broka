"""
BROKA - Conversational Buying Agent tests
Run: pytest backend/tests/test_buy_agent_conversation.py -v

Covers the two things that make the Buying Agent an agent rather than a
form: that it ASKS before it searches, and that when it searches it comes
back with the closest thing it could find plus an honest account of what
that thing falls short on - instead of "0 results found".

The LLM itself is stubbed throughout. What is under test is the turn
policy, the scoring, and the honesty of the verdict - all of which live in
our code precisely so they are testable without a model in the loop.
"""

import json
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_buy_agent_convo.db"
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


async def _register(client, phone, name, email) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    token = verify.json()["phone_verify_token"]
    await client.post("/auth/register", json={
        "phone_verify_token": token, "name": name, "email": email,
        "password": "TestPass123!", "lat": -1.286, "lng": 36.817,
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    return login.json()["access_token"]


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    return await _register(client, "0755110011", "Sam Seller", "sam.convo@test.ke")


@pytest_asyncio.fixture(scope="module")
async def buyer_token(client):
    return await _register(client, "0755110022", "Xavier Buyer", "xavier.convo@test.ke")


def _stub_ai(monkeypatch, *, turn: dict, narration: str = "Here's what I found."):
    """Stub the single LLM entry point every AI path in this codebase goes
    through, so the turn policy and scoring are what's actually tested."""
    from api.domains.ai_broker.service import AIBrokerService

    async def fake_call(self, messages, cache_key=None):
        prompt = messages[0]["content"]
        if "finished searching on a buyer's behalf" in prompt:
            return narration
        return json.dumps(turn)

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)


class TestConversationalBuyingAgent:
    @pytest.mark.asyncio
    async def test_vague_opening_gets_a_question_not_a_search(self, client, buyer_token, monkeypatch):
        """"I'm looking for an iPhone" used to fire a search for the word
        "iPhone" immediately - no model, no specs, nothing asked. This is
        the whole complaint the rewrite exists to answer."""
        _stub_ai(monkeypatch, turn={
            "action": "ASK",
            "reply": "Nice — which iPhone are you after, and how much RAM and storage do you need?",
            "slots": {"query": "iPhone", "category": "Electronics", "subcategory": "Phones",
                      "attributes": {"brand": "Apple"}},
        })
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "I'm looking for an iPhone", "history": [], "questions_asked": 0,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["phase"] == "ASKING"
        assert "which iPhone" in body["reply"]
        assert body["matches"] == []
        assert body["questions_asked"] == 1
        # The criteria it did pick up are carried forward, not thrown away.
        assert body["slots"]["subcategory"] == "Phones"

    @pytest.mark.asyncio
    async def test_zeno_stops_asking_and_searches(self, client, buyer_token, monkeypatch):
        """An agent that keeps asking is worse than one that shows you its
        best guess - so the question budget is enforced here, not left to
        the model's judgement."""
        _stub_ai(monkeypatch, turn={
            "action": "ASK",  # the model wants to ask a third time
            "reply": "And what colour?",
            "slots": {"query": "iPhone 14", "category": "Electronics", "subcategory": "Phones"},
        }, narration="Found a couple of options for you.")
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "just get on with it", "history": [], "questions_asked": 2,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        body = res.json()
        assert body["phase"] == "RESULTS"
        assert "colour" not in body["reply"]

    @pytest.mark.asyncio
    async def test_cannot_search_with_nothing_to_search_for(self, client, buyer_token, monkeypatch):
        """SEARCH on empty criteria returns the whole marketplace, which is
        not an answer to anything - so it is forced back to a question."""
        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "", "slots": {"query": None, "category": None},
        })
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "hi", "history": [], "questions_asked": 0,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        body = res.json()
        assert body["phase"] == "ASKING"
        assert body["reply"]  # never an empty bubble

    @pytest.mark.asyncio
    async def test_near_miss_is_returned_and_named_instead_of_zero_results(
        self, client, buyer_token, seller_token, monkeypatch
    ):
        """THE point of the rewrite. A buyer wants 12GB RAM; the only
        iPhone 14 on Broka is 8GB. The old search hard-filtered attributes,
        so this was "0 results found" and the buyer never learned why.
        """
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "iPhone 14 128GB", "category": "Electronics", "price": 78000,
            "lat": -1.286, "lng": 36.817,
            "attributes": {"brand": "Apple", "ram": "8GB", "storage": "128GB"},
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201, create.text

        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "iPhone 14", "category": "Electronics", "subcategory": "Phones",
                      "attributes": {"ram": "12GB", "storage": "128GB"}},
        }, narration="Closest I could get is one, but it's 8GB not 12GB.")
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "iPhone 14, at least 12GB RAM and 128GB storage",
            "history": [], "questions_asked": 1,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        body = res.json()

        assert body["phase"] == "RESULTS"
        assert len(body["matches"]) >= 1, "a near miss must come back, not be filtered away"
        match = next(m for m in body["matches"] if m["name"] == "iPhone 14 128GB")

        # It is NOT presented as a match...
        assert match["match_is_exact"] is False
        assert body["verdict"] == "PARTIAL"
        # ...and what it falls short on is a concrete fact, not a percentage.
        ram_miss = next(m for m in match["match_misses"] if m["field"] == "ram")
        assert ram_miss["wanted"] == "12GB"
        assert ram_miss["actual"] == "8GB"
        # storage was asked for and met, so it is not a shortfall.
        assert not any(m["field"] == "storage" for m in match["match_misses"])
        # Zeno is told, explicitly, that nothing met the RAM ask.
        assert "ram" in body["unmet"]

    @pytest.mark.asyncio
    async def test_exact_match_is_called_a_match(self, client, buyer_token, seller_token, monkeypatch):
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Samsung Galaxy S23", "category": "Electronics", "price": 62000,
            "lat": -1.286, "lng": 36.817,
            "attributes": {"brand": "Samsung", "ram": "12GB"},
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201

        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "Samsung Galaxy S23", "category": "Electronics",
                      "max_price": 70000, "attributes": {"ram": "12GB"}},
        }, narration="Found it.")
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "Samsung Galaxy S23, 12GB, under 70k", "history": [], "questions_asked": 1,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        body = res.json()
        top = body["matches"][0]
        assert top["name"] == "Samsung Galaxy S23"
        assert top["match_is_exact"] is True
        assert top["match_misses"] == []

    @pytest.mark.asyncio
    async def test_over_budget_listing_ranks_below_but_still_appears(
        self, client, buyer_token, seller_token, monkeypatch
    ):
        """A buyer who says "under 50k" and is shown nothing has no idea
        whether 55k would have got them one. Over-budget results come back,
        ranked below and labelled."""
        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Hisense TV 43 inch", "category": "Electronics", "price": 47000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Hisense TV 55 inch", "category": "Electronics", "price": 58000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})

        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "Hisense TV", "category": "Electronics", "max_price": 50000},
        })
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "Hisense TV under 50k", "history": [], "questions_asked": 1,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        names = [m["name"] for m in res.json()["matches"]]
        assert "Hisense TV 43 inch" in names
        assert "Hisense TV 55 inch" in names, "the over-budget option must still be offered"
        assert names.index("Hisense TV 43 inch") < names.index("Hisense TV 55 inch")
        over = next(m for m in res.json()["matches"] if m["name"] == "Hisense TV 55 inch")
        assert any(m["field"] == "max_price" for m in over["match_misses"])

    @pytest.mark.asyncio
    async def test_buyers_own_listing_is_never_offered_back_to_them(
        self, client, buyer_token, monkeypatch
    ):
        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "My Own Nikon Camera", "category": "Electronics", "price": 30000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {buyer_token}"})

        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "Nikon Camera", "category": "Electronics"},
        })
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "find me a nikon camera", "history": [], "questions_asked": 1,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert all(m["name"] != "My Own Nikon Camera" for m in res.json()["matches"])

    @pytest.mark.asyncio
    async def test_empty_result_still_speaks_and_offers_a_way_forward(
        self, client, buyer_token, monkeypatch
    ):
        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "helicopter", "category": "Vehicles"},
        }, narration="")  # model gives nothing - the deterministic fallback must carry it
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "find me a helicopter", "history": [], "questions_asked": 2,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        body = res.json()
        assert body["verdict"] == "EMPTY"
        assert body["matches"] == []
        assert body["reply"], "Zeno must always say something"
        assert "watching" in body["reply"].lower()

    @pytest.mark.asyncio
    async def test_question_budget_resets_once_results_are_on_screen(
        self, client, buyer_token, monkeypatch
    ):
        """MAX_QUESTIONS is "questions before a search", not a lifetime
        allowance. Once the buyer can see real results, the next thing they
        say is usually about those results - Zeno answering "which one?"
        should not be blocked by a counter it spent getting there."""
        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "office chair", "category": "Home & Furniture"},
        }, narration="Found a few. Which one shall we look at?")
        after_search = await client.post("/buy-agent-requests/converse", json={
            "message": "office chair", "history": [], "questions_asked": 2,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert after_search.json()["phase"] == "RESULTS"
        assert after_search.json()["questions_asked"] == 0

        # With the budget back, a genuine follow-up question is allowed.
        _stub_ai(monkeypatch, turn={
            "action": "ASK", "reply": "Happy to — which of those caught your eye?",
            "slots": {"query": "office chair", "category": "Home & Furniture"},
        })
        follow_up = await client.post("/buy-agent-requests/converse", json={
            "message": "tell me more about them", "history": [],
            "questions_asked": after_search.json()["questions_asked"],
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert follow_up.json()["phase"] == "ASKING"

    @pytest.mark.asyncio
    async def test_dropping_the_budget_mid_conversation_actually_drops_it(
        self, client, buyer_token, monkeypatch
    ):
        """"Don't worry about the price, just get on with it" has to be able
        to clear a budget the buyer gave earlier - so price is deliberately
        NOT carried forward when the model omits it, unlike category."""
        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            # Model returns no category and no max_price this turn.
            "slots": {"query": "iPhone 14", "attributes": {}},
        })
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "forget the price, just go",
            "history": [{"role": "user", "content": "iPhone 14 under 50k"}],
            "slots": {"query": "iPhone 14", "category": "Electronics", "max_price": 50000},
            "questions_asked": 1,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        slots = res.json()["slots"]
        assert slots["max_price"] is None, "the buyer waived the budget - it must clear"
        assert slots["category"] == "Electronics", "category is structural and carries forward"

    @pytest.mark.asyncio
    async def test_a_dead_model_does_not_break_the_conversation(
        self, client, buyer_token, monkeypatch
    ):
        from api.domains.ai_broker.service import AIBrokerService

        async def dead(self, messages, cache_key=None):
            raise RuntimeError("every provider is down")

        monkeypatch.setattr(AIBrokerService, "_call_ai", dead)
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "I want a laptop", "history": [], "questions_asked": 0,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert res.status_code == 200
        assert res.json()["reply"]


class TestConversationReview:
    """Regression tests for the buying-agent review (2026-09-26). Fresh
    buyers throughout: /converse is on ai_chat_limiter (20 a minute)."""

    @pytest.mark.asyncio
    async def test_malformed_slots_from_the_client_are_not_a_500(self, client, monkeypatch):
        """`slots` came back from the client unchecked. A non-string
        category was used as a dict key before any model call (TypeError:
        unhashable), and on the model-down path the raw slots went straight
        into scoring, where a string budget met a float - both a 500 on the
        one screen whose fallbacks exist so it never 500s."""
        from api.domains.ai_broker.service import AIBrokerService

        buyer = await _register(client, "0755110033", "Odd Slots", "odd.slots@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}

        _stub_ai(monkeypatch, turn={"action": "ASK", "reply": "Which laptop?", "slots": {}})
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "a laptop", "history": [], "questions_asked": 0,
            "slots": {"category": ["Electronics"], "subcategory": {"a": 1}},
        }, headers=headers)
        assert res.status_code == 200, res.text

        async def dead(self, messages, cache_key=None):
            raise RuntimeError("every provider is down")

        monkeypatch.setattr(AIBrokerService, "_call_ai", dead)
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "just search", "history": [], "questions_asked": 2,
            "slots": {"query": "laptop", "max_price": "fifty thousand", "min_price": [1],
                      "max_distance_km": "far", "attributes": "ram=8GB", "condition": 7},
        }, headers=headers)
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["phase"] == "RESULTS"
        assert body["slots"]["max_price"] is None
        assert body["slots"]["attributes"] == {}

    @pytest.mark.asyncio
    async def test_client_slots_cannot_inflate_the_prompt(self, client, monkeypatch):
        """history and message are clipped before they reach a billed
        prompt; slots were pasted in whole, so one request could make every
        turn's prompt as large as the 32MB body cap allows."""
        from api.domains.ai_broker.service import AIBrokerService

        prompts = []

        async def capture(self, messages, cache_key=None):
            prompts.append(messages[0]["content"])
            return json.dumps({"action": "ASK", "reply": "Which one?", "slots": {}})

        monkeypatch.setattr(AIBrokerService, "_call_ai", capture)
        buyer = await _register(client, "0755110044", "Big Slots", "big.slots@test.ke")
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "a phone", "history": [], "questions_asked": 0,
            "slots": {"query": "q" * 50_000, "padding": "p" * 50_000,
                      "attributes": {f"k{i}": "v" * 500 for i in range(200)}},
        }, headers={"Authorization": f"Bearer {buyer}"})
        assert res.status_code == 200, res.text
        assert prompts and len(prompts[0]) < 15_000, len(prompts[0])

    @pytest.mark.asyncio
    async def test_the_named_item_is_found_even_past_the_ranked_pool(
        self, client, seller_token, monkeypatch
    ):
        """The candidate pool was the category's top-N by BROKA ranking,
        with the buyer's own words playing no part in which rows got in. In
        a category busier than the pool, the listing a buyer names exactly
        can rank outside it - and Zeno answered "closest I could get" with
        unrelated items while the real thing sat on the marketplace."""
        from api.domains.buy_agent import conversation

        target = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Fender Stratocaster Electric Guitar", "category": "Music & Instruments", "price": 90000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert target.status_code == 201
        for i in range(4):  # newer, so they out-rank it on the tie-break
            await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
                "name": f"Cajon Drum Box {i}", "category": "Music & Instruments", "price": 7000 + i,
                "lat": -1.286, "lng": 36.817,
            }, headers={"Authorization": f"Bearer {seller_token}"})

        monkeypatch.setattr(conversation, "CANDIDATE_POOL", 3)
        _stub_ai(monkeypatch, turn={
            "action": "SEARCH", "reply": "",
            "slots": {"query": "Fender Stratocaster", "category": "Music & Instruments"},
        })
        buyer = await _register(client, "0755110055", "Strat Buyer", "strat.buyer@test.ke")
        res = await client.post("/buy-agent-requests/converse", json={
            "message": "a fender stratocaster", "history": [], "questions_asked": 2,
        }, headers={"Authorization": f"Bearer {buyer}"})
        body = res.json()
        assert body["phase"] == "RESULTS"
        assert body["matches"] and body["matches"][0]["id"] == target.json()["id"], [
            m["name"] for m in body["matches"]]

    @pytest.mark.asyncio
    async def test_parse_intent_existing_filters_cannot_inflate_the_prompt(self, client, monkeypatch):
        """/parse-intent pasted `existing_filters` into its prompt with
        json.dumps and no bound - the same hole as /converse's slots."""
        from api.domains.ai_broker.service import AIBrokerService

        prompts = []

        async def capture(self, messages, cache_key=None):
            prompts.append(messages[0]["content"])
            return "{}"

        monkeypatch.setattr(AIBrokerService, "_call_ai", capture)
        buyer = await _register(client, "0755110066", "Big Filters", "big.filters@test.ke")
        res = await client.post("/buy-agent-requests/parse-intent", json={
            "text": "cheaper please",
            "existing_filters": {"query": "q" * 50_000, "junk": "j" * 50_000,
                                 "category": "Electronics", "max_price": 50000},
        }, headers={"Authorization": f"Bearer {buyer}"})
        assert res.status_code == 200, res.text
        assert prompts and len(prompts[0]) < 15_000, len(prompts[0])
        # What the follow-up is meant to refine still reaches the model.
        assert '"max_price": 50000' in prompts[0]
