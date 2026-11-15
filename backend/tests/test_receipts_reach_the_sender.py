"""Sent, Delivered, Seen - on the sender's screen too (2026-11-15).

Reported: a message sent to someone offline went from Sent straight to
Seen, never showing Delivered - though Railway's log had MESSAGE_DELIVERED
for it when the recipient's phone synced. The server recorded the delivery;
the sender's phone was not told:

  * A receipt is announced once, the moment a watermark moves, to the chat
    sockets of the process that moved it. Railway runs the API as two
    replicas: an acknowledgement handled by one never reached a sender whose
    socket the other held. Chat frames now go through a Redis relay
    (api/core/chat_relay.py) to every replica's sockets.
  * A socket that connects (or comes back after a drop) was sent the
    thread's messages and none of its ticks; it now gets the other side's
    receipts as they stand, before the replay.
  * Opening a chat socket moved the connecting side's delivered watermark to
    "now" - before a single message had gone down it, and with no record of
    which messages. It no longer counts as a delivery.
  * mark-read read the thread "up to now", including whatever reached the
    server after the reader's screen last loaded - a message the phone had
    never been sent became Seen. It now reads up to the message the app
    names (`up_to_message_id`, the newest of the other side's on screen).
"""
import asyncio
import io
import logging
import uuid
from datetime import datetime
from unittest.mock import patch

import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.core import chat_relay, message_delivery, message_push
from api.database import (
    AsyncSessionLocal, Listing, ThreadReadState, User, init_db, reset_engine,
)
from api.models.message_delivery import MessageDelivery
from api.models.store import Store
from api.routers import calls, media
from api.security import create_access_token
from main import app

LOGGER = "api.core.message_delivery"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_receipts_reach_the_sender.db"
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
    """Every push a test started finishes inside it (test_offline_delivery)."""
    yield
    loop = asyncio.get_running_loop()
    while True:
        pending = [t for t in list(message_push._inflight)
                   if t.get_loop() is loop and not t.done()]
        if not pending:
            return
        await asyncio.gather(*pending, return_exceptions=True)


class _OtherReplica:
    """The chat sockets another API process holds: what reaches them."""

    def __init__(self):
        self.received: list[tuple] = []

    async def deliver(self, key, frame, exclude):
        self.received.append((key, frame, exclude))

    def frames(self, key, kind=None):
        return [f for k, f, _ in self.received
                if k == key and (kind is None or f.get("type") == kind)]

    def excluded(self, key, kind):
        return {e for k, f, e in self.received if k == key and f.get("type") == kind}


@pytest.fixture
def other_replica(monkeypatch):
    """This process and another, sharing one Pub/Sub bus - Railway's two
    replicas sharing Redis."""
    bus = chat_relay.MemoryBus()
    here = chat_relay.ChatRelay(instance_id=f"here-{uuid.uuid4().hex[:6]}", bus=bus)
    there = chat_relay.ChatRelay(instance_id=f"there-{uuid.uuid4().hex[:6]}", bus=bus)
    here.set_deliver(media._broadcast_local)
    remote = _OtherReplica()
    there.set_deliver(remote.deliver)
    here.ensure_listening()
    there.ensure_listening()
    monkeypatch.setattr(chat_relay, "relay", here)
    return remote


class FakeFcm:
    """Firebase as configured: every push accepted, with a message id."""

    def __init__(self):
        self.sent: list[dict] = []

    async def __call__(self, **kwargs):
        self.sent.append(kwargs)
        return calls.FcmResult(True, message_id=f"projects/broka/messages/{len(self.sent)}")

    def message_pushes(self) -> list[dict]:
        return [p for p in self.sent if p["data"].get("type") == "new_message"]


@pytest_asyncio.fixture
async def fcm():
    fake = FakeFcm()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=fake), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield fake
        await message_push.drain()
    message_push._last_pushed.clear()


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _people():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _store_people():
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        return store.id, owner.id, buyer.id


async def _register(client, uid) -> str:
    phone = f"tok-{uuid.uuid4().hex}"
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": phone, "token_type": "fcm", "platform": "android"})
    assert r.status_code == 200, r.text
    await message_push.drain()
    return phone


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None) -> dict:
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


async def _store_direct(client, store_id, sender_id, role, content, buyer_id=None) -> dict:
    body = {"store_id": store_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


def _photo() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (40, 120, 200)).save(buf, "JPEG")
    return buf.getvalue()


