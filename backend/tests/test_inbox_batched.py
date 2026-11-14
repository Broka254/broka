"""The inbox with its figures batched (api/core/inbox_threads.py).

GET /negotiate/inbox/{user_id} used to ask the database for each
conversation's figures one conversation at a time. It now asks once per
group of conversations. This file holds it to what it always answered:

  * per-scenario: a buyer's several conversations, a seller's buyers kept
    apart, store conversations from both sides, unread counts and read
    receipts, delivered before read, Zeno's counts kept to their side,
    deleted chats, missed and cancelled calls, unsent messages, the ETag
    and its 304, and several polls at once;
  * and against the per-thread rules themselves, over a randomized mix of
    all of that at once: every row the inbox sends is compared with what
    the per-thread helpers (negotiate._thread_unread_and_seen, _zeno_unread,
    the old last-row and unread-by-kind queries) say for that thread.
"""
import asyncio
import random
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, or_, select

from api.core import thread_clears
from api.core.message_visibility import thread_visible_to_role_clause
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.models.store import Store
from api.models.thread_clear import ThreadClear
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_inbox_batched.db"
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


async def _user(name: str) -> str:
    async with AsyncSessionLocal() as db:
        u = User(name=name, phone=f"+2547{uuid.uuid4().int % 10**8:08d}", password_hash="x")
        db.add(u)
        await db.commit()
        return u.id


async def _listing(seller_id: str, name: str = "Phone") -> str:
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller_id, name=name, category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id


async def _store(owner_id: str, name: str = "Tech Hub", deleted: bool = False) -> str:
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner_id, name=name, slug=f"s-{uuid.uuid4().hex[:10]}",
                      deleted_at=_ago(1) if deleted else None)
        db.add(store)
        await db.commit()
        return store.id


async def _say(*, buyer_id: str, role: str, sender_id: str, content="hi", minutes_ago=1.0,
               listing_id=None, store_id=None, via_ai=False, to=None, msg_type="text",
               call_type=None, deleted=False) -> str:
    """One row in a thread. A human's direct message is addressed to the
    other side, as /direct-message stores it; Zeno's names its side."""
    if to is None and role in ("buyer", "seller") and not via_ai:
        to = "seller" if role == "buyer" else "buyer"
    async with AsyncSessionLocal() as db:
        m = NegotiationMessage(
            listing_id=listing_id, store_id=store_id, sender_id=sender_id, role=role,
            recipient_role=to, content=content, buyer_id=buyer_id, via_ai=via_ai,
            msg_type=msg_type, call_type=call_type, created_at=_ago(minutes_ago),
            deleted_at=_ago(minutes_ago - 0.01) if deleted else None,
        )
        db.add(m)
        await db.commit()
        return m.id


async def _inbox(client, uid: str) -> list:
    r = await client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


def _row(rows, *, listing_id=None, store_id=None, buyer_id=None):
    found = [t for t in rows
             if (listing_id is None or t["listing_id"] == listing_id)
             and (store_id is None or t.get("store_id") == store_id)
             and (buyer_id is None or t["buyer_id"] == buyer_id)]
    assert len(found) == 1, found
    return found[0]


# ── Scenarios ────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_buyer_sees_each_of_their_conversations_newest_first(client):
    buyer = await _user("Bea Buyer")
    s1, s2 = await _user("Sam One"), await _user("Sue Two")
    l1, l2, l3 = await _listing(s1, "Phone"), await _listing(s1, "Laptop"), await _listing(s2, "Bike")
    await _say(listing_id=l1, buyer_id=buyer, role="buyer", sender_id=buyer, minutes_ago=30)
    await _say(listing_id=l1, buyer_id=buyer, role="seller", sender_id=s1, content="yes", minutes_ago=29)
    await _say(listing_id=l2, buyer_id=buyer, role="buyer", sender_id=buyer, minutes_ago=20)
    await _say(listing_id=l3, buyer_id=buyer, role="buyer", sender_id=buyer, minutes_ago=10)
    await _say(listing_id=l3, buyer_id=buyer, role="seller", sender_id=s2, content="a", minutes_ago=9)
    await _say(listing_id=l3, buyer_id=buyer, role="seller", sender_id=s2, content="b", minutes_ago=8)

    rows = await _inbox(client, buyer)
    assert [t["listing_id"] for t in rows] == [l3, l2, l1]
    assert all(t["my_role"] == "buyer" and t["buyer_id"] == buyer for t in rows)
    assert [t["counterpart_name"] for t in rows] == ["Sue Two", "Sam One", "Sam One"]
    assert [t["unread"] for t in rows] == [2, 0, 1]
    assert [t["unread_count"] for t in rows] == [2, 0, 1]
    assert rows[0]["last_message"] == "b" and rows[0]["last_role"] == "seller"
    assert rows[0]["unread_message"]["content"] == "b"


