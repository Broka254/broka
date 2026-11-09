"""Answering without "Connecting..." (2026-11-09).

Reported from phones: when someone calls and the other person answers, the
call shows "Connecting..." for 3 to 5 seconds before the voices come
through. After Accept the callee's phone used to open its socket, join the
room, wait for `ready`, receive the offer, answer it, and only then start
ICE and DTLS - five or six round trips on mobile data.

A ringing phone now waits in the call's room (/calls/ws/{room}/ringing, a
"standby" socket): the call is negotiated while it rings, and Accept is one
`accept` frame on a socket that is already there. These tests drive the
signaling handler with a stand-in socket and check what each side is told:

  * a standby socket never answers the call, and never ends it by leaving;
  * of what it sends before Accept only its answer and ICE reach the caller;
  * Accept on it is answered with `ready` at once, naming the connection
    the phone negotiated (so the caller keeps it, and starts again for any
    other phone);
  * the caller leaving an unanswered call stops the ringing phone at once;
  * only the callee, only while it rings, and only with the switch on.
"""
import asyncio
import json
import random
import uuid
from types import SimpleNamespace

import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from starlette.datastructures import Headers

from api.core import call_state
from api.core.call_signaling import CallSignalingHub, _MemoryBackend
from api.core.call_state import CallState
from api.core.config import settings
from api.database import init_db, reset_engine
from api.routers import calls
from api.security import create_call_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_call_answer_while_ringing.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest.fixture(autouse=True)
def memory_hub(monkeypatch):
    """A hub of this test's own: the module-level one is built once per
    process, and in CI on Redis Pub/Sub, whose listener is bound to
    whichever test's event loop first started it."""
    hub = CallSignalingHub(instance_id=f"test-{uuid.uuid4().hex[:6]}", backend=_MemoryBackend())
    hub.set_handler(calls._deliver_remote)
    monkeypatch.setattr(calls, "signaling_hub", hub)
    return hub


class FakeSocket:
    """As much of a Starlette WebSocket as calls._signaling uses."""

    def __init__(self):
        # Every socket its own address: the pre-auth limiter is per IP.
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

    def got(self, kind: str) -> list:
        return [m for m in self.jsons if m.get("type") == kind]

    def relayed(self, kind: str) -> list:
        return [m for m in self.texts if m.get("type") == kind]


async def _until(condition, timeout: float = 5.0):
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not condition():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.01)