async def _upload_photo(client, store_id, sender, role) -> dict:
    r = await client.post("/media/upload", headers=_auth(sender), data={
        "store_id": store_id, "sender_role": role, "sender_id": sender,
        "content_type": "image"}, files={"file": ("image.jpg", _photo(), "image/jpeg")})
    assert r.status_code == 200, r.text
    return r.json()


async def _sync(client, uid) -> dict:
    r = await client.get("/negotiate/sync", params={"trigger": "connectivity_restored"},
                         headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _ack(client, uid, ids, source="sync") -> dict:
    r = await client.post("/negotiate/sync/ack", json={"message_ids": ids, "source": source},
                          headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _status(message_id: str) -> str:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(MessageDelivery.status).where(
            MessageDelivery.message_id == message_id))).scalars().all()
    assert len(rows) == 1, rows
    return rows[0]


async def _marks(*, listing_id=None, store_id=None, buyer_id, role):
    """(last_delivered_at, last_read_at) of one side's watermark row."""
    where = (ThreadReadState.store_id == store_id) if store_id \
        else (ThreadReadState.listing_id == listing_id)
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(ThreadReadState).where(
            where, ThreadReadState.buyer_id == buyer_id,
            ThreadReadState.role == role))).scalar_one_or_none()
    if row is None:
        return None, None
    read = row.last_read_at if row.last_read_at and row.last_read_at.year > 1970 else None
    return row.last_delivered_at, read


def _created(message: dict) -> datetime:
    return datetime.fromisoformat(message["created_at"].rstrip("Z"))


class _FakeSocket:
    """Enough of a Starlette WebSocket for the chat sockets."""

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

    def of(self, kind):
        return [p for p in self.sent if p.get("type") == kind]


async def _open_socket(uid, *, listing_id=None, store_id=None, buyer_id=None):
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    token = create_access_token({"sub": uid})
    if store_id:
        task = asyncio.create_task(media.store_ws(
            store_id, sock, token=token, buyer_id=buyer_id, since=None, db=db))
    else:
        task = asyncio.create_task(media.negotiate_ws(
            listing_id, sock, token=token, buyer_id=buyer_id, since=None, db=db))
    return sock, task, db


async def _close_socket(sock, task, db):
    await sock.inbox.put(WebSocketDisconnect(1000))
    await asyncio.wait_for(task, 2)
    await db.close()


async def _until(check, timeout=2.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while not check():
        if loop.time() > end:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.01)


# ── The reported lifecycle: offline, back, read later ──────────────────────

@pytest.mark.asyncio
async def test_an_offline_message_shows_delivered_on_a_sender_held_by_the_other_replica(
        client, fcm, other_replica):
    """The buyer's chat socket is on the other replica; the seller's phone,
    back from being offline, syncs through this one."""
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    key = media._thread_key(listing_id, buyer_id)
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Sent while you were away")
    await message_push.drain()

    # FCM took the push for the offline phone: still undelivered, and no
    # tick moved for it - accepted is not delivered.
    assert await _status(msg["id"]) == "PUSH_ACCEPTED"
    assert other_replica.frames(key, "receipt") == []
    assert await _marks(listing_id=listing_id, buyer_id=buyer_id, role="seller") == (None, None)

    # Back online: the sync hands it out, the app stores it and says so.
    synced = await _sync(client, seller_id)
    assert msg["id"] in [m["id"] for m in synced["messages"]]
    assert other_replica.frames(key, "receipt") == [], "handed out is not delivered"
    await _ack(client, seller_id, [msg["id"]])

    [delivered] = other_replica.frames(key, "receipt")
    assert delivered["role"] == "seller"
    assert delivered["last_delivered"] == msg["created_at"]
    assert delivered["last_read"] is None, "Delivered - not Seen"
    assert delivered["message_ids"] == [msg["id"]]
    assert delivered["up_to_message_id"] == msg["id"]
    assert other_replica.excluded(key, "receipt") == {seller_id}, (
        "never sent back to the side whose ticks these are")

    # Later they open the chat, with the message on screen.
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": msg["id"]})
    assert r.status_code == 200, r.text
    receipts = other_replica.frames(key, "receipt")
    assert [(f["last_read"] is None) for f in receipts] == [True, False], (
        "Sent, then Delivered, then Seen - in that order")
    assert receipts[-1]["last_read"] == msg["created_at"]
    assert await _status(msg["id"]) == "READ"


