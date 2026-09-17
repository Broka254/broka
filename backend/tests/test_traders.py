"""
BROKA - Traders Endpoint Tests
Run: pytest backend/tests/test_traders.py -v

Confirms Traders is a view over sellers, not a separate table (Design
Journal Volume 6, Ch.5). Follows test_listings.py's real fixture
convention; the design doc's draft for this file assumed a db_session
fixture that doesn't exist in this codebase (same gap as its
test_categories.py draft), so completed_deals is set directly via
AsyncSessionLocal rather than by simulating a full escrow flow to
completion, per the doc's own TODO for this test.
"""

import asyncio
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, User, Category


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    """CI runs a real Redis service container (REDIS_URL is set), so
    settings.redis_enabled is True and publish() would route ListingCreated
    to a Redis Stream instead of calling trader_specialization_subscribers.py's
    in-process handler that test_specialization_derived_from_listings_not_self_declared
    depends on. Force the in-process path, same fixture as test_events_v4.py
    uses for the same reason."""
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_traders.db"
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


async def _register(client, phone, name, email) -> tuple[str, str]:
    """Returns (user_id, access_token)."""
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    verify_token = verify.json()["phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify_token, "name": name, "email": email,
        "password": "TestPass123!", "lat": -1.286, "lng": 36.817,
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    # AuthService.register() returns "user_id", not "id" (see api/domains/auth/service.py) —
    # "id" was never a key on this response, matching test_auth.py's own assertions.
    return reg.json()["user_id"], login.json()["access_token"]


class TestTraders:
    @pytest.mark.asyncio
    async def test_seller_with_completed_deal_appears_with_name_fallback(self, client):
        user_id, _ = await _register(client, "0744001100", "Helen Ochieng", "helen.o@test.ke")
        async with AsyncSessionLocal() as db:
            user = (await db.execute(select(User).where(User.id == user_id))).scalar_one()
            user.completed_deals = 3
            user.rating = 4.6
            await db.commit()

        res = await client.get("/traders")
        assert res.status_code == 200
        traders = {t["id"]: t for t in res.json()}
        assert user_id in traders
        # business_name was never set at registration - must fall back to name
        assert traders[user_id]["business_name"] == "Helen Ochieng"
        assert traders[user_id]["completed_deals"] == 3

    @pytest.mark.asyncio
    async def test_seller_without_completed_deal_is_not_a_trader(self, client):
        user_id, _ = await _register(client, "0744002200", "Ian Kiptoo", "ian.k@test.ke")
        res = await client.get("/traders")
        ids = [t["id"] for t in res.json()]
        assert user_id not in ids

    @pytest.mark.asyncio
    async def test_trader_profile_returns_404_for_unknown_id(self, client):
        res = await client.get("/traders/does-not-exist")
        assert res.status_code == 404

    @pytest.mark.asyncio
    async def test_specialization_derived_from_listings_not_self_declared(self, client):
        user_id, token = await _register(client, "0744003300", "Joy Wambui", "joy.w@test.ke")
        async with AsyncSessionLocal() as db:
            user = (await db.execute(select(User).where(User.id == user_id))).scalar_one()
            user.completed_deals = 1
            # FIX (2026-08-14 CI run): this used to insert name="Electronics",
            # which collides with the real top-level "Electronics" category
            # seed_categories() already created (setup_db's init_db() call
            # above seeds the full canonical taxonomy before any test runs).
            # trader_specialization_subscribers.py's exact-name lookup then
            # had two legitimate rows to choose between and deterministically
            # (but arbitrarily, by id) picked the *seeded* one instead of
            # this test's - the assertion below was failing not because
            # specialization-derivation was broken, but because the test
            # created an ambiguity that can't actually happen in production
            # (seed_categories() is dedup-checked, so real duplicate
            # top-level names never occur outside a test doing this on
            # purpose). A name outside the canonical list removes the
            # collision entirely rather than relying on the subscriber's
            # tie-break picking a particular row.
            db.add(Category(id="cat-electronics-2", name="Test Electronics", icon=None, parent_id=None))
            await db.commit()

        # ListingCreated fires trader_specialization_subscribers.py, which
        # only matches a canonical Category by exact name.
        create = await client.post("/listings/", json={
            "name": "Used Laptop", "category": "Test Electronics", "price": 45000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {token}"})
        assert create.status_code == 201  # POST /listings/ is status_code=201 (see router.py)
        await asyncio.sleep(0.05)  # let the in-process subscriber run (publish() is fire-and-forget)

        profile = await client.get(f"/traders/{user_id}")
        assert profile.status_code == 200
        # No self-declared specialization field exists to set - this can
        # only be populated by the subscriber reacting to the listing above.
        spec_ids = [s["id"] for s in profile.json()["specializations"]]
        assert "cat-electronics-2" in spec_ids
