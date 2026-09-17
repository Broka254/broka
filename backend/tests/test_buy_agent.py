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
        assert res.json()["category"] == "electronics"

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
        create = await client.post("/listings/", json={
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
        create = await client.post("/listings/", json={
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
