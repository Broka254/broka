"""
BROKA - Auction Tests
Run: pytest backend/tests/test_auctions.py -v

Confirms the real-time event wiring (a bid publishes BidPlaced) and that
the new domain endpoints read auction_meta correctly, including the
lazy-creation path for auctions that predate the auction_meta migration.
Follows test_listings.py's real fixture convention; the doc's draft
assumed a nonexistent db_session fixture and left listing/user setup as
TODOs.
"""

import asyncio
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.core.events import subscribe, BidPlaced


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    """CI runs a real Redis service container (REDIS_URL is set), so
    settings.redis_enabled is True and publish() would route BidPlaced to
    a Redis Stream instead of calling this test's in-process @subscribe
    handler directly. Force the in-process path, same fixture as
    test_events_v4.py uses for the same reason."""
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_auctions.db"
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
async def seller_token(client):
    return await _register(client, "0755001100", "Ken Seller", "ken.seller@test.ke")


@pytest_asyncio.fixture(scope="module")
async def bidder_token(client):
    return await _register(client, "0755002200", "Lea Bidder", "lea.bidder@test.ke")


class TestAuctions:
    @pytest.mark.asyncio
    async def test_place_bid_publishes_bid_placed_event(self, client, seller_token, bidder_token):
        received = []

        @subscribe(BidPlaced)
        async def _capture(event: BidPlaced):
            received.append(event)

        create = await client.post("/listings/", json={
            "name": "Vintage Watch", "category": "collectibles", "price": 10000,
            "lat": -1.286, "lng": 36.817, "listing_type": "auction",
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create.status_code == 201  # POST /listings/ is status_code=201 (see router.py)
        listing_id = create.json()["id"]

        res = await client.post("/auction/bid", json={
            "listing_id": listing_id, "amount": 11000,
        }, headers={"Authorization": f"Bearer {bidder_token}"})
        await asyncio.sleep(0.05)  # let the in-process subscriber run, per test_events_v4.py's pattern

        assert res.status_code == 201
        assert len(received) == 1
        assert received[0].listing_id == listing_id
        assert received[0].amount == 11000

    @pytest.mark.asyncio
    async def test_bid_lazily_creates_auction_meta_and_updates_it(self, client, seller_token, bidder_token):
        create = await client.post("/listings/", json={
            "name": "Antique Clock", "category": "collectibles", "price": 5000,
            "lat": -1.286, "lng": 36.817, "listing_type": "auction",
        }, headers={"Authorization": f"Bearer {seller_token}"})
        listing_id = create.json()["id"]

        # auction_meta has no row yet for this listing (nothing creates one
        # at listing-creation time) - the first bid must not crash.
        bid1 = await client.post("/auction/bid", json={
            "listing_id": listing_id, "amount": 5500,
        }, headers={"Authorization": f"Bearer {bidder_token}"})
        assert bid1.status_code == 201

        detail = await client.get(f"/auctions/{listing_id}")
        assert detail.status_code == 200
        assert detail.json()["current_bid"] == 5500
        assert detail.json()["bid_count"] == 1

        bid2 = await client.post("/auction/bid", json={
            "listing_id": listing_id, "amount": 6000,
        }, headers={"Authorization": f"Bearer {bidder_token}"})
        assert bid2.status_code == 201

        detail2 = await client.get(f"/auctions/{listing_id}")
        assert detail2.json()["current_bid"] == 6000
        assert detail2.json()["bid_count"] == 2
        assert len(detail2.json()["bid_history"]) == 2

    @pytest.mark.asyncio
    async def test_get_auction_404_for_unknown_listing(self, client):
        res = await client.get("/auctions/does-not-exist")
        assert res.status_code == 404
