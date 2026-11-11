"""Messages that take long to reach the other person, photos sent together,
and a "Ringing" the caller never saw (2026-11-11).

Reported: "a sent message takes long before reaching the other person".
On the server, three things stood between a message and the other phone:

  * Every open chat socket held a pooled database connection for as long
    as the chat stayed on screen (its session sat in a transaction after the
    history replay). Thirty open chats and every request - a sent message
    included - queued for a connection.
  * A broadcast wrote to the thread's sockets one after another with no time
    limit, and the sender's request waited for it: one dead socket held the
    message back from everyone else and kept the sender on "Sending".
  * Every connect replayed the last fifty messages, photos as base64 -
    megabytes on mobile data, ahead of anything new.

Also here: photos sent together keep the album they were sent in, the
caller is told the other phone is ringing even when a socket's write raced
the acknowledgement, and a first delivered receipt written twice at once no
longer fails.
"""
import asyncio
import io
import json
import uuid
from unittest.mock import patch

import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.core import call_state, message_push
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.routers import calls, media
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_socket_and_albums.db"
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
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None):
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


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


async def _until(check, timeout=2.0):
    loop = asyncio.get_running_loop()
    end = loop.time() + timeout
    while not check():
        if loop.time() > end:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.01)


def _messages(sock):
    return [p for p in sock.sent if p.get("type") == "message"]


# ── The chat socket ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_an_open_chat_holds_no_database_connection_while_it_waits(client, monkeypatch):
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    listing_id, _, buyer = await _people()
    await _direct(client, buyer, "buyer", listing_id, "hi")
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    task = asyncio.create_task(media.negotiate_ws(
        listing_id, sock, token=create_access_token({"sub": buyer}), buyer_id=None, db=db))
    try:
        await _until(lambda: len(_messages(sock)) == 1)
        await asyncio.sleep(0.05)
        assert not task.done()
        assert not db.in_transaction(), (
            "the socket's session is still in a transaction - it holds a pooled "
            "connection for as long as the chat is open")
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()


@pytest.mark.asyncio
async def test_an_open_store_chat_holds_no_database_connection_either(client, monkeypatch):
    from api.models.store import Store

    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    _, owner, buyer = await _people()
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id = store.id
    r = await client.post("/negotiate/direct-message", headers=_auth(buyer), json={
        "store_id": store_id, "sender_role": "buyer", "sender_id": buyer, "content": "Hello"})
    assert r.status_code == 200, r.text
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    task = asyncio.create_task(media.store_ws(
        store_id, sock, token=create_access_token({"sub": buyer}), buyer_id=None,
        since=None, db=db))
    try:
        await _until(lambda: len(_messages(sock)) == 1)
        await asyncio.sleep(0.05)
        assert not db.in_transaction()
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()


@pytest.mark.asyncio
async def test_a_reconnect_replays_only_what_the_app_does_not_have(client, monkeypatch):
    monkeypatch.setattr(media, "CHAT_WS_PING_SECONDS", 5, raising=False)
    listing_id, seller, buyer = await _people()
    first = await _direct(client, buyer, "buyer", listing_id, "first")
    await _direct(client, seller, "seller", listing_id, "second", buyer_id=buyer)
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    task = asyncio.create_task(media.negotiate_ws(
        listing_id, sock, token=create_access_token({"sub": buyer}), buyer_id=None,
        since=first["created_at"], db=db))
    try:
        await _until(lambda: len(_messages(sock)) >= 1)
        await asyncio.sleep(0.05)
        assert [m["content"] for m in _messages(sock)] == ["second"]
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()

    # Without `since` (an older app), or with one it can't read, the replay
    # is what it always was.
    sock = _FakeSocket()
    db = AsyncSessionLocal()
    task = asyncio.create_task(media.negotiate_ws(
        listing_id, sock, token=create_access_token({"sub": buyer}), buyer_id=None,
        since="not-a-time", db=db))
    try:
        await _until(lambda: len(_messages(sock)) >= 2)
        assert [m["content"] for m in _messages(sock)] == ["first", "second"]
    finally:
        await sock.inbox.put(WebSocketDisconnect(1000))
        await asyncio.wait_for(task, 2)
        await db.close()