@pytest.mark.asyncio
async def test_a_seller_gets_one_conversation_per_buyer_kept_apart(client):
    seller = await _user("Sam Seller")
    b1, b2, b3 = await _user("Ann One"), await _user("Ben Two"), await _user("Cat Three")
    l1, l2 = await _listing(seller, "Phone"), await _listing(seller, "Laptop")
    await _say(listing_id=l1, buyer_id=b1, role="buyer", sender_id=b1, content="b1 here", minutes_ago=9)
    await _say(listing_id=l1, buyer_id=b2, role="buyer", sender_id=b2, content="b2 one", minutes_ago=8)
    await _say(listing_id=l1, buyer_id=b2, role="buyer", sender_id=b2, content="b2 two", minutes_ago=7)
    await _say(listing_id=l2, buyer_id=b3, role="buyer", sender_id=b3, content="b3 here", minutes_ago=6)
    await _say(listing_id=l1, buyer_id=b1, role="broker", sender_id="broker", to="seller",
               content="Zeno to seller about b1", via_ai=True, minutes_ago=5)

    rows = await _inbox(client, seller)
    assert len(rows) == 3 and all(t["my_role"] == "seller" for t in rows)
    one, two, three = (_row(rows, listing_id=l1, buyer_id=b1), _row(rows, listing_id=l1, buyer_id=b2),
                       _row(rows, listing_id=l2, buyer_id=b3))
    assert (one["counterpart_name"], one["unread"], one["zeno_unread"]) == ("Ann One", 1, 1)
    assert (two["counterpart_name"], two["unread"], two["zeno_unread"]) == ("Ben Two", 2, 0)
    assert (three["counterpart_name"], three["unread"]) == ("Cat Three", 1)
    # Zeno's message is the seller's preview of b1's thread, never b2's.
    assert one["last_message"] == "Zeno to seller about b1"
    assert two["last_message"] == "b2 two"


@pytest.mark.asyncio
async def test_store_conversations_from_both_sides(client):
    owner, buyer, other = await _user("Olive Owner"), await _user("Bea Buyer"), await _user("Ola Other")
    store = await _store(owner, "Tech Hub")
    gone = await _store(owner, "Closed Shop", deleted=True)
    await _say(store_id=store, buyer_id=buyer, role="buyer", sender_id=buyer, content="open?", minutes_ago=5)
    await _say(store_id=store, buyer_id=buyer, role="seller", sender_id=owner, content="till 6",
               minutes_ago=4)
    await _say(store_id=store, buyer_id=other, role="buyer", sender_id=other, content="price?", minutes_ago=3)
    await _say(store_id=gone, buyer_id=buyer, role="buyer", sender_id=buyer, content="hello?", minutes_ago=2)

    mine = await _inbox(client, buyer)
    row = _row(mine, store_id=store)
    assert (row["thread_type"], row["my_role"], row["counterpart_name"]) == ("store", "buyer", "Tech Hub")
    assert (row["listing_id"], row["zeno_unread"], row["unread"]) == (None, 0, 1)
    assert row["last_message"] == "till 6"
    assert not any(t.get("store_id") == gone for t in mine), "a deleted store's thread is gone"

    theirs = await _inbox(client, owner)
    assert {t["buyer_id"] for t in theirs if t.get("store_id") == store} == {buyer, other}
    b = _row(theirs, store_id=store, buyer_id=buyer)
    # Replying is not reading: only the owner's read watermark clears it.
    assert (b["my_role"], b["counterpart_name"], b["unread"]) == ("seller", "Bea Buyer", 1)
    assert b["last_message"] == "till 6"
    o = _row(theirs, store_id=store, buyer_id=other)
    assert (o["counterpart_name"], o["unread"], o["last_message"]) == ("Ola Other", 1, "price?")

    r = await client.post(f"/negotiate/store/{store}/mark-read", headers=_auth(owner),
                          json={"buyer_id": other})
    assert r.status_code == 200, r.text
    assert _row(await _inbox(client, owner), store_id=store, buyer_id=other)["unread"] == 0


