"""Store-general conversations land in the Inbox (regression).

"Message Store" used to borrow the store's first listing as its thread:
the conversation moved whenever that listing changed, vanished with it,
and a store with nothing live could not be messaged at all. Store threads
are now keyed by (store_id, buyer_id) with no listing.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_conversations.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _shop(with_listing: bool = True):
    """An owner, their store, a buyer, and optionally one listing."""
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.flush()
        listing = None
        if with_listing:
            listing = Listing(seller_id=owner.id, store_id=store.id, name="Phone",
                              category="Electronics", price=25000, lat=-1.28, lng=36.82)
            db.add(listing)
        await db.commit()
        return store.id, owner.id, buyer.id, (listing.id if listing else None)


async def _say(client, store_id, sender, role, content, buyer_id=None, client_msg_id=None):
    body = {"sender_role": role, "sender_id": sender, "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    if client_msg_id:
        body["client_msg_id"] = client_msg_id
    return await client.post(
        f"/negotiate/store/{store_id}/direct-message", json=body, headers=_auth(sender))


@pytest.mark.asyncio
async def test_a_store_message_is_in_both_inboxes(client):
    store_id, owner, buyer, _ = await _shop()
    r = await _say(client, store_id, buyer, "buyer", "Do you deliver to Kisumu?")
    assert r.status_code == 200, r.text

    buyer_inbox = (await client.get(f"/negotiate/inbox/{buyer}", headers=_auth(buyer))).json()
    thread = next(t for t in buyer_inbox if t.get("store_id") == store_id)
    assert thread["thread_type"] == "store"
    assert thread["listing_id"] is None
    assert thread["last_message"] == "Do you deliver to Kisumu?"
    assert thread["my_role"] == "buyer"

    owner_inbox = (await client.get(f"/negotiate/inbox/{owner}", headers=_auth(owner))).json()
    othread = next(t for t in owner_inbox if t.get("store_id") == store_id)
    assert othread["my_role"] == "seller"
    assert othread["buyer_id"] == buyer
    assert othread["unread"] == 1


@pytest.mark.asyncio
async def test_a_store_with_no_listings_can_be_messaged(client):
    store_id, owner, buyer, listing_id = await _shop(with_listing=False)
    assert listing_id is None
    r = await _say(client, store_id, buyer, "buyer", "When do you open?")
    assert r.status_code == 200, r.text
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(owner))).json()
    assert [m["content"] for m in history] == ["When do you open?"]


@pytest.mark.asyncio
async def test_the_thread_survives_its_listings_being_archived(client):
    store_id, owner, buyer, listing_id = await _shop()
    await _say(client, store_id, buyer, "buyer", "Hello shop")
    async with AsyncSessionLocal() as db:
        listing = (await db.execute(
            select(Listing).where(Listing.id == listing_id))).scalar_one()
        listing.status = "cancelled"
        await db.commit()
    inbox = (await client.get(f"/negotiate/inbox/{buyer}", headers=_auth(buyer))).json()
    assert any(t.get("store_id") == store_id for t in inbox)
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in history] == ["Hello shop"]


@pytest.mark.asyncio
async def test_two_buyers_have_separate_store_threads(client):
    store_id, owner, buyer, _ = await _shop()
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.commit()
        other_id = other.id
    await _say(client, store_id, buyer, "buyer", "from buyer one")
    await _say(client, store_id, other_id, "buyer", "from buyer two")
    mine = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in mine] == ["from buyer one"]
    owners_view = (await client.get(
        f"/negotiate/store/{store_id}/history",
        params={"buyer_id": other_id}, headers=_auth(owner))).json()
    assert [m["content"] for m in owners_view] == ["from buyer two"]


@pytest.mark.asyncio
async def test_the_owner_answers_and_reads_clear_the_badge(client):
    store_id, owner, buyer, _ = await _shop()
    await _say(client, store_id, buyer, "buyer", "Is the shop open?")
    r = await _say(client, store_id, owner, "seller", "Yes, until 6pm", buyer_id=buyer)
    assert r.status_code == 200, r.text
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in history] == ["Is the shop open?", "Yes, until 6pm"]

    await client.post(f"/negotiate/store/{store_id}/mark-read",
                      json={}, headers=_auth(owner))
    inbox = (await client.get(f"/negotiate/inbox/{owner}", headers=_auth(owner))).json()
    thread = next(t for t in inbox if t.get("store_id") == store_id)
    assert thread["unread"] == 0


@pytest.mark.asyncio
async def test_a_resend_is_stored_once_and_roles_are_checked(client):
    store_id, owner, buyer, _ = await _shop()
    first = await _say(client, store_id, buyer, "buyer", "Hi", client_msg_id="s-1")
    again = await _say(client, store_id, buyer, "buyer", "Hi", client_msg_id="s-1")
    assert again.json()["message"]["id"] == first.json()["message"]["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.store_id == store_id))).scalars().all()
    assert len(rows) == 1
    assert rows[0].listing_id is None

    wrong = await _say(client, store_id, buyer, "seller", "I am not the owner")
    assert wrong.status_code == 403
    missing = await _say(client, "no-such-store", buyer, "buyer", "Hello?")
    assert missing.status_code == 404