@pytest.mark.asyncio
async def test_a_dead_socket_does_not_hold_the_message_back_from_the_rest(monkeypatch):
    monkeypatch.setattr(media, "CHAT_WS_SEND_TIMEOUT_SECONDS", 0.1, raising=False)

    class _Stuck(_FakeSocket):
        """A phone gone from the network: its send never completes."""

        async def send_json(self, payload):
            await asyncio.Event().wait()

    alive, stuck = _FakeSocket(), _Stuck()
    key = media._thread_key("L-dead", "B-dead")
    # The stuck one first: it used to be written to first, and held the
    # live one back until TCP gave up on it.
    media._thread_connections[key] = {stuck: "S1", alive: "S2"}
    try:
        await asyncio.wait_for(media._broadcast(key, {"type": "message", "content": "hi"}), 1.0)
        assert alive.sent == [{"type": "message", "content": "hi"}]
        assert stuck not in media._thread_connections.get(key, {}), "a dead socket is dropped"
        assert stuck.closed == 4000, "and closed, so a slow phone reconnects"
    finally:
        media._thread_connections.pop(key, None)


# ── Receipts ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_first_receipt_written_twice_at_once_still_lands():
    """The push's delivered receipt and the inbox sweep's land together on a
    thread with no watermark yet: both INSERT, the second broke the unique
    constraint and answered 500 - and on the chat socket left its session
    failed, so the history replay after it raised too."""
    from api.routers.negotiate import _touch_watermark

    listing_id, _, buyer = await _people()
    async with AsyncSessionLocal() as db:
        real_commit = db.commit
        raced = []

        async def commit_after_the_other_request():
            if not raced:
                raced.append(True)
                async with AsyncSessionLocal() as other:
                    await _touch_watermark(other, listing_id, buyer, "buyer",
                                           delivered=True, read=False)
            await real_commit()

        db.commit = commit_after_the_other_request
        await _touch_watermark(db, listing_id, buyer, "buyer", delivered=True, read=True)
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(ThreadReadState).where(
            ThreadReadState.listing_id == listing_id,
            ThreadReadState.buyer_id == buyer,
            ThreadReadState.role == "buyer",
        ))).scalars().all()
    assert len(rows) == 1
    assert rows[0].last_read_at is not None and rows[0].last_read_at.year > 1970, (
        "the read this request carried was kept, on the row the other one made")


# ── Calls ─────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_ring_acknowledgement_survives_a_racing_session_write():
    from api.core.call_state import _store, _RedisCallStore

    if not isinstance(_store, _RedisCallStore):
        pytest.skip("only the Redis store reads and writes the session whole")
    room = f"race-{uuid.uuid4().hex}"
    await call_state.create_session(room_id=room, caller_id="caller", callee_id="callee",
                                    listing_id="l1", call_type="audio", caller_name="C")
    await call_state.update_state(room, call_state.CallState.ringing)
    # A socket joining reads the session...
    stale = await _store.get(room)
    # ...the callee's phone acknowledges the ring...
    await call_state.mark_callee_alerted(room)
    # ...and the join writes back what it read.
    stale.callee_connected = True
    await _store._write(stale, ttl_seconds=60)
    session = await call_state.get_session(room)
    assert session.callee_alerted is True, (
        "the acknowledgement was overwritten: a caller joining now is never "
        "told the phone is ringing")