@pytest.mark.asyncio
async def test_unread_counts_and_read_receipts(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    listing = await _listing(seller)
    for i in range(3):
        await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer,
                   content=f"q{i}", minutes_ago=5 - i)
    s = _row(await _inbox(client, seller), listing_id=listing)
    assert (s["unread"], s["last_message_seen"], s["last_message_delivered"]) == (3, False, False)
    b = _row(await _inbox(client, buyer), listing_id=listing)
    assert (b["last_message_seen"], b["last_message_delivered"]) == (False, False)

    r = await client.post(f"/negotiate/{listing}/mark-read", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200, r.text
    assert _row(await _inbox(client, seller), listing_id=listing)["unread"] == 0
    b = _row(await _inbox(client, buyer), listing_id=listing)
    assert (b["last_message_seen"], b["last_message_delivered"]) == (True, True)

    # A newer message is unread again, and not yet seen.
    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, content="q4",
               minutes_ago=-0.05)
    assert _row(await _inbox(client, seller), listing_id=listing)["unread"] == 1
    assert _row(await _inbox(client, buyer), listing_id=listing)["last_message_seen"] is False


@pytest.mark.asyncio
async def test_delivered_is_shown_before_it_is_read(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    listing = await _listing(seller)
    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, minutes_ago=2)
    r = await client.post(f"/negotiate/{listing}/mark-delivered", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200, r.text
    b = _row(await _inbox(client, buyer), listing_id=listing)
    assert (b["last_message_delivered"], b["last_message_seen"]) == (True, False)
    # Delivered says nothing about reading: still unread for the seller.
    assert _row(await _inbox(client, seller), listing_id=listing)["unread"] == 1
    # The ticks describe the viewer's own last message only.
    assert _row(await _inbox(client, seller), listing_id=listing)["last_message_delivered"] is False


@pytest.mark.asyncio
async def test_zeno_counts_stay_with_their_side_and_private_words_stay_private(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    l1, l2 = await _listing(seller, "Phone"), await _listing(seller, "Laptop")
    for listing in (l1, l2):
        await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer,
                   content="is it there?", minutes_ago=9)
        await _say(listing_id=listing, buyer_id=buyer, role="broker", sender_id="broker",
                   to="buyer", content="Zeno to buyer", via_ai=True, minutes_ago=8)
    await _say(listing_id=l1, buyer_id=buyer, role="broker", sender_id="broker", to="seller",
               content="Zeno to seller", via_ai=True, minutes_ago=7)
    await _say(listing_id=l1, buyer_id=buyer, role="buyer", sender_id=buyer,
               content="my real max is 20000", via_ai=True, minutes_ago=6)
    await _say(listing_id=l2, buyer_id=buyer, role="broker", sender_id="broker", to=None,
               content="legacy shared reply", via_ai=True, minutes_ago=5)

    s1, s2 = (_row(await _inbox(client, seller), listing_id=l) for l in (l1, l2))
    assert (s1["zeno_unread"], s2["zeno_unread"]) == (1, 0)
    assert s1["last_message"] == "Zeno to seller"
    assert s2["last_message"] == "is it there?", "no audience, no preview"
    # The buyer's private words to Zeno are neither previewed nor counted.
    assert (s1["unread"], s2["unread"]) == (1, 1)
    b1, b2 = (_row(await _inbox(client, buyer), listing_id=l) for l in (l1, l2))
    assert (b1["zeno_unread"], b2["zeno_unread"]) == (1, 1)
    # A row for the Zeno room is not the direct chat's preview, even to
    # its author; Zeno's reply to them is.
    assert b1["last_message"] == "Zeno to buyer"

    r = await client.post(f"/negotiate/{l1}/zeno-read", headers=_auth(buyer), json={})
    assert r.status_code == 200, r.text
    b1, b2 = (_row(await _inbox(client, buyer), listing_id=l) for l in (l1, l2))
    assert (b1["zeno_unread"], b2["zeno_unread"]) == (0, 1), "one thread's room, one count"


@pytest.mark.asyncio
async def test_a_deleted_chat_leaves_one_inbox_and_comes_back_with_only_the_new(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    listing = await _listing(seller)
    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, content="old",
               minutes_ago=5)
    await _say(listing_id=listing, buyer_id=buyer, role="broker", sender_id="broker", to="seller",
               content="old Zeno", via_ai=True, minutes_ago=4)
    r = await client.post(f"/negotiate/{listing}/clear", headers=_auth(seller),
                          json={"buyer_id": buyer})
    assert r.status_code == 200, r.text
    assert not [t for t in await _inbox(client, seller) if t["listing_id"] == listing]
    # The other side's copy is untouched.
    assert _row(await _inbox(client, buyer), listing_id=listing)["last_message"] == "old"

    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, content="new",
               minutes_ago=-0.05)
    row = _row(await _inbox(client, seller), listing_id=listing)
    assert (row["last_message"], row["unread"], row["zeno_unread"]) == ("new", 1, 0)


