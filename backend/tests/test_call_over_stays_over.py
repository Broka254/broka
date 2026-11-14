"""A call that is over stays over - at every door (2026-11-14).

Railway, room HfedVQp_gK_0pLMgzro5eg, times EAT:

  15:04:50  call placed; the callee had no push token
  15:04:55  the caller's socket joined; 15:04:56 its offer was made
  15:05:14  the caller hung up; 15:05:16 the call was recorded cancelled
  15:05:38  the callee's phone (its in-app sweep) reported it ringing
  15:05:52  that phone joined the room on its ringing socket
  15:05:53  and was handed the caller's buffered hang-up
  15:05:54  its Accept was answered 200

Supabase was refusing new clients minutes before (EMAXCONNSESSION). The
caller's hang-up claimed the call's result and then needed the database to
end the call; a claimed result whose database step failed left the call
ringing with nobody able to end it - and every Redis write read the whole
session and wrote it back, so any change that had read it while it rang
could put "ringing" back over its end. Both are fixed; these tests hold the
doors: /answer and /alerted answer 410, the sweep finds nothing, a socket is
refused, nothing kept for the absent phone is replayed, and the database
failing never leaves a call alive.
"""
import asyncio
import json
import logging
import random
import time
import uuid
from types import SimpleNamespace
from unittest.mock import patch

import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.exc import OperationalError
from starlette.datastructures import Headers

from api import database
from api.core import call_state, message_push, push_devices
from api.core.call_signaling import CallSignalingHub, _MemoryBackend
from api.core.call_state import CallState
from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.routers import calls
from api.security import create_access_token, create_call_token
from main import app
from tests.call_races import gate, interleave, redis_store


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_call_over_stays_over.db"
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
def memory_hub(monkeypatch):
    """A signaling hub of this test's own (see test_call_answer_while_ringing)."""
    hub = CallSignalingHub(instance_id=f"test-{uuid.uuid4().hex[:6]}", backend=_MemoryBackend())
    hub.set_handler(calls._deliver_remote)
    monkeypatch.setattr(calls, "signaling_hub", hub)
    return hub


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


class _Fcm:
    """Firebase as configured; every send accepted unless `accept` is off."""

    def __init__(self):
        self.sent = []
        self.accept = True
        self.on_send = None

    async def __call__(self, **kwargs):
        if self.on_send is not None:
            self.on_send(kwargs)
        self.sent.append(kwargs)
        return calls.FcmResult(self.accept, message_id="projects/x/messages/1")


@pytest_asyncio.fixture
async def fcm():
    send = _Fcm()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield send
        await _settled()


async def _settled():
    await asyncio.gather(*list(calls._background), return_exceptions=True)
    await message_push.drain()


async def _people():
    async with AsyncSessionLocal() as db:
        seller = User(name="Xavier Bravin", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Airtel Smart Connect",
                          category="Electronics", price=4500, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer.id, role="buyer",
                                  recipient_role="seller", content="hi", buyer_id=buyer.id,
                                  via_ai=False, msg_type="text"))
        await db.commit()
        return listing.id, seller.id, buyer.id


async def _register(client, uid):
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm"})
    assert r.status_code == 200, r.text


async def _initiate(client, caller, listing_id, client_call_id=None):
    body = {"listing_id": listing_id, "caller_name": "Bea Buyer", "call_type": "audio"}
    if client_call_id:
        body["client_call_id"] = client_call_id
    r = await client.post("/calls/initiate", headers=_auth(caller), json=body)
    assert r.status_code == 200, r.text
    return r.json()["room_id"]


async def _answer(client, room, callee):
    return await client.post(f"/calls/{room}/answer",
                             json={"call_token": create_call_token(callee, room)})


async def _alerted(client, room, callee):
    return await client.post(f"/calls/{room}/alerted",
                             json={"call_token": create_call_token(callee, room)})


async def _cancel(client, caller, attempt):
    return await client.post("/calls/cancel-setup", headers=_auth(caller),
                             json={"client_call_id": attempt, "reason": "user_hung_up"})


