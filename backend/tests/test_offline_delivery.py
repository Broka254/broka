"""No message lost to an offline recipient, and a log that says so (2026-11-12).

Asked for: a message sent while its recipient is offline - no signal, phone
off, app closed - must reach them when they come back, whatever happened to
its push; and the API log (Render) must show, per message, whether it was
saved, pushed, delivered or read, with "delivered" meaning the recipient's
app has it - never that Firebase accepted a push.

What was missing:

  * Nothing about a push was stored. One that failed - FCM unavailable, no
    phone registered yet - was never tried again, and a restart lost every
    push still waiting out its debounce.
  * Delivery was a per-thread watermark only, moved by the app's inbox
    sweep before it had fetched a single message.
  * The log had "MESSAGE_PUSHED phones=N" per thread and nothing per
    message.

Now each message has a delivery row per recipient (api/models/
message_delivery.py, written in the message's own transaction), the push
outcome is recorded on it and retried from it, the app's sync
(GET /negotiate/sync) hands out what is undelivered until the app
acknowledges it (POST /negotiate/sync/ack), and every step is one log line.

The scenarios are the ones asked for: A an online recipient, B an offline
one, C an app closed while several messages arrive, D many messages in
order without duplicates, E a sync cut off half way, F the same message by
push and by sync, G read receipts. Then retries, restarts, and privacy.
"""
import asyncio
import logging
import uuid
from datetime import datetime, timedelta
from unittest.mock import patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.core import message_delivery, message_push, push_devices
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.models.message_delivery import MessageDelivery
from api.models.push_device import PushDevice
from api.models.store import Store
from api.routers import calls
from api.security import create_access_token
from main import app

LOGGER = "api.core.message_delivery"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_offline_delivery.db"
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
    """Every push a test started finishes inside it (see the same fixture in
    test_push_delivery_receipts.py: a task left half way through a read kept
    the SQLite file locked for every later test)."""
    yield
    loop = asyncio.get_running_loop()
    while True:
        pending = [t for t in list(message_push._inflight)
                   if t.get_loop() is loop and not t.done()]
        if not pending:
            return
        await asyncio.gather(*pending, return_exceptions=True)


class FakeFcm:
    """FCM configured on the server. `answer(token)` is what Firebase says
    to each send - accepted by default, the way Firebase accepts one: with
    a message id, which proves nothing about the phone."""

    def __init__(self):
        self.sent: list[dict] = []
        self.answer = lambda token: calls.FcmResult(
            True, message_id=f"projects/broka/messages/{len(self.sent)}")

    async def __call__(self, **kwargs):
        self.sent.append(kwargs)
        return self.answer(kwargs["token"])

    def message_pushes(self) -> list[dict]:
        return [p for p in self.sent if p["data"].get("type") == "new_message"]


def _unavailable(token):
    return calls.FcmResult(False, failure_category="provider_transient", retryable=True,
                           error_code="UNAVAILABLE")


def _unregistered(token):
    return calls.FcmResult(False, unregistered=True, failure_category="invalid_token",
                           retryable=False, error_code="UNREGISTERED")


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


async def _register(client, uid, phone=None) -> str:
    phone = phone or f"tok-{uuid.uuid4().hex}"
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


async def _rows(message_id: str) -> list:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(MessageDelivery).where(MessageDelivery.message_id == message_id)
        )).scalars().all()


async def _row(message_id: str):
    rows = await _rows(message_id)
    assert len(rows) == 1, f"one delivery row per message and recipient, got {len(rows)}"
    return rows[0]


async def _status(message_id: str) -> str:
    return (await _row(message_id)).status