@pytest.mark.asyncio
async def test_missed_and_cancelled_calls_are_named_beside_the_last_text(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    l1, l2, l3 = (await _listing(seller, n) for n in ("Phone", "Laptop", "Bike"))
    await _say(listing_id=l1, buyer_id=buyer, role="buyer", sender_id=buyer, content="call me?",
               minutes_ago=5)
    call = await _say(listing_id=l1, buyer_id=buyer, role="buyer", sender_id=buyer, content="missed",
                      msg_type="call", call_type="video", minutes_ago=4)
    await _say(listing_id=l2, buyer_id=buyer, role="buyer", sender_id=buyer, content="cancelled",
               msg_type="call", call_type="audio", minutes_ago=3)
    await _say(listing_id=l3, buyer_id=buyer, role="buyer", sender_id=buyer, content="completed",
               msg_type="call", call_type="audio", minutes_ago=2)
    rows = await _inbox(client, seller)
    one, two, three = (_row(rows, listing_id=l) for l in (l1, l2, l3))
    assert (one["last_msg_type"], one["last_call_type"]) == ("call", "video")
    assert one["unread_message"]["content"] == "call me?"
    assert one["unread_missed_call"] == {"id": call, "call_type": "video"}
    assert two["unread_missed_call"]["call_type"] == "audio", "a cancelled call is a missed call"
    assert two["unread_message"] is None
    assert three["unread_missed_call"] is None, "an answered call is not missed"
    assert three["unread"] == 1, "call cards still count, as the badge always has"


@pytest.mark.asyncio
async def test_an_unsent_message_is_named_as_deleted_and_is_not_unread(client):
    seller, buyer = await _user("Sam Seller"), await _user("Bea Buyer")
    listing = await _listing(seller)
    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, content="kept",
               minutes_ago=5)
    await _say(listing_id=listing, buyer_id=buyer, role="buyer", sender_id=buyer, content="oops",
               minutes_ago=4, deleted=True)
    row = _row(await _inbox(client, seller), listing_id=listing)
    assert row["last_message"] == "Message deleted"
    assert row["unread"] == 1
    assert row["unread_message"]["content"] == "kept"


