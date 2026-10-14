"""
BROKA - /calls/initiate authorization tests
Run: pytest backend/tests/test_calls_initiate.py -v

No endpoint-level tests existed for calls.py at all before this file -
test_call_state.py only exercises the internal call_state.py store
directly, never through the actual HTTP routes. This file specifically
covers the gap found during the calling-hardening pass (Phase 12/16):
`/calls/initiate` let a seller supply an arbitrary callee_id and would
create a call session (and send a push) to ANY registered user, with no
check that the two ever had an actual negotiation thread on that listing.
Fixed in calls.py by requiring an existing NegotiationMessage row for
that (listing_id, buyer_id) pair before allowing a seller-initiated call.

Test users/listings/messages are inserted directly via the ORM rather
than through the full OTP/registration and listing-creation endpoints -
this only needs realistic rows to exist, not to re-test registration or
listing creation themselves (those have their own test files).
"""
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, User, Listing, NegotiationMessage
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    """Point DATABASE_URL at an in-memory SQLite for tests, same as test_auth.py."""
    db_path = tmp_path_factory.mktemp("data") / "test.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
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


def _uid() -> str:
    return uuid.uuid4().hex[:10]


async def _make_user(name: str) -> User:
    """Inserts a minimal, valid user row and returns it."""
    tag = _uid()
    user = User(
        name=name,
        phone=f"+2547{tag}",
        password_hash="not-a-real-hash",
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _make_listing(seller: User) -> Listing:
    listing = Listing(
        seller_id=seller.id,
        name="Test listing",
        category="electronics",
        price=1000.0,
        lat=-1.2921,
        lng=36.8219,
    )
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing


async def _make_thread_message(listing: Listing, buyer: User) -> None:
    """Inserts one negotiation message so (listing, buyer) has a real thread."""
    msg = NegotiationMessage(
        listing_id=listing.id,
        sender_id=buyer.id,
        role="buyer",
        buyer_id=buyer.id,
        content="Hi, is this still available?",
    )
    async with AsyncSessionLocal() as db:
        db.add(msg)
        await db.commit()


def _auth_headers(user: User) -> dict:
    token = create_access_token({"sub": user.id})
    return {"Authorization": f"Bearer {token}"}


class TestInitiateCallAuthorization:
    @pytest.mark.asyncio
    async def test_buyer_initiates_call_to_seller(self, client):
        seller = await _make_user("Seller A")
        buyer  = await _make_user("Buyer A")
        listing = await _make_listing(seller)

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(buyer),
            json={
                "listing_id": listing.id,
                "call_type": "audio",
                "caller_name": buyer.name,
            },
        )
        assert resp.status_code == 200, resp.text
        assert "room_id" in resp.json()

    @pytest.mark.asyncio
    async def test_seller_can_call_buyer_with_existing_thread(self, client):
        seller = await _make_user("Seller B")
        buyer  = await _make_user("Buyer B")
        listing = await _make_listing(seller)
        await _make_thread_message(listing, buyer)

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(seller),
            json={
                "listing_id": listing.id,
                "call_type": "audio",
                "caller_name": seller.name,
                "callee_id": buyer.id,
            },
        )
        assert resp.status_code == 200, resp.text
        assert "room_id" in resp.json()

    @pytest.mark.asyncio
    async def test_seller_cannot_call_unrelated_user(self, client):
        """Regression test for the fix: a valid callee_id alone must not be
        enough to ring someone with no actual relationship to the listing."""
        seller     = await _make_user("Seller C")
        bystander  = await _make_user("Uninvolved User C")
        listing    = await _make_listing(seller)
        # Deliberately no _make_thread_message() call - bystander has never
        # messaged about this listing.

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(seller),
            json={
                "listing_id": listing.id,
                "call_type": "audio",
                "caller_name": seller.name,
                "callee_id": bystander.id,
            },
        )
        assert resp.status_code == 403, resp.text

    @pytest.mark.asyncio
    async def test_seller_missing_callee_id_rejected(self, client):
        seller = await _make_user("Seller D")
        listing = await _make_listing(seller)

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(seller),
            json={
                "listing_id": listing.id,
                "call_type": "audio",
                "caller_name": seller.name,
            },
        )
        assert resp.status_code == 400, resp.text

    @pytest.mark.asyncio
    async def test_buyer_self_call_on_own_listing_rejected(self, client):
        """A user calling their own listing (buyer view of a listing they
        also happen to own) must be rejected as a self-call, not treated as
        a normal buyer-calls-seller flow."""
        owner = await _make_user("Owner E")
        listing = await _make_listing(owner)

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(owner),
            json={
                "listing_id": listing.id,
                "call_type": "audio",
                "caller_name": owner.name,
            },
        )
        assert resp.status_code == 400, resp.text

    @pytest.mark.asyncio
    async def test_invalid_listing_id_404(self, client):
        buyer = await _make_user("Buyer F")

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(buyer),
            json={
                "listing_id": "does-not-exist",
                "call_type": "audio",
                "caller_name": buyer.name,
            },
        )
        assert resp.status_code == 404, resp.text

    @pytest.mark.asyncio
    async def test_incoming_call_push_is_data_only(self, client, monkeypatch):
        """Regression test for the FCM fix in this pass: an FCM
        'notification' block gets auto-displayed by the OS using generic
        styling whenever the app isn't foregrounded, bypassing our own
        rich incoming-call notification (full-screen intent, ringtone,
        Accept/Decline). The push must be sent data_only=True so the
        app's own handlers always decide what to show."""
        import api.routers.calls as calls_module

        seller = await _make_user("Seller G")
        buyer  = await _make_user("Buyer G")
        listing = await _make_listing(seller)
        await _make_thread_message(listing, buyer)

        # Give the buyer a token so the endpoint actually attempts a push
        # instead of short-circuiting on "no token registered".
        async with AsyncSessionLocal() as db:
            db_buyer = await db.get(User, buyer.id)
            db_buyer.fcm_token = "fake-token-for-test"
            await db.commit()

        calls_seen = []

        async def fake_send_fcm(*args, **kwargs):
            calls_seen.append(kwargs)
            return calls_module.FcmResult(True)

        monkeypatch.setattr(calls_module, "_send_fcm", fake_send_fcm)

        resp = await client.post(
            "/calls/initiate",
            headers=_auth_headers(seller),
            json={
                "listing_id": listing.id,
                "call_type": "video",
                "caller_name": seller.name,
                "callee_id": buyer.id,
            },
        )
        assert resp.status_code == 200, resp.text
        assert len(calls_seen) == 1
        assert calls_seen[0].get("data_only") is True
        assert calls_seen[0]["data"]["type"] == "incoming_call"
