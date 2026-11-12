"""A message push reaching a phone, and the double tick it earns (2026-11-12).

Asked for: the sender's "Delivered" must mean the recipient's phone has the
message - with the app in the background, closed, or the phone locked - and
nothing else. Firebase accepting a push is not delivery; a receipt that
failed is not delivery; a notification arriving is never "Seen".

What was wrong with POST /negotiate/notification/delivered, the receipt the
phone sends from the push's background handler:

  * It moved the delivery watermark to the moment the receipt landed, not
    to the message the push announced. A receipt that landed late - a
    retry, a phone slow out of Doze, the handler run again when its
    notification is dismissed - marked as delivered whatever the sender had
    written since, which that phone had not been shown to have. The
    sender's open chat was told the same instant and kept it: the app
    applies receipts forward only, and saves them.
  * The same push acknowledged twice announced the receipt twice.
  * Nothing was logged, on success or refusal: "why is it still one tick?"
    had no answer in the API log.

The phone now names the message (the push's messageId). It must be news for
that side of that conversation; the watermark moves up to it and no further.
"""
import asyncio
import logging
import uuid
from datetime import datetime, timedelta, timezone
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from jose import jwt
from sqlalchemy import select

from api.core import message_push, push_devices
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.routers import calls
from api.security import ALGORITHM, SECRET_KEY, create_access_token, create_thread_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_push_delivery_receipts.db"
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


@pytest_asyncio.fixture(autouse=True)
async def _pushes_settled():
    """Let the re-push that POST /calls/register-token schedules finish
    inside the test that started it. A test that ends straight after
    registering a phone - or fails there - closed its event loop with that
    task halfway through a read, and the SQLite connection it held kept the
    file locked: every later test in the module failed with "database is
    locked" instead of saying what was wrong."""
    yield
    loop = asyncio.get_running_loop()
    while True:
        pending = [t for t in list(message_push._inflight)
                   if t.get_loop() is loop and not t.done()]
        if not pending:
            return
        await asyncio.gather(*pending, return_exceptions=True)


@pytest_asyncio.fixture
async def fcm():
    """FCM as configured: every send captured, and accepted the way Firebase
    accepts one - with a message id, which proves nothing about the phone."""
    async def _send(**kwargs):
        _send.sent.append(kwargs)
        return calls.FcmResult(True, message_id=f"projects/broka/messages/{len(_send.sent)}")

    _send.sent = []
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield _send
        await message_push.drain()
        await asyncio.gather(*list(calls._background), return_exceptions=True)
    message_push._last_pushed.clear()


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _people(n_buyers: int = 1):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _register(client, uid, phone):
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": phone, "token_type": "fcm", "platform": "android"})
    assert r.status_code == 200, r.text


def _token(user, role, buyer, phone, *, listing_id=None, store_id=None):
    """What the push to [phone] carried for this conversation."""
    return create_thread_token(user, role, buyer, listing_id=listing_id, store_id=store_id,
                               device=push_devices.token_fingerprint(phone))


def _at(minutes_ago: float) -> datetime:
    # Naive UTC, as every DateTime column holds; microseconds kept, so the
    # watermark is compared to the exact instant, not a rounded one.
    return (datetime.utcnow() - timedelta(minutes=minutes_ago)).replace(microsecond=123456)


async def _message(sender, role, buyer, at, *, listing_id=None, store_id=None,
                   content="Still available?") -> str:
    async with AsyncSessionLocal() as db:
        msg = NegotiationMessage(listing_id=listing_id, store_id=store_id, sender_id=sender,
                                 role=role, content=content, buyer_id=buyer, via_ai=False,
                                 msg_type="text", created_at=at)
        db.add(msg)
        await db.commit()
        return msg.id


async def _watermarks(buyer, role, *, listing_id=None, store_id=None):
    async with AsyncSessionLocal() as db:
        cond = (ThreadReadState.store_id == store_id) if store_id \
            else (ThreadReadState.listing_id == listing_id)
        row = (await db.execute(select(ThreadReadState).where(
            cond, ThreadReadState.buyer_id == buyer, ThreadReadState.role == role,
        ))).scalar_one_or_none()
        return (row.last_delivered_at, row.last_read_at) if row else (None, None)


