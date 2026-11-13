"""A call placed is a call the caller can join, end, and read about (2026-11-13).

Reported: Person A calls, Person B's phone rings, B accepts - and both sit
on "Connecting..." until the call drops about ten seconds in, A's screen
saying "Could not start the call - please check your connection and try
again."

That sentence is the app's answer to POST /calls/initiate failing, and the
app gives that request ten seconds. The server pushed B's phone before it
answered A, so whenever the work before the answer - Redis, the database,
Firebase - ran past ten seconds, B was ringing for a call whose caller had
been told it never started, and had no room to join or hang up. B answered
into an empty room; nothing ever timed the call out (the callee's heartbeat
renewed it), and B's screen logged it "completed".

  * The caller is answered within CALL_PUSH_WAIT_SECONDS whatever the push
    does; a push that fails late is told to the caller's socket.
  * The same attempt again (client_call_id) gets the call already placed.
  * An attempt the app gave up on can be cancelled by that id: unanswered
    it stops ringing, answered it frees the callee at once.
  * An answered call whose caller never came lapses, and the heartbeat
    closes the sockets of a call that is over (4004).
  * Answered-and-never-connected is "failed_to_connect", not "completed".
  * What the phones see reaches the logs as call events, cleaned.
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
from starlette.datastructures import Headers

from api.core import call_state, message_push
from api.core.call_signaling import CallSignalingHub, _MemoryBackend
from api.core.call_state import CallState
from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.routers import calls
from api.security import create_access_token, create_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_call_setup_reliability.db"
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
    """Firebase as configured. Each send waits on `gate` when one is set,
    and answers `accept`."""

    def __init__(self):
        self.sent = []
        self.gate = None
        self.accept = True

    async def __call__(self, **kwargs):
        if self.gate is not None:
            await self.gate.wait()
        self.sent.append(kwargs)
        return calls.FcmResult(self.accept)


@pytest_asyncio.fixture
async def fcm():
    send = _Fcm()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield send
        if send.gate is not None:
            send.gate.set()
        await message_push.drain()
        await asyncio.gather(*list(calls._background), return_exceptions=True)


async def _people():
    async with AsyncSessionLocal() as db:
        seller = User(name="Xavier Bravin", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Airtel Smart Connect Home & Office WiFi",
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
    return await client.post("/calls/initiate", headers=_auth(caller), json=body)


async def _answer(client, room, callee):
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(callee, room)})
    assert r.status_code == 200, r.text


async def _cards(listing_id):
    async with AsyncSessionLocal() as db:
        return list((await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all())


def _pushes(fcm, kind, room=None):
    return [p for p in fcm.sent if p["data"].get("type") == kind
            and (room is None or p["data"].get("roomId") == room)]


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


async def _settled():
    await asyncio.gather(*list(calls._background), return_exceptions=True)
    await message_push.drain()


def _new_client_call_id() -> str:
    return f"cc{uuid.uuid4().hex}"


# ── The caller is answered whatever the push does ────────────────────────────

@pytest.mark.asyncio
async def test_a_slow_push_does_not_hold_the_callers_answer(client, fcm, monkeypatch):
    """The push took 3 seconds here; in production it, and what came before
    it, could take more than the app's 10. The caller waited for all of it."""
    monkeypatch.setattr(calls, "CALL_PUSH_WAIT_SECONDS", 0.3, raising=False)
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    fcm.gate = asyncio.Event()
    asyncio.get_running_loop().call_later(3.0, fcm.gate.set)

    started = time.monotonic()
    r = await _initiate(client, buyer, listing_id)
    elapsed = time.monotonic() - started
    assert r.status_code == 200, r.text
    assert elapsed < 1.5, f"the caller waited {elapsed:.1f}s for the callee's push"
    body = r.json()
    assert body["status"] == "sending", "not known yet - and not a no-push status"
    room = body["room_id"]
    assert (await call_state.get_session(room)).state == CallState.ringing
    assert _pushes(fcm, "incoming_call", room) == [], "still on its way"

    await asyncio.wait_for(_settled(), timeout=5)
    assert len(_pushes(fcm, "incoming_call", room)) == 1, "the callee still rings"


