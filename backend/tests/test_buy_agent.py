"""
BROKA - Buy-Agent Tests
Run: pytest backend/tests/test_buy_agent.py -v

Covers the one-active-request-per-buyer cap and, most importantly, the
full match -> opening message -> disclosure flag chain end to end, since
that's Chapter 22's non-negotiable requirement for this feature.
"""

import asyncio
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    """CI runs a real Redis service container (REDIS_URL is set), so
    settings.redis_enabled is True and publish() would route ListingCreated
    to a Redis Stream instead of calling buy_agent_subscribers.py's
    in-process handler that this test depends on. Force the in-process
    path, same fixture as test_events_v4.py uses for the same reason."""
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_buy_agent.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
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
    verify_token = verify.json()["phone_verify_token"]
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token, "name": name, "email": email,
        "password": "TestPass123!", "lat": -1.286, "lng": 36.817,
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    return login.json()["access_token"]


@pytest_asyncio.fixture(scope="module")
async def buyer_token(client):
    return await _register(client, "0766001100", "Mary Buyer", "mary.buyer@test.ke")


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    return await _register(client, "0766002200", "Nick Seller", "nick.seller@test.ke")


class TestBuyAgent:
    @pytest.mark.asyncio
    async def test_create_request_then_second_request_is_rejected(self, client, buyer_token):
        headers = {"Authorization": f"Bearer {buyer_token}"}
        first = await client.post("/buy-agent-requests", json={
            "category": "electronics", "max_price": 50000, "must_have_features": ["8GB RAM"],
            # negotiation_authorized: this test (below, same class) verifies
            # a match auto-opens a negotiation thread - that only happens
            # when the buyer has pre-authorized it (see buy_agent_subscribers.py
            # and Design v2 §24: "Zeno must not negotiate automatically...
            # unless the user has pre-authorized"). Without this, matching
            # still occurs (status -> "matched", match_count increments)
            # but no message is sent - a separate, equally real scenario
            # this test doesn't currently cover.
            "negotiation_authorized": True,
        }, headers=headers)
        assert first.status_code == 200
        assert first.json()["status"] == "active"

        second = await client.post("/buy-agent-requests", json={
            "category": "furniture", "max_price": 20000,
        }, headers=headers)
        assert second.status_code == 409

    @pytest.mark.asyncio
    async def test_get_me_returns_active_request(self, client, buyer_token):
        res = await client.get("/buy-agent-requests/me", headers={"Authorization": f"Bearer {buyer_token}"})
        assert res.status_code == 200
        # Canonicalised, not echoed: the test above posts "electronics" and
        # the row stores the real Category.name. Before the buying-agent
        # bug-hunt (2026-09-17) whatever the client typed was stored
        # verbatim, and buy_agent_subscribers.py compared it to
        # Listing.category with a case-SENSITIVE `==` - so a buyer who
        # typed a different case than the seller never matched anything on
        # PostgreSQL. Both ends are fixed; this asserts the storage half.
        assert res.json()["category"] == "Electronics"

    @pytest.mark.asyncio
    async def test_matching_listing_opens_disclosed_negotiation_thread(
        self, client, buyer_token, seller_token
    ):
        # The active request from the first test (electronics, <= 50000,
        # must_have_features=["8GB RAM"]) should match a new listing in the
        # same category, under that price, that actually satisfies the
        # stated requirement. "8GB RAM" has to appear in the listing's own
        # text - buy_agent_subscribers.py's must_have_features check
        # (ChatGPT-review audit, 2026-08-15) is a best-effort text match
        # against name+description, not structured attribute comparison,
        # so the listing has to actually say it, the same way a real
        # seller's listing would need to for a real buyer to find it this way.
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Samsung Galaxy A54 8GB RAM", "category": "electronics", "price": 42000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201  # POST /listings/ is status_code=201 (see router.py)
        listing_id = create.json()["id"]
        await asyncio.sleep(0.05)  # let the in-process subscriber run

        history = await client.get(
            f"/negotiate/{listing_id}/history",
            headers={"Authorization": f"Bearer {seller_token}"},
        )
        assert history.status_code == 200
        broker_msgs = [m for m in history.json() if m["role"] == "broker"]
        assert len(broker_msgs) == 1
        assert broker_msgs[0]["is_agent_initiated"] is True
        assert "Zeno" in broker_msgs[0]["content"]

        # FIX (redesign-guide audit, Round 4, 2026-08-13): this used to
        # assert None here. BuyAgentService.get_active_for_buyer previously
        # only ever queried status=="active", so a request became invisible
        # to this endpoint the instant it matched - home_screen.dart's
        # "Match found!" display branch had real code that could never
        # actually be reached. Now correctly surfaces a "matched" request
        # too (see CHANGES.md Round 4). A matched request still counts
        # against the one-request cap, since it is still watching (see
        # TestBuyAgentReview.test_a_matched_request_still_counts_against_the_cap).
        me = await client.get("/buy-agent-requests/me", headers={"Authorization": f"Bearer {buyer_token}"})
        assert me.json() is not None
        assert me.json()["status"] == "matched"
        assert me.json()["match_count"] == 1

    @pytest.mark.asyncio
    async def test_non_matching_listing_does_not_open_a_thread(self, client, buyer_token, seller_token):
        headers = {"Authorization": f"Bearer {buyer_token}"}
        # The matched electronics request from above still holds the one
        # slot, so it is cancelled first - otherwise this create is a 409
        # and the test below checks nothing about the furniture request.
        cancelled = await client.post("/buy-agent-requests/action", json={
            "action": "CANCEL_REQUEST", "parameters": {},
        }, headers=headers)
        assert cancelled.json()["status"] == "SUCCESS"
        made = await client.post("/buy-agent-requests", json={
            "category": "furniture", "max_price": 10000, "negotiation_authorized": True,
        }, headers=headers)
        assert made.status_code == 200, made.json()

        # Wrong category - should not match.
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Office Chair", "category": "electronics", "price": 8000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        listing_id = create.json()["id"]
        await asyncio.sleep(0.05)

        history = await client.get(
            f"/negotiate/{listing_id}/history",
            headers={"Authorization": f"Bearer {seller_token}"},
        )
        broker_msgs = [m for m in history.json() if m["role"] == "broker"]
        assert len(broker_msgs) == 0