def _parsed(iso):
    return datetime.fromisoformat(iso.rstrip("Z")) if iso else None


async def _ack(client, token, message_id=None):
    body = {"thread_token": token}
    if message_id is not None:
        body["message_id"] = message_id
    return await client.post("/negotiate/notification/delivered", json=body)


async def _inbox_row(client, uid, listing_id):
    rows = (await client.get(f"/negotiate/inbox/{uid}", headers=_auth(uid))).json()
    return next(t for t in rows if t.get("listing_id") == listing_id)


# ── The watermark moves to the message the push announced ────────────────────

@pytest.mark.asyncio
async def test_a_late_receipt_ticks_the_message_it_announced_and_nothing_written_since(client):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "bounded-phone")
    t1, t2 = _at(2), _at(1)
    m1 = await _message(buyer, "buyer", buyer, t1, listing_id=listing_id)
    # The buyer writes again before the seller's phone gets its receipt for
    # m1 through - and before the push for this one reaches it.
    m2 = await _message(buyer, "buyer", buyer, t2, listing_id=listing_id, content="Hello?")
    token = _token(seller, "seller", buyer, "bounded-phone", listing_id=listing_id)

    with patch("api.routers.media.broadcast_receipt", new=AsyncMock()) as announce:
        r = await _ack(client, token, m1)
    assert r.status_code == 200, r.text
    assert r.json()["advanced"] is True
    assert _parsed(r.json()["last_delivered_at"]) == t1

    delivered, read = await _watermarks(buyer, "seller", listing_id=listing_id)
    assert delivered == t1, "up to the message the push announced - not to when the receipt landed"
    assert read is None or read < t1, "a push arriving is not the chat being read"
    # Only this side of this conversation moved.
    assert await _watermarks(buyer, "buyer", listing_id=listing_id) == (None, None)

    # The buyer, who sent both: m1 delivered, m2 still only sent, neither seen.
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(buyer))).json()
    assert _parsed(status["seller_last_delivered"]) == t1
    last_read = _parsed(status["seller_last_read"])
    assert last_read is None or last_read < t1
    row = await _inbox_row(client, buyer, listing_id)
    assert row["last_message_delivered"] is False, "m2 has not reached the seller's phone"
    assert row["last_message_seen"] is False

    # The buyer's open chat was told the watermark the thread holds - which
    # it applies forward only and keeps, so "now" would have stuck.
    announce.assert_awaited_once()
    args, kwargs = announce.call_args
    assert args == (listing_id, buyer, "seller")
    assert kwargs["exclude_uid"] == seller
    assert kwargs["delivered_at"] == t1
    assert kwargs["read_at"] is None

    # m2's own push arrives, and its receipt ticks it.
    r = await _ack(client, token, m2)
    assert r.status_code == 200, r.text
    assert (await _watermarks(buyer, "seller", listing_id=listing_id))[0] == t2
    row = await _inbox_row(client, buyer, listing_id)
    assert row["last_message_delivered"] is True
    assert row["last_message_seen"] is False


@pytest.mark.asyncio
async def test_the_same_push_acknowledged_twice_is_announced_once(client):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "twice-phone")
    m1 = await _message(buyer, "buyer", buyer, _at(1), listing_id=listing_id)
    token = _token(seller, "seller", buyer, "twice-phone", listing_id=listing_id)
    with patch("api.routers.media.broadcast_receipt", new=AsyncMock()) as announce:
        first = await _ack(client, token, m1)
        again = await _ack(client, token, m1)
    assert first.status_code == again.status_code == 200
    assert first.json()["advanced"] is True
    assert again.json()["advanced"] is False
    assert again.json()["last_delivered_at"] == first.json()["last_delivered_at"]
    announce.assert_awaited_once()


@pytest.mark.asyncio
async def test_an_older_pushs_receipt_after_a_newer_ones_rewinds_nothing(client):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "order-phone")
    t1, t2 = _at(2), _at(1)
    m1 = await _message(buyer, "buyer", buyer, t1, listing_id=listing_id)
    m2 = await _message(buyer, "buyer", buyer, t2, listing_id=listing_id)
    token = _token(seller, "seller", buyer, "order-phone", listing_id=listing_id)
    assert (await _ack(client, token, m2)).status_code == 200
    late = await _ack(client, token, m1)
    assert late.status_code == 200
    assert late.json()["advanced"] is False
    assert (await _watermarks(buyer, "seller", listing_id=listing_id))[0] == t2