@pytest.mark.asyncio
async def test_a_push_that_fails_late_is_told_to_the_caller(client, fcm, monkeypatch):
    monkeypatch.setattr(calls, "CALL_PUSH_WAIT_SECONDS", 0.2, raising=False)
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    fcm.gate = asyncio.Event()
    fcm.accept = False
    # Released by itself too: a server that waits for the push before
    # answering would otherwise wait here for good.
    asyncio.get_running_loop().call_later(3.0, fcm.gate.set)

    r = await _initiate(client, buyer, listing_id)
    room = r.json()["room_id"]
    assert r.json()["status"] == "sending"
    caller_socket = _Listener()
    calls._rooms.setdefault(room, {})[buyer] = caller_socket
    try:
        fcm.gate.set()
        await asyncio.wait_for(_settled(), timeout=5)
        assert caller_socket.got("push_status") == [
            {"type": "push_status", "room_id": room, "status": "push_failed"}]
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_a_quick_push_still_reports_its_result(client, fcm):
    """Nothing changes for a healthy push: the caller hears how it went."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    r = await _initiate(client, buyer, listing_id)
    assert r.json()["status"] == "sent"
    fcm.accept = False
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    assert (await _initiate(client, buyer, listing_id)).json()["status"] == "push_failed"


# ── The same attempt again ───────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_retried_setup_gets_the_call_already_placed(client, fcm):
    """The app's request timed out after the server had placed the call: its
    retry used to place a second one, superseding the first - which the
    callee might be answering at that moment."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _new_client_call_id()

    first = await _initiate(client, buyer, listing_id, client_call_id=attempt)
    room = first.json()["room_id"]
    again = await _initiate(client, buyer, listing_id, client_call_id=attempt)
    assert again.status_code == 200, again.text
    assert again.json()["room_id"] == room
    assert again.json().get("replayed") is True
    assert again.json()["call_token"], "a token to join it with"
    await _settled()
    assert len(_pushes(fcm, "incoming_call", room)) == 1, "the callee rings once"
    assert (await call_state.get_session(room)).state == CallState.ringing, "not superseded"