class TestBuyAgentBugHunt:
    """Regression tests for the buying-agent bug-hunt pass (2026-09-17).

    Every test here failed before the corresponding fix - they are the
    reason each change is in the diff, not a restatement of the code.
    """

    @pytest.mark.asyncio
    async def test_search_finds_a_listing_with_no_subcategory(self, client, seller_token):
        """THE headline bug. _search_products passed category_id, which
        ListingService.list_listings turns into
        `Listing.subcategory_id IN (...)`. subcategory_id is nullable and
        routinely null (the sell wizard's subcategory step is optional), so
        a category-scoped search - the Buying Agent Hub's primary flow -
        returned ZERO results for those listings, while the exact same
        listing matched fine through the standing-request matcher.
        """
        buyer = await _register(client, "0766003300", "Cat Buyer", "cat.buyer@test.ke")
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Solar Water Pump 2HP", "category": "Agriculture", "price": 31000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201
        assert create.json()["subcategory_id"] is None  # the case that used to be invisible

        res = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS",
            "parameters": {"category": "Agriculture"},
        }, headers={"Authorization": f"Bearer {buyer}"})
        assert res.status_code == 200
        body = res.json()
        assert body["status"] == "SUCCESS", body
        assert body["result_count"] >= 1
        assert any(m["id"] == create.json()["id"] for m in body["matches"])

    @pytest.mark.asyncio
    async def test_search_rejects_out_of_range_paging_and_inverted_prices(self, client, seller_token):
        buyer = await _register(client, "0766003400", "Page Buyer", "page.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}

        # limit/offset were unbounded ints straight off the wire.
        bad_limit = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS", "parameters": {"limit": 100000},
        }, headers=headers)
        assert bad_limit.json()["status"] == "FAILED"
        assert bad_limit.json()["error_code"] == "INVALID_PARAMETERS"

        bad_offset = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS", "parameters": {"offset": -5},
        }, headers=headers)
        assert bad_offset.json()["status"] == "FAILED"

        inverted = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS", "parameters": {"min_price": 900, "max_price": 100},
        }, headers=headers)
        assert inverted.json()["status"] == "FAILED"
        assert inverted.json()["error_code"] == "INVALID_PRICE_RANGE"

    @pytest.mark.asyncio
    async def test_search_result_count_matches_what_is_returned(self, client, seller_token):
        """result_count used to be the raw SQL total while only the ranking
        pool was ever paginated, so the Hub could print a number no page of
        the same response could reach."""
        buyer = await _register(client, "0766003500", "Count Buyer", "count.buyer@test.ke")
        res = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS", "parameters": {"limit": 50},
        }, headers={"Authorization": f"Bearer {buyer}"})
        body = res.json()
        assert body["status"] == "SUCCESS"
        assert body["result_count"] >= len(body["matches"])
        assert body["result_count"] <= body["total_available"]
        if not body["has_more"]:
            assert body["offset"] + len(body["matches"]) == body["result_count"]

    @pytest.mark.asyncio
    async def test_auto_opener_never_tells_the_seller_the_buyers_budget(self, client, seller_token):
        """The auto-opener used to say "...under KES 50,000" verbatim -
        handing the seller the buyer's ceiling before a word was
        negotiated."""
        buyer = await _register(client, "0766003600", "Budget Buyer", "budget.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        made = await client.post("/buy-agent-requests", json={
            "category": "Vehicles", "max_price": 777777, "negotiation_authorized": True,
        }, headers=headers)
        assert made.status_code == 200

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Toyota Probox 2014", "category": "Vehicles", "price": 640000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        listing_id = create.json()["id"]
        await asyncio.sleep(0.05)

        history = await client.get(
            f"/negotiate/{listing_id}/history",
            headers={"Authorization": f"Bearer {seller_token}"},
        )
        broker = [m for m in history.json() if m["role"] == "broker"]
        assert len(broker) == 1
        assert "777,777" not in broker[0]["content"]
        assert "777777" not in broker[0]["content"]

    @pytest.mark.asyncio
    async def test_match_count_keeps_counting_past_the_first_match(self, client, seller_token):
        """The candidate query selected status=="active" only, while the
        first match set status="matched" - so a standing request stopped
        watching the instant it matched once and match_count could never
        exceed 1, though both UIs render "N matches found"."""
        buyer = await _register(client, "0766003700", "Many Buyer", "many.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        assert (await client.post("/buy-agent-requests", json={
            "category": "Home & Furniture", "max_price": 90000,
        }, headers=headers)).status_code == 200

        for i in range(2):
            r = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
                "name": f"Mahogany Dining Set {i}", "category": "Home & Furniture", "price": 40000 + i,
                "lat": -1.286, "lng": 36.817,
            }, headers={"Authorization": f"Bearer {seller_token}"})
            assert r.status_code == 201
            await asyncio.sleep(0.05)

        me = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert me["status"] == "matched"
        assert me["match_count"] == 2

    @pytest.mark.asyncio
    async def test_a_buyers_own_listing_never_matches_their_own_request(self, client):
        """Nothing excluded listing.seller_id == req.buyer_id, so anyone who
        both buys and sells got Zeno opening a negotiation with them about
        their own item."""
        both = await _register(client, "0766003800", "Both Ways", "both.ways@test.ke")
        headers = {"Authorization": f"Bearer {both}"}
        assert (await client.post("/buy-agent-requests", json={
            "category": "Fashion", "max_price": 20000, "negotiation_authorized": True,
        }, headers=headers)).status_code == 200

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Leather Jacket", "category": "Fashion", "price": 9000,
            "lat": -1.286, "lng": 36.817,
        }, headers=headers)
        listing_id = create.json()["id"]
        await asyncio.sleep(0.05)

        history = await client.get(f"/negotiate/{listing_id}/history", headers=headers)
        assert [m for m in history.json() if m["role"] == "broker"] == []
        me = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert me["status"] == "active"
        assert me["match_count"] == 0

    @pytest.mark.asyncio
    async def test_listing_below_the_buyers_floor_does_not_match(self, client, seller_token):
        buyer = await _register(client, "0766003900", "Floor Buyer", "floor.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        made = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Sports & Fitness", "min_price": 50000, "max_price": 200000},
        }, headers=headers)
        assert made.json()["status"] == "SUCCESS", made.json()

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Second-hand Bicycle", "category": "Sports & Fitness", "price": 6000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201
        await asyncio.sleep(0.05)

        me = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert me["status"] == "active"
        assert me["match_count"] == 0

    @pytest.mark.asyncio
    async def test_start_negotiation_is_idempotent_per_thread(self, client, seller_token):
        """Every tap of the Hub's "Ask Zeno to negotiate" button wrote a
        fresh opener, so a buyer tapping twice sent the seller two identical
        Zeno messages on the same thread."""
        buyer = await _register(client, "0766004000", "Nego Buyer", "nego.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Ex-UK Laptop i7", "category": "Electronics", "price": 55000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        listing_id = create.json()["id"]

        first = await client.post("/buy-agent-requests/action", json={
            "action": "START_NEGOTIATION", "parameters": {"listing_id": listing_id},
        }, headers=headers)
        assert first.json()["status"] == "SUCCESS", first.json()
        assert first.json()["already_open"] is False

        second = await client.post("/buy-agent-requests/action", json={
            "action": "START_NEGOTIATION", "parameters": {"listing_id": listing_id},
        }, headers=headers)
        assert second.json()["status"] == "SUCCESS"
        assert second.json()["already_open"] is True
        assert second.json()["message_id"] == first.json()["message_id"]
        # The already-open response deliberately carries no message content:
        # the row is addressed to the seller and the buyer reads the thread
        # through negotiate.py's own audience-scoped history instead. See
        # tests/test_message_visibility_guard.py.
        assert "opening_message" not in second.json()

        history = await client.get(
            f"/negotiate/{listing_id}/history",
            headers={"Authorization": f"Bearer {seller_token}"},
        )
        assert len([m for m in history.json() if m["role"] == "broker"]) == 1

    @pytest.mark.asyncio
    async def test_start_negotiation_rejects_own_and_missing_listings(self, client, seller_token):
        own = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "My Own Sofa", "category": "Home & Furniture", "price": 15000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        res = await client.post("/buy-agent-requests/action", json={
            "action": "START_NEGOTIATION", "parameters": {"listing_id": own.json()["id"]},
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert res.json()["error_code"] == "INVALID_TARGET"

        missing = await client.post("/buy-agent-requests/action", json={
            "action": "START_NEGOTIATION", "parameters": {"listing_id": "does-not-exist"},
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert missing.json()["error_code"] == "LISTING_NOT_FOUND"

    @pytest.mark.asyncio
    async def test_non_positive_budget_is_rejected(self, client):
        """max_price <= 0 used to be stored happily as a standing request
        that no listing can ever satisfy (ListingCreate requires price > 0),
        so it just sat there matching nothing forever."""
        buyer = await _register(client, "0766004100", "Zero Buyer", "zero.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        assert (await client.post("/buy-agent-requests", json={
            "category": "Electronics", "max_price": 0,
        }, headers=headers)).status_code == 422
        assert (await client.post("/buy-agent-requests", json={
            "category": "Electronics", "max_price": -1000,
        }, headers=headers)).status_code == 422

        inverted = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Electronics", "max_price": 1000, "min_price": 9000},
        }, headers=headers)
        assert inverted.json()["error_code"] == "INVALID_PRICE_RANGE"

    @pytest.mark.asyncio
    async def test_update_then_cancel_round_trip(self, client):
        buyer = await _register(client, "0766004200", "Edit Buyer", "edit.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        assert (await client.post("/buy-agent-requests", json={
            "category": "Electronics", "max_price": 30000,
        }, headers=headers)).status_code == 200

        bumped = await client.post("/buy-agent-requests/action", json={
            "action": "CHANGE_BUDGET", "parameters": {"max_price": 45000},
        }, headers=headers)
        assert bumped.json()["status"] == "SUCCESS", bumped.json()
        assert bumped.json()["request"]["max_price"] == 45000

        # A rejected update must not leave the attempted values behind.
        bad = await client.post("/buy-agent-requests/action", json={
            "action": "CHANGE_BUDGET", "parameters": {"min_price": 90000},
        }, headers=headers)
        assert bad.json()["error_code"] == "INVALID_PRICE_RANGE"
        still = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert still["max_price"] == 45000
        assert still["min_price"] is None

        cancelled = await client.post("/buy-agent-requests/action", json={
            "action": "CANCEL_REQUEST", "parameters": {},
        }, headers=headers)
        assert cancelled.json()["request"]["status"] == "cancelled"
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json() is None
        # The cancelled slot is genuinely free again.
        assert (await client.post("/buy-agent-requests", json={
            "category": "Home & Furniture", "max_price": 12000,
        }, headers=headers)).status_code == 200

    @pytest.mark.asyncio
    async def test_category_matching_is_case_insensitive_end_to_end(self, client, seller_token):
        """Listing.category is free text a seller typed; a standing request
        holds the canonical Category.name. Compared with a case-SENSITIVE
        `==` on both the matcher and the search, a seller who wrote
        "electronics" was invisible to a buyer watching "Electronics" on
        PostgreSQL - which is what production runs."""
        buyer = await _register(client, "0766004300", "Case Buyer", "case.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        assert (await client.post("/buy-agent-requests", json={
            "category": "Music & Instruments", "max_price": 80000,
        }, headers=headers)).status_code == 200

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Yamaha Keyboard PSR", "category": "music & instruments", "price": 35000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201
        await asyncio.sleep(0.05)

        me = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert me["status"] == "matched", me
        assert me["match_count"] == 1

        found = await client.post("/buy-agent-requests/action", json={
            "action": "SEARCH_PRODUCTS", "parameters": {"category": "Music & Instruments"},
        }, headers=headers)
        assert any(m["id"] == create.json()["id"] for m in found.json()["matches"])

    @pytest.mark.asyncio
    async def test_a_match_notifies_the_buyer(self, client, seller_token, monkeypatch):
        """Both entry points promise it in writing ("you'll be notified when
        a match comes in") and nothing sent anything before this pass."""
        sent = []

        async def _capture(token, title, body, data):
            sent.append((token, title, body, data))

        from api.core import push as push_module
        monkeypatch.setattr(push_module.push_service, "send", _capture)

        buyer = await _register(client, "0766004400", "Push Buyer", "push.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        # PATCH /auth/fcm-token takes the token as a query param, not a body.
        reg = await client.patch("/auth/fcm-token?fcm_token=test-device-token", headers=headers)
        assert reg.status_code == 200, reg.text
        assert (await client.post("/buy-agent-requests", json={
            "category": "Pets & Animals", "max_price": 60000,
        }, headers=headers)).status_code == 200

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "German Shepherd Puppy", "category": "Pets & Animals", "price": 25000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201
        await asyncio.sleep(0.05)

        assert len(sent) == 1, sent
        assert sent[0][0] == "test-device-token"
        assert "German Shepherd Puppy" in sent[0][2]
        assert sent[0][3]["listing_id"] == create.json()["id"]


def _on_postgres() -> bool:
    from api import database
    return database.DATABASE_URL.startswith("postgresql")


class TestBuyAgentReview:
    """Regression tests for the buying-agent review (2026-09-26).

    Each one failed on the code before the fix it is named after."""

    @pytest.mark.asyncio
    async def test_start_negotiation_never_puts_the_buyers_words_in_zenos_mouth(
        self, client, seller_token
    ):
        """START_NEGOTIATION's optional `message` was stored as Zeno's own
        opener (role="broker", via_ai=True). The app never sends one, so the
        only way to reach it was a hand-made request - and it let any buyer
        write whatever they liked into a seller's inbox under Zeno's name:
        "BROKA needs a KES 500 verification fee first, send it to 07..."."""
        buyer = await _register(client, "0766005100", "Voice Buyer", "voice.buyer@test.ke")
        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Canon EOS 250D", "category": "Electronics", "price": 52000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        listing_id = create.json()["id"]

        scam = "BROKA requires a KES 500 verification fee before this deal, send it to 0700000000"
        res = await client.post("/buy-agent-requests/action", json={
            "action": "START_NEGOTIATION",
            "parameters": {"listing_id": listing_id, "message": scam},
        }, headers={"Authorization": f"Bearer {buyer}"})
        assert res.json()["status"] == "SUCCESS", res.json()

        history = (await client.get(
            f"/negotiate/{listing_id}/history",
            headers={"Authorization": f"Bearer {seller_token}"},
        )).json()
        broker = [m for m in history if m["role"] == "broker"]
        assert broker and all(scam not in m["content"] for m in broker), broker
        # The buyer's words still arrive - as the buyer's.
        assert any(m["role"] == "buyer" and m["content"] == scam for m in history), history

    @pytest.mark.asyncio
    async def test_a_matched_request_still_counts_against_the_cap(self, client, seller_token):
        """A "matched" request keeps watching (and auto-messaging sellers)
        but did not count against BUY_AGENT_MAX_ACTIVE. So after a first
        match the buyer could start a second watch; GET /me, update and
        cancel only ever see the newest row, and the first went on
        matching, pushing and opening negotiations where the buyer could
        neither see nor stop it."""
        buyer = await _register(client, "0766005200", "Ghost Buyer", "ghost.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        first = await client.post("/buy-agent-requests", json={
            "category": "Gaming", "max_price": 90000, "negotiation_authorized": True,
        }, headers=headers)
        assert first.status_code == 200

        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "PlayStation 5 Slim", "category": "Gaming", "price": 65000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["status"] == "matched"

        second = await client.post("/buy-agent-requests", json={
            "category": "Books & Education", "max_price": 5000,
        }, headers=headers)
        assert second.status_code == 409, second.json()
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["id"] == first.json()["id"]

        # Cancelling is still the way to free the slot.
        cancelled = await client.post("/buy-agent-requests/action", json={
            "action": "CANCEL_REQUEST", "parameters": {},
        }, headers=headers)
        assert cancelled.json()["status"] == "SUCCESS"
        assert (await client.post("/buy-agent-requests", json={
            "category": "Books & Education", "max_price": 5000,
        }, headers=headers)).status_code == 200

    @pytest.mark.asyncio
    @pytest.mark.skipif(not _on_postgres(), reason="Postgres only (tests/postgres_plugin.py)")
    async def test_two_creates_at_once_cannot_exceed_the_cap(self, client, monkeypatch):
        """count-then-insert, re-counted after the flush, still let two
        concurrent creates through on PostgreSQL: each transaction's
        re-count sees its own uncommitted row and never the other's. The
        buyer's row is now locked for the check, so the second create waits
        for the first and then sees it."""
        from api.database import AsyncSessionLocal, BuyAgentRequest
        from api.domains.buy_agent.service import BuyAgentService
        from fastapi import HTTPException
        from sqlalchemy import func, select

        buyer = await _register(client, "0766005300", "Race Buyer", "race.buyer@test.ke")
        buyer_id = (await client.get("/auth/me", headers={"Authorization": f"Bearer {buyer}"})).json()["id"]

        # Hold each create just after its count, until the other has counted
        # too (or half a second has passed, which is what happens when the
        # second is correctly waiting on the lock).
        real_count = BuyAgentService._active_count
        arrived = []
        both = asyncio.Event()

        async def held_count(self, bid):
            n = await real_count(self, bid)
            arrived.append(n)
            if len(arrived) >= 2:
                both.set()
            try:
                await asyncio.wait_for(both.wait(), 0.5)
            except asyncio.TimeoutError:
                pass
            return n

        monkeypatch.setattr(BuyAgentService, "_active_count", held_count)

        async def attempt(category):
            async with AsyncSessionLocal() as db:
                try:
                    await BuyAgentService(db).create_request(
                        buyer_id=buyer_id, category=category, max_price=1000, must_have_features=[],
                    )
                    return "created"
                except HTTPException as e:
                    return e.status_code

        outcomes = await asyncio.gather(attempt("Electronics"), attempt("Fashion"))
        assert sorted(outcomes, key=str) == sorted(["created", 409], key=str), outcomes

        async with AsyncSessionLocal() as db:
            live = (await db.execute(select(func.count(BuyAgentRequest.id)).where(
                BuyAgentRequest.buyer_id == buyer_id, BuyAgentRequest.status == "active",
            ))).scalar_one()
        assert live == 1

    @pytest.mark.asyncio
    async def test_a_watch_only_matches_listings_of_the_item_it_asked_for(self, client, seller_token):
        """The matcher checked category and price and ignored `query`, so a
        watch Zeno set up for "iPhone 14" fired on any Electronics listing
        under budget - a TV, a kettle - telling the buyer it "matches what
        you asked Zeno to watch for" and, when authorised, telling the
        seller the same."""
        buyer = await _register(client, "0766005400", "Query Buyer", "query.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        made = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Electronics", "query": "Pixel 8", "max_price": 150000},
        }, headers=headers)
        assert made.json()["status"] == "SUCCESS", made.json()

        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "LG Soundbar SN4", "category": "Electronics", "price": 18000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["match_count"] == 0

        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Google Pixel 8 128GB", "category": "Electronics", "price": 70000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["match_count"] == 1

    @pytest.mark.asyncio
    async def test_a_watch_skips_a_listing_that_states_a_spec_short_of_the_ask(self, client, seller_token):
        """Attributes were stored on the standing request and never read
        again. A listing that says 8GB must not be announced as a match for
        a 12GB ask; one that doesn't say is still let through, the same
        "unknown, don't exclude" rule every other field follows."""
        buyer = await _register(client, "0766005500", "Spec Buyer", "spec.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        made = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Baby & Kids", "max_price": 90000,
                           "attributes": {"ram": "12GB"}},
        }, headers=headers)
        assert made.json()["status"] == "SUCCESS", made.json()

        short = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Kids Learning Tablet", "category": "Baby & Kids", "price": 15000,
            "lat": -1.286, "lng": 36.817, "attributes": {"ram": "8GB"},
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert short.status_code == 201, short.text
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["match_count"] == 0

        silent = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Kids Learning Tablet Pro", "category": "Baby & Kids", "price": 25000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert silent.status_code == 201
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["match_count"] == 1

    @pytest.mark.asyncio
    async def test_condition_is_stored_the_way_listings_spell_it(self, client, seller_token):
        """Listings store condition lower-case ("used"). A watch created
        with "Used" was stored as typed and compared with a case-sensitive
        `!=`, so it could never match a single listing; an unknown value
        ("mint") was accepted and matched nothing either."""
        buyer = await _register(client, "0766005600", "Cond Buyer", "cond.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}

        bad = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Arts & Crafts", "max_price": 30000, "condition": "mint"},
        }, headers=headers)
        assert bad.json()["status"] == "FAILED"
        assert bad.json()["error_code"] == "INVALID_PARAMETERS"

        made = await client.post("/buy-agent-requests/action", json={
            "action": "CREATE_BUYING_REQUEST",
            "parameters": {"category": "Arts & Crafts", "max_price": 30000, "condition": "Used"},
        }, headers=headers)
        assert made.json()["status"] == "SUCCESS", made.json()
        assert made.json()["request"]["condition"] == "used"

        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Easel and Oil Paint Set", "category": "Arts & Crafts", "price": 8000,
            "condition": "used", "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await asyncio.sleep(0.05)
        assert (await client.get("/buy-agent-requests/me", headers=headers)).json()["match_count"] == 1

    @pytest.mark.asyncio
    async def test_posting_a_listing_does_not_wait_on_match_notifications(
        self, client, seller_token, monkeypatch
    ):
        """The matcher runs inside POST /listings (event_catalog.emit awaits
        its handlers) and sent one push per matched buyer, one after the
        other, each allowed 15 seconds. A slow FCM made every seller wait
        for every watching buyer's notification before their own listing
        was confirmed."""
        release = asyncio.Event()
        sent = []

        async def slow_send(token, title, body, data):
            await release.wait()
            sent.append(token)

        from api.core import push as push_module
        monkeypatch.setattr(push_module.push_service, "send", slow_send)

        buyer = await _register(client, "0766005700", "Slow Buyer", "slow.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        await client.patch("/auth/fcm-token?fcm_token=slow-device-token", headers=headers)
        assert (await client.post("/buy-agent-requests", json={
            "category": "Health & Medical", "max_price": 40000,
        }, headers=headers)).status_code == 200

        try:
            create = await asyncio.wait_for(client.post("/listings/", json={
                "description": "Well kept, works perfectly - selling because I upgraded.",
                "name": "Omron Blood Pressure Monitor", "category": "Health & Medical", "price": 6000,
                "lat": -1.286, "lng": 36.817,
            }, headers={"Authorization": f"Bearer {seller_token}"}), timeout=3)
        finally:
            release.set()
        assert create.status_code == 201

        for _ in range(100):
            if sent:
                break
            await asyncio.sleep(0.02)
        assert sent == ["slow-device-token"]

    @pytest.mark.asyncio
    async def test_two_matches_at_once_both_count(self, client, seller_token, monkeypatch):
        """match_count was read into Python, incremented and written back,
        so two listings matching the same watch at the same moment both
        wrote 1. It is incremented in SQL now."""
        from api.core import buy_agent_subscribers as subs
        from api.core.event_catalog import EventEnvelope, EventType

        buyer = await _register(client, "0766005800", "Twin Buyer", "twin.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        ids = []
        for name in ("Hardcover Atlas", "Hardcover Dictionary"):
            r = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
                "name": name, "category": "Books & Education", "price": 2500,
                "lat": -1.286, "lng": 36.817,
            }, headers={"Authorization": f"Bearer {seller_token}"})
            ids.append(r.json()["id"])
        # Created after the listings, so neither has matched it yet.
        assert (await client.post("/buy-agent-requests", json={
            "category": "Books & Education", "max_price": 3000,
        }, headers=headers)).status_code == 200

        # Hold each handler's commit until both have loaded the request.
        real_factory = subs.AsyncSessionLocal
        waiting = []
        both = asyncio.Event()

        def factory():
            session = real_factory()
            real_commit = session.commit

            async def held_commit():
                waiting.append(1)
                if len(waiting) >= 2:
                    both.set()
                try:
                    await asyncio.wait_for(both.wait(), 0.5)
                except asyncio.TimeoutError:
                    pass
                await real_commit()

            session.commit = held_commit
            return session

        monkeypatch.setattr(subs, "AsyncSessionLocal", factory)

        def envelope(listing_id):
            return EventEnvelope(
                id=listing_id, type=EventType.LISTING_CREATED, aggregate="listing",
                aggregate_id=listing_id, actor="system",
                payload={"listing_id": listing_id, "category": "Books & Education", "price": 2500},
            )

        await asyncio.gather(*(subs.on_listing_created_match_buy_agents(envelope(i)) for i in ids))
        me = (await client.get("/buy-agent-requests/me", headers=headers)).json()
        assert me["match_count"] == 2, me

    @pytest.mark.asyncio
    async def test_standing_request_fields_are_bounded(self, client):
        """CREATE_BUYING_REQUEST's free-text and JSON fields had no bounds
        at all - they are stored on the row, loaded for every new listing in
        the category, and a negative distance produced a watch that could
        never match anything."""
        buyer = await _register(client, "0766005900", "Big Buyer", "big.buyer@test.ke")
        headers = {"Authorization": f"Bearer {buyer}"}
        for params in (
            {"query": "x" * 5000},
            {"location": "y" * 5000},
            {"must_have_features": ["z" * 5000]},
            {"must_have_features": ["ok"] * 100},
            {"attributes": {f"k{i}": "v" for i in range(200)}},
            {"max_distance_km": -5},
        ):
            res = await client.post("/buy-agent-requests/action", json={
                "action": "CREATE_BUYING_REQUEST",
                "parameters": {"category": "Services", "max_price": 1000, **params},
            }, headers=headers)
            assert res.json()["status"] == "FAILED", (params.keys(), res.json())
            assert res.json()["error_code"] == "INVALID_PARAMETERS"

    @pytest.mark.asyncio
    async def test_the_hot_lookups_are_indexed(self):
        """buy_agent_requests had no index but its primary key; GET /me
        runs on every Home load and the matcher inside every POST /listings,
        each a full scan of a table whose cancelled rows are never removed."""
        from sqlalchemy import text
        from api import database

        async with database.engine.connect() as conn:
            if conn.dialect.name == "postgresql":
                rows = await conn.execute(text(
                    "SELECT indexname FROM pg_indexes WHERE tablename = 'buy_agent_requests'"))
            else:
                rows = await conn.execute(text(
                    "SELECT name FROM sqlite_master WHERE type = 'index' "
                    "AND tbl_name = 'buy_agent_requests'"))
            names = {r[0] for r in rows}
        assert {"ix_buy_agent_requests_buyer_status", "ix_buy_agent_requests_status_category"} <= names

    @pytest.mark.asyncio
    async def test_a_buyer_with_two_live_requests_gets_one_opener_per_thread(
        self, client, seller_token
    ):
        """Rows written before the cap counted "matched" can leave a buyer
        with two live, authorised requests in one category. One new listing
        must still open one thread, not two identical Zeno messages."""
        from api.database import AsyncSessionLocal, BuyAgentRequest
        import json as _json
        import uuid as _uuid
        from datetime import datetime as _dt

        buyer = await _register(client, "0766006000", "Two Rows", "two.rows@test.ke")
        buyer_id = (await client.get("/auth/me", headers={"Authorization": f"Bearer {buyer}"})).json()["id"]
        async with AsyncSessionLocal() as db:
            for status in ("matched", "active"):
                db.add(BuyAgentRequest(
                    id=str(_uuid.uuid4()), buyer_id=buyer_id, category="Construction",
                    max_price=90000, must_have_features=_json.dumps([]), status=status,
                    negotiation_authorized=True, match_count=0, created_at=_dt.utcnow(),
                ))
            await db.commit()

        create = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": "Bosch Concrete Mixer", "category": "Construction", "price": 48000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        await asyncio.sleep(0.05)
        history = (await client.get(
            f"/negotiate/{create.json()['id']}/history?buyer_id={buyer_id}",
            headers={"Authorization": f"Bearer {seller_token}"},
        )).json()
        assert len([m for m in history if m["role"] == "broker"]) == 1, history
