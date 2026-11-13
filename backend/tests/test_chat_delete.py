"""Deleting a chat from one's own inbox (POST /negotiate/thread/delete).

Old conversations piled up in the inbox with no way out. Deleting one
removes it from that person's inbox and history only: the other person
keeps their copy, nothing is removed from the database, and a new message
brings the chat back from that message. A chat whose deal holds money in
escrow can't be deleted until the deal is settled.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, NegotiationMessage, ThreadReadState,
    User, init_db, reset_engine,
)
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


@pytest.fixture(autouse=True)
def no_push(monkeypatch):
    async def nothing(*a, **k):
        return 0
    monkeypatch.setattr("api.core.push_devices.push_user", nothing)


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _people():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Airtel Router", category="Electronics",
                          price=4500, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _say(client, sender_id, role, listing_id, content, buyer_id=None):
    body = {"listing_id": listing_id, "sender_role": role,
            "sender_id": sender_id, "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


async def _inbox(client, uid):
    r = await client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _history(client, uid, listing_id, buyer_id=None):
    params = {"buyer_id": buyer_id} if buyer_id else None
    r = await client.get(f"/negotiate/{listing_id}/history", params=params, headers=_auth(uid))
    assert r.status_code == 200, r.text
    return [m["content"] for m in r.json()]


async def _delete(client, uid, **body):
    return await client.post("/negotiate/thread/delete", json=body, headers=_auth(uid))


@pytest.mark.asyncio
async def test_the_buyer_deletes_it_and_only_their_copy_goes(client):
    listing_id, seller, buyer = await _people()
    await _say(client, buyer, "buyer", listing_id, "Is it still available?")
    await _say(client, seller, "seller", listing_id, "Yes it is", buyer_id=buyer)

    r = await _delete(client, buyer, listing_id=listing_id)
    assert r.status_code == 200, r.text
    assert r.json()["deleted"] is True

    assert not [t for t in await _inbox(client, buyer) if t["listing_id"] == listing_id]
    assert await _history(client, buyer, listing_id) == []
    # The seller's copy is untouched.
    assert [t for t in await _inbox(client, seller) if t["listing_id"] == listing_id]
    seller_sees = await _history(client, seller, listing_id, buyer)
    assert "Is it still available?" in seller_sees and "Yes it is" in seller_sees
    # And the database still has every message: evidence for a dispute.
    async with AsyncSessionLocal() as db:
        n = (await db.execute(select(func.count(NegotiationMessage.id)).where(
            NegotiationMessage.listing_id == listing_id))).scalar()
    assert n >= 2


@pytest.mark.asyncio
async def test_a_new_message_brings_it_back_from_that_message(client):
    listing_id, seller, buyer = await _people()
    await _say(client, seller, "seller", listing_id, "old news", buyer_id=buyer)
    assert (await _delete(client, buyer, listing_id=listing_id)).status_code == 200

    await _say(client, seller, "seller", listing_id, "Price dropped to 4,000", buyer_id=buyer)
    thread = next(t for t in await _inbox(client, buyer) if t["listing_id"] == listing_id)
    assert thread["last_message"] == "Price dropped to 4,000"
    # The message from before the delete is not counted as unread news.
    assert thread["unread"] == 1
    assert await _history(client, buyer, listing_id) == ["Price dropped to 4,000"]


@pytest.mark.asyncio
async def test_deleting_is_not_reading(client):
    # The other side must not see "Seen" because someone threw the chat away.
    listing_id, seller, buyer = await _people()
    await _say(client, seller, "seller", listing_id, "Still keen?", buyer_id=buyer)

    async def buyer_read_mark():
        async with AsyncSessionLocal() as db:
            return (await db.execute(select(ThreadReadState.last_read_at).where(
                ThreadReadState.listing_id == listing_id,
                ThreadReadState.buyer_id == buyer,
                ThreadReadState.role == "buyer",
            ))).scalar_one_or_none()

    before = await buyer_read_mark()
    assert (await _delete(client, buyer, listing_id=listing_id)).status_code == 200
    assert await buyer_read_mark() == before
    status = await client.get(f"/negotiate/{listing_id}/read-status",
                              params={"buyer_id": buyer}, headers=_auth(seller))
    assert status.status_code == 200, status.text


@pytest.mark.asyncio
async def test_the_seller_deletes_one_buyers_chat(client):
    listing_id, seller, buyer = await _people()
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.commit()
        other_id = other.id
    await _say(client, buyer, "buyer", listing_id, "Hi from Bea")
    await _say(client, other_id, "buyer", listing_id, "Hi from Other")

    assert (await _delete(client, seller, listing_id=listing_id)).status_code == 400, \
        "a seller has a chat per buyer: which one must be said"
    assert (await _delete(client, seller, listing_id=listing_id, buyer_id=buyer)).status_code == 200

    left = [t["buyer_id"] for t in await _inbox(client, seller) if t["listing_id"] == listing_id]
    assert left == [other_id]


@pytest.mark.asyncio
async def test_a_chat_with_money_in_escrow_stays(client):
    listing_id, seller, buyer = await _people()
    await _say(client, buyer, "buyer", listing_id, "Paid")
    async with AsyncSessionLocal() as db:
        deal = Deal(listing_id=listing_id, seller_id=seller, buyer_id=buyer,
                    agreed_price=4500, commission=0, status=DealStatus.paid)
        db.add(deal)
        await db.commit()
        deal_id = deal.id

    r = await _delete(client, buyer, listing_id=listing_id)
    assert r.status_code == 409
    assert "deal in progress" in r.json()["detail"]
    assert [t for t in await _inbox(client, buyer) if t["listing_id"] == listing_id]

    # Settled: now it can go.
    async with AsyncSessionLocal() as db:
        d = await db.get(Deal, deal_id)
        d.status = DealStatus.released
        await db.commit()
    assert (await _delete(client, buyer, listing_id=listing_id)).status_code == 200


@pytest.mark.asyncio
async def test_a_store_chat_can_be_deleted(client):
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id, owner_id, buyer_id = store.id, owner.id, buyer.id
    r = await client.post("/negotiate/direct-message", headers=_auth(buyer_id), json={
        "store_id": store_id, "sender_role": "buyer", "sender_id": buyer_id,
        "content": "Do you deliver?"})
    assert r.status_code == 200, r.text

    assert (await _delete(client, buyer_id, store_id=store_id)).status_code == 200
    assert not [t for t in await _inbox(client, buyer_id) if t.get("store_id") == store_id]
    hist = await client.get(f"/negotiate/store/{store_id}/history", headers=_auth(buyer_id))
    assert hist.json() == []
    assert [t for t in await _inbox(client, owner_id) if t.get("store_id") == store_id]


@pytest.mark.asyncio
async def test_it_names_a_chat_that_exists(client):
    _, _, buyer = await _people()
    assert (await _delete(client, buyer)).status_code == 400
    assert (await _delete(client, buyer, listing_id="no-such-listing")).status_code == 404
    assert (await client.post("/negotiate/thread/delete", json={"listing_id": "x"})).status_code == 401