@pytest.mark.asyncio
async def test_an_unchanged_inbox_is_a_304_and_any_change_is_not(client):
    seller = await _user("Sam Seller")
    buyers = [await _user(f"Buyer {i}") for i in range(4)]
    listing = await _listing(seller)
    for i, b in enumerate(buyers):
        await _say(listing_id=listing, buyer_id=b, role="buyer", sender_id=b, minutes_ago=10 - i)
    first = await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))
    etag = first.headers["etag"]
    # The same rows give the same tag, request after request.
    for _ in range(3):
        again = await client.get(f"/negotiate/inbox/{seller}",
                                 headers={**_auth(seller), "If-None-Match": etag})
        assert again.status_code == 304 and again.content == b""
        assert again.headers["etag"] == etag
    r = await client.post(f"/negotiate/{listing}/mark-read", headers=_auth(seller),
                          json={"buyer_id": buyers[0]})
    assert r.status_code == 200
    changed = await client.get(f"/negotiate/inbox/{seller}",
                               headers={**_auth(seller), "If-None-Match": etag})
    assert changed.status_code == 200 and changed.headers["etag"] != etag


@pytest.mark.asyncio
async def test_many_polls_at_once_get_the_same_answer(client):
    seller = await _user("Sam Seller")
    listings = [await _listing(seller, f"Item {i}") for i in range(3)]
    buyers = [await _user(f"Buyer {i}") for i in range(6)]
    for i, b in enumerate(buyers):
        await _say(listing_id=listings[i % 3], buyer_id=b, role="buyer", sender_id=b, minutes_ago=20 - i)
        await _say(listing_id=listings[i % 3], buyer_id=b, role="broker", sender_id="broker",
                   to="seller", content=f"Zeno {i}", via_ai=True, minutes_ago=19 - i)
    answers = await asyncio.gather(*[
        client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))
        for uid in [seller] * 8 + buyers[:4]
    ])
    assert all(r.status_code == 200 for r in answers), [r.status_code for r in answers]
    seller_answers = answers[:8]
    assert len({r.headers["etag"] for r in seller_answers}) == 1
    assert len(seller_answers[0].json()) == 6


# ── The same answers as the per-thread rules, over a randomized mix ──────────

async def _reference_last(db, *, kind, thread_id, buyer_id, role, cut):
    """The old inbox's newest-row query for one thread."""
    col = NegotiationMessage.listing_id if kind == "listing" else NegotiationMessage.store_id
    # visibility-ok: test reference, the same audience clause the inbox uses
    q = select(NegotiationMessage).where(
        col == thread_id, NegotiationMessage.buyer_id == buyer_id,
        thread_visible_to_role_clause(role))
    if cut:
        q = q.where(NegotiationMessage.created_at > cut)
    return (await db.execute(q.order_by(NegotiationMessage.created_at.desc(),
                                        NegotiationMessage.id.desc()).limit(1))).scalar_one_or_none()


async def _reference_by_kind(db, *, kind, thread_id, buyer_id, role, cut):
    """The old inbox's _unread_by_kind for one thread."""
    counterpart = "seller" if role == "buyer" else "buyer"
    trs_col = ThreadReadState.listing_id if kind == "listing" else ThreadReadState.store_id
    msg_col = NegotiationMessage.listing_id if kind == "listing" else NegotiationMessage.store_id
    my_last_read = (await db.execute(select(ThreadReadState.last_read_at).where(
        trs_col == thread_id, ThreadReadState.buyer_id == buyer_id, ThreadReadState.role == role,
    ))).scalar_one_or_none()
    conds = [
        msg_col == thread_id, NegotiationMessage.buyer_id == buyer_id,
        NegotiationMessage.role == counterpart,
        or_(NegotiationMessage.via_ai.is_(False), NegotiationMessage.via_ai.is_(None)),
        or_(NegotiationMessage.recipient_role.is_(None), NegotiationMessage.recipient_role == role),
        NegotiationMessage.deleted_at.is_(None),
    ]
    floor = thread_clears.later(my_last_read, cut)
    if floor:
        conds.append(NegotiationMessage.created_at > floor)

    async def newest(*extra):
        # visibility-ok: test reference - the other side's direct messages, as the inbox selects them
        return (await db.execute(
            select(NegotiationMessage).where(*conds, *extra)
            .order_by(NegotiationMessage.created_at.desc(), NegotiationMessage.id.desc()).limit(1)
        )).scalar_one_or_none()

    msg = await newest(or_(NegotiationMessage.msg_type.is_(None), NegotiationMessage.msg_type != "call"))
    call = await newest(NegotiationMessage.msg_type == "call",
                        NegotiationMessage.content.in_(("missed", "cancelled")))
    return (
        {"id": msg.id, "content": (msg.content or "[media]")[:80],
         "msg_type": msg.msg_type or "text"} if msg else None,
        {"id": call.id, "call_type": call.call_type} if call else None,
    )