@pytest.mark.asyncio
async def test_iphones_ring_alongside_android_phones_not_before_them(client):
    listing_id, seller, buyer = await _people()
    for token, kind in (("android-callee", "fcm"), ("iphone-callee", "apns_voip")):
        r = await client.post("/calls/register-token", headers=_auth(seller), json={
            "fcm_token": token, "token_type": kind, "platform": "android"})
        assert r.status_code == 200, r.text
    voip_done = asyncio.Event()
    android_rang_before_iphone_was_done = []

    async def slow_voip(token, data):
        await asyncio.sleep(0.3)
        voip_done.set()
        return True

    async def fcm(**kwargs):
        if kwargs["data"].get("type") == "incoming_call":
            android_rang_before_iphone_was_done.append(not voip_done.is_set())
        return calls.FcmResult(True)

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=fcm), \
         patch.object(calls, "_send_voip_push", new=slow_voip), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        r = await client.post("/calls/initiate", headers=_auth(buyer), json={
            "listing_id": listing_id, "caller_name": "Bea", "call_type": "audio"})
        assert r.status_code == 200, r.text
        await message_push.drain()
        await asyncio.gather(*list(calls._background), return_exceptions=True)
    assert r.json()["status"] == "sent"
    assert android_rang_before_iphone_was_done == [True]
    assert voip_done.is_set(), "the iPhone was rung too"


# ── Photos sent together ──────────────────────────────────────────────────────

def _photo() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (40, 120, 200)).save(buf, "JPEG")
    return buf.getvalue()


async def _upload(client, listing_id, sender, role, *, album_id=None, content_type="image",
                  buyer_id=None, raw=None, name="image.jpg", mime="image/jpeg"):
    data = {"listing_id": listing_id, "sender_role": role, "sender_id": sender,
            "content_type": content_type}
    if album_id is not None:
        data["album_id"] = album_id
    if buyer_id:
        data["buyer_id"] = buyer_id
    return await client.post("/media/upload", headers=_auth(sender), data=data,
                             files={"file": (name, raw or _photo(), mime)})


@pytest.mark.asyncio
async def test_photos_sent_together_keep_their_album_on_both_phones(client):
    listing_id, seller, buyer = await _people()
    seller_sock = _FakeSocket()
    key = media._thread_key(listing_id, buyer)
    media._thread_connections[key] = {seller_sock: seller}
    try:
        answers = []
        for _ in range(3):
            r = await _upload(client, listing_id, buyer, "buyer", album_id="cAlbum_1-x")
            assert r.status_code == 200, r.text
            answers.append(r.json())
    finally:
        media._thread_connections.pop(key, None)
    assert [a["album_id"] for a in answers] == ["cAlbum_1-x"] * 3
    assert [m["album_id"] for m in _messages(seller_sock)] == ["cAlbum_1-x"] * 3, (
        "the other phone's live copy names the album too")
    for viewer, params in ((buyer, {}), (seller, {"buyer_id": buyer})):
        history = (await client.get(f"/negotiate/{listing_id}/history",
                                    params=params, headers=_auth(viewer))).json()
        assert [m["album_id"] for m in history] == ["cAlbum_1-x"] * 3


@pytest.mark.asyncio
async def test_only_a_photo_with_an_id_the_app_could_make_is_in_an_album(client):
    listing_id, seller, buyer = await _people()
    r = await _upload(client, listing_id, buyer, "buyer", album_id="<script>")
    assert r.status_code == 200, r.text
    assert r.json()["album_id"] is None, "dropped - the photo still goes, on its own"
    r = await _upload(client, listing_id, buyer, "buyer", album_id="doc-album",
                      content_type="file", raw=b"%PDF-1.4 quote", name="Quote.pdf",
                      mime="application/pdf")
    assert r.status_code == 200, r.text
    assert r.json()["album_id"] is None
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage.album_id).where(
            NegotiationMessage.listing_id == listing_id))).scalars().all()
    assert rows == [None, None]


@pytest.mark.asyncio
async def test_an_unsent_photo_leaves_its_album(client):
    listing_id, seller, buyer = await _people()
    r = await _upload(client, listing_id, buyer, "buyer", album_id="album-unsend")
    photo_id = r.json()["id"]
    r = await client.delete(f"/negotiate/message/{photo_id}", headers=_auth(buyer))
    assert r.status_code == 200, r.text
    history = (await client.get(f"/negotiate/{listing_id}/history", headers=_auth(buyer))).json()
    assert history[0]["deleted"] is True
    assert history[0]["album_id"] is None
