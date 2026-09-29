"""
BROKA - What one user can see of another
Run: pytest backend/tests/test_user_privacy.py -v

GET /auth/search and GET /auth/user/{id} returned the full account record
(AuthService._user_dict) for anyone, to any signed-in user: email, phone,
trust score, fraud flag, admin bit, language and security settings. Search
also matched on email, so "@gmail" listed who had an account with which
address. Other people now get AuthService._public_user_dict; the account
itself still gets everything on its own id.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, User


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    # Same reason as test_traders.py: with REDIS_URL set, events would go to
    # a stream nothing in this test consumes.
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_user_privacy.db"
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


async def _register(client, phone, name, email) -> tuple[str, str]:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": name,
        "email": email, "password": "TestPass123!", "lat": -1.286, "lng": 36.817,
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    return reg.json()["user_id"], login.json()["access_token"]


# Grace's exact GPS fix. Two decimals is -1.29, 36.82 - about 500 m away.
GRACE_LAT, GRACE_LNG = -1.28634, 36.81722

PRIVATE_FIELDS = {
    "email", "email_verified", "phone", "phone_verified", "trust_score",
    "trust_band", "is_flagged", "is_admin", "preferred_language",
    "biometric_enrolled", "location_visible", "verify_expires_at",
    "dcr_score", "rank_score",
}


@pytest_asyncio.fixture(scope="module")
async def people(client):
    grace_id, grace_token = await _register(client, "0746661101", "Grace Akinyi", "grace.akinyi@test.ke")
    otieno_id, otieno_token = await _register(client, "0746661102", "Otieno Ouma", "otieno.o@test.ke")
    async with AsyncSessionLocal() as db:
        grace = (await db.execute(select(User).where(User.id == grace_id))).scalar_one()
        grace.nickname = "Gee"
        grace.business_name = "Clanix Electronics"
        grace.business_location = "Westlands, Nairobi"
        grace.lat, grace.lng = GRACE_LAT, GRACE_LNG
        grace.location_visible = True
        grace.completed_deals = 4
        grace.trust_score = 35
        grace.is_flagged = True
        await db.commit()
    return {
        "grace": (grace_id, {"Authorization": f"Bearer {grace_token}"}),
        "otieno": (otieno_id, {"Authorization": f"Bearer {otieno_token}"}),
    }


class TestSearch:
    @pytest.mark.asyncio
    async def test_results_carry_no_private_fields(self, client, people):
        _, as_otieno = people["otieno"]
        res = await client.get("/auth/search", params={"q": "grace"}, headers=as_otieno)
        assert res.status_code == 200
        [grace] = res.json()
        assert grace["name"] == "Grace Akinyi"
        leaked = PRIVATE_FIELDS & set(grace)
        assert not leaked, f"search returned {sorted(leaked)} of another user"

    @pytest.mark.asyncio
    async def test_an_email_address_finds_nobody(self, client, people):
        _, as_otieno = people["otieno"]
        for q in ("grace.akinyi@test.ke", "@test.ke"):
            res = await client.get("/auth/search", params={"q": q}, headers=as_otieno)
            assert res.json() == [], q

    @pytest.mark.asyncio
    async def test_finds_by_preferred_or_business_name(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        for q in ("gee", "clanix electronics", "akinyi grace"):
            res = await client.get("/auth/search", params={"q": q}, headers=as_otieno)
            assert [u["id"] for u in res.json()] == [grace_id], q

    @pytest.mark.asyncio
    async def test_never_lists_the_caller(self, client, people):
        _, as_grace = people["grace"]
        res = await client.get("/auth/search", params={"q": "grace"}, headers=as_grace)
        assert res.json() == []

    @pytest.mark.asyncio
    async def test_query_is_bounded(self, client, people):
        _, as_otieno = people["otieno"]
        res = await client.get("/auth/search", params={"q": "x" * 101}, headers=as_otieno)
        assert res.status_code == 422


class TestProfile:
    @pytest.mark.asyncio
    async def test_another_users_profile_is_the_public_view(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        res = await client.get(f"/auth/user/{grace_id}", headers=as_otieno)
        assert res.status_code == 200
        body = res.json()
        leaked = PRIVATE_FIELDS & set(body)
        assert not leaked, f"profile returned {sorted(leaked)} of another user"
        # What the chat header, product page and profile screen do read.
        assert body["name"] == "Grace Akinyi"
        assert body["completed_deals"] == 4
        assert "is_online" in body and "last_seen_label" in body
        # Social proof for a seller with deals (Volume 2 §2.4) stays public.
        assert "escrow_success_rate_pct" in body

    @pytest.mark.asyncio
    async def test_location_is_approximate(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        body = (await client.get(f"/auth/user/{grace_id}", headers=as_otieno)).json()
        assert (body["lat"], body["lng"]) == (-1.29, 36.82)
        # Standing exactly on Grace's fix must not read "0.0 km": a distance
        # from the exact point, asked for from made-up places, pinpoints her.
        at_her_door = await client.get(
            f"/auth/user/{grace_id}",
            params={"lat": GRACE_LAT, "lng": GRACE_LNG}, headers=as_otieno)
        assert at_her_door.json()["distance_km"] >= 0.3

    @pytest.mark.asyncio
    async def test_a_hidden_location_stays_hidden(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        async with AsyncSessionLocal() as db:
            grace = (await db.execute(select(User).where(User.id == grace_id))).scalar_one()
            grace.location_visible = False
            await db.commit()
        try:
            body = (await client.get(
                f"/auth/user/{grace_id}", params={"lat": -1.3, "lng": 36.8},
                headers=as_otieno)).json()
            assert body["lat"] is None and body["lng"] is None
            assert body["business_location"] is None
            assert "distance_km" not in body
        finally:
            async with AsyncSessionLocal() as db:
                grace = (await db.execute(select(User).where(User.id == grace_id))).scalar_one()
                grace.location_visible = True
                await db.commit()

    @pytest.mark.asyncio
    async def test_your_own_profile_is_still_complete(self, client, people):
        # The seller dashboard reads its own trust score here.
        grace_id, as_grace = people["grace"]
        body = (await client.get(f"/auth/user/{grace_id}", headers=as_grace)).json()
        assert body["email"] == "grace.akinyi@test.ke"
        assert body["phone"]
        assert body["trust_score"] == 35
        assert body["lat"] == GRACE_LAT

    @pytest.mark.asyncio
    async def test_signed_out_callers_get_nothing(self, client, people):
        grace_id, _ = people["grace"]
        assert (await client.get(f"/auth/user/{grace_id}")).status_code in (401, 403)
        assert (await client.get("/auth/search", params={"q": "grace"})).status_code in (401, 403)


class TestSellerStanding:
    """The seller dashboard's rating, completion rate and response time, as
    a buyer sees them on a listing's screen - and nothing else of the
    seller's metrics (trust/public_standing.py)."""

    @pytest_asyncio.fixture(autouse=True)
    async def _no_snapshots(self, people):
        from sqlalchemy import delete
        from api.database import SellerMetricSnapshot
        async with AsyncSessionLocal() as db:
            await db.execute(delete(SellerMetricSnapshot))
            await db.commit()

    @staticmethod
    async def _snapshot(seller_id: str, days_ago: int, **fields):
        from datetime import datetime, timedelta
        from api.database import SellerMetricSnapshot
        values = dict(overall_rating=8.46, dcr_score=92.3, rank_score=0.71, rank_position=3,
                      median_response_min=25.0, completed_deals=14, pending_deals=6)
        values.update(fields)
        async with AsyncSessionLocal() as db:
            db.add(SellerMetricSnapshot(
                seller_id=seller_id,
                snapshot_date=datetime.utcnow().date() - timedelta(days=days_ago), **values))
            await db.commit()

    @pytest.mark.asyncio
    async def test_a_buyer_sees_rating_completion_and_reply_time(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        await self._snapshot(grace_id, 3, overall_rating=5.0, dcr_score=60.0, median_response_min=300.0)
        await self._snapshot(grace_id, 1)
        body = (await client.get(f"/auth/user/{grace_id}", headers=as_otieno)).json()
        standing = body["seller_standing"]
        assert standing == {
            "overall_rating": 8.5, "dcr": 92.3, "dcr_provisional": False,
            "median_response_minutes": 25.0, "completed_deals": 14,
            "as_of": standing["as_of"],
        }
        # Rank and backlog are the seller's own.
        assert not {"rank_score", "rank_position", "pending_deals"} & set(standing)
        assert not PRIVATE_FIELDS & set(body)

    @pytest.mark.asyncio
    async def test_no_completion_rate_before_a_completed_deal(self, client, people):
        # DCR starts at an 80% prior (§3.2); shown to a buyer, that is a
        # track record the seller does not have.
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        await self._snapshot(grace_id, 1, dcr_score=80.0, completed_deals=0, median_response_min=None)
        standing = (await client.get(f"/auth/user/{grace_id}", headers=as_otieno)).json()["seller_standing"]
        assert standing["dcr"] is None and standing["dcr_provisional"] is False
        assert standing["median_response_minutes"] is None
        assert standing["overall_rating"] == 8.5

    @pytest.mark.asyncio
    async def test_under_ten_deals_is_provisional(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        await self._snapshot(grace_id, 0, completed_deals=4)
        standing = (await client.get(f"/auth/user/{grace_id}", headers=as_otieno)).json()["seller_standing"]
        assert standing["dcr"] == 92.3 and standing["dcr_provisional"] is True

    @pytest.mark.asyncio
    async def test_stale_figures_are_not_shown(self, client, people):
        grace_id, _ = people["grace"]
        _, as_otieno = people["otieno"]
        await self._snapshot(grace_id, 8)
        body = (await client.get(f"/auth/user/{grace_id}", headers=as_otieno)).json()
        assert "seller_standing" not in body

    @pytest.mark.asyncio
    async def test_someone_who_has_never_sold_has_none(self, client, people):
        otieno_id, _ = people["otieno"]
        _, as_grace = people["grace"]
        body = (await client.get(f"/auth/user/{otieno_id}", headers=as_grace)).json()
        assert "seller_standing" not in body