async def _expected(db, row, cleared):
    """What the per-thread rules say for one inbox row."""
    from api.routers.negotiate import _thread_unread_and_seen, _zeno_unread
    kind = "store" if row.get("thread_type") == "store" else "listing"
    thread_id = row["store_id"] if kind == "store" else row["listing_id"]
    buyer_id, role = row["buyer_id"], row["my_role"]
    cut = cleared.get((kind, thread_id, buyer_id))
    last = await _reference_last(db, kind=kind, thread_id=thread_id, buyer_id=buyer_id,
                                 role=role, cut=cut)
    assert last is not None, f"the inbox listed a thread with nothing to show: {row}"
    listing_id = thread_id if kind == "listing" else None
    store_id = thread_id if kind == "store" else None
    unread, seen, delivered = await _thread_unread_and_seen(
        db, listing_id, buyer_id, role, last, store_id=store_id, cleared_at=cut)
    zeno = await _zeno_unread(db, thread_id, buyer_id, role, cleared_at=cut) if kind == "listing" else 0
    message, call = (await _reference_by_kind(db, kind=kind, thread_id=thread_id,
                                              buyer_id=buyer_id, role=role, cut=cut)
                     if unread else (None, None))
    return {"last_message_id": last.id, "unread": unread, "last_message_seen": seen,
            "last_message_delivered": delivered, "zeno_unread": zeno,
            "unread_message": message, "unread_missed_call": call}


async def _randomized_world(rng: random.Random) -> str:
    """One user who buys, sells and keeps a store, and a randomized mix in
    every conversation they are in: both sides' words, Zeno to each side and
    to nobody, private words to Zeno, unsent messages, every kind of call,
    watermarks on either side and the Zeno rooms, deletions by this user and
    by others, and timestamps that tie."""
    me = await _user("Mixed User")
    sellers = [await _user(f"Seller {i}") for i in range(3)]
    buyers = [await _user(f"Buyer {i}") for i in range(5)]
    mine = [await _listing(me, f"Mine {i}") for i in range(3)]
    theirs = [await _listing(rng.choice(sellers), f"Theirs {i}") for i in range(4)]
    my_store = await _store(me, "My Store")
    their_store = await _store(sellers[0], "Their Store")
    threads = [("listing", l, me) for l in theirs]
    threads += [("listing", l, b) for l in mine for b in rng.sample(buyers, 3)]
    threads += [("store", my_store, b) for b in rng.sample(buyers, 3)]
    threads += [("store", their_store, me)]
    base = datetime.utcnow() - timedelta(days=2)
    stamps = [base + timedelta(minutes=rng.randrange(0, 2000)) for _ in range(25)]

    def stamp():
        return rng.choice(stamps)

    async with AsyncSessionLocal() as db:
        for kind, thread_id, buyer_id in threads:
            where = {"listing_id": thread_id} if kind == "listing" else {"store_id": thread_id}
            db.add(NegotiationMessage(sender_id=buyer_id, role="buyer", recipient_role="seller",
                                      content="opening", buyer_id=buyer_id, via_ai=False,
                                      created_at=stamp(), **where))
            for _ in range(rng.randrange(1, 10)):
                role = rng.choice(["buyer", "seller", "broker", "broker"])
                is_call = role != "broker" and rng.random() < 0.3
                db.add(NegotiationMessage(
                    sender_id="broker" if role == "broker" else buyer_id, role=role,
                    recipient_role=rng.choice(["buyer", "seller", None]),
                    content=(rng.choice(["missed", "cancelled", "completed", "declined"])
                             if is_call else rng.choice(["ok", "", None, "how much?", "x" * 100])),
                    buyer_id=buyer_id, msg_type="call" if is_call else rng.choice(
                        ["text", None, "image", "voice", "file"]),
                    call_type=rng.choice(["audio", "video", None]),
                    via_ai=True if role == "broker" else rng.choice([False, None, True]),
                    deleted_at=stamp() if rng.random() < 0.15 else None,
                    file_name=rng.choice([None, "Invoice.pdf"]),
                    created_at=stamp(), **where))
            for side in ("buyer", "seller", "zeno_buyer", "zeno_seller"):
                if rng.random() < 0.5:
                    db.add(ThreadReadState(
                        buyer_id=buyer_id, role=side,
                        last_read_at=rng.choice([datetime(1970, 1, 1), stamp()]),
                        last_delivered_at=rng.choice([None, stamp()]), **where))
            if rng.random() < 0.3:
                db.add(ThreadClear(user_id=me, buyer_id=buyer_id,
                                   role="buyer" if buyer_id == me else "seller",
                                   cleared_at=stamp(), **where))
            if rng.random() < 0.3:
                db.add(ThreadClear(user_id=str(uuid.uuid4()), buyer_id=buyer_id, role="seller",
                                   cleared_at=datetime.utcnow(), **where))
        await db.commit()
    return me