@pytest.mark.asyncio
async def test_another_attempt_is_another_call(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    first = (await _initiate(client, buyer, listing_id, _new_client_call_id())).json()["room_id"]
    second = (await _initiate(client, buyer, listing_id, _new_client_call_id())).json()["room_id"]
    assert first != second, "a redial is a new call, as before"


# ── An attempt the app gave up on ────────────────────────────────────────────

@pytest.mark.asyncio
async def test_cancelling_an_unanswered_setup_stops_the_ring(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _new_client_call_id()
    room = (await _initiate(client, buyer, listing_id, attempt)).json()["room_id"]
    ringing_phone = _Listener()
    calls._rooms.setdefault(room, {})[seller] = ringing_phone
    try:
        r = await client.post("/calls/cancel-setup", headers=_auth(buyer),
                              json={"client_call_id": attempt, "reason": "setup_timeout"})
        assert r.status_code == 200, r.text
        assert r.json() == {"status": "cancelled", "room_id": room, "outcome": "cancelled"}
        await _settled()
        assert await _cards(listing_id) == ["cancelled"]
        assert len(_pushes(fcm, "missed_call", room)) == 1, "the ring comes down as a missed call"
        assert {"type": "hangup", "reason": "cancelled"} in ringing_phone.jsons
        assert call_state.is_terminal((await call_state.get_session(room)).state)
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_cancelling_an_answered_setup_frees_the_callee(client, fcm):
    """The 2026-11-13 call: answered, and its caller had already given up."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _new_client_call_id()
    room = (await _initiate(client, buyer, listing_id, attempt)).json()["room_id"]
    await _answer(client, room, seller)
    callee_socket = _Listener()
    calls._rooms.setdefault(room, {})[seller] = callee_socket
    try:
        r = await client.post("/calls/cancel-setup", headers=_auth(buyer),
                              json={"client_call_id": attempt, "reason": "setup_timeout"})
        assert r.json()["outcome"] == "failed_to_connect"
        await _settled()
        assert await _cards(listing_id) == ["failed_to_connect"]
        assert _pushes(fcm, "missed_call", room) == [], "they answered: nothing was missed"
        assert {"type": "hangup", "reason": "failed"} in callee_socket.jsons, \
            "the callee hears it now, not after a timeout"
        assert (await call_state.get_session(room)).state == CallState.failed
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_cancelling_is_idempotent_and_never_someone_elses(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    attempt = _new_client_call_id()
    room = (await _initiate(client, buyer, listing_id, attempt)).json()["room_id"]
    # The callee can't cancel the caller's attempt, even knowing its id.
    r = await client.post("/calls/cancel-setup", headers=_auth(seller),
                          json={"client_call_id": attempt})
    assert r.json() == {"status": "unknown"}
    assert (await call_state.get_session(room)).state == CallState.ringing
    first = await client.post("/calls/cancel-setup", headers=_auth(buyer),
                              json={"client_call_id": attempt})
    second = await client.post("/calls/cancel-setup", headers=_auth(buyer),
                               json={"client_call_id": attempt})
    assert first.json()["status"] == "cancelled"
    assert second.json() == {"status": "over", "room_id": room}
    nothing = await client.post("/calls/cancel-setup", headers=_auth(buyer),
                                json={"client_call_id": _new_client_call_id()})
    assert nothing.json() == {"status": "unknown"}


# ── Nobody is left on "Connecting..." ────────────────────────────────────────

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
            self.say({"type": "pong"})  # a live phone answers the heartbeat

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


async def _until(condition, timeout: float = 5.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not condition():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.01)


async def _open(room: str, uid: str):
    ws = FakeSocket()
    task = asyncio.create_task(calls._signaling(ws, room, create_call_token(uid, room)))
    await _until(lambda: ws.accepted or ws.closed is not None or task.done())
    for _ in range(20):
        await asyncio.sleep(0.005)
    return ws, task


async def _ringing_call(ttl_seconds: int = call_state.ESTABLISHMENT_SESSION_TTL_SECONDS):
    room = f"room-{uuid.uuid4().hex[:10]}"
    caller, callee = f"buyer-{uuid.uuid4().hex[:8]}", f"seller-{uuid.uuid4().hex[:8]}"
    await call_state.create_session(room, caller, callee, f"listing-{uuid.uuid4().hex[:6]}",
                                    "audio", "Bea Buyer", ttl_seconds=ttl_seconds)
    await call_state.update_state(room, CallState.ringing)
    return room, caller, callee


@pytest.mark.asyncio
async def test_a_call_that_is_over_closes_the_sockets_still_in_it(monkeypatch):
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    room, caller, callee = await _ringing_call()
    await call_state.mark_answered(room)
    ws, task = await _open(room, callee)
    assert ws.closed is None
    await call_state.update_state(room, CallState.ended)
    await _until(lambda: ws.closed is not None, timeout=3)
    assert ws.closed[0] == 4004, "the code the app ends a never-connected call on"
    await asyncio.wait_for(task, timeout=3)


@pytest.mark.asyncio
async def test_an_answered_call_whose_caller_never_came_lapses(monkeypatch):
    """The callee's own heartbeat used to renew it every 15 seconds: the
    call never ended, and the callee sat on "Connecting..." in it."""
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    monkeypatch.setattr(call_state, "ESTABLISHMENT_SESSION_TTL_SECONDS", 1)
    room, caller, callee = await _ringing_call(ttl_seconds=1)
    await call_state.mark_answered(room)
    ws, task = await _open(room, callee)  # the callee, alone in the room
    await _until(lambda: ws.closed is not None, timeout=4)
    assert ws.closed[0] == 4004
    await asyncio.wait_for(task, timeout=3)


@pytest.mark.asyncio
async def test_a_socket_hears_at_once_that_it_is_in_the_room():
    """A callee alone in the room heard nothing until the first heartbeat
    ping, 15 seconds on: until then its phone could not tell a live socket
    from one a proxy had swallowed, nor send what it had queued."""
    room, caller, callee = await _ringing_call()
    await call_state.mark_answered(room)
    ws, task = await _open(room, callee)
    assert ws.jsons[0] == {"type": "joined", "room_id": room}
    ws.drop()
    await asyncio.wait_for(task, timeout=3)


@pytest.mark.asyncio
async def test_a_call_under_way_is_not_closed_by_the_heartbeat(monkeypatch):
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    room, caller, callee = await _ringing_call()
    a, a_task = await _open(room, caller)
    b, b_task = await _open(room, callee)
    a.say({"type": "state", "state": "connected"})
    await asyncio.sleep(0.4)
    assert a.closed is None and b.closed is None
    a.say({"type": "hangup"})
    b.drop()
    await asyncio.wait_for(asyncio.gather(a_task, b_task), timeout=3)


@pytest.mark.asyncio
async def test_a_call_that_is_up_does_not_lapse_as_only_answered(monkeypatch):
    """Both phones joined, but the room-ready check missed it (two
    replicas' joins crossing), so the server still has the call `accepted`
    - which is never renewed. A phone saying the call is up has to move it
    on, or the call is closed under them once the setup window runs out."""
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    monkeypatch.setattr(call_state, "ESTABLISHMENT_SESSION_TTL_SECONDS", 1)
    monkeypatch.setattr(calls, "_joined", lambda peers, session: set())
    room, caller, callee = await _ringing_call(ttl_seconds=1)
    await call_state.mark_answered(room)
    a, a_task = await _open(room, caller)
    b, b_task = await _open(room, callee)
    assert (await call_state.get_session(room)).state == CallState.accepted
    a.say({"type": "state", "state": "connected"})
    await asyncio.sleep(1.6)
    assert a.closed is None and b.closed is None
    session = await call_state.get_session(room)
    assert session.state == CallState.connected and session.ever_connected
    a.say({"type": "hangup"})
    b.drop()
    await asyncio.wait_for(asyncio.gather(a_task, b_task), timeout=3)


@pytest.mark.asyncio
async def test_a_call_that_is_up_survives_its_session_being_lost(monkeypatch):
    """Redis restarting (or evicting the key) loses a session; the call's
    audio does not need the server, and it is not closed for it."""
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    room, caller, callee = await _ringing_call()
    a, a_task = await _open(room, caller)
    b, b_task = await _open(room, callee)
    a.say({"type": "state", "state": "connected"})
    b.say({"type": "state", "state": "connected"})
    await asyncio.sleep(0.05)
    assert (await call_state.get_session(room)).ever_connected
    await call_state.end_session(room)
    await asyncio.sleep(0.4)
    assert a.closed is None and b.closed is None
    a.drop()
    b.drop()
    await asyncio.wait_for(asyncio.gather(a_task, b_task), timeout=3)


@pytest.mark.asyncio
async def test_a_call_that_never_connected_is_closed_once_its_session_is_gone(monkeypatch):
    """With Redis, a lapsed setup window is the key expiring: gone, not
    `expired` - the 2026-11-13 callee alone in the room."""
    monkeypatch.setattr(calls, "WS_HEARTBEAT_INTERVAL_SECONDS", 0.05)
    room, caller, callee = await _ringing_call()
    await call_state.mark_answered(room)
    ws, task = await _open(room, callee)
    await call_state.end_session(room)
    await _until(lambda: ws.closed is not None, timeout=3)
    assert ws.closed[0] == 4004
    await asyncio.wait_for(task, timeout=3)


# ── What a call is recorded as ───────────────────────────────────────────────

async def _log(client, uid, room, outcome, **extra):
    return await client.post("/calls/log-result", headers=_auth(uid),
                             json={"room_id": room, "outcome": outcome, **extra})


@pytest.mark.asyncio
async def test_answered_and_never_connected_is_not_completed(client, fcm):
    """Every build until now logged a call it had pressed Accept on as
    completed - with no duration, which is how it can be told apart."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    r = await _log(client, seller, room, "completed")
    assert r.json()["outcome"] == "failed_to_connect"
    await _settled()
    assert await _cards(listing_id) == ["failed_to_connect"]
    assert _pushes(fcm, "missed_call", room) == []


@pytest.mark.asyncio
async def test_a_call_that_connected_is_completed(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    await call_state.update_state(room, CallState.connecting)
    await call_state.update_state(room, CallState.connected)
    r = await _log(client, buyer, room, "completed", duration_secs=42)
    assert r.json()["outcome"] == "completed"
    async with AsyncSessionLocal() as db:
        card = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call"))).scalar_one()
    assert (card.content, card.duration_secs) == ("completed", 42)


@pytest.mark.asyncio
async def test_a_timer_that_ran_is_believed(client, fcm):
    """A duration - even 0 - is the reporting phone's call timer, which only
    runs once connected: its "completed" stands even if the server never
    heard the connection come up (the socket was down at that moment)."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    r = await _log(client, buyer, room, "completed", duration_secs=0)
    assert r.json()["outcome"] == "completed"


@pytest.mark.asyncio
async def test_failed_to_connect_is_recorded_and_told_to_the_other_side(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    caller_socket = _Listener()
    calls._rooms.setdefault(room, {})[buyer] = caller_socket
    try:
        r = await _log(client, seller, room, "failed_to_connect", reason="no_offer")
        assert r.status_code == 200, r.text
        assert {"type": "hangup", "reason": "failed"} in caller_socket.jsons
    finally:
        calls._rooms.pop(room, None)
    await _settled()
    history = (await client.get("/calls/history", headers=_auth(seller))).json()["calls"]
    mine = [c for c in history if c["listing_id"] == listing_id]
    assert [(c["outcome"], c["missed"]) for c in mine] == [("failed_to_connect", False)]
    assert _pushes(fcm, "missed_call", room) == []


@pytest.mark.asyncio
async def test_an_unknown_outcome_is_still_refused(client, fcm):
    listing_id, seller, buyer = await _people()
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    assert (await _log(client, buyer, room, "succeeded")).status_code == 400


# ── What the phones see, in the logs ─────────────────────────────────────────

def _events(caplog, name):
    return [r.call_event for r in caplog.records
            if getattr(r, "call_event", None) and r.call_event["event"] == name]


@pytest.mark.asyncio
async def test_a_phones_diagnostics_reach_the_log_cleaned_and_unrelayed(caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    room, caller, callee = await _ringing_call()
    a, a_task = await _open(room, caller)
    b, b_task = await _open(room, callee)
    a.say({"type": "diag", "event": "ICE_CONNECTION_FAILED", "call_state": "calling",
           "ws": "open", "ice_gathering": "complete", "ice": "failed", "pc": "failed",
           "path": "-", "reason": "ice_failed",
           "error": "PlatformException(addIceCandidate, 196.201.214.10 rejected: a=candidate:1 1 udp ...)",
           "relay": 0, "received_relay": 0, "seq": 7, "client_ts": "2026-11-13T12:33:05.101Z",
           "sdp": "v=0 o=- 1 2 IN IP4 10.0.0.1", "token": "secret"})
    a.say({"type": "diag", "event": "MADE_UP_EVENT"})
    for _ in range(20):
        await asyncio.sleep(0.005)
    [event] = _events(caplog, "ICE_CONNECTION_FAILED")
    assert (event["room"], event["role"], event["source"]) == (room, "caller", "client")
    assert (event["ice"], event["pc"], event["reason"], event["relay"]) == ("failed", "failed", "ice_failed", 0)
    assert "196.201" not in event["error"] and "candidate:" not in event["error"]
    assert "sdp" not in event and "token" not in event, "only listed fields are kept"
    assert not _events(caplog, "MADE_UP_EVENT")
    assert [m for m in b.texts if m.get("type") == "diag"] == [], "never relayed"
    line = next(r.getMessage() for r in caplog.records if "ICE_CONNECTION_FAILED" in r.getMessage())
    assert line.startswith("[call-event] event=ICE_CONNECTION_FAILED room=")
    a.say({"type": "hangup"})
    b.drop()
    await asyncio.wait_for(asyncio.gather(a_task, b_task), timeout=3)


@pytest.mark.asyncio
async def test_a_socket_cannot_flood_the_log(caplog, monkeypatch):
    caplog.set_level(logging.INFO, logger="api.call_events")
    monkeypatch.setattr(calls, "CALL_EVENTS_MAX_PER_SOCKET", 5)
    room, caller, callee = await _ringing_call()
    a, a_task = await _open(room, caller)
    for i in range(9):
        a.say({"type": "diag", "event": "ICE_CANDIDATE_GATHERED", "seq": i})
    for _ in range(30):
        await asyncio.sleep(0.005)
    assert len(_events(caplog, "ICE_CANDIDATE_GATHERED")) == 5
    a.drop()
    await asyncio.wait_for(a_task, timeout=3)


@pytest.mark.asyncio
async def test_a_call_leaves_its_story_in_the_log(caplog):
    """Joined, both in, the connection reported, a failure hung up - every
    step one event naming the room and the side."""
    caplog.set_level(logging.INFO, logger="api.call_events")
    room, caller, callee = await _ringing_call()
    a, a_task = await _open(room, caller)
    b, b_task = await _open(room, callee)
    a.say({"type": "offer", "sdp": "v=0 offer", "offer_id": "o1"})
    b.say({"type": "answer", "sdp": "v=0 answer", "offer_id": "o1"})
    b.say({"type": "state", "state": "failed"})
    b.say({"type": "hangup", "reason": "failed", "detail": "ice_failed"})
    await asyncio.wait_for(b_task, timeout=3)
    a.drop()
    await asyncio.wait_for(a_task, timeout=3)

    joined = _events(caplog, "WEBSOCKET_CONNECTED")
    assert [(e["role"], e["peer_in_room"]) for e in joined] == [("caller", False), ("callee", True)]
    assert [e["role"] for e in _events(caplog, "PEER_JOINED")] == ["callee"]
    assert [e["role"] for e in _events(caplog, "SDP_OFFER_RELAYED")] == ["caller"]
    assert [e["delivered"] for e in _events(caplog, "SDP_ANSWER_RELAYED")] == [1]
    assert [(e["role"], e["pc"]) for e in _events(caplog, "WEBRTC_FAILED")] == [("callee", "failed")]
    [hangup] = _events(caplog, "CALL_HANGUP")
    assert (hangup["role"], hangup["reason"], hangup["detail"]) == ("callee", "failed", "ice_failed")
    left = {e["role"]: e for e in _events(caplog, "WEBSOCKET_DISCONNECTED")}
    assert left["callee"]["reason"] == "hangup:failed"
    assert left["caller"]["offers"] == 1 and left["caller"]["connected"] is False
    assert (await call_state.get_session(room)).state == CallState.failed


@pytest.mark.asyncio
async def test_diagnostics_after_the_call_come_in_over_http(client, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    room, caller, callee = await _ringing_call()
    events = [
        {"event": "TURN_CREDENTIAL_FAILURE", "reason": "timeout", "call_state": "connecting"},
        {"event": "WEBRTC_FAILED", "reason": "ice_failed", "pc": "failed"},
        {"event": "NOT_A_THING"},
        "not an object",
    ]
    r = await client.post(f"/calls/{room}/events",
                          json={"call_token": create_call_token(callee, room), "events": events})
    assert r.json() == {"logged": 2}
    [turn] = _events(caplog, "TURN_CREDENTIAL_FAILURE")
    assert (turn["role"], turn["source"], turn["transport"]) == ("callee", "client", "http")

    # The call's token expired a minute ago: its report is still taken.
    from jose import jwt
    from api.security import ALGORITHM, SECRET_KEY
    old = jwt.encode({"sub": callee, "room_id": room, "type": "call",
                      "exp": int(time.time()) - 60}, SECRET_KEY, algorithm=ALGORITHM)
    r = await client.post(f"/calls/{room}/events",
                          json={"call_token": old, "events": events[:1]})
    assert r.json() == {"logged": 1}
    # Never for another call's room.
    other = create_call_token(callee, "another-room")
    r = await client.post(f"/calls/{room}/events", json={"call_token": other, "events": events})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_a_failed_relay_request_is_in_the_log(client, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    room, caller, callee = await _ringing_call()
    # No Cloudflare credentials in the test environment: the relay fails.
    r = await client.post(f"/calls/{room}/turn-credentials",
                          json={"call_token": create_call_token(caller, room)})
    assert r.status_code == 503
    [failure] = _events(caplog, "TURN_CREDENTIAL_FAILURE")
    assert (failure["room"], failure["role"], failure["reason"]) == (room, "caller", "relay_unavailable")


@pytest.mark.asyncio
async def test_initiating_logs_how_long_the_caller_waited(client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id, _new_client_call_id())).json()["room_id"]
    [started] = _events(caplog, "CALL_INITIATED")
    assert started["room"] == room and started["role"] == "caller"
    assert isinstance(started["setup_ms"], int) and started["push"] == "sent"
    [pushed] = _events(caplog, "CALL_PUSH_RESULT")
    assert pushed["push"] == "sent" and pushed["late"] is False
