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
        # too (see CHANGES.md Round 4). The buyer remains free to create a
        # *different* standing request afterward regardless - the
        # one-active-request cap only ever counted status=="active"
        # (BuyAgentService.create_request), which this fix doesn't touch.
        me = await client.get("/buy-agent-requests/me", headers={"Authorization": f"Bearer {buyer_token}"})
        assert me.json() is not None
        assert me.json()["status"] == "matched"
        assert me.json()["match_count"] == 1

    @pytest.mark.asyncio
    async def test_non_matching_listing_does_not_open_a_thread(self, client, buyer_token, seller_token):
        await client.post("/buy-agent-requests", json={
            "category": "furniture", "max_price": 10000,
        }, headers={"Authorization": f"Bearer {buyer_token}"})

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