@pytest.mark.asyncio
@pytest.mark.parametrize("seed", range(4))
async def test_every_row_says_what_the_per_thread_rules_say(client, seed):
    rng = random.Random(seed)
    me = await _randomized_world(rng)
    rows = await _inbox(client, me)
    assert rows, "the user is in several conversations"
    fields = ("last_message_id", "unread", "last_message_seen", "last_message_delivered",
              "zeno_unread", "unread_message", "unread_missed_call")
    async with AsyncSessionLocal() as db:
        cleared = await thread_clears.clears_for(db, me)
        for row in rows:
            want = await _expected(db, row, cleared)
            got = {k: row[k] for k in fields}
            assert got == want, (row.get("thread_type"), row["my_role"], row["listing_id"])
            assert row["unread_count"] == row["unread"]
        # And nothing that should be listed is missing: every conversation
        # with something this user may see is there exactly once.
        listed = {("store" if r.get("thread_type") == "store" else "listing",
                   r.get("store_id") or r["listing_id"], r["buyer_id"], r["my_role"]) for r in rows}
        assert len(listed) == len(rows)
        candidates = (await db.execute(
            # visibility-ok: test bookkeeping - thread ids only, no content
            select(NegotiationMessage.listing_id, NegotiationMessage.store_id,
                   NegotiationMessage.buyer_id, func.count())
            .group_by(NegotiationMessage.listing_id, NegotiationMessage.store_id,
                      NegotiationMessage.buyer_id)
        )).all()
        mine = {l.id for l in (await db.execute(select(Listing).where(Listing.seller_id == me))).scalars()}
        my_stores = {s.id for s in (await db.execute(select(Store).where(Store.owner_id == me))).scalars()}
        for listing_id, store_id, buyer_id, _n in candidates:
            kind, thread_id = ("listing", listing_id) if listing_id else ("store", store_id)
            for role in ("buyer", "seller"):
                if role == "buyer" and buyer_id != me:
                    continue
                if role == "seller" and thread_id not in (mine | my_stores):
                    continue
                if role == "seller" and kind == "store" and buyer_id == me:
                    continue
                last = await _reference_last(
                    db, kind=kind, thread_id=thread_id, buyer_id=buyer_id, role=role,
                    cut=cleared.get((kind, thread_id, buyer_id)))
                if last is not None:
                    assert (kind, thread_id, buyer_id, role) in listed, (kind, role)
