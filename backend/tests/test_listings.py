"""
BROKA - Listings Endpoint Tests
Run: pytest backend/tests/test_listings.py -v
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listings.db"
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
    """Runs otp/request -> otp/verify, returns a phone_verify_token.

    v6.1 registration is phone-first: register requires a verified-phone
    token instead of a bare phone number (see test_auth.py).
    """
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    phone = "0798765432"
    verify_token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": "Bob Seller",
        "email": "bob@test.ke",
        "password": "SellerPass123!",
        "lat": -1.286,
        "lng": 36.817,
    })
    resp = await client.post("/auth/login", json={
        "phone": phone,
        "password": "SellerPass123!",
    })
    return resp.json()["access_token"]


@pytest_asyncio.fixture(scope="module")
async def buyer_token(client):
    phone = "0722112233"
    verify_token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": "Carol Buyer",
        "email": "carol.buyer@test.ke",
        "password": "BuyerPass123!",
        "lat": -1.290,
        "lng": 36.820,
    })
    resp = await client.post("/auth/login", json={
        "phone": phone,
        "password": "BuyerPass123!",
    })
    return resp.json()["access_token"]


class TestListingsCRUD:
    @pytest.mark.asyncio
    async def test_create_listing(self, client, seller_token):
        resp = await client.post("/listings/", json={
            "name": "Toyota Land Cruiser 2019",
            "category": "vehicles",
            "price": 4500000,
            "lat": -1.286,
            "lng": 36.817,
            "description": "Well maintained, full service history",
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert resp.status_code == 201
        data = resp.json()
        assert data["name"] == "Toyota Land Cruiser 2019"
        assert data["price"] == 4500000

    @pytest.mark.asyncio
    async def test_list_listings(self, client):
        resp = await client.get("/listings/")
        assert resp.status_code == 200
        assert isinstance(resp.json(), list)

    @pytest.mark.asyncio
    async def test_get_stats(self, client):
        resp = await client.get("/listings/stats")
        assert resp.status_code == 200
        data = resp.json()
        assert "total" in data
        assert "active" in data

    @pytest.mark.asyncio
    async def test_create_listing_requires_auth(self, client):
        resp = await client.post("/listings/", json={
            "name": "Unauth Listing",
            "category": "other",
            "price": 1000,
            "lat": -1.0,
            "lng": 36.0,
        })
        assert resp.status_code == 401


class TestInterest:
    listing_id: str = ""

    @pytest.mark.asyncio
    async def test_express_interest(self, client, seller_token, buyer_token):
        # Create listing first
        create_resp = await client.post("/listings/", json={
            "name": "Samsung Galaxy S24",
            "category": "electronics",
            "price": 85000,
            "lat": -1.286,
            "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        assert create_resp.status_code == 201
        lid = create_resp.json()["id"]
        TestInterest.listing_id = lid

        # Express interest as buyer
        resp = await client.post(f"/listings/{lid}/interest", json={
            "offer_price": 80000,
        }, headers={"Authorization": f"Bearer {buyer_token}"})
        assert resp.status_code == 200
        assert resp.json()["ok"] is True

    @pytest.mark.asyncio
    async def test_get_matches(self, client, seller_token):
        lid = TestInterest.listing_id
        resp = await client.get(f"/listings/{lid}/matches",
            headers={"Authorization": f"Bearer {seller_token}"})
        assert resp.status_code == 200
        matches = resp.json()
        assert len(matches) >= 1
        assert "trust_score" in matches[0]  # v3.0: trust score in matches