@pytest.mark.asyncio
async def test_a_receipt_from_an_app_that_names_no_message_is_answered_as_before(client):
    """App builds from before the message id was sent post the token alone."""
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "old-app-phone")
    await _message(buyer, "buyer", buyer, _at(1), listing_id=listing_id)
    before = datetime.utcnow()
    r = await _ack(client, _token(seller, "seller", buyer, "old-app-phone", listing_id=listing_id))
    assert r.status_code == 200, r.text
    delivered, _ = await _watermarks(buyer, "seller", listing_id=listing_id)
    assert before <= delivered <= datetime.utcnow()


# ── Only the conversation, and the side, the push was for ────────────────────

@pytest.mark.asyncio
async def test_a_message_of_another_conversation_or_of_this_side_is_refused(client):
    listing_id, seller, [buyer_a, buyer_b] = await _people(n_buyers=2)
    await _register(client, seller, "two-buyers-phone")
    in_b = await _message(buyer_b, "buyer", buyer_b, _at(2), listing_id=listing_id)
    own = await _message(seller, "seller", buyer_a, _at(1), listing_id=listing_id,
                         content="Yes, it is")
    token_a = _token(seller, "seller", buyer_a, "two-buyers-phone", listing_id=listing_id)

    # Buyer B's message, named with buyer A's thread token.
    assert (await _ack(client, token_a, in_b)).status_code == 404
    # The seller's own message is no news to the seller.
    assert (await _ack(client, token_a, own)).status_code == 404
    # Nothing that does not exist either.
    assert (await _ack(client, token_a, str(uuid.uuid4()))).status_code == 404
    for buyer in (buyer_a, buyer_b):
        for role in ("seller", "buyer"):
            assert await _watermarks(buyer, role, listing_id=listing_id) == (None, None), (
                f"{role} watermark of {buyer}'s thread moved on a refused receipt")


# ── Firebase accepting a push is not delivery ─────────────────────────────────

@pytest.mark.asyncio
async def test_firebase_accepting_the_push_is_not_delivery_the_phones_receipt_is(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "fcm-accepted-phone")
    r = await client.post("/negotiate/direct-message", headers=_auth(buyer), json={
        "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
        "content": "Bei ya mwisho?"})
    assert r.status_code == 200, r.text
    sent = r.json()["message"]
    await message_push.drain()
    [push] = [p for p in fcm.sent
              if p["data"].get("type") == "new_message" and p["data"].get("listingId") == listing_id]
    assert push["token"] == "fcm-accepted-phone"

    # Firebase took it, with a message id - and nothing says the phone has it.
    assert (await _watermarks(buyer, "seller", listing_id=listing_id)) == (None, None)
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(buyer))).json()
    assert status["seller_last_delivered"] is None
    assert (await _inbox_row(client, buyer, listing_id))["last_message_delivered"] is False

    # The phone's own receipt, with what the push carried, is what does.
    assert push["data"]["messageId"] == sent["id"]
    r = await _ack(client, push["data"]["threadToken"], push["data"]["messageId"])
    assert r.status_code == 200, r.text
    async with AsyncSessionLocal() as db:
        created = (await db.execute(select(NegotiationMessage.created_at).where(
            NegotiationMessage.id == sent["id"]))).scalar_one()
    delivered, read = await _watermarks(buyer, "seller", listing_id=listing_id)
    assert delivered == created
    assert read is None or read < created
    row = await _inbox_row(client, buyer, listing_id)
    assert row["last_message_delivered"] is True
    assert row["last_message_seen"] is False