async def _sync(client, uid, **params):
    r = await client.get("/negotiate/sync", params=params, headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _sync_all(client, uid, limit=100, **params) -> list[dict]:
    """A whole sync pass, page by page, the way the app runs one."""
    out, after, page = [], None, 1
    while True:
        query = {"limit": limit, "page": page, **params}
        if after:
            query["after"] = after
        body = await _sync(client, uid, **query)
        out.extend(body["messages"])
        if not body["has_more"]:
            return out
        after, page = body["next_cursor"], page + 1


async def _ack(client, uid, ids, **extra):
    r = await client.post("/negotiate/sync/ack", json={"message_ids": ids, **extra},
                          headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


def _events(caplog, message_id: str) -> list[str]:
    """This message's lifecycle, in order, from the delivery log."""
    return [r.getMessage().split()[0] for r in caplog.records
            if r.name == LOGGER and f"message_id={message_id} " in r.getMessage() + " "]


def _lines(caplog, event: str) -> list[str]:
    return [r.getMessage() for r in caplog.records
            if r.name == LOGGER and r.getMessage().startswith(event + " ")]


async def _seller_delivered_watermark(listing_id, buyer_id):
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(ThreadReadState.last_delivered_at).where(
            ThreadReadState.listing_id == listing_id, ThreadReadState.buyer_id == buyer_id,
            ThreadReadState.role == "seller"))).scalar_one_or_none()


def _created(message: dict) -> datetime:
    return datetime.fromisoformat(message["created_at"].rstrip("Z"))