async def _eventually(check, timeout: float = 5.0):
    """`check` is a coroutine function: the session lives in Redis in CI."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + timeout
    while not await check():
        if loop.time() > deadline:
            raise AssertionError("timed out waiting")
        await asyncio.sleep(0.02)


async def _quiet():
    for _ in range(30):
        await asyncio.sleep(0.005)


async def _call():
    room = f"room-{uuid.uuid4().hex[:10]}"
    caller, callee = f"buyer-{uuid.uuid4().hex[:8]}", f"seller-{uuid.uuid4().hex[:8]}"
    await call_state.create_session(room, caller, callee, f"listing-{uuid.uuid4().hex[:6]}",
                                    "audio", "Bea Buyer")
    await call_state.update_state(room, CallState.ringing)
    return room, caller, callee


class Line:
    """One open socket and the handler task behind it."""

    def __init__(self, ws: FakeSocket, task: asyncio.Task):
        self.ws, self.task = ws, task

    async def hang_up(self):
        self.ws.drop()
        await asyncio.wait_for(self.task, timeout=5)


async def _open(room: str, uid: str, *, ringing: bool = False, peer: str = "") -> Line:
    ws = FakeSocket()
    task = asyncio.create_task(calls._signaling(
        ws, room, create_call_token(uid, room), peer=peer, ringing=ringing))
    await _until(lambda: ws.accepted or ws.closed is not None or task.done())
    await _quiet()
    return Line(ws, task)


@pytest.mark.asyncio
async def test_a_ringing_phone_waits_in_the_room_without_answering():
    room, caller, callee = await _call()
    me = await _open(room, caller)
    phone = await _open(room, callee, ringing=True, peer="pc-1")

    await _until(lambda: me.ws.got("ringing_ready"))
    assert me.ws.got("ringing_ready")[0]["peer"] == "pc-1"
    session = await call_state.get_session(room)
    assert session.state == CallState.ringing, "waiting in the room is not answering"
    assert session.answered is False
    assert me.ws.got("ready") == [] and phone.ws.got("ready") == []

    await phone.hang_up()
    await me.hang_up()


@pytest.mark.asyncio
async def test_a_caller_joining_after_the_phone_rings_is_told_at_once():
    room, caller, callee = await _call()
    phone = await _open(room, callee, ringing=True, peer="pc-2")
    me = await _open(room, caller)
    await _until(lambda: me.ws.got("ringing_ready"))
    assert me.ws.got("ringing_ready")[0]["peer"] == "pc-2"
    assert me.ws.got("ready") == []
    await phone.hang_up()
    await me.hang_up()


@pytest.mark.asyncio
async def test_the_offer_reaches_the_ringing_phone_and_only_its_answer_comes_back():
    room, caller, callee = await _call()
    me = await _open(room, caller)
    phone = await _open(room, callee, ringing=True, peer="pc-3")

    me.ws.say({"type": "offer", "room_id": room, "sdp": "v=0 offer", "offer_id": "o1"})
    await _until(lambda: phone.ws.relayed("offer"))
    phone.ws.say({"type": "answer", "room_id": room, "sdp": "v=0 answer", "offer_id": "o1"})
    phone.ws.say({"type": "ice", "room_id": room, "candidate": {"candidate": "c"}})
    await _until(lambda: me.ws.relayed("ice"))
    assert me.ws.relayed("answer")[0]["offer_id"] == "o1"

    # Not the call's yet: its connection state is not the session's, and
    # a camera or a fresh offer from it goes nowhere.
    phone.ws.say({"type": "state", "state": "connected"})
    phone.ws.say({"type": "video_state", "enabled": False})
    phone.ws.say({"type": "offer", "sdp": "v=0 from the callee"})
    await _quiet()
    assert (await call_state.get_session(room)).state == CallState.ringing
    assert me.ws.relayed("video_state") == []
    assert len(me.ws.relayed("offer")) == 0

    await phone.hang_up()
    await me.hang_up()


@pytest.mark.asyncio
async def test_accept_on_the_ringing_socket_puts_the_call_through():
    room, caller, callee = await _call()
    me = await _open(room, caller)
    phone = await _open(room, callee, ringing=True, peer="pc-4")

    phone.ws.say({"type": "accept", "room_id": room})
    await _until(lambda: me.ws.got("ready") and phone.ws.got("ready"))
    assert me.ws.got("ready")[0]["peer"] == "pc-4", (
        "names the connection negotiated while it rang, so the caller keeps it")
    session = await call_state.get_session(room)
    assert session.answered is True
    assert session.state == CallState.connecting

    # Joined now: its state reports are the call's.
    phone.ws.say({"type": "state", "state": "connected"})

    async def connected():
        return (await call_state.get_session(room)).state == CallState.connected
    await _eventually(connected)

    await phone.hang_up()
    await me.hang_up()


@pytest.mark.asyncio
async def test_a_ringing_phone_leaving_never_ends_the_call():
    # It may still be answered from the notification, or on another phone.
    room, caller, callee = await _call()
    me = await _open(room, caller)
    phone = await _open(room, callee, ringing=True, peer="pc-5")

    await phone.hang_up()
    await _until(lambda: me.ws.got("ringing_left"))
    assert me.ws.got("ringing_left")[0]["peer"] == "pc-5"
    assert me.ws.got("peer_state") == [], "it is not a dropped peer: it never joined"
    assert (await call_state.get_session(room)).state == CallState.ringing

    # A hang-up from it before Accept is it leaving, not the call ending.
    phone = await _open(room, callee, ringing=True, peer="pc-6")
    phone.ws.say({"type": "hangup", "room_id": room})
    await asyncio.wait_for(phone.task, timeout=5)
    assert me.ws.relayed("hangup") == []
    assert (await call_state.get_session(room)).state == CallState.ringing

    await me.hang_up()


@pytest.mark.asyncio
async def test_the_caller_leaving_stops_the_ringing_phone_at_once():
    room, caller, callee = await _call()
    me = await _open(room, caller)
    phone = await _open(room, callee, ringing=True, peer="pc-7")

    await me.hang_up()
    await _until(lambda: phone.ws.got("hangup"))
    assert phone.ws.got("hangup")[0]["reason"] == "cancelled"
    session = await call_state.get_session(room)
    assert call_state.is_terminal(session.state), "an unanswered call the caller left is over"

    await phone.hang_up()


@pytest.mark.asyncio
async def test_only_the_callee_and_only_while_it_rings():
    room, caller, callee = await _call()
    me = await _open(room, caller, ringing=True)
    assert me.ws.closed and me.ws.closed[0] == 4010
    assert not me.ws.accepted

    await call_state.mark_answered(room)
    phone = await _open(room, callee, ringing=True)
    assert phone.ws.closed and phone.ws.closed[0] == 4010, "answered: it joins the ordinary way"


@pytest.mark.asyncio
async def test_the_switch_turns_it_off():
    # Settings are frozen: flipped the way conftest.py's fixtures do.
    object.__setattr__(settings, "call_ringing_preconnect", False)
    try:
        room, _, callee = await _call()
        phone = await _open(room, callee, ringing=True)
        assert phone.ws.closed and phone.ws.closed[0] == 4010
    finally:
        object.__setattr__(settings, "call_ringing_preconnect", True)


@pytest.mark.asyncio
async def test_the_callees_first_join_is_not_announced_as_a_reconnect():
    # Every call's `ready` used to come after a "peer_state: reconnected"
    # broadcast (and a Redis publish), because the caller was already in
    # the room when the callee first joined.
    room, caller, callee = await _call()
    me = await _open(room, caller)
    them = await _open(room, callee, peer="pc-8")
    await _until(lambda: me.ws.got("ready"))
    assert me.ws.got("peer_state") == []
    assert me.ws.got("ready")[0]["peer"] == "pc-8"
    await them.hang_up()
    await me.hang_up()
