"""Deleting a whole chat from one's own inbox (models/thread_clear.py).

Old and finished conversations piled up in the inbox with no way to remove
them. A delete is for the person who asks: the chat leaves their inbox,
history and unread counts, and comes back with only the new messages when
either side writes again. The other person's copy is untouched.
Run: pytest backend/tests/test_chat_delete.py -v
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.models.message_delivery import MessageDelivery
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_delete.db"
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


async def _people():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None):
    body = {"listing_id": listing_id, "sender_role": role,
            "sender_id": sender_id, "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


async def _inbox(client, uid) -> list:
    r = await client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _history(client, uid, listing_id, buyer_id=None) -> list:
    params = {"buyer_id": buyer_id} if buyer_id else {}
    r = await client.get(f"/negotiate/{listing_id}/history", params=params, headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_a_deleted_chat_leaves_only_the_deleters_inbox(client):
    listing_id, seller, buyer = await _people()
    await _direct(client, buyer, "buyer", listing_id, "Is it still available?")
    await _direct(client, seller, "seller", listing_id, "Yes", buyer_id=buyer)
    await _direct(client, buyer, "buyer", listing_id, "Deal, thanks")
    assert [t["listing_id"] for t in await _inbox(client, seller)] == [listing_id]
    assert (await _inbox(client, seller))[0]["unread"] >= 1

    r = await client.post(f"/negotiate/{listing_id}/clear", json={"buyer_id": buyer},
                          headers=_auth(seller))
    assert r.status_code == 200, r.text
    assert r.json()["cleared_at"]

    assert await _inbox(client, seller) == []
    assert await _history(client, seller, listing_id, buyer) == []
    # Nothing waiting on the seller's phone hands the deleted chat back.
    synced = (await client.get("/negotiate/sync", headers=_auth(seller))).json()
    assert [m for m in synced["messages"] if m.get("listing_id") == listing_id] == []
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(MessageDelivery).where(
            MessageDelivery.recipient_id == seller,
            MessageDelivery.listing_id == listing_id))).scalars().all()
    assert all(r.status in ("DELIVERED", "READ") for r in rows)

    # The buyer's copy is as it was.
    theirs = await _inbox(client, buyer)
    assert [t["listing_id"] for t in theirs] == [listing_id]
    words = [m["content"] for m in await _history(client, buyer, listing_id)]
    assert {"Is it still available?", "Yes", "Deal, thanks"} <= set(words)


@pytest.mark.asyncio
async def test_it_comes_back_with_only_the_new_messages(client):
    listing_id, seller, buyer = await _people()
    await _direct(client, buyer, "buyer", listing_id, "Old question")
    await client.post(f"/negotiate/{listing_id}/clear", json={}, headers=_auth(buyer))
    assert await _inbox(client, buyer) == []

    await _direct(client, seller, "seller", listing_id, "Still interested?", buyer_id=buyer)
    rows = await _inbox(client, buyer)
    assert [t["listing_id"] for t in rows] == [listing_id]
    assert rows[0]["last_message"] == "Still interested?" and rows[0]["unread"] == 1
    words = [m["content"] for m in await _history(client, buyer, listing_id)]
    assert "Still interested?" in words and "Old question" not in words


@pytest.mark.asyncio
async def test_a_seller_must_name_the_buyer(client):
    # /history guesses the most recent buyer for a seller who names none; a
    # delete must never guess which conversation it removes.
    listing_id, seller, buyer = await _people()
    await _direct(client, buyer, "buyer", listing_id, "Hi")
    r = await client.post(f"/negotiate/{listing_id}/clear", json={}, headers=_auth(seller))
    assert r.status_code == 400
    assert [t["listing_id"] for t in await _inbox(client, seller)] == [listing_id]


@pytest.mark.asyncio
async def test_a_seller_deleting_one_buyer_keeps_the_others(client):
    listing_id, seller, first = await _people()
    async with AsyncSessionLocal() as db:
        other = User(name="Otto Other", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.commit()
        second = other.id
    await _direct(client, first, "buyer", listing_id, "Me first")
    await _direct(client, second, "buyer", listing_id, "Me too")
    await client.post(f"/negotiate/{listing_id}/clear", json={"buyer_id": first},
                      headers=_auth(seller))
    assert [t["buyer_id"] for t in await _inbox(client, seller)] == [second]


@pytest.mark.asyncio
async def test_a_store_conversation_can_be_deleted_too(client):
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id, owner_id, buyer_id = store.id, owner.id, buyer.id
    r = await client.post(f"/negotiate/store/{store_id}/direct-message", headers=_auth(buyer_id),
                          json={"sender_role": "buyer", "sender_id": buyer_id, "content": "Open today?"})
    assert r.status_code == 200, r.text
    assert any(t.get("store_id") == store_id for t in await _inbox(client, buyer_id))

    r = await client.post(f"/negotiate/store/{store_id}/clear", json={}, headers=_auth(buyer_id))
    assert r.status_code == 200, r.text
    assert not any(t.get("store_id") == store_id for t in await _inbox(client, buyer_id))
    hist = await client.get(f"/negotiate/store/{store_id}/history", headers=_auth(buyer_id))
    assert hist.status_code == 200 and hist.json() == []
    # The owner still has it.
    assert any(t.get("store_id") == store_id for t in await _inbox(client, owner_id))


@pytest.mark.asyncio
async def test_deleting_twice_is_harmless(client):
    listing_id, _, buyer = await _people()
    await _direct(client, buyer, "buyer", listing_id, "Hello")
    first = await client.post(f"/negotiate/{listing_id}/clear", json={}, headers=_auth(buyer))
    again = await client.post(f"/negotiate/{listing_id}/clear", json={}, headers=_auth(buyer))
    assert first.status_code == again.status_code == 200
    assert again.json()["cleared_at"] >= first.json()["cleared_at"]