# ── A: the recipient is online ──────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_online_message_is_saved_pushed_and_delivered_only_on_the_phones_receipt(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, "Is it still available?")
        await message_push.drain()
        # FCM took the push. That is not delivery.
        row = await _row(msg["id"])
        assert row.status == "PUSH_ACCEPTED"
        assert row.delivered_at is None
        assert row.recipient_id == seller_id
        push = fcm.message_pushes()[-1]
        assert push["data"]["messageId"] == msg["id"]

        # The phone's push handler ran and says so.
        r = await client.post("/negotiate/notification/delivered", json={
            "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
        assert r.status_code == 200, r.text
    row = await _row(msg["id"])
    assert row.status == "DELIVERED"
    assert row.delivered_via == "push_receipt"
    assert _events(caplog, msg["id"]) == [
        "MESSAGE_SAVED", "MESSAGE_PUSH_STARTED", "MESSAGE_PUSH_ACCEPTED",
        "MESSAGE_DELIVERY_ACK_RECEIVED", "MESSAGE_DELIVERED",
    ]
    saved = _lines(caplog, "MESSAGE_SAVED")[-1]
    for field in (f"message_id={msg['id']}", f"conversation_id=listing:{listing_id}:{buyer_id}",
                  f"sender_id={buyer_id}", f"recipient_id={seller_id}",
                  "delivery_status=SAVED", "attempt=0", "timestamp="):
        assert field in saved, f"{field} missing from {saved!r}"
    accepted = next(l for l in _lines(caplog, "MESSAGE_PUSH_ACCEPTED") if msg["id"] in l)
    assert "device_count=1" in accepted and "delivery_status=PUSH_ACCEPTED" in accepted
    delivered = next(l for l in _lines(caplog, "MESSAGE_DELIVERED") if msg["id"] in l)
    assert "delivery_status=DELIVERED" in delivered and "delivered_via=push_receipt" in delivered


# ── B: the recipient is offline ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_b_an_offline_recipient_gets_the_message_from_the_sync_and_only_then_delivered(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    fcm.answer = _unavailable  # their phone cannot be reached
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, "Sent while you were away")
        await message_push.drain()
        row = await _row(msg["id"])
        # Saved, the push failed - and the message is still there.
        assert row.status == "PUSH_FAILED"
        assert row.push_error == "UNAVAILABLE"
        assert row.next_push_at is not None, "a transient failure is tried again"
        failed = next(l for l in _lines(caplog, "MESSAGE_PUSH_FAILED") if msg["id"] in l)
        assert "error=UNAVAILABLE" in failed and "retryable=true" in failed

        # They come back online: the app syncs.
        synced = await _sync(client, seller_id, trigger="connectivity_restored", page=1)
        assert [m["id"] for m in synced["messages"]] == [msg["id"]]
        got = synced["messages"][0]
        assert got["content"] == "Sent while you were away"
        assert got["listing_id"] == listing_id and got["buyer_id"] == buyer_id
        assert got["my_role"] == "seller" and got["room"] == "direct"
        # Handed out is not delivered: the sender still sees one tick.
        assert await _status(msg["id"]) == "PUSH_FAILED"
        assert await _seller_delivered_watermark(listing_id, buyer_id) is None

        # The app stored it and says so.
        ack = await _ack(client, seller_id, [msg["id"]], source="sync", final=True)
        assert ack["delivered"] == [msg["id"]]
    row = await _row(msg["id"])
    assert row.status == "DELIVERED" and row.delivered_via == "sync"
    assert row.next_push_at is None, "a delivered message is not pushed again"
    assert await _seller_delivered_watermark(listing_id, buyer_id) == _created(msg)
    assert _events(caplog, msg["id"]) == [
        "MESSAGE_SAVED", "MESSAGE_PUSH_STARTED", "MESSAGE_PUSH_FAILED",
        "MESSAGE_SYNCED_TO_CLIENT", "MESSAGE_DELIVERY_ACK_RECEIVED", "MESSAGE_DELIVERED",
    ]
    assert any("trigger=connectivity_restored" in l for l in _lines(caplog, "OFFLINE_SYNC_STARTED"))
    assert any(f"recipient_id={seller_id}" in l for l in _lines(caplog, "OFFLINE_SYNC_COMPLETED"))

    # The retry sweep has nothing left to do for it.
    fcm.sent.clear()
    await message_delivery.retry_due_pushes(now=datetime.utcnow() + timedelta(hours=1))
    assert fcm.message_pushes() == []


# ── C: app closed or phone locked, several messages ─────────────────────────

@pytest.mark.asyncio
async def test_c_messages_sent_while_the_app_was_closed_all_arrive_when_it_opens(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    # The seller's phone never registered a token (an APK without Firebase,
    # or signed out): no push can reach it.
    sent = []
    with caplog.at_level(logging.INFO, logger=LOGGER):
        for words in ("Hello", "Is it new?", "Last price?"):
            sent.append(await _direct(client, buyer_id, "buyer", listing_id, words))
            await message_push.drain()
        for m in sent:
            row = await _row(m["id"])
            assert row.status == "PUSH_FAILED" and row.push_error == "NO_DEVICES"
            assert row.next_push_at is None, "no phone to retry: the sync delivers it"

        # Later they open BROKA.
        got = await _sync_all(client, seller_id, trigger="app_start")
        assert [m["id"] for m in got] == [m["id"] for m in sent]
        assert [m["content"] for m in got] == ["Hello", "Is it new?", "Last price?"]
        await _ack(client, seller_id, [m["id"] for m in got], final=True)
    for m in sent:
        assert await _status(m["id"]) == "DELIVERED"
    failed = [l for l in _lines(caplog, "MESSAGE_PUSH_FAILED") if f"recipient_id={seller_id}" in l]
    assert failed and all("error=NO_DEVICES" in l and "final=true" in l for l in failed)
    assert (await _sync(client, seller_id))["messages"] == [], "nothing left once acknowledged"


# ── D: many offline messages, in order, once each ───────────────────────────

@pytest.mark.asyncio
async def test_d_many_offline_messages_sync_in_order_across_pages_without_duplicates(client):
    listing_id, seller_id, buyer_id = await _people()
    sent = [await _direct(client, buyer_id, "buyer", listing_id, f"message {i}") for i in range(7)]

    first = await _sync_all(client, seller_id, limit=3)
    assert [m["id"] for m in first] == [m["id"] for m in sent]
    # Asking again before acknowledging is safe: the same seven, nothing new.
    again = await _sync_all(client, seller_id, limit=2)
    assert [m["id"] for m in again] == [m["id"] for m in sent]

    await _ack(client, seller_id, [m["id"] for m in first], final=True)
    # And acknowledging twice changes nothing.
    second = await _ack(client, seller_id, [m["id"] for m in first])
    assert second["delivered"] == []
    assert sorted(second["already_delivered"]) == sorted(m["id"] for m in sent)
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(func.count(MessageDelivery.id)).where(
            MessageDelivery.message_id.in_([m["id"] for m in sent])))).scalar()
    assert rows == 7, "one delivery row per message, however often it was synced"