@pytest.mark.asyncio
async def test_a_push_receipt_reaches_the_other_replica_too(client, fcm, other_replica):
    """The phone's push handler posts its receipt from a closed app."""
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Is it still there?")
    await message_push.drain()
    push = fcm.message_pushes()[-1]
    r = await client.post("/negotiate/notification/delivered", json={
        "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
    assert r.status_code == 200, r.text
    [receipt] = other_replica.frames(media._thread_key(listing_id, buyer_id), "receipt")
    assert (receipt["last_delivered"], receipt["last_read"]) == (msg["created_at"], None)
    assert receipt["message_ids"] == [msg["id"]]


@pytest.mark.asyncio
async def test_messages_delivered_together_move_the_tick_once_and_name_them_all(
        client, other_replica):
    listing_id, seller_id, buyer_id = await _people()
    sent = [await _direct(client, buyer_id, "buyer", listing_id, f"message {i}")
            for i in range(3)]
    await _ack(client, seller_id, [m["id"] for m in sent])
    [receipt] = other_replica.frames(media._thread_key(listing_id, buyer_id), "receipt")
    assert receipt["last_delivered"] == sent[-1]["created_at"], "up to the newest, no further"
    assert sorted(receipt["message_ids"]) == sorted(m["id"] for m in sent)
    assert receipt["up_to_message_id"] == sent[-1]["id"]


@pytest.mark.asyncio
async def test_a_second_phone_acknowledging_the_same_message_changes_nothing(
        client, other_replica):
    """The recipient on two phones: the second acknowledgement is not a
    second delivery, and no tick moves back or forward for it."""
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Two phones")
    first = await _ack(client, seller_id, [msg["id"]])
    again = await _ack(client, seller_id, [msg["id"]], source="chat")
    assert first["delivered"] == [msg["id"]]
    assert again["already_delivered"] == [msg["id"]]
    assert len(other_replica.frames(media._thread_key(listing_id, buyer_id), "receipt")) == 1
    delivered, _ = await _marks(listing_id=listing_id, buyer_id=buyer_id, role="seller")
    assert delivered == _created(msg)


@pytest.mark.asyncio
async def test_a_store_chats_photo_climbs_the_same_ladder(client, other_replica):
    store_id, owner_id, buyer_id = await _store_people()
    photo = await _upload_photo(client, store_id, buyer_id, "buyer")
    key = media._store_thread_key(store_id, buyer_id)
    await _ack(client, owner_id, [photo["id"]])
    [delivered] = other_replica.frames(key, "receipt")
    assert (delivered["role"], delivered["last_read"]) == ("seller", None)
    assert delivered["message_ids"] == [photo["id"]]

    r = await client.post(f"/negotiate/store/{store_id}/mark-read", headers=_auth(owner_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": photo["id"]})
    assert r.status_code == 200, r.text
    read = other_replica.frames(key, "receipt")[-1]
    assert read["last_read"] == photo["created_at"]
    assert await _status(photo["id"]) == "READ"


# ── What a connecting socket is told ────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_socket_that_connects_is_told_the_other_sides_ticks(client, monkeypatch):
    """The receipt went out while this socket was away - reconnecting, or on
    another replica. Connecting, it hears where the ticks stand."""
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Bado iko?")
    await _ack(client, seller_id, [msg["id"]])

    sock, task, db = await _open_socket(buyer_id, listing_id=listing_id)
    try:
        await _until(lambda: sock.of("receipt") and sock.of("message"))
        assert sock.of("receipt") == [{
            "type": "receipt", "role": "seller",
            "last_delivered": msg["created_at"], "last_read": None,
        }]
        assert sock.sent.index(sock.of("receipt")[0]) < sock.sent.index(sock.of("message")[0]), (
            "before the replay: the replayed bubbles render with their ticks")
    finally:
        await _close_socket(sock, task, db)


@pytest.mark.asyncio
async def test_a_store_socket_that_connects_is_told_too(client, monkeypatch):
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    store_id, owner_id, buyer_id = await _store_people()
    msg = await _store_direct(client, store_id, buyer_id, "buyer", "Mnafunga saa ngapi?")
    r = await client.post(f"/negotiate/store/{store_id}/mark-read", headers=_auth(owner_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": msg["id"]})
    assert r.status_code == 200, r.text

    sock, task, db = await _open_socket(buyer_id, store_id=store_id)
    try:
        await _until(lambda: bool(sock.of("receipt")))
        [receipt] = sock.of("receipt")
        assert receipt["role"] == "seller"
        assert receipt["last_read"] == msg["created_at"]
        assert receipt["last_delivered"] == msg["created_at"]
    finally:
        await _close_socket(sock, task, db)


@pytest.mark.asyncio
async def test_opening_a_chat_socket_is_not_a_delivery(client, monkeypatch):
    """It used to move the connecting side's delivered watermark to now,
    before a message had gone down the socket - the sender saw Delivered
    for messages that phone was never shown to have."""
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Uko?")
    with patch("api.routers.media.broadcast_receipt") as announce:
        sock, task, db = await _open_socket(seller_id, listing_id=listing_id, buyer_id=buyer_id)
        try:
            await _until(lambda: bool(sock.of("message")))
            await asyncio.sleep(0.05)
        finally:
            await _close_socket(sock, task, db)
    announce.assert_not_called()
    assert await _marks(listing_id=listing_id, buyer_id=buyer_id, role="seller") == (None, None)
    assert await _status(msg["id"]) == "SAVED"
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(buyer_id))).json()
    assert status["seller_last_delivered"] is None


@pytest.mark.asyncio
async def test_a_store_socket_connecting_is_not_a_delivery_either(client, monkeypatch):
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    store_id, owner_id, buyer_id = await _store_people()
    await _store_direct(client, store_id, buyer_id, "buyer", "Hello")
    sock, task, db = await _open_socket(owner_id, store_id=store_id, buyer_id=buyer_id)
    try:
        await _until(lambda: bool(sock.of("message")))
    finally:
        await _close_socket(sock, task, db)
    assert await _marks(store_id=store_id, buyer_id=buyer_id, role="seller") == (None, None)


# ── A read covers what was on screen ────────────────────────────────────────

@pytest.mark.asyncio
async def test_mark_read_reads_up_to_the_message_on_screen_not_up_to_now(client):
    listing_id, seller_id, buyer_id = await _people()
    shown = await _direct(client, buyer_id, "buyer", listing_id, "Seen on the seller's screen")
    # Reaches the server after the seller's screen loaded - their phone does
    # not have it (its socket frame lost, the poll idle).
    unseen = await _direct(client, buyer_id, "buyer", listing_id, "Not on their phone yet")

    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": shown["id"]})
    assert r.status_code == 200, r.text
    assert r.json()["up_to_message_id"] == shown["id"]
    assert await _status(shown["id"]) == "READ"
    assert await _status(unseen["id"]) == "SAVED", "never read, nor delivered by the read"
    delivered, read = await _marks(listing_id=listing_id, buyer_id=buyer_id, role="seller")
    assert read == _created(shown) and delivered == _created(shown)
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               headers=_auth(buyer_id))).json()
    assert status["seller_last_read"] == shown["created_at"]

    # The phone gets the second message and shows it: read now, and the
    # watermarks only ever move forward.
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": unseen["id"]})
    assert r.status_code == 200
    assert await _status(unseen["id"]) == "READ"
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": shown["id"]})
    assert r.status_code == 200
    _, read = await _marks(listing_id=listing_id, buyer_id=buyer_id, role="seller")
    assert read == _created(unseen), "an older read takes nothing back"


@pytest.mark.asyncio
async def test_a_read_bound_that_is_not_theirs_to_read_is_refused(client):
    listing_id, seller_id, buyer_id = await _people()
    theirs = await _direct(client, buyer_id, "buyer", listing_id, "From the buyer")
    mine = await _direct(client, seller_id, "seller", listing_id, "From the seller",
                         buyer_id=buyer_id)
    other_listing, _, other_buyer = await _people()
    elsewhere = await _direct(client, other_buyer, "buyer", other_listing, "Another chat")
    for bound in (mine["id"], elsewhere["id"], "no-such-message"):
        r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                              json={"buyer_id": buyer_id, "up_to_message_id": bound})
        assert r.status_code == 404, (bound, r.text)
    assert await _status(theirs["id"]) == "SAVED", "a bad bound reads nothing at all"


@pytest.mark.asyncio
async def test_an_older_app_without_a_bound_still_reads_up_to_now(client):
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Old build")
    r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id})
    assert r.status_code == 200
    assert r.json().get("up_to_message_id") is None
    assert await _status(msg["id"]) == "READ"


