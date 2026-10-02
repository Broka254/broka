"""Direct chat: one bubble per message, ticks that move, missed calls that
tell someone (2026-10-02).

Reported from a phone: the last two messages showed twice for a while, the
buyer had read a message and the seller's screen still showed one grey
tick, and a missed call produced no notification.

  * POST /negotiate/direct-message answered {"ok": true} and nothing else,
    so the app could not tell the server's copy of a message from the one
    it was already showing - and the chat socket closed itself after a
    minute of quiet, leaving the app on a poll that raced its own send.
  * A seller whose app named no buyer had no receipts at all (read-status
    answered "no thread"), no socket (refused with 4003), and their
    messages were stored with buyer_id NULL - which every buyer on the
    listing is shown.
  * Nothing pushed a missed call; the only notice was the app's own poller,
    alive only while the app is.
"""
import asyncio
import json
import uuid
from datetime import datetime
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core import call_state
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_delivery.db"
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


async def _people(n_buyers: int = 1):
    """A seller, their listing, and [n_buyers] buyers."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None, client_msg_id=None):
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    if client_msg_id:
        body["client_msg_id"] = client_msg_id
    return await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))


# ── One bubble per message ────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_direct_message_comes_back_as_stored(client):
    listing_id, _, [buyer] = await _people()
    r = await _direct(client, buyer, "buyer", listing_id, "Yooh", client_msg_id="local-1")
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    assert msg["id"] and msg["created_at"].endswith("Z")
    assert msg["content"] == "Yooh" and msg["role"] == "buyer"
    assert msg["client_msg_id"] == "local-1"


@pytest.mark.asyncio
async def test_a_resend_of_the_same_message_is_stored_once(client):
    """The first attempt arrived but its answer was lost to a timeout; the
    app sends it again under the same id."""
    listing_id, _, [buyer] = await _people()
    first = await _direct(client, buyer, "buyer", listing_id, "Yooh", client_msg_id="local-2")
    again = await _direct(client, buyer, "buyer", listing_id, "Yooh", client_msg_id="local-2")
    assert again.status_code == 200
    assert again.json()["message"]["id"] == first.json()["message"]["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id))).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_the_same_words_twice_are_two_messages(client):
    """Two "Yooh"s in a row are two messages - they only share text."""
    listing_id, _, [buyer] = await _people()
    a = await _direct(client, buyer, "buyer", listing_id, "Yooh", client_msg_id="local-a")
    b = await _direct(client, buyer, "buyer", listing_id, "Yooh", client_msg_id="local-b")
    assert a.json()["message"]["id"] != b.json()["message"]["id"]


@pytest.mark.asyncio
async def test_history_carries_the_client_id_on_my_own_messages_only(client):
    listing_id, seller, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi", client_msg_id="local-h")
    mine = (await client.get(f"/negotiate/{listing_id}/history", headers=_auth(buyer))).json()
    assert [m["client_msg_id"] for m in mine] == ["local-h"]
    theirs = (await client.get(f"/negotiate/{listing_id}/history",
                               params={"buyer_id": buyer}, headers=_auth(seller))).json()
    assert [m["client_msg_id"] for m in theirs] == [None]


# ── A seller whose app named no buyer ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_sellers_reply_without_a_buyer_goes_to_the_thread_they_see(client):
    listing_id, seller, [first, latest] = await _people(2)
    await _direct(client, first, "buyer", listing_id, "is it available?")
    await _direct(client, latest, "buyer", listing_id, "still there?")

    r = await _direct(client, seller, "seller", listing_id, "yes it is")
    assert r.status_code == 200, r.text
    async with AsyncSessionLocal() as db:
        reply = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == r.json()["message"]["id"]))).scalar_one()
    # Not NULL: a NULL row shows in every buyer's thread.
    assert reply.buyer_id == latest

    other = (await client.get(f"/negotiate/{listing_id}/history", headers=_auth(first))).json()
    assert "yes it is" not in [m["content"] for m in other]


@pytest.mark.asyncio
async def test_a_seller_without_any_buyer_cannot_post_into_nowhere(client):
    listing_id, seller, _ = await _people(0)
    r = await _direct(client, seller, "seller", listing_id, "hello?")
    assert r.status_code == 400


@pytest.mark.asyncio
async def test_a_seller_without_a_buyer_still_sees_seen_ticks(client):
    listing_id, seller, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")
    await _direct(client, seller, "seller", listing_id, "hello", buyer_id=buyer)
    r = await client.post(f"/negotiate/{listing_id}/mark-read", json={}, headers=_auth(buyer))
    assert r.status_code == 200

    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(seller))).json()
    assert status["buyer_last_read"] is not None
    assert status["buyer_last_delivered"] is not None


# ── Receipts reach the open chat ──────────────────────────────────────────────

@pytest.mark.asyncio
async def test_reading_a_thread_tells_the_other_sides_open_chat(client):
    listing_id, seller, [buyer] = await _people()
    await _direct(client, seller, "seller", listing_id, "hello", buyer_id=buyer)
    with patch("api.routers.media.broadcast_receipt", new=AsyncMock()) as announce:
        r = await client.post(f"/negotiate/{listing_id}/mark-read", json={}, headers=_auth(buyer))
    assert r.status_code == 200
    announce.assert_awaited_once()
    args, kwargs = announce.call_args
    assert args == (listing_id, buyer, "buyer")
    assert kwargs["exclude_uid"] == buyer
    assert kwargs["read_at"] is not None and kwargs["delivered_at"] is not None


@pytest.mark.asyncio
async def test_a_receipt_is_sent_to_the_thread_but_not_back_to_its_owner():
    from api.routers import media

    class _Sock:
        def __init__(self):
            self.sent = []

        async def send_json(self, payload):
            self.sent.append(payload)

    seller_sock, buyer_sock = _Sock(), _Sock()
    key = media._thread_key("L1", "B1")
    media._thread_connections[key] = {seller_sock: "S1", buyer_sock: "B1"}
    try:
        now = datetime.utcnow()
        await media.broadcast_receipt("L1", "B1", "buyer", exclude_uid="B1",
                                      delivered_at=now, read_at=now)
    finally:
        media._thread_connections.pop(key, None)
    assert buyer_sock.sent == []
    assert seller_sock.sent == [{
        "type": "receipt", "role": "buyer",
        "last_delivered": now.isoformat() + "Z", "last_read": now.isoformat() + "Z",
    }]


# ── The chat socket stays open ────────────────────────────────────────────────

class _FakeSocket:
    """Enough of a Starlette WebSocket for negotiate_ws."""

    def __init__(self):
        self.sent = []
        self.closed = None
        self.inbox: asyncio.Queue = asyncio.Queue()

    async def accept(self):
        pass

    async def send_json(self, payload):
        if self.closed is not None:
            raise RuntimeError("closed")
        self.sent.append(payload)

    async def receive_text(self):
        item = await self.inbox.get()
        if isinstance(item, BaseException):
            raise item
        return item

    async def close(self, code=1000, reason=""):
        self.closed = code
        await self.inbox.put(WebSocketDisconnect(code))


async def _open_socket(listing_id, uid, buyer_id=None):
    from api.routers import media
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    task = asyncio.create_task(media.negotiate_ws(
        listing_id, sock, token=create_access_token({"sub": uid}), buyer_id=buyer_id, db=db))
    return sock, task, db


@pytest.mark.asyncio
async def test_a_quiet_chat_socket_is_kept_alive_not_closed(client, monkeypatch):
    """It used to close itself after 60s in which nobody typed."""
    from api.routers import media
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 0.02, raising=False)
    monkeypatch.setattr(media, "CHAT_WS_STALE_SECONDS", 60, raising=False)
    listing_id, _, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")

    sock, task, db = await _open_socket(listing_id, buyer)
    try:
        await asyncio.sleep(0.3)
        assert not task.done(), "the socket closed itself while idle"
        assert sum(1 for p in sock.sent if p.get("type") == "ping") >= 2
        await sock.inbox.put(json.dumps({"type": "ping"}))
        await asyncio.sleep(0.05)
        assert {"type": "pong"} in sock.sent
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()
    assert media._thread_key(listing_id, buyer) not in media._thread_connections


@pytest.mark.asyncio
async def test_a_silent_socket_is_closed(client, monkeypatch):
    from api.routers import media
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 0.02, raising=False)
    monkeypatch.setattr(media, "CHAT_WS_STALE_SECONDS", 0.1, raising=False)
    listing_id, _, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")
    sock, task, db = await _open_socket(listing_id, buyer)
    try:
        await asyncio.wait_for(task, 2)
    finally:
        await db.close()
    assert sock.closed == 4000


@pytest.mark.asyncio
async def test_a_seller_socket_without_a_buyer_joins_the_thread_they_see(client, monkeypatch):
    from api.routers import media
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    listing_id, seller, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")
    sock, task, db = await _open_socket(listing_id, seller)
    try:
        await asyncio.sleep(0.1)
        assert sock.closed is None
        assert media._thread_key(listing_id, buyer) in media._thread_connections
        assert [p["content"] for p in sock.sent if p.get("type") == "message"] == ["hi"]
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()


# ── Inbox: which message is the last one ──────────────────────────────────────

@pytest.mark.asyncio
async def test_two_identical_messages_have_different_inbox_signatures(client):
    listing_id, seller, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "ok")
    first = (await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))).json()
    await _direct(client, buyer, "buyer", listing_id, "ok")
    second = (await client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller))).json()
    t1 = next(t for t in first if t["listing_id"] == listing_id)
    t2 = next(t for t in second if t["listing_id"] == listing_id)
    assert t1["last_message"] == t2["last_message"] == "ok"
    assert t1["last_message_id"] != t2["last_message_id"]
    assert t2["last_message_at"].endswith("Z")


# ── Missed calls are pushed ───────────────────────────────────────────────────

async def _call(listing_id, caller, callee, call_type="audio"):
    room_id = f"room-{uuid.uuid4().hex[:10]}"
    await call_state.create_session(
        room_id=room_id, caller_id=caller, callee_id=callee, listing_id=listing_id,
        call_type=call_type, caller_name="Buyer 0",
    )
    return room_id


async def _give_token(uid, token="fcm-token-callee"):
    async with AsyncSessionLocal() as db:
        user = (await db.execute(select(User).where(User.id == uid))).scalar_one()
        user.fcm_token = token
        await db.commit()


@pytest.mark.asyncio
@pytest.mark.parametrize("outcome", ["cancelled", "missed"])
async def test_a_missed_call_is_pushed_to_the_callee(client, outcome):
    listing_id, seller, [buyer] = await _people()
    await _give_token(seller)
    room_id = await _call(listing_id, caller=buyer, callee=seller, call_type="video")
    with patch("api.routers.calls._send_fcm", new=AsyncMock(return_value=True)) as push:
        r = await client.post("/calls/log-result", headers=_auth(buyer), json={
            "room_id": room_id, "outcome": outcome})
    assert r.status_code == 200, r.text
    push.assert_awaited_once()
    kwargs = push.call_args.kwargs
    assert kwargs["token"] == "fcm-token-callee"
    assert kwargs["title"] == "Missed video call from Buyer 0"
    assert kwargs["data"]["type"] == "missed_call"
    assert kwargs["data"]["roomId"] == room_id
    assert kwargs["data"]["listingId"] == listing_id
    assert kwargs["data"]["buyerId"] == buyer
    assert kwargs["data"]["myRole"] == "seller"
    # A visible notification - shown by the phone with the app closed -
    # under the tag the app's own missed-call notification uses.
    assert not kwargs.get("data_only")
    assert kwargs["android_tag"] == f"missed_{listing_id}_{buyer}"
    assert kwargs["android_channel_id"] == "broka_messages"


@pytest.mark.asyncio
@pytest.mark.parametrize("outcome", ["completed", "declined"])
async def test_a_call_that_was_answered_or_declined_is_not_announced(client, outcome):
    listing_id, seller, [buyer] = await _people()
    await _give_token(seller)
    room_id = await _call(listing_id, caller=buyer, callee=seller)
    with patch("api.routers.calls._send_fcm", new=AsyncMock(return_value=True)) as push:
        r = await client.post("/calls/log-result", headers=_auth(seller), json={
            "room_id": room_id, "outcome": outcome})
    assert r.status_code == 200, r.text
    push.assert_not_awaited()


@pytest.mark.asyncio
async def test_a_seller_calling_a_buyer_tells_the_buyer_they_missed_it(client):
    listing_id, seller, [buyer] = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")
    await _give_token(buyer, "fcm-token-buyer")
    room_id = await _call(listing_id, caller=seller, callee=buyer)
    with patch("api.routers.calls._send_fcm", new=AsyncMock(return_value=True)) as push:
        r = await client.post("/calls/log-result", headers=_auth(seller), json={
            "room_id": room_id, "outcome": "cancelled"})
    assert r.status_code == 200, r.text
    kwargs = push.call_args.kwargs
    assert kwargs["token"] == "fcm-token-buyer"
    assert kwargs["data"]["myRole"] == "buyer"
    assert kwargs["data"]["buyerId"] == buyer