@pytest.mark.asyncio
async def test_d_messages_with_the_same_timestamp_are_each_synced_exactly_once(client):
    """A page boundary between two messages sent in the same instant must
    neither skip nor repeat either: the cursor is (time, id), not time."""
    listing_id, seller_id, buyer_id = await _people()
    at = datetime.utcnow().replace(microsecond=0) - timedelta(minutes=5)
    async with AsyncSessionLocal() as db:
        ids = []
        for i in range(4):
            m = NegotiationMessage(listing_id=listing_id, sender_id=buyer_id, role="buyer",
                                   recipient_role="seller", content=f"same instant {i}",
                                   buyer_id=buyer_id, via_ai=False, msg_type="text",
                                   created_at=at)
            db.add(m)
            await db.flush()
            ids.append(m.id)
        await db.commit()
    got = await _sync_all(client, seller_id, limit=1)
    assert sorted(m["id"] for m in got) == sorted(ids)
    assert len(got) == len(set(m["id"] for m in got)) == 4


# ── E: a sync cut off half way ──────────────────────────────────────────────

@pytest.mark.asyncio
async def test_e_a_sync_interrupted_half_way_resumes_without_losing_anything(client, caplog):
    listing_id, seller_id, buyer_id = await _people()
    sent = [await _direct(client, buyer_id, "buyer", listing_id, f"m{i}") for i in range(5)]
    with caplog.at_level(logging.INFO, logger=LOGGER):
        page1 = await _sync(client, seller_id, limit=2, page=1, sync_id="pass-1", trigger="resume")
        assert page1["has_more"] is True
        await _ack(client, seller_id, [m["id"] for m in page1["messages"]], sync_id="pass-1")
        # Page 2 was fetched, then the network went: never acknowledged.
        page2 = await _sync(client, seller_id, limit=2, page=2, after=page1["next_cursor"],
                            sync_id="pass-1")
        assert len(page2["messages"]) == 2
        # Connectivity is back: a new pass, which says the last one failed.
        rest = await _sync_all(client, seller_id, sync_id="pass-2", attempt=2,
                               previous_error="SocketException", trigger="connectivity_restored")
        assert [m["id"] for m in rest] == [m["id"] for m in sent[2:]], (
            "the resumed sync hands out exactly what the phone has not acknowledged")
        await _ack(client, seller_id, [m["id"] for m in rest], sync_id="pass-2", final=True)
    for m in sent:
        assert await _status(m["id"]) == "DELIVERED"
    reported = _lines(caplog, "OFFLINE_SYNC_FAILED")
    assert any("error=SocketException" in l and "source=client_report" in l for l in reported)
    assert any("sync_id=pass-2" in l for l in _lines(caplog, "OFFLINE_SYNC_COMPLETED"))
    assert not any("sync_id=pass-1" in l for l in _lines(caplog, "OFFLINE_SYNC_COMPLETED")), (
        "a pass that never acknowledged its last page did not complete")


# ── F: the same message by push and by sync ─────────────────────────────────