# ── Store conversations ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_store_conversations_receipt_is_bounded_too(client):
    from api.models.store import Store

    _, owner, [buyer] = await _people()
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner, name=f"Clanix {uuid.uuid4().hex[:6]}",
                      slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id = store.id
    await _register(client, buyer, "store-receipt-phone")
    t1, t2 = _at(2), _at(1)
    s1 = await _message(owner, "seller", buyer, t1, store_id=store_id, content="Welcome")
    await _message(owner, "seller", buyer, t2, store_id=store_id, content="We deliver")
    token = _token(buyer, "buyer", buyer, "store-receipt-phone", store_id=store_id)
    with patch("api.routers.media.broadcast_store_receipt", new=AsyncMock()) as announce:
        r = await _ack(client, token, s1)
    assert r.status_code == 200, r.text
    assert (await _watermarks(buyer, "buyer", store_id=store_id))[0] == t1
    _, kwargs = announce.call_args
    assert kwargs["delivered_at"] == t1 and kwargs["read_at"] is None


# ── The log says what happened, and never holds a token ──────────────────────

@pytest.mark.asyncio
async def test_a_receipt_is_logged_from_token_to_watermark(client, caplog):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "logged-phone")
    t1 = _at(1)
    m1 = await _message(buyer, "buyer", buyer, t1, listing_id=listing_id)
    token = _token(seller, "seller", buyer, "logged-phone", listing_id=listing_id)
    with caplog.at_level(logging.INFO, logger="api.routers.negotiate"):
        assert (await _ack(client, token, m1)).status_code == 200
        assert (await _ack(client, token, m1)).status_code == 200
    lines = [r.getMessage() for r in caplog.records if r.name == "api.routers.negotiate"]
    updated = [line for line in lines if "DELIVERY_WATERMARK_UPDATED" in line]
    assert len(updated) == 1, "the duplicate moved nothing"
    assert f"thread={listing_id}:{buyer}" in updated[0]
    assert "role=seller" in updated[0] and f"user={seller}" in updated[0]
    assert f"message={m1}" in updated[0]
    assert "from=-" in updated[0] and f"to={t1.isoformat()}Z" in updated[0]
    acks = [line for line in lines if "DELIVERY_ACK_SUCCESS" in line]
    assert len(acks) == 2
    assert "advanced=True" in acks[0] and "advanced=False" in acks[1]
    assert f"device={push_devices.token_fingerprint('logged-phone')}" in acks[0]
    assert token not in caplog.text
    assert "logged-phone" not in caplog.text, "the push token is a credential too"


@pytest.mark.asyncio
async def test_a_refused_receipt_says_why_and_never_holds_the_token(client, caplog):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "shared-phone")
    m1 = await _message(buyer, "buyer", buyer, _at(1), listing_id=listing_id)
    expired = jwt.encode({
        "sub": seller, "type": "thread", "role": "seller", "bid": buyer,
        "lid": listing_id, "sid": None,
        "dev": push_devices.token_fingerprint("shared-phone"),
        "exp": datetime.now(timezone.utc) - timedelta(hours=1),
    }, SECRET_KEY, algorithm=ALGORITHM)
    forged = jwt.encode({
        "sub": seller, "type": "thread", "role": "seller", "bid": buyer,
        "lid": listing_id, "sid": None, "dev": "0123456789",
        "exp": datetime.now(timezone.utc) + timedelta(hours=1),
    }, "not-the-server-key", algorithm=ALGORITHM)
    valid = _token(seller, "seller", buyer, "shared-phone", listing_id=listing_id)
    with caplog.at_level(logging.INFO, logger="api.routers.negotiate"):
        assert (await _ack(client, expired, m1)).status_code == 401
        assert (await _ack(client, forged, m1)).status_code == 401
        # Another BROKA account signs in on the same phone: the token moves.
        _, other, _ = await _people()
        await _register(client, other, "shared-phone")
        assert (await _ack(client, valid, m1)).status_code == 401
    failed = [r.getMessage() for r in caplog.records if "DELIVERY_ACK_FAILED" in r.getMessage()]
    assert len(failed) == 3
    assert "reason=token_expired" in failed[0] and f"user={seller}" in failed[0]
    assert f"thread={listing_id}:{buyer}" in failed[0]
    assert "reason=token_invalid" in failed[1] and seller not in failed[1], (
        "a forged token's claims are whatever its maker wrote")
    assert "reason=device_signed_out" in failed[2] and "status=401" in failed[2]
    for token in (expired, forged, valid):
        assert token not in caplog.text
    # The first account's conversation was not marked delivered by any of it.
    assert await _watermarks(buyer, "seller", listing_id=listing_id) == (None, None)
