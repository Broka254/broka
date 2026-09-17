"""
BROKA - Auth Endpoint Tests
Run: pytest backend/tests/test_auth.py -v

v6.1: registration is phone-first (otp/request -> otp/verify -> register).
No AT_USERNAME/AT_API_KEY is set in the test env, so get_sms_provider()
returns ConsoleSMS and /auth/otp/request additionally returns `debug_code`
(only when settings.is_production is False) so tests can read the code
without a live SMS account.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    """Point DATABASE_URL at an in-memory SQLite for tests."""
    db_path = tmp_path_factory.mktemp("data") / "test.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
    reset_engine()
    mp.setenv("ENV", "test")
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


async def _verified_token(client, phone: str) -> str:
    """Helper: runs otp/request -> otp/verify, returns a phone_verify_token."""
    req = await client.post("/auth/otp/request", json={"phone": phone})
    assert req.status_code == 200, req.text
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    assert verify.status_code == 200, verify.text
    return verify.json()["phone_verify_token"]


class TestOtp:
    @pytest.mark.asyncio
    async def test_otp_request_and_verify(self, client):
        req = await client.post("/auth/otp/request", json={"phone": "+254711000001"})
        assert req.status_code == 200
        code = req.json()["debug_code"]

        verify = await client.post("/auth/otp/verify", json={
            "phone": "+254711000001", "code": code,
        })
        assert verify.status_code == 200
        assert "phone_verify_token" in verify.json()

    @pytest.mark.asyncio
    async def test_otp_wrong_code_rejected(self, client):
        await client.post("/auth/otp/request", json={"phone": "+254711000002"})
        verify = await client.post("/auth/otp/verify", json={
            "phone": "+254711000002", "code": "000000",
        })
        assert verify.status_code == 400

    @pytest.mark.asyncio
    async def test_otp_request_blocked_for_existing_number(self, client):
        # Register a full account on this number first...
        token = await _verified_token(client, "+254711000003")
        resp = await client.post("/auth/register", json={
            "phone_verify_token": token,
            "name": "Existing User",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 201
        # ...then confirm a second OTP request for the same number is refused.
        req = await client.post("/auth/otp/request", json={"phone": "+254711000003"})
        assert req.status_code == 409


class TestAuthRegister:
    @pytest.mark.asyncio
    async def test_register_success_minimal_fields(self, client):
        """Buyer registration needs no email — matches the onboarding redesign."""
        token = await _verified_token(client, "+254712345678")
        resp = await client.post("/auth/register", json={
            "phone_verify_token": token,
            "name": "Alice Wanjiku",
            "nickname": "Alice",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 201
        data = resp.json()
        assert "access_token" in data
        assert data["name"] == "Alice Wanjiku"
        assert data["phone"] == "+254712345678"
        assert data["phone_verified"] is True
        assert data["account_type"] == "buyer"

    @pytest.mark.asyncio
    async def test_register_rejects_unverified_phone(self, client):
        """Registering with a bogus phone_verify_token must still fail —
        claiming verification and failing it is different from honestly
        skipping it (see test_register_without_otp_* below)."""
        resp = await client.post("/auth/register", json={
            "phone_verify_token": "not-a-real-token",
            "name": "No Otp",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_register_without_otp_creates_unverified_account(self, client):
        """OTP is optional at signup — omitting phone_verify_token entirely
        and sending a plain phone instead should still create the account,
        just marked as not phone-verified."""
        resp = await client.post("/auth/register", json={
            "phone": "+254722000101",
            "name": "Frank Mwangi",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 201
        data = resp.json()
        assert "access_token" in data
        assert data["phone"] == "+254722000101"
        assert data["phone_verified"] is False

        # The skipped account is fully usable — it can log in immediately.
        login = await client.post("/auth/login", json={
            "phone": "+254722000101", "password": "SecurePass123!",
        })
        assert login.status_code == 200

    @pytest.mark.asyncio
    async def test_register_without_otp_or_phone_rejected(self, client):
        """At least one of phone_verify_token / phone is still required —
        you must identify yourself somehow, just not necessarily via SMS."""
        resp = await client.post("/auth/register", json={
            "name": "Nobody",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_register_verified_token_beats_mismatched_raw_phone(self, client):
        """If both are present, the verified token's phone must win over a
        raw `phone` field — otherwise a verified number could be swapped
        for an unverified one in the same request."""
        token = await _verified_token(client, "+254722000102")
        resp = await client.post("/auth/register", json={
            "phone_verify_token": token,
            "phone": "+254722000103",  # different, unverified number
            "name": "Grace Achieng",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 201
        data = resp.json()
        assert data["phone"] == "+254722000102"
        assert data["phone_verified"] is True

    @pytest.mark.asyncio
    async def test_register_duplicate_phone(self, client):
        token = await _verified_token(client, "+254712345679")
        payload = {
            "phone_verify_token": token,
            "name": "Bob Otieno",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        }
        first = await client.post("/auth/register", json=payload)
        assert first.status_code == 201
        # Re-using the same (now-consumed) token / phone should fail.
        second = await client.post("/auth/register", json=payload)
        assert second.status_code in (400, 409)

    @pytest.mark.asyncio
    async def test_register_missing_field(self, client):
        resp = await client.post("/auth/register", json={
            "name": "Incomplete",
        })
        assert resp.status_code == 422

    @pytest.mark.asyncio
    async def test_register_optional_email_still_accepted(self, client):
        token = await _verified_token(client, "+254712345680")
        resp = await client.post("/auth/register", json={
            "phone_verify_token": token,
            "name": "Carol Njeri",
            "email": "carol@test.ke",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })
        assert resp.status_code == 201


class TestAuthLogin:
    @pytest_asyncio.fixture(scope="class", autouse=True)
    async def registered_user(self, client):
        token = await _verified_token(client, "+254700111222")
        await client.post("/auth/register", json={
            "phone_verify_token": token,
            "name": "Dennis Kiptoo",
            "password": "SecurePass123!",
            "lat": -1.286389,
            "lng": 36.817223,
        })

    @pytest.mark.asyncio
    async def test_login_success(self, client):
        resp = await client.post("/auth/login", json={
            "phone": "+254700111222",
            "password": "SecurePass123!",
        })
        assert resp.status_code == 200
        assert "access_token" in resp.json()

    @pytest.mark.asyncio
    async def test_login_wrong_password(self, client):
        resp = await client.post("/auth/login", json={
            "phone": "+254700111222",
            "password": "WrongPassword",
        })
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_login_unknown_phone(self, client):
        resp = await client.post("/auth/login", json={
            "phone": "+254799999999",
            "password": "whatever",
        })
        assert resp.status_code == 401


class TestAuthMe:
    @pytest.mark.asyncio
    async def test_me_requires_auth(self, client):
        resp = await client.get("/auth/me")
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_me_with_valid_token(self, client):
        login = await client.post("/auth/login", json={
            "phone": "+254700111222",
            "password": "SecurePass123!",
        })
        token = login.json()["access_token"]
        resp = await client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
        assert resp.status_code == 200
        data = resp.json()
        assert data["phone"] == "+254700111222"
        assert "trust_score" in data
        assert data["trust_score"] >= 0


class TestSellerUpgrade:
    @pytest_asyncio.fixture(scope="class")
    async def buyer_token(self, client):
        token = await _verified_token(client, "+254733444555")
        resp = await client.post("/auth/register", json={
            "phone_verify_token": token,
            "name": "Evelyn Achieng",
            "password": "SecurePass123!",
            "lat": 0.0,
            "lng": 34.5,
        })
        return resp.json()["access_token"]

    @pytest.mark.asyncio
    async def test_upgrade_generates_structured_display_name(self, client, buyer_token):
        resp = await client.post(
            "/auth/upgrade-to-seller",
            headers={"Authorization": f"Bearer {buyer_token}"},
            json={
                "business_name": "Clanix",
                "business_category": "Wholesale",
                "business_location": "Sira",
                "business_description": "General wholesale supplies for the Ugunja area.",
            },
        )
        assert resp.status_code == 200
        data = resp.json()
        assert data["account_type"] == "buyer_seller"
        assert data["business_display_name"] == "Clanix · Wholesale · Sira"
