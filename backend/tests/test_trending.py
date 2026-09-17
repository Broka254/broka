"""
BROKA - Trending Endpoint Tests
Run: pytest backend/tests/test_trending.py -v

Confirms trending order is engagement-driven, not just recency. The design
doc's draft for this file was a TODO-annotated sketch of intent rather than
a runnable test; this fills that in against test_listings.py's real fixture
convention (module-scoped sqlite DB, plain httpx client, phone-first OTP
registration) since there is no db_session fixture in this codebase.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, Listing
from sqlalchemy import select
from datetime import datetime


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_trending.db"
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
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def _verified_token(client, phone: str) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


async def _register_and_login(client, phone: str, name: str, email: str) -> str:
    verify_token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": name,
        "email": email,
        "password": "TestPass123!",
        "lat": -1.286,
        "lng": 36.817,
    })
    resp = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    return resp.json()["access_token"]


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    return await _register_and_login(client, "0733001100", "Erin Seller", "erin.seller@test.ke")


@pytest_asyncio.fixture(scope="module")
async def buyer_a_token(client):
    return await _register_and_login(client, "0733002200", "Frank Buyer", "frank.buyer@test.ke")


@pytest_asyncio.fixture(scope="module")
async def buyer_b_token(client):
    return await _register_and_login(client, "0733003300", "Grace Buyer", "grace.buyer@test.ke")


class TestTrending:
    @pytest.mark.asyncio
    async def test_higher_engagement_ranks_above_lower(
        self, client, seller_token, buyer_a_token, buyer_b_token
    ):
        # Two listings, created back-to-back via the same helper
        # test_listings.py uses (POST /listings/), not hand-built rows.
        low = await client.post("/listings/", json={
            "name": "Low Engagement Sofa", "category": "furniture", "price": 20000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        high = await client.post("/listings/", json={
            "name": "High Engagement Sofa", "category": "furniture", "price": 20000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        low_id, high_id = low.json()["id"], high.json()["id"]

        # Force identical created_at so the decay term is equal for both -
        # the only thing that should distinguish them is engagement.
        async with AsyncSessionLocal() as db:
            same_time = datetime.utcnow()
            for lid in (low_id, high_id):
                listing = (await db.execute(select(Listing).where(Listing.id == lid))).scalar_one()
                listing.created_at = same_time
                listing.views = 1
            await db.commit()

        # Two Interest rows on the high-engagement listing, zero on the
        # other - interest_weight in TrendingService outweighs a lone view.
        for token in (buyer_a_token, buyer_b_token):
            resp = await client.post(f"/listings/{high_id}/interest", json={
                "offer_price": 18000,
            }, headers={"Authorization": f"Bearer {token}"})
            assert resp.status_code == 200

        res = await client.get("/trending")
        assert res.status_code == 200
        ids = [item["id"] for item in res.json()]
        assert high_id in ids and low_id in ids
        assert ids.index(high_id) < ids.index(low_id)

    @pytest.mark.asyncio
    async def test_trending_response_matches_listing_shape(self, client, seller_token):
        # Ch.24's TODO: trending results must carry the same fields as
        # every other listing response (image/verified/price), not a
        # thinner placeholder shape.
        await client.post("/listings/", json={
            "name": "Shape Check Item", "category": "electronics", "price": 5000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        res = await client.get("/trending")
        assert res.status_code == 200
        data = res.json()
        assert len(data) >= 1
        for field in ("id", "name", "price", "category", "location_name", "verified_photos", "seller_id"):
            assert field in data[0]