async def _cards(listing_id):
    async with AsyncSessionLocal() as db:
        return list((await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all())


def _pushes(fcm, kind, room=None):
    return [p for p in fcm.sent if p["data"].get("type") == kind
            and (room is None or p["data"].get("roomId") == room)]


def _attempt() -> str:
    return f"cc{uuid.uuid4().hex}"


class _Listener:
    """A socket that only listens, put straight into the room's registry."""

    def __init__(self):
        self.jsons = []

    async def send_json(self, data):
        self.jsons.append(data)

    async def send_text(self, raw):
        self.jsons.append(json.loads(raw))

    async def close(self, code=1000, reason=None):
        pass

    def got(self, kind):
        return [m for m in self.jsons if m.get("type") == kind]


class FakeSocket:
    """As much of a Starlette WebSocket as calls._signaling uses."""

    def __init__(self):
        self.headers = Headers()
        self.client = SimpleNamespace(
            host=f"10.{random.randint(0, 255)}.{random.randint(0, 255)}.{random.randint(1, 254)}",
            port=40000)
        self.accepted = False
        self.closed = None
        self.jsons = []
        self.texts = []
        self._inbox: asyncio.Queue = asyncio.Queue()

    async def accept(self):
        self.accepted = True

    async def close(self, code=1000, reason=None):
        if self.closed is None:
            self.closed = (code, reason)
        self._inbox.put_nowait(None)

    async def send_json(self, data):
        self.jsons.append(data)
        if data == {"type": "ping"}:
            self.say({"type": "pong"})

    async def send_text(self, raw):
        self.texts.append(json.loads(raw))

    async def receive_text(self):
        item = await self._inbox.get()
        if item is None:
            raise WebSocketDisconnect(code=1000)
        return item

    def say(self, message: dict):
        self._inbox.put_nowait(json.dumps(message))

    def drop(self):
        self._inbox.put_nowait(None)

    def got(self, kind):
        return [m for m in self.jsons if m.get("type") == kind]

    def relayed(self, kind):
        return [m for m in self.texts if m.get("type") == kind]


async def _until(condition, timeout: float = 5.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not condition():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.01)


async def _open(room: str, uid: str, *, ringing: bool = False, peer: str = ""):
    ws = FakeSocket()
    task = asyncio.create_task(calls._signaling(
        ws, room, create_call_token(uid, room), peer=peer, ringing=ringing))
    await _until(lambda: ws.accepted or ws.closed is not None or task.done())
    for _ in range(20):
        await asyncio.sleep(0.005)
    return ws, task


def _events(caplog, name):
    return [r.call_event for r in caplog.records
            if getattr(r, "call_event", None) and r.call_event["event"] == name]


def _refused(*, kind: str = "refused"):
    """What asyncpg passes on, wrapped by SQLAlchemy, when Supavisor admits no
    more clients - Railway's own words."""
    driver = Exception("(EMAXCONNSESSION) max clients reached in session mode - "
                       "max clients are limited to pool_size: 15")
    return OperationalError("SELECT 1", {}, driver)


# ── The incident, step by step ────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_incident_room_cannot_come_back(client, fcm, memory_hub):
    """No push token, the caller's offer made and its hang-up sent while
    nobody else was in the room: everything the callee's phone tried
    afterwards is told the call is over."""
    listing_id, seller, buyer = await _people()            # the seller has no token
    room = await _initiate(client, buyer, listing_id)
    caller, caller_task = await _open(room, buyer)
    caller.say({"type": "offer", "sdp": "v=0 caller offer", "offer_id": "o1"})
    caller.say({"type": "ice", "candidate": {"candidate": "candidate:1 1 udp 1 1.2.3.4 9 typ host"}})
    caller.say({"type": "hangup", "room_id": room})
    await asyncio.wait_for(caller_task, timeout=5)
    await _settled()

    session = await call_state.get_session(room)
    assert session.state == CallState.missed
    assert await _cards(listing_id) == ["cancelled"]

    # 15:05:38 - the sweep, and the ring report.
    incoming = await client.get("/calls/incoming", headers=_auth(seller))
    assert incoming.json() == {"has_call": False}
    assert (await _alerted(client, room, seller)).status_code == 410
    # 15:05:52 - the ringing socket.
    phone, phone_task = await _open(room, seller, ringing=True, peer="pc-1")
    assert phone.closed and phone.closed[0] == 4004
    assert phone.texts == [], "nothing kept for the absent phone is handed over"
    assert not phone.got("joined")
    # 15:05:54 - Accept.
    r = await _answer(client, room, seller)
    assert r.status_code == 410, r.text
    assert (await call_state.get_session(room)).state == CallState.missed
    assert _pushes(fcm, "call_over", room) == []
    # And the ordinary socket a notification's Accept would open.
    joined, joined_task = await _open(room, seller)
    assert joined.closed and joined.closed[0] == 4004
    await asyncio.wait_for(asyncio.gather(phone_task, joined_task), timeout=5)


@pytest.mark.asyncio
async def test_a_hang_up_is_never_kept_for_a_phone_that_is_not_there(memory_hub):
    room = f"room-{uuid.uuid4().hex[:10]}"
    envelope = await memory_hub.publish_signal(room, "caller", "c1", '{"type":"hangup"}',
                                               "hangup", "callee")
    assert envelope.get("dropped") == "recipient_absent"
    await memory_hub.publish_signal(room, "caller", "c1", '{"type":"ice"}', "ice", "callee")
    kept = await memory_hub.drain_buffer(room, "callee")
    assert [e["msg_type"] for e in kept] == ["ice"], "candidates are still kept; hang-ups never"


@pytest.mark.asyncio
async def test_a_hang_up_is_never_kept_on_redis_either(monkeypatch):
    import os
    url = os.getenv("REDIS_URL", "")
    if not url:
        pytest.skip("REDIS_URL not set")
    hub = CallSignalingHub(instance_id=f"test-{uuid.uuid4().hex[:6]}", redis_url=url)
    room = f"room-{uuid.uuid4().hex[:10]}"
    try:
        await hub.publish_signal(room, "caller", "c1", '{"type":"hangup"}', "hangup", "callee")
        await hub.publish_signal(room, "caller", "c1", '{"type":"ice"}', "ice", "callee")
        assert await hub.clear_buffers(room, ["caller", "callee"]) == 1
        assert await hub.drain_buffer(room, "callee") == []
    finally:
        await hub.close()


# ── Answer and alert after the end: 410 ──────────────────────────────────────

@pytest.mark.asyncio
async def test_answering_after_the_caller_cancelled_is_refused(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _attempt()
    room = await _initiate(client, buyer, listing_id, attempt)
    caller_socket = _Listener()
    calls._rooms.setdefault(room, {})[buyer] = caller_socket
    try:
        assert (await _cancel(client, buyer, attempt)).json()["outcome"] == "cancelled"
        r = await _answer(client, room, seller)
        assert r.status_code == 410, r.text
        assert caller_socket.got("callee_answered") == [], "the caller is not told a lie"
        await _settled()
        assert _pushes(fcm, "call_over", room) == [], "nobody answered: no ring-over"
        assert len(_pushes(fcm, "missed_call", room)) == 1
        assert (await call_state.get_session(room)).state == CallState.missed
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_a_ring_report_after_the_caller_cancelled_is_refused(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _attempt()
    room = await _initiate(client, buyer, listing_id, attempt)
    caller_socket = _Listener()
    calls._rooms.setdefault(room, {})[buyer] = caller_socket
    try:
        await _cancel(client, buyer, attempt)
        r = await _alerted(client, room, seller)
        assert r.status_code == 410, r.text
        assert caller_socket.got("callee_ringing") == []
        session = await call_state.get_session(room)
        assert session.state == CallState.missed and session.callee_alerted is False
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_answering_twice_is_one_answer(client, fcm):
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    caller_socket = _Listener()
    calls._rooms.setdefault(room, {})[buyer] = caller_socket
    try:
        first, again = await asyncio.gather(_answer(client, room, seller),
                                            _answer(client, room, seller))
        assert (first.status_code, again.status_code) == (200, 200)
        assert len(caller_socket.got("callee_answered")) == 1
    finally:
        calls._rooms.pop(room, None)


# ── The database refusing clients never keeps a call alive ────────────────────

@pytest.mark.asyncio
async def test_a_hang_up_while_the_database_refuses_still_ends_the_call(client, fcm, monkeypatch):
    """The incident's likeliest path: the caller's hang-up reached the server
    while Supabase admitted no more clients. The call is over at once; its
    card follows when the database takes it."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    monkeypatch.setattr(calls, "CALL_CARD_RETRY_DELAYS_SECONDS", (0.05, 0.1))
    real = calls.AsyncSessionLocal
    refusals = {"left": 1}

    def refusing():
        if refusals["left"] > 0:
            refusals["left"] -= 1
            raise _refused()
        return real()

    monkeypatch.setattr(calls, "AsyncSessionLocal", refusing)
    caller, caller_task = await _open(room, buyer)
    caller.say({"type": "hangup", "room_id": room})
    await asyncio.wait_for(caller_task, timeout=5)

    assert (await call_state.get_session(room)).state == CallState.missed, (
        "over the moment the hang-up arrived, database or not")
    assert (await _answer(client, room, seller)).status_code == 410
    assert (await client.get("/calls/incoming", headers=_auth(seller))).json() == {"has_call": False}

    await _settled()
    assert await _cards(listing_id) == ["cancelled"], "written once the database took it"
    assert len(_pushes(fcm, "missed_call", room)) == 1


@pytest.mark.asyncio
async def test_a_logged_result_whose_card_cannot_be_written_still_ends_the_call(
        client, fcm, monkeypatch):
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    monkeypatch.setattr(calls, "CALL_CARD_RETRY_DELAYS_SECONDS", (0.05,))

    real_thread_of = calls._thread_of
    failures = {"left": 1}

    async def thread_of(db, session):
        if failures["left"] > 0:
            failures["left"] -= 1
            raise _refused()
        return await real_thread_of(db, session)

    monkeypatch.setattr(calls, "_thread_of", thread_of)
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room, "outcome": "cancelled"})
    assert r.status_code == 200, r.text
    assert r.json()["card"] == "pending"
    assert (await call_state.get_session(room)).state == CallState.missed
    await _settled()
    assert await _cards(listing_id) == ["cancelled"]


# ── Answer and cancel crossing: one outcome ──────────────────────────────────

@pytest.mark.asyncio
async def test_an_accept_that_loses_the_race_to_a_cancel_is_refused(client, fcm, monkeypatch):
    store = redis_store()
    if store is None:
        pytest.skip("the race is between Redis writes")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _attempt()
    room = await _initiate(client, buyer, listing_id, attempt)
    held = gate(store, room, matches=lambda s: s.get("answered") is True,
                monkeypatch=monkeypatch)
    answered, cancelled = await interleave(
        held,
        slow=lambda: _answer(client, room, seller),
        fast=lambda: _cancel(client, buyer, attempt),
    )
    assert cancelled.json()["outcome"] == "cancelled"
    assert answered.status_code == 410, answered.text
    await _settled()
    assert await _cards(listing_id) == ["cancelled"]
    assert len(_pushes(fcm, "missed_call", room)) == 1
    assert _pushes(fcm, "call_over", room) == []


@pytest.mark.asyncio
async def test_a_cancel_that_loses_the_race_to_an_accept_ends_an_answered_call(
        client, fcm, monkeypatch):
    store = redis_store()
    if store is None:
        pytest.skip("the race is between Redis writes")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _attempt()
    room = await _initiate(client, buyer, listing_id, attempt)
    held = gate(store, room, matches=lambda s: s.get("state") == "missed",
                monkeypatch=monkeypatch)
    cancelled, answered = await interleave(
        held,
        slow=lambda: _cancel(client, buyer, attempt),
        fast=lambda: _answer(client, room, seller),
    )
    assert answered.status_code == 200
    assert cancelled.json()["outcome"] == "failed_to_connect", (
        "answered first: the caller giving up is a call that failed to connect")
    await _settled()
    assert await _cards(listing_id) == ["failed_to_connect"]
    assert _pushes(fcm, "missed_call", room) == [], "they answered: nothing was missed"
    assert (await call_state.get_session(room)).state == CallState.failed


@pytest.mark.asyncio
async def test_accept_and_cancel_at_once_always_have_one_outcome(client, fcm):
    """Unforced, many times: whichever lands first, exactly one of the two
    stands, and the card and pushes agree with it."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    for _ in range(6):
        attempt = _attempt()
        room = await _initiate(client, buyer, listing_id, attempt)
        answered, cancelled = await asyncio.gather(
            _answer(client, room, seller), _cancel(client, buyer, attempt))
        await _settled()
        outcome = cancelled.json()["outcome"]
        if answered.status_code == 200:
            assert outcome == "failed_to_connect"
            assert _pushes(fcm, "missed_call", room) == []
        else:
            assert answered.status_code == 410 and outcome == "cancelled"
            assert len(_pushes(fcm, "missed_call", room)) == 1
        assert call_state.is_terminal((await call_state.get_session(room)).state)
    cards = await _cards(listing_id)
    assert len(cards) == 6, "one card per call, never two"


# ── The no-answer watchdog and the caller's cancel ───────────────────────────

@pytest.mark.asyncio
async def test_the_watchdog_and_a_cancel_crossing_leave_one_card(client, fcm, monkeypatch):
    store = redis_store()
    if store is None:
        pytest.skip("the race is between Redis writes")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _attempt()
    room = await _initiate(client, buyer, listing_id, attempt)
    # The watchdog's "missed" waits while the caller's cancel lands.
    held = gate(store, room, matches=lambda s: s.get("state") == "missed",
                monkeypatch=monkeypatch)
    settled, cancelled = await interleave(
        held,
        slow=lambda: calls.ring_watchdog_tick(now=time.time() + 3600),
        fast=lambda: _cancel(client, buyer, attempt),
    )
    await _settled()
    assert cancelled.json()["outcome"] == "cancelled"
    assert await _cards(listing_id) == ["cancelled"], "one card, the cancel's"
    assert len(_pushes(fcm, "missed_call", room)) == 1, "one missed-call push"


@pytest.mark.asyncio
async def test_the_watchdog_and_a_cancel_at_once_never_duplicate(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    rooms = []
    for _ in range(4):
        attempt = _attempt()
        room = await _initiate(client, buyer, listing_id, attempt)
        rooms.append(room)
        await asyncio.gather(calls.ring_watchdog_tick(now=time.time() + 3600),
                             _cancel(client, buyer, attempt))
    await _settled()
    assert len(await _cards(listing_id)) == 4, "one card per call"
    for room in rooms:
        assert len(_pushes(fcm, "missed_call", room)) == 1


# ── A stale socket's signals never reach the call ────────────────────────────

@pytest.mark.asyncio
async def test_a_replaced_socket_cannot_replay_its_old_offer_into_the_call(client, fcm):
    """The caller's first socket sent an offer while the callee was away,
    then reconnected with a new one. When the callee joins, the old socket's
    offer is not handed over; the live socket's offer, sent on `ready`, is."""
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    assert (await _answer(client, room, seller)).status_code == 200
    first, first_task = await _open(room, buyer)
    first.say({"type": "offer", "sdp": "v=0 old offer", "offer_id": "old"})
    for _ in range(20):
        await asyncio.sleep(0.005)
    second, second_task = await _open(room, buyer)       # the reconnect
    await asyncio.wait_for(first_task, timeout=5)
    assert first.closed and first.closed[0] == 4009

    callee, callee_task = await _open(room, seller)
    await _until(lambda: second.got("ready"))
    assert callee.relayed("offer") == [], "the replaced socket's offer is gone with it"
    second.say({"type": "offer", "sdp": "v=0 live offer", "offer_id": "live"})
    await _until(lambda: callee.relayed("offer"))
    assert [o["offer_id"] for o in callee.relayed("offer")] == ["live"]
    second.say({"type": "hangup"})
    callee.drop()
    await asyncio.wait_for(asyncio.gather(second_task, callee_task), timeout=5)


@pytest.mark.asyncio
async def test_a_caller_reconnecting_while_it_rings_does_not_cancel_its_call(
        client, fcm, memory_hub, monkeypatch):
    """The old socket's teardown, woken by its replacement, decided whether
    it was the last one in the room by whether the slot was still its own -
    and the new socket took the slot only after a round trip to Redis. In
    that gap the teardown found the room empty and cancelled the call under
    the phone reconnecting to it."""
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    first, first_task = await _open(room, buyer)
    real_peers = memory_hub.distributed_peers

    async def slow_peers(room_id):
        await asyncio.sleep(0.05)  # Redis, across the network
        return await real_peers(room_id)

    monkeypatch.setattr(memory_hub, "distributed_peers", slow_peers)
    second, second_task = await _open(room, buyer)
    await asyncio.wait_for(first_task, timeout=5)
    for _ in range(30):
        await asyncio.sleep(0.01)
    assert first.closed and first.closed[0] == 4009
    assert (await call_state.get_session(room)).state == CallState.ringing, (
        "a reconnect is not the caller leaving")
    assert await _cards(listing_id) == []
    assert second.closed is None
    second.say({"type": "hangup"})
    await asyncio.wait_for(second_task, timeout=5)
    assert (await call_state.get_session(room)).state == CallState.missed


@pytest.mark.asyncio
async def test_signals_from_the_live_socket_are_still_replayed(client, fcm):
    """What the buffer is for: the caller's candidates, trickled while the
    callee's socket was briefly down, reach it when it comes back."""
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    await _answer(client, room, seller)
    caller, caller_task = await _open(room, buyer)
    caller.say({"type": "ice", "candidate": {"candidate": "candidate:9 1 udp 1 1.2.3.4 9 typ relay"}})
    for _ in range(20):
        await asyncio.sleep(0.005)
    callee, callee_task = await _open(room, seller)
    assert [m["type"] for m in callee.texts] == ["ice"]
    caller.say({"type": "hangup"})
    callee.drop()
    await asyncio.wait_for(asyncio.gather(caller_task, callee_task), timeout=5)


@pytest.mark.asyncio
async def test_a_call_ending_while_a_socket_joins_sends_it_no_ready(client, fcm, monkeypatch):
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    caller, caller_task = await _open(room, buyer)
    real = call_state.mark_answered

    async def answered_then_hung_up(room_id):
        # The caller's hang-up lands between the callee's checks and its answer.
        await call_state.update_state(room_id, CallState.missed)
        return await real(room_id)

    monkeypatch.setattr(call_state, "mark_answered", answered_then_hung_up)
    callee, callee_task = await _open(room, seller)
    await asyncio.wait_for(callee_task, timeout=5)
    assert callee.closed and callee.closed[0] == 4004
    assert callee.got("ready") == [] and caller.got("ready") == []
    caller.drop()
    await asyncio.wait_for(caller_task, timeout=5)


# ── How far a call got, in its last line ─────────────────────────────────────

@pytest.mark.asyncio
async def test_the_end_of_a_call_says_how_far_it_got(client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()

    # Nobody answered.
    room = await _initiate(client, buyer, listing_id)
    await client.post("/calls/log-result", headers=_auth(buyer),
                      json={"room_id": room, "outcome": "cancelled"})
    [ended] = [e for e in _events(caplog, "CALL_ENDED") if e["room"] == room]
    assert (ended["stage"], ended["outcome"], ended["call_state"]) == (
        "unanswered", "cancelled", "missed")

    # Both in the room, no offer ever crossed.
    room = await _initiate(client, buyer, listing_id)
    a, a_task = await _open(room, buyer)
    b, b_task = await _open(room, seller)
    await _until(lambda: a.got("ready"))
    b.say({"type": "hangup", "reason": "failed", "detail": "no_offer"})
    await asyncio.wait_for(b_task, timeout=5)
    await client.post("/calls/log-result", headers=_auth(seller),
                      json={"room_id": room, "outcome": "failed_to_connect", "reason": "no_offer"})
    [ended] = [e for e in _events(caplog, "CALL_ENDED") if e["room"] == room]
    assert ended["stage"] == "no_offer"
    assert (ended["caller_joined"], ended["callee_joined"], ended["offer_relayed"]) == (
        True, True, False)
    a.drop()
    await asyncio.wait_for(a_task, timeout=5)

    # Up and running.
    room = await _initiate(client, buyer, listing_id)
    a, a_task = await _open(room, buyer)
    b, b_task = await _open(room, seller)
    await _until(lambda: a.got("ready"))
    a.say({"type": "offer", "sdp": "v=0 o", "offer_id": "o1"})
    await _until(lambda: b.relayed("offer"))
    b.say({"type": "answer", "sdp": "v=0 a", "offer_id": "o1"})
    await _until(lambda: a.relayed("answer"))
    a.say({"type": "state", "state": "connected"})
    for _ in range(20):
        await asyncio.sleep(0.005)
    a.say({"type": "hangup"})
    await asyncio.wait_for(a_task, timeout=5)
    await client.post("/calls/log-result", headers=_auth(buyer),
                      json={"room_id": room, "outcome": "completed", "duration_secs": 12})
    [ended] = [e for e in _events(caplog, "CALL_ENDED") if e["room"] == room]
    assert (ended["stage"], ended["outcome"]) == ("connected", "completed")
    b.drop()
    await asyncio.wait_for(b_task, timeout=5)


# ── Database connections are not held through a push ─────────────────────────

@pytest.mark.asyncio
async def test_recording_a_missed_call_gives_its_connection_back_before_the_push(
        client, fcm, monkeypatch):
    """Firebase's round trip was made with the database connection still
    checked out - a fifth of the new pool, for as long as Google took."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    sessions = []
    real_tokens_for = push_devices.tokens_for

    async def tokens_for(db, user_id, kind="fcm"):
        sessions.append(db)
        return await real_tokens_for(db, user_id, kind)

    monkeypatch.setattr(push_devices, "tokens_for", tokens_for)
    held_at_push = []
    fcm.on_send = lambda kwargs: held_at_push.append(
        (kwargs["data"].get("type"), [s.in_transaction() for s in sessions]))
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room, "outcome": "cancelled"})
    assert r.status_code == 200, r.text
    await _settled()
    missed = [held for kind, held in held_at_push if kind == "missed_call"]
    assert missed, "the missed-call push was sent"
    assert not any(missed[0]), "no database session was mid-transaction during the push"


@pytest.mark.asyncio
async def test_placing_a_call_gives_its_connection_back_before_waiting_on_the_push(
        client, fcm, monkeypatch):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    sessions = []
    real_tokens_for = push_devices.tokens_for

    async def tokens_for(db, user_id, kind="fcm"):
        sessions.append(db)
        return await real_tokens_for(db, user_id, kind)

    monkeypatch.setattr(push_devices, "tokens_for", tokens_for)
    held_at_push = []
    fcm.on_send = lambda kwargs: held_at_push.append(
        (kwargs["data"].get("type"), [s.in_transaction() for s in sessions]))
    await _initiate(client, buyer, listing_id)
    await _settled()
    [(kind, held)] = [(k, h) for k, h in held_at_push if k == "incoming_call"]
    assert held and not any(held), "the request's session was given back before Firebase"


@pytest.mark.asyncio
async def test_a_pool_with_nothing_to_give_is_a_503_not_a_500(client):
    from sqlalchemy.exc import TimeoutError as PoolTimeout

    def exhausted():
        raise PoolTimeout("QueuePool limit of size 3 overflow 2 reached, "
                          "connection timed out, timeout 10.00")

    def refused():
        raise _refused()

    _, seller, buyer = await _people()
    for failure in (exhausted, refused):
        with patch.object(database, "_session_factory", failure):
            for path in ("/negotiate/sync", f"/negotiate/inbox/{buyer}", "/calls/incoming"):
                r = await client.get(path, headers=_auth(buyer))
                assert r.status_code in (503,), f"{path} answered {r.status_code}: {r.text}"
                assert r.headers.get("retry-after") == "2"
                assert r.json()["code"] == "DB_UNAVAILABLE"


@pytest.mark.asyncio
async def test_an_ordinary_database_error_is_still_a_500():
    from sqlalchemy.exc import IntegrityError

    def broken():
        raise IntegrityError("INSERT", {}, Exception("duplicate key value"))

    async with AsyncClient(transport=ASGITransport(app=app, raise_app_exceptions=False),
                           base_url="http://test") as c:
        with patch.object(database, "_session_factory", broken):
            r = await c.get("/negotiate/sync", headers=_auth(f"u-{uuid.uuid4().hex[:6]}"))
    assert r.status_code == 500


def test_unavailable_is_told_apart_from_other_database_errors():
    from sqlalchemy.exc import IntegrityError, TimeoutError as PoolTimeout

    assert database.db_unavailable_kind(PoolTimeout("QueuePool limit reached")) == "pool_timeout"
    assert database.db_unavailable_kind(_refused()) == "refused"
    gone = OperationalError("SELECT 1", {}, ConnectionResetError("connection reset by peer"))
    assert database.db_unavailable_kind(gone) == "connection"
    assert database.db_unavailable_kind(IntegrityError("x", {}, Exception("duplicate"))) is None
    assert database.db_unavailable_kind(ValueError("EMAXCONNSESSION")) == "refused"


def test_one_process_holds_at_most_a_third_of_supabase_session_mode(monkeypatch):
    """Supabase's session-mode pooler admits 15 clients for the project; the
    defaults were 10 + 20 per process. Two replicas, side by side with the
    two of a deploy's overlap, must stay inside it with room for the
    migration job."""
    for name in ("DB_POOL_SIZE", "DB_MAX_OVERFLOW", "DB_POOL_TIMEOUT_SECONDS"):
        monkeypatch.delenv(name, raising=False)
    _, pool = database._postgres_transport_options()
    per_process = pool["pool_size"] + pool["max_overflow"]
    assert (pool["pool_size"], pool["max_overflow"]) == (3, 2)
    assert per_process * 2 <= 10, "two replicas leave a third of the 15 free"
    assert pool["pool_size"] * 4 < 15, "a deploy's four processes idle inside the limit"
    assert pool["pool_timeout"] == 10


# ── Under load: nothing lost, nothing a 500 ──────────────────────────────────

class _SmallPool:
    """At most `size` sessions at once, as a pool of that size gives them; a
    request that waits longer than `timeout` is refused the way QueuePool
    refuses it."""

    def __init__(self, factory, size: int, timeout: float):
        self._factory = factory
        self._slots = asyncio.Semaphore(size)
        self._timeout = timeout

    def __call__(self):
        return _PooledSession(self, self._factory())


class _PooledSession:
    def __init__(self, pool: _SmallPool, session):
        self._pool, self._session = pool, session

    def __getattr__(self, name):
        return getattr(self._session, name)

    async def __aenter__(self):
        from sqlalchemy.exc import TimeoutError as PoolTimeout
        try:
            await asyncio.wait_for(self._pool._slots.acquire(), timeout=self._pool._timeout)
        except asyncio.TimeoutError:
            raise PoolTimeout("QueuePool limit reached, connection timed out")
        return await self._session.__aenter__()

    async def __aexit__(self, *exc):
        try:
            return await self._session.__aexit__(*exc)
        finally:
            self._pool._slots.release()


@pytest.mark.asyncio
async def test_sync_inbox_calls_and_messages_at_once_on_a_small_pool(client, fcm, monkeypatch):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    monkeypatch.setattr(database, "_session_factory",
                        _SmallPool(database._session_factory, size=3, timeout=5.0))
    sent = []

    async def message(n):
        r = await client.post("/negotiate/direct-message", headers=_auth(buyer), json={
            "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": f"Is it still available? ({n})"})
        if r.status_code == 200:
            sent.append(r.json()["message"]["id"])
        return r

    requests = [message(n) for n in range(6)]
    requests += [client.get("/negotiate/sync", headers=_auth(seller)) for _ in range(6)]
    requests += [client.get(f"/negotiate/inbox/{seller}", headers=_auth(seller)) for _ in range(6)]
    requests += [client.get("/calls/incoming", headers=_auth(seller)) for _ in range(6)]
    requests += [client.post("/calls/initiate", headers=_auth(buyer), json={
        "listing_id": listing_id, "caller_name": "Bea Buyer", "call_type": "audio"})
        for _ in range(3)]
    answers = await asyncio.gather(*requests)
    statuses = [r.status_code for r in answers]
    assert 500 not in statuses, statuses
    assert set(statuses) <= {200, 304, 409, 503}, statuses
    await _settled()

    # Every message the sender was told was sent is there, for its recipient.
    got = []
    after = None
    while True:
        params = {"limit": 100, **({"after": after} if after else {})}
        page = (await client.get("/negotiate/sync", params=params, headers=_auth(seller))).json()
        got += [m["id"] for m in page["messages"]]
        if not page["has_more"]:
            break
        after = page["next_cursor"]
    assert set(sent) <= set(got), "a message reported sent was lost"
    # And the calls placed are calls: ringing, or replaced by the next one.
    placed = [r.json()["room_id"] for r in answers[-3:] if r.status_code == 200]
    for room in placed:
        assert await call_state.get_session(room) is not None