@pytest.mark.asyncio
async def test_f_a_message_delivered_by_push_is_not_synced_again_and_counts_once(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, "One message, two routes")
        await message_push.drain()
        push = fcm.message_pushes()[-1]
        r = await client.post("/negotiate/notification/delivered", json={
            "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
        assert r.status_code == 200
        # The sync ran too (the app came to the front as the push arrived).
        assert msg["id"] not in [m["id"] for m in (await _sync(client, seller_id))["messages"]]
        # The chat, which also has it, acknowledges it again.
        again = await _ack(client, seller_id, [msg["id"]], source="chat")
        assert again["already_delivered"] == [msg["id"]]
    assert await _status(msg["id"]) == "DELIVERED"
    assert _events(caplog, msg["id"]).count("MESSAGE_DELIVERED") == 1
    history = (await client.get(f"/negotiate/{listing_id}/history",
                                params={"buyer_id": buyer_id}, headers=_auth(seller_id))).json()
    assert [m["id"] for m in history].count(msg["id"]) == 1


# ── G: read receipts ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_g_a_received_message_is_delivered_not_read_until_the_chat_is_opened(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, "Can you do 23k?")
        await message_push.drain()
        push = fcm.message_pushes()[-1]
        await client.post("/negotiate/notification/delivered", json={
            "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
        # The notification arriving is never a read.
        assert await _status(msg["id"]) == "DELIVERED"
        status = (await client.get(f"/negotiate/{listing_id}/read-status",
                                   params={"buyer_id": buyer_id},
                                   headers=_auth(buyer_id))).json()
        sent_at = _created(msg)
        assert datetime.fromisoformat(status["seller_last_delivered"].rstrip("Z")) >= sent_at
        last_read = status["seller_last_read"]
        assert last_read is None or datetime.fromisoformat(last_read.rstrip("Z")) < sent_at, (
            "the buyer must still see Delivered, not Seen")

        r = await client.post(f"/negotiate/{listing_id}/mark-read",
                              json={"buyer_id": buyer_id}, headers=_auth(seller_id))
        assert r.status_code == 200
        row = await _row(msg["id"])
        assert row.status == "READ" and row.read_at is not None

        # A delivery receipt that lands late - after the read - moves nothing back.
        late = await _ack(client, seller_id, [msg["id"]], source="push")
        assert late["already_delivered"] == [msg["id"]]
        r = await client.post("/negotiate/notification/delivered", json={
            "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
        assert r.status_code == 200
    assert await _status(msg["id"]) == "READ"
    assert _events(caplog, msg["id"])[-1] == "MESSAGE_DELIVERY_ACK_RECEIVED"
    read = next(l for l in _lines(caplog, "MESSAGE_READ") if msg["id"] in l)
    assert "delivery_status=READ" in read and "source=chat_open" in read
    assert any("result=already_read" in l and msg["id"] in l
               for l in _lines(caplog, "MESSAGE_DELIVERY_ACK_RECEIVED"))


@pytest.mark.asyncio
async def test_g_a_message_read_without_a_delivery_receipt_is_logged_delivered_then_read(
        client, caplog):
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Read in the open chat")
    with caplog.at_level(logging.INFO, logger=LOGGER):
        r = await client.post(f"/negotiate/{listing_id}/mark-read",
                              json={"buyer_id": buyer_id}, headers=_auth(seller_id))
        assert r.status_code == 200
    assert _events(caplog, msg["id"]) == ["MESSAGE_SAVED", "MESSAGE_DELIVERED", "MESSAGE_READ"]
    row = await _row(msg["id"])
    assert row.status == "READ" and row.delivered_via == "read"


@pytest.mark.asyncio
async def test_g_reading_the_direct_chat_does_not_read_zenos_messages(client):
    listing_id, seller_id, buyer_id = await _people()
    async with AsyncSessionLocal() as db:
        zeno = NegotiationMessage(listing_id=listing_id, sender_id="broker", role="broker",
                                  recipient_role="buyer", content="The seller replied.",
                                  buyer_id=buyer_id, via_ai=True, msg_type="text")
        db.add(zeno)
        await db.commit()
        zeno_id = zeno.id
    row = await _row(zeno_id)
    assert row.from_zeno is True and row.recipient_id == buyer_id

    await client.post(f"/negotiate/{listing_id}/mark-read", json={}, headers=_auth(buyer_id))
    assert await _status(zeno_id) != "READ", "Zeno's messages are read in Zeno's room"
    synced = await _sync(client, buyer_id)
    zeno_out = next(m for m in synced["messages"] if m["id"] == zeno_id)
    assert zeno_out["room"] == "zeno" and zeno_out["role"] == "broker"

    await client.post(f"/negotiate/{listing_id}/zeno-read", json={}, headers=_auth(buyer_id))
    assert await _status(zeno_id) == "READ"


# ── Retries ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_transient_push_failure_is_retried_with_backoff_until_accepted(
        client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    fcm.answer = _unavailable
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Try again later")
    await message_push.drain()
    row = await _row(msg["id"])
    assert row.status == "PUSH_FAILED" and row.push_attempts == 1
    first_wait = (row.next_push_at - row.updated_at).total_seconds()
    assert 25 <= first_wait <= 35, f"first retry about 30s later, got {first_wait}"

    # Not due yet: the sweep leaves it.
    fcm.sent.clear()
    await message_delivery.retry_due_pushes(now=datetime.utcnow())
    assert fcm.message_pushes() == []

    # Still down at the second try: the wait doubles.
    await message_delivery.retry_due_pushes(now=row.next_push_at + timedelta(seconds=1))
    row = await _row(msg["id"])
    assert row.status == "PUSH_FAILED" and row.push_attempts == 2
    second_wait = (row.next_push_at - row.updated_at).total_seconds()
    assert 55 <= second_wait <= 65, f"second retry about 60s later, got {second_wait}"

    # FCM is back.
    fcm.answer = FakeFcm().answer
    with caplog.at_level(logging.INFO, logger=LOGGER):
        await message_delivery.retry_due_pushes(now=row.next_push_at + timedelta(seconds=1))
    row = await _row(msg["id"])
    assert row.status == "PUSH_ACCEPTED" and row.push_attempts == 3
    assert row.next_push_at is None
    retries = [l for l in _lines(caplog, "MESSAGE_DELIVERY_RETRY") if msg["id"] in l]
    assert [l.split("attempt=")[1].split()[0] for l in retries] == ["2", "3"]
    assert all("previous_error=UNAVAILABLE" in l for l in retries)
    assert "trigger=retry" in [l for l in _lines(caplog, "MESSAGE_PUSH_ACCEPTED")
                               if msg["id"] in l][-1]


@pytest.mark.asyncio
async def test_retries_stop_after_the_last_attempt(client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _register(client, seller_id)
    fcm.answer = _unavailable
    msg = await _direct(client, buyer_id, "buyer", listing_id, "FCM is down for good")
    await message_push.drain()
    for _ in range(message_delivery.MAX_PUSH_ATTEMPTS + 2):
        row = await _row(msg["id"])
        if row.next_push_at is None:
            break
        await message_delivery.retry_due_pushes(now=row.next_push_at + timedelta(seconds=1))
    row = await _row(msg["id"])
    assert row.push_attempts == message_delivery.MAX_PUSH_ATTEMPTS
    assert row.status == "PUSH_FAILED" and row.next_push_at is None
    # The message is not lost with the push: the sync still hands it out.
    assert msg["id"] in [m["id"] for m in (await _sync(client, seller_id))["messages"]]


@pytest.mark.asyncio
async def test_a_receipt_that_lands_while_the_push_is_in_flight_is_kept(client, caplog):
    """The phone's sync can acknowledge a message before FCM has answered
    the push for it. The push result must not take it back to
    PUSH_ACCEPTED - and its log line must say what the row really is."""
    listing_id, seller_id, buyer_id = await _people()

    async def _send(**kwargs):
        async with AsyncSessionLocal() as db:
            await message_delivery.mark_delivered(
                db, recipient_id=seller_id, message_ids=[kwargs["data"]["messageId"]],
                source="sync")
        return calls.FcmResult(True, message_id="projects/broka/messages/1")

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        await _register(client, seller_id)
        with caplog.at_level(logging.INFO, logger=LOGGER):
            msg = await _direct(client, buyer_id, "buyer", listing_id, "Raced its own push")
            await message_push.drain()
    message_push._last_pushed.clear()
    assert await _status(msg["id"]) == "DELIVERED"
    accepted = [l for l in _lines(caplog, "MESSAGE_PUSH_ACCEPTED") if msg["id"] in l][-1]
    assert "delivery_status=DELIVERED" in accepted


@pytest.mark.asyncio
async def test_a_dead_token_is_forgotten_and_not_retried(client, fcm):
    listing_id, seller_id, buyer_id = await _people()
    phone = await _register(client, seller_id)
    fcm.answer = _unregistered
    msg = await _direct(client, buyer_id, "buyer", listing_id, "To an uninstalled app")
    await message_push.drain()
    row = await _row(msg["id"])
    assert row.status == "PUSH_FAILED" and row.push_error == "UNREGISTERED"
    assert row.next_push_at is None, "a dead token is not retried"
    async with AsyncSessionLocal() as db:
        assert await db.get(PushDevice, phone) is None, "FCM said the token is dead"


@pytest.mark.asyncio
async def test_a_push_lost_to_a_restart_is_sent_by_the_retry_sweep(client, caplog):
    """The debounced push lives in memory. A message saved just before a
    restart - or on a server that could not push at that moment - had its
    push dropped for good. Its delivery row stays due, and the sweep sends
    it once FCM is there."""
    listing_id, seller_id, buyer_id = await _people()
    fake = FakeFcm()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=fake):
        await _register(client, seller_id)
    # Saved while no push could be scheduled: the process that took it went
    # away before its debounced push ran (here: FCM not there at that moment).
    msg = await _direct(client, buyer_id, "buyer", listing_id, "Saved during a restart")
    assert await _status(msg["id"]) == "SAVED"

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=fake), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        fake.sent.clear()
        message_push._last_pushed.clear()
        # Before the grace period the debounced push may still be coming.
        await message_delivery.retry_due_pushes(now=datetime.utcnow())
        assert await _status(msg["id"]) == "SAVED"
        with caplog.at_level(logging.INFO, logger=LOGGER):
            await message_delivery.retry_due_pushes(
                now=datetime.utcnow()
                + timedelta(seconds=message_delivery.FAST_PATH_GRACE_SECONDS + 1))
    assert await _status(msg["id"]) == "PUSH_ACCEPTED"
    assert [p["data"]["messageId"] for p in fake.message_pushes()] == [msg["id"]]
    assert any(msg["id"] in l and "trigger=retry" in l
               for l in _lines(caplog, "MESSAGE_DELIVERY_RETRY"))
    message_push._last_pushed.clear()


@pytest.mark.asyncio
async def test_a_server_without_fcm_says_so_per_message_instead_of_retrying(client, caplog):
    listing_id, seller_id, buyer_id = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "No Firebase on this server")
    with caplog.at_level(logging.INFO, logger=LOGGER):
        await message_delivery.retry_due_pushes(now=datetime.utcnow() + timedelta(minutes=5))
    row = await _row(msg["id"])
    assert row.status == "PUSH_FAILED" and row.push_error == "PUSH_NOT_CONFIGURED"
    assert row.next_push_at is None
    assert any(msg["id"] in l and "error=PUSH_NOT_CONFIGURED" in l
               for l in _lines(caplog, "MESSAGE_PUSH_FAILED"))


# ── Privacy and scope ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_private_words_to_zeno_are_never_tracked_or_synced_to_the_other_side(client):
    listing_id, seller_id, buyer_id = await _people()
    async with AsyncSessionLocal() as db:
        private = NegotiationMessage(listing_id=listing_id, sender_id=buyer_id, role="buyer",
                                     content="My budget is really 30k", buyer_id=buyer_id,
                                     via_ai=True, msg_type="text")
        db.add(private)
        await db.commit()
        private_id = private.id
    assert await _rows(private_id) == []
    assert private_id not in [m["id"] for m in (await _sync(client, seller_id))["messages"]]


@pytest.mark.asyncio
async def test_nobody_can_acknowledge_or_sync_someone_elses_messages(client):
    listing_id, seller_id, buyer_id = await _people()
    _, other_seller, _ = await _people()
    msg = await _direct(client, buyer_id, "buyer", listing_id, "For the seller only")
    # Another account, and the sender themselves.
    for intruder in (other_seller, buyer_id):
        ack = await _ack(client, intruder, [msg["id"]])
        assert ack["unknown"] == [msg["id"]] and ack["delivered"] == []
        assert msg["id"] not in [m["id"] for m in (await _sync(client, intruder))["messages"]]
    assert await _status(msg["id"]) == "SAVED"


@pytest.mark.asyncio
async def test_the_ack_moves_the_senders_tick_to_what_was_acknowledged_not_to_now(client):
    listing_id, seller_id, buyer_id = await _people()
    first = await _direct(client, buyer_id, "buyer", listing_id, "first")
    second = await _direct(client, buyer_id, "buyer", listing_id, "second")
    await _ack(client, seller_id, [first["id"]])
    watermark = await _seller_delivered_watermark(listing_id, buyer_id)
    assert watermark == _created(first)
    assert watermark < _created(second), "the second message is not on that phone yet"


@pytest.mark.asyncio
async def test_a_store_conversation_is_tracked_and_synced_too(client):
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id, owner_id, buyer_id = store.id, owner.id, buyer.id
    r = await client.post("/negotiate/direct-message", json={
        "store_id": store_id, "sender_role": "buyer", "sender_id": buyer_id,
        "content": "Do you deliver to Thika?"}, headers=_auth(buyer_id))
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    row = await _row(msg["id"])
    assert row.store_id == store_id and row.listing_id is None and row.recipient_id == owner_id
    got = (await _sync(client, owner_id))["messages"]
    out = next(m for m in got if m["id"] == msg["id"])
    assert out["thread_type"] == "store" and out["store_id"] == store_id
    await _ack(client, owner_id, [msg["id"]])
    assert await _status(msg["id"]) == "DELIVERED"
    async with AsyncSessionLocal() as db:
        mark = (await db.execute(select(ThreadReadState.last_delivered_at).where(
            ThreadReadState.store_id == store_id, ThreadReadState.buyer_id == buyer_id,
            ThreadReadState.role == "seller"))).scalar_one_or_none()
    assert mark == _created(msg)


@pytest.mark.asyncio
async def test_tracking_failing_never_loses_the_message(client, caplog, monkeypatch):
    """The delivery rows are written in the message's own transaction. If
    writing them fails - a missing table, a bad statement - the message must
    still be saved: on PostgreSQL a failed statement aborts the whole
    transaction unless it ran in its own savepoint."""
    from sqlalchemy import text

    def _broken(conn, messages):
        conn.execute(text("SELECT no_such_column FROM no_such_table"))

    monkeypatch.setattr(message_delivery, "_write_rows", _broken)
    listing_id, seller_id, buyer_id = await _people()
    with caplog.at_level(logging.INFO, logger=LOGGER):
        msg = await _direct(client, buyer_id, "buyer", listing_id, "Saved however tracking fares")
    async with AsyncSessionLocal() as db:
        stored = await db.get(NegotiationMessage, msg["id"])
    assert stored is not None and stored.content == "Saved however tracking fares"
    assert await _rows(msg["id"]) == []
    assert any(r.levelname == "ERROR" and r.getMessage().startswith("MESSAGE_TRACKING_FAILED")
               for r in caplog.records if r.name == LOGGER)
    saved = next(l for l in _lines(caplog, "MESSAGE_SAVED") if msg["id"] in l)
    assert "tracked=false" in saved


@pytest.mark.asyncio
async def test_the_delivery_log_never_carries_tokens_or_words(client, fcm, caplog):
    listing_id, seller_id, buyer_id = await _people()
    phone = await _register(client, seller_id, f"secret-fcm-token-{uuid.uuid4().hex}")
    secret_words = f"my M-Pesa PIN is {uuid.uuid4().hex[:6]}"
    with caplog.at_level(logging.INFO):
        msg = await _direct(client, buyer_id, "buyer", listing_id, secret_words)
        await message_push.drain()
        push = fcm.message_pushes()[-1]
        await client.post("/negotiate/notification/delivered", json={
            "thread_token": push["data"]["threadToken"], "message_id": msg["id"]})
        await _sync(client, seller_id)
    text = caplog.text
    assert phone not in text
    assert secret_words not in text
    assert push["data"]["threadToken"] not in text


@pytest.mark.asyncio
async def test_the_summary_says_where_recent_messages_stand(client, caplog):
    listing_id, seller_id, buyer_id = await _people()
    await _direct(client, buyer_id, "buyer", listing_id, "Counted in the summary")
    with caplog.at_level(logging.INFO, logger=LOGGER):
        summary = await message_delivery.delivery_summary()
    assert summary["saved"] >= 1
    line = _lines(caplog, "MESSAGE_DELIVERY_SUMMARY")[-1]
    for field in ("saved=", "push_accepted=", "push_failed=", "delivered=", "read=",
                  "undelivered_over_10m="):
        assert field in line


@pytest.mark.asyncio
async def test_a_bad_cursor_is_refused(client):
    _, seller_id, _ = await _people()
    r = await client.get("/negotiate/sync", params={"after": "not-a-cursor"},
                         headers=_auth(seller_id))
    assert r.status_code == 400