@pytest.mark.asyncio
async def test_a_store_read_is_bounded_too(client):
    store_id, owner_id, buyer_id = await _store_people()
    shown = await _store_direct(client, store_id, buyer_id, "buyer", "Shown")
    unseen = await _store_direct(client, store_id, buyer_id, "buyer", "Not yet")
    r = await client.post(f"/negotiate/store/{store_id}/mark-read", headers=_auth(owner_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": shown["id"]})
    assert r.status_code == 200, r.text
    assert await _status(shown["id"]) == "READ"
    assert await _status(unseen["id"]) == "SAVED"


@pytest.mark.asyncio
async def test_mark_as_read_on_a_notification_reads_what_it_showed(client, fcm):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    msg = await _direct(client, buyer_id, "buyer", listing_id, "On the notification")
    await message_push.drain()
    push = fcm.message_pushes()[-1]
    later = await _direct(client, buyer_id, "buyer", listing_id, "Arrived after it was drawn")
    r = await client.post("/negotiate/notification/read", json={
        "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
    assert r.status_code == 200, r.text
    assert await _status(msg["id"]) == "READ"
    assert await _status(later["id"]) != "READ"


# ── The relay ────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_relay_never_echoes_and_keeps_huge_frames_at_home():
    bus = chat_relay.MemoryBus()
    got = {"a": [], "b": []}
    a = chat_relay.ChatRelay(instance_id="a", bus=bus)
    b = chat_relay.ChatRelay(instance_id="b", bus=bus)

    def into(name):
        async def deliver(key, frame, exclude):
            got[name].append((key, frame, exclude))
        return deliver

    a.set_deliver(into("a"))
    b.set_deliver(into("b"))
    a.ensure_listening()
    b.ensure_listening()
    assert await a.publish("L1:B1", {"type": "receipt", "role": "seller"}, "S1") is True
    assert got["a"] == [], "the publishing process delivered it already"
    assert got["b"] == [("L1:B1", {"type": "receipt", "role": "seller"}, "S1")]

    huge = {"type": "message", "media_url": "x" * (chat_relay.MAX_FRAME_BYTES + 1)}
    assert await a.publish("L1:B1", huge) is False
    assert len(got["b"]) == 1


@pytest.mark.asyncio
async def test_a_dead_relay_never_costs_the_local_sockets_their_frame(monkeypatch):
    class _Sock:
        def __init__(self):
            self.sent = []

        async def send_json(self, payload):
            self.sent.append(payload)

    relay = chat_relay.ChatRelay(instance_id="lonely", redis_url="redis://127.0.0.1:1/0")
    monkeypatch.setattr(chat_relay, "relay", relay)
    sock = _Sock()
    key = media._thread_key("L-relay", "B-relay")
    media._thread_connections[key] = {sock: "S1"}
    try:
        # Nothing listens on that port: the publish fails, quietly.
        await asyncio.wait_for(media._broadcast(key, {"type": "receipt"}), 5)
    finally:
        media._thread_connections.pop(key, None)
    assert sock.sent == [{"type": "receipt"}]


# ── The log ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_every_lifecycle_line_names_its_message_and_where_it_came_from(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    words = f"secret words {uuid.uuid4().hex[:6]}"
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, words)
        await message_push.drain()
        await _sync(client, seller_id)
        await _ack(client, seller_id, [msg["id"]])
        await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller_id),
                          json={"buyer_id": buyer_id, "up_to_message_id": msg["id"]})

    def line(event):
        return next(r.getMessage() for r in caplog.records
                    if r.name == LOGGER and r.getMessage().startswith(event + " ")
                    and f"message_id={msg['id']} " in r.getMessage() + " ")

    for event, source in (("MESSAGE_SAVED", "direct_message"),
                          ("MESSAGE_PUSH_ACCEPTED", "fcm"),
                          ("MESSAGE_DELIVERY_ACK_RECEIVED", "sync"),
                          ("MESSAGE_DELIVERED", "sync"),
                          ("MESSAGE_READ", "chat_open")):
        text = line(event)
        for field in (f"correlation_id={msg['id']}", "timestamp=", f"source={source}",
                      f"recipient_id={seller_id}"):
            assert field in text, f"{field} missing from {text!r}"
    assert words not in caplog.text


@pytest.mark.asyncio
async def test_a_photos_saved_line_says_it_was_uploaded(client, caplog):
    store_id, _, buyer_id = await _store_people()
    with caplog.at_level(logging.INFO, logger=LOGGER):
        photo = await _upload_photo(client, store_id, buyer_id, "buyer")
    saved = next(r.getMessage() for r in caplog.records
                 if r.name == LOGGER and r.getMessage().startswith("MESSAGE_SAVED ")
                 and photo["id"] in r.getMessage())
    assert "source=media_upload" in saved and "kind=image" in saved
