"""Edit and unsend for direct messages.

Both are sender-only, windowed, and leave a row in place. The tests pin the
three things a chat can get wrong:

  * the other party's copy must change too - not just the sender's screen;
  * Zeno's private notes are not the sender's to edit (they were never the
    sender's words), and the other side's messages are not either;
  * an unsend clears content/media, not just hides it, while keeping the
    row so unread counts and later replies stay anchored.
"""
import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_message_edit_unsend.db"
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


@pytest.mark.asyncio
async def test_sender_can_edit_and_both_sides_see_the_new_text(client):
    listing_id, _, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "90,000")

    with patch("api.routers.media.broadcast_message_update", new=AsyncMock()) as announce:
        r = await client.patch(f"/negotiate/message/{msg['id']}",
                               json={"content": "85,000"}, headers=_auth(buyer))
    assert r.status_code == 200, r.text
    updated = r.json()["message"]
    assert updated["content"] == "85,000"
    assert updated["edited_at"]
    announce.assert_awaited_once()

    seller_view = (await client.get(f"/negotiate/{listing_id}/history",
                                    params={"buyer_id": buyer},
                                    headers=_auth((await _seller_of(listing_id))))).json()
    assert next(m for m in seller_view if m["id"] == msg["id"])["content"] == "85,000"


async def _seller_of(listing_id):
    async with AsyncSessionLocal() as db:
        listing = (await db.execute(select(Listing).where(
            Listing.id == listing_id))).scalar_one()
        return listing.seller_id


@pytest.mark.asyncio
async def test_only_the_sender_can_edit(client):
    listing_id, seller, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "hello")
    r = await client.patch(f"/negotiate/message/{msg['id']}",
                           json={"content": "hacked"}, headers=_auth(seller))
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_zenos_private_note_is_not_editable_client_side(client):
    listing_id, seller, buyer = await _people()
    async with AsyncSessionLocal() as db:
        note = NegotiationMessage(
            listing_id=listing_id, sender_id="broker", role="broker",
            recipient_role="buyer", content="Zeno's private note",
            buyer_id=buyer, via_ai=True, msg_type="text",
        )
        db.add(note)
        await db.commit()
        note_id = note.id
    r = await client.patch(f"/negotiate/message/{note_id}",
                           json={"content": "not yours"}, headers=_auth(buyer))
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_media_cannot_be_edited(client):
    listing_id, _, buyer = await _people()
    async with AsyncSessionLocal() as db:
        msg = NegotiationMessage(
            listing_id=listing_id, sender_id=buyer, role="buyer",
            recipient_role="seller", content=None, buyer_id=buyer,
            via_ai=False, msg_type="image", media_url="data:image/webp;base64,AA==",
        )
        db.add(msg)
        await db.commit()
        msg_id = msg.id
    r = await client.patch(f"/negotiate/message/{msg_id}",
                           json={"content": "new caption"}, headers=_auth(buyer))
    assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_an_old_message_can_no_longer_be_edited(client):
    listing_id, _, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "old")
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == msg["id"]))).scalar_one()
        row.created_at = datetime.utcnow() - timedelta(minutes=16)
        await db.commit()
    r = await client.patch(f"/negotiate/message/{msg['id']}",
                           json={"content": "too late"}, headers=_auth(buyer))
    assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_unsend_clears_content_and_leaves_a_tombstone(client):
    listing_id, seller, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "my number is 0712...")

    with patch("api.routers.media.broadcast_message_update", new=AsyncMock()) as announce:
        r = await client.delete(f"/negotiate/message/{msg['id']}", headers=_auth(buyer))
    assert r.status_code == 200, r.text
    tomb = r.json()["message"]
    assert tomb["deleted"] is True
    assert tomb["content"] == "" and tomb["msg_type"] == "deleted"
    assert announce.await_args.args[2]["type"] == "message_deleted"

    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == msg["id"]))).scalar_one()
    assert row.deleted_at is not None
    assert row.content is None and row.media_url is None

    seller_view = (await client.get(f"/negotiate/{listing_id}/history",
                                    params={"buyer_id": buyer},
                                    headers=_auth(seller))).json()
    seen = next(m for m in seller_view if m["id"] == msg["id"])
    assert seen["deleted"] is True and seen["content"] == ""

    inbox = (await client.get(f"/negotiate/inbox/{seller}",
                              headers=_auth(seller))).json()
    from_inbox = next(t for t in inbox if t["listing_id"] == listing_id)
    assert from_inbox["last_message"] == "Message deleted"

    # A retry after a lost response is the same tombstone, not an error or
    # a second mutation.
    again = await client.delete(f"/negotiate/message/{msg['id']}", headers=_auth(buyer))
    assert again.status_code == 200
    assert again.json()["message"]["deleted"] is True


@pytest.mark.asyncio
async def test_only_the_sender_can_unsend(client):
    listing_id, seller, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "hello")
    r = await client.delete(f"/negotiate/message/{msg['id']}", headers=_auth(seller))
    assert r.status_code == 403, r.text


@pytest.mark.asyncio
async def test_an_old_message_can_no_longer_be_unsent(client):
    listing_id, _, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "old")
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == msg["id"]))).scalar_one()
        row.created_at = datetime.utcnow() - timedelta(hours=49)
        await db.commit()
    r = await client.delete(f"/negotiate/message/{msg['id']}", headers=_auth(buyer))
    assert r.status_code == 400, r.text


@pytest.mark.asyncio
async def test_an_unsent_message_stops_being_unread_and_is_never_pushed(client):
    """A tombstone is not news.

    The sender takes the message back before the other person reads it.
    Counting or pushing the row would buzz a phone about words that no
    longer exist, and leave a badge that opens onto nothing.
    """
    listing_id, seller, buyer = await _people()
    msg = await _direct(client, buyer, "buyer", listing_id, "wrong chat, ignore")

    before = (await client.get(f"/negotiate/inbox/{seller}",
                               headers=_auth(seller))).json()
    row = next(t for t in before if t["listing_id"] == listing_id)
    assert row["unread"] == 1

    with patch("api.routers.media.broadcast_message_update", new=AsyncMock()):
        r = await client.delete(f"/negotiate/message/{msg['id']}", headers=_auth(buyer))
    assert r.status_code == 200, r.text

    after = (await client.get(f"/negotiate/inbox/{seller}",
                              headers=_auth(seller))).json()
    row = next(t for t in after if t["listing_id"] == listing_id)
    assert row["unread"] == 0

    from api.core.message_push import build_notification
    async with AsyncSessionLocal() as db:
        note = await build_notification(db, listing_id, buyer, "seller")
    assert note is None
