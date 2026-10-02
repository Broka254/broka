"""The inbox opens the screen the user was using (2026-10-02).

Asked for from a phone: someone who moved a deal to the direct chat kept
landing in Zeno's room from the Inbox, every time. The app now remembers,
per thread, which of the two screens the user last used and opens that one
- unless only the other one has something new. `unread` already said when
the direct chat had news (the other person's messages). Nothing said when
Zeno did, so:

  * every inbox thread carries `zeno_unread`: Zeno's messages to this
    viewer since they were last in the Zeno room;
  * POST /negotiate/{listing_id}/zeno-read is the Zeno room saying "seen" -
    its own watermark, which leaves the direct chat's unread count and the
    other side's ticks alone and is never shown to the other side;
  * a thread from before this existed falls back to the direct chat's
    watermark, so Zeno's old replies aren't all "new".
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_inbox_zeno_unread.db"
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


def _ago(minutes: float) -> datetime:
    return datetime.utcnow() - timedelta(minutes=minutes)


async def _thread():
    """A seller, a buyer, and a thread between them: one direct message
    from the buyer, a minute old."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer.id, role="buyer",
                                  content="hi", buyer_id=buyer.id, via_ai=False,
                                  created_at=_ago(10)))
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _zeno_says(listing_id, buyer_id, to, minutes_ago=0.0):
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id="system", role="broker",
                                  recipient_role=to, content=f"Zeno to {to}",
                                  buyer_id=buyer_id, via_ai=True,
                                  created_at=_ago(minutes_ago)))
        await db.commit()


async def _row(client, uid, listing_id):
    r = await client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))
    assert r.status_code == 200, r.text
    return next(t for t in r.json() if t["listing_id"] == listing_id)


@pytest.mark.asyncio
async def test_zeno_messages_count_for_the_side_they_were_written_to(client):
    listing_id, seller, buyer = await _thread()
    await _zeno_says(listing_id, buyer, to="buyer", minutes_ago=5)
    await _zeno_says(listing_id, buyer, to="buyer", minutes_ago=4)
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=3)

    b = await _row(client, buyer, listing_id)
    s = await _row(client, seller, listing_id)
    assert b["zeno_unread"] == 2
    assert s["zeno_unread"] == 1
    # Zeno's messages are not the other person's: the direct chat's count
    # is the buyer's one message, as before.
    assert s["unread"] == 1
    assert b["unread"] == 0


@pytest.mark.asyncio
async def test_seeing_the_zeno_room_clears_only_zenos_count(client):
    listing_id, seller, buyer = await _thread()
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=2)

    r = await client.post(f"/negotiate/{listing_id}/zeno-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200, r.text
    s = await _row(client, seller, listing_id)
    assert s["zeno_unread"] == 0
    # The buyer's direct message is still unread, and the buyer is not told
    # the seller read anything.
    assert s["unread"] == 1
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(buyer))).json()
    assert status["seller_last_read"] is None


@pytest.mark.asyncio
async def test_zeno_saying_something_after_that_counts_again(client):
    listing_id, _, buyer = await _thread()
    await _zeno_says(listing_id, buyer, to="buyer", minutes_ago=2)
    r = await client.post(f"/negotiate/{listing_id}/zeno-read", headers=_auth(buyer), json={})
    assert r.status_code == 200, r.text
    assert (await _row(client, buyer, listing_id))["zeno_unread"] == 0

    await _zeno_says(listing_id, buyer, to="buyer", minutes_ago=-0.05)
    assert (await _row(client, buyer, listing_id))["zeno_unread"] == 1


@pytest.mark.asyncio
async def test_reading_the_direct_chat_does_not_mark_zeno_seen(client):
    listing_id, seller, buyer = await _thread()
    r = await client.post(f"/negotiate/{listing_id}/zeno-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=-0.05)
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200
    s = await _row(client, seller, listing_id)
    assert s["unread"] == 0
    assert s["zeno_unread"] == 1


@pytest.mark.asyncio
async def test_a_thread_from_before_falls_back_to_the_direct_chat_watermark(client):
    listing_id, seller, buyer = await _thread()
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=8)
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=7)
    # Read in the direct chat - the only watermark anyone had until now.
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200
    assert (await _row(client, seller, listing_id))["zeno_unread"] == 0

    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=-0.05)
    assert (await _row(client, seller, listing_id))["zeno_unread"] == 1


@pytest.mark.asyncio
async def test_a_seller_marks_the_buyer_they_name(client):
    listing_id, seller, buyer = await _thread()
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.flush()
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=other.id, role="buyer",
                                  content="me too", buyer_id=other.id, via_ai=False,
                                  created_at=_ago(1)))
        await db.commit()
        other_id = other.id
    await _zeno_says(listing_id, buyer, to="seller", minutes_ago=2)
    await _zeno_says(listing_id, other_id, to="seller", minutes_ago=2)

    r = await client.post(f"/negotiate/{listing_id}/zeno-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200
    rows = (await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))).json()
    by_buyer = {t["buyer_id"]: t for t in rows if t["listing_id"] == listing_id}
    assert by_buyer[buyer]["zeno_unread"] == 0
    assert by_buyer[other_id]["zeno_unread"] == 1


@pytest.mark.asyncio
async def test_someone_outside_the_thread_cannot_mark_it(client):
    listing_id, _, buyer = await _thread()
    r = await client.post("/negotiate/no-such-listing/zeno-read", headers=_auth(buyer), json={})
    assert r.status_code == 404
