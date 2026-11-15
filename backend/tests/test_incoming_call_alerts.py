"""A ring is the callee's phone saying so - and the log says what happened
(2026-11-15).

Railway, a real call: CALL_INITIATED, FCM accepted the incoming-call push,
the caller's socket joined - and then nothing from the callee's phone. No
CALLEE_ALERTED, no join; the caller gave up and the missed-call push was
accepted. The server did its part. What it could not do was say why: a push
that never reached the phone, a ring the phone refused (notifications off,
another call saved as on screen), an acknowledgement that failed four times
and a refused one (a bad or expired token) all left the same silence.

These hold:

  * FCM accepting a push is never a ring: the caller is told "Ringing" only
    after POST /alerted succeeds (CALLEE_ALERTED), "Connecting" only after
    an answer (CALL_ANSWERED).
  * Every refused acknowledgement is logged with its status and why
    (CALL_ALERT_REJECTED), the accepted one with the phone's own account of
    its attempt; a phone's CALL_RING_BLOCKED / CALL_ALERT_FAILED reports
    reach the log.
  * A call nobody's phone acknowledged still ends as a missed call - card,
    push, CALL_NO_ANSWER and CALL_MISSED - whether or not the caller's app
    is still there, and a watchdog step that fails is tried again.
  * A late acknowledgement cannot bring a call back.
"""
import asyncio
import json
import logging
import random
import time
import uuid
from types import SimpleNamespace
from unittest.mock import patch

import httpx
import pytest
import pytest_asyncio
from fastapi import WebSocketDisconnect
from httpx import ASGITransport, AsyncClient
from jose import jwt
from sqlalchemy import select
from starlette.datastructures import Headers

from api.core import call_state, message_push
from api.core.call_signaling import CallSignalingHub, _MemoryBackend
from api.core.call_state import CallState
from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.routers import calls
from api.security import ALGORITHM, SECRET_KEY, create_access_token, create_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_incoming_call_alerts.db"
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
    hub = CallSignalingHub(instance_id=f"test-{uuid.uuid4().hex[:6]}", backend=_MemoryBackend())
    hub.set_handler(calls._deliver_remote)
    monkeypatch.setattr(calls, "signaling_hub", hub)
    return hub


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


class _Fcm:
    """Firebase as configured: every send accepted, with a message id -
    which proves only that Firebase took it."""

    def __init__(self):
        self.sent = []

    async def __call__(self, **kwargs):
        self.sent.append(kwargs)
        return calls.FcmResult(True, message_id=f"projects/x/messages/{len(self.sent)}")


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


async def _initiate(client, caller, listing_id):
    r = await client.post("/calls/initiate", headers=_auth(caller), json={
        "listing_id": listing_id, "caller_name": "Bea Buyer", "call_type": "audio"})
    assert r.status_code == 200, r.text
    return r.json()["room_id"]


async def _alerted(client, room, token, **report):
    return await client.post(f"/calls/{room}/alerted", json={"call_token": token, **report})


async def _cards(listing_id):
    async with AsyncSessionLocal() as db:
        return list((await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all())


def _pushes(fcm, kind, room=None):
    return [p for p in fcm.sent if p["data"].get("type") == kind
            and (room is None or p["data"].get("roomId") == room)]


def _events(caplog, name, room=None):
    """One kind of call event - of one room, when named: the watchdog also
    sweeps rooms other test modules left ringing."""
    return [r.call_event for r in caplog.records
            if getattr(r, "call_event", None) and r.call_event["event"] == name
            and (room is None or r.call_event["room"] == room)]


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


def _expired_call_token(uid: str, room: str) -> str:
    return jwt.encode({"sub": uid, "room_id": room, "type": "call",
                       "exp": int(time.time()) - 60}, SECRET_KEY, algorithm=ALGORITHM)


# ── FCM accepting is not a ring ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_push_fcm_accepted_is_not_a_ring_until_the_phone_says_so(client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    await _settled()
    assert _pushes(fcm, "incoming_call", room), "FCM took the push"
    caller, caller_task = await _open(room, buyer)
    for _ in range(20):
        await asyncio.sleep(0.005)
    assert caller.got("callee_ringing") == [], "the caller stays on Calling…"
    assert (await call_state.get_session(room)).callee_alerted is False

    # Refused acknowledgements tell the caller nothing either.
    assert (await _alerted(client, room, "not-a-token")).status_code == 401
    assert (await _alerted(client, room, create_call_token(buyer, room))).status_code == 403
    for _ in range(10):
        await asyncio.sleep(0.005)
    assert caller.got("callee_ringing") == []

    # The callee's phone rings and says so: now, and only now.
    r = await _alerted(client, room, create_call_token(seller, room),
                       attempt=2, handler="background", previous_error="timeout",
                       push_age_ms=1800)
    assert r.status_code == 200, r.text
    await _until(lambda: bool(caller.got("callee_ringing")))
    [alerted] = _events(caplog, "CALLEE_ALERTED")
    assert (alerted["room"], alerted["correlation_id"], alerted["role"], alerted["user"]) == (
        room, room, "callee", seller)
    assert (alerted["attempt"], alerted["delivery_source"], alerted["previous_error"],
            alerted["push_age_ms"]) == (2, "background", "timeout", 1800)
    assert alerted["ts"].endswith("Z")

    # The same acknowledgement again is not a second ring.
    assert (await _alerted(client, room, create_call_token(seller, room))).status_code == 200
    assert len(_events(caplog, "CALLEE_ALERTED")) == 1
    caller.say({"type": "hangup"})
    await asyncio.wait_for(caller_task, timeout=5)
    await _settled()


# ── Every refusal, logged ───────────────────────────────────────────────────

@pytest.mark.asyncio
@pytest.mark.parametrize("case", ["invalid_token", "token_expired", "wrong_room",
                                  "not_callee", "call_gone", "not_ringing"])
async def test_a_refused_acknowledgement_is_logged_with_its_status_and_why(
        client, fcm, caplog, case):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    target, token, status = room, create_call_token(seller, room), 200
    if case == "invalid_token":
        token, status = "SECRET-LOOKING-GARBAGE-TOKEN", 401
    elif case == "token_expired":
        token, status = _expired_call_token(seller, room), 401
    elif case == "wrong_room":
        token, status = create_call_token(seller, "another-room"), 401
    elif case == "not_callee":
        token, status = create_call_token(buyer, room), 403
    elif case == "call_gone":
        target = f"gone-{uuid.uuid4().hex[:8]}"
        token, status = create_call_token(seller, target), 404
    elif case == "not_ringing":
        await call_state.transition(room, CallState.missed)
        status = 410
    r = await _alerted(client, target, token, attempt=3, handler="poller",
                       previous_error="http_503")
    assert r.status_code == status, r.text
    [refused] = _events(caplog, "CALL_ALERT_REJECTED")
    assert (refused["room"], refused["status"], refused["reason"]) == (target, status, case)
    assert (refused["attempt"], refused["delivery_source"], refused["previous_error"]) == (
        3, "poller", "http_503")
    assert token not in caplog.text, "never the token"
    assert not _events(caplog, "CALLEE_ALERTED")
    await call_state.transition(room, CallState.missed)


# ── No answer: still a missed call ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_call_no_phone_acknowledged_ends_as_a_missed_call(client, fcm, caplog):
    """The caller's app died right after placing the call: no socket, no
    hang-up. The ring runs out on the server's clock."""
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    await _settled()

    assert await calls.ring_watchdog_tick(now=time.time() + calls.CALL_RING_TIMEOUT_SECONDS + 5) >= 1
    await _settled()
    assert (await call_state.get_session(room)).state == CallState.missed
    assert await _cards(listing_id) == ["missed"]
    assert _pushes(fcm, "missed_call", room), "the callee is told"
    [no_answer] = _events(caplog, "CALL_NO_ANSWER", room)
    assert (no_answer["reason"], no_answer["reported_by"]) == ("ring_timeout", "server")
    assert no_answer["callee_alerted"] is False, "no phone of theirs ever said it rang"
    [missed] = _events(caplog, "CALL_MISSED", room)
    assert (missed["user"], missed["outcome"]) == (seller, "missed")
    assert missed["push_accepted"] == 1 and missed["card_message_id"]
    assert missed["delivery_source"] == "fcm"


@pytest.mark.asyncio
async def test_a_caller_whose_app_vanishes_mid_ring_still_leaves_a_missed_call(
        client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    caller, caller_task = await _open(room, buyer)
    caller.drop()   # the socket goes, no hang-up said
    await asyncio.wait_for(caller_task, timeout=5)
    await _settled()
    assert await _cards(listing_id) == ["cancelled"]
    assert _pushes(fcm, "missed_call", room)
    [missed] = _events(caplog, "CALL_MISSED", room)
    assert (missed["outcome"], missed["push_accepted"]) == ("cancelled", 1)


@pytest.mark.asyncio
async def test_a_watchdog_step_that_fails_is_tried_again(client, fcm, caplog, monkeypatch):
    """The room leaves the ringing index as the watchdog takes it. A
    failure then - Redis or the database refusing for a moment - used to
    lose the missed call for good: no card, no missed-call push."""
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    await _settled()
    real = call_state.get_session
    failed = []

    async def flaky(room_id):
        if room_id == room and not failed:
            failed.append(True)
            raise ConnectionError("Redis went away for a moment")
        return await real(room_id)

    monkeypatch.setattr(call_state, "get_session", flaky)
    due = time.time() + calls.CALL_RING_TIMEOUT_SECONDS + 5
    with caplog.at_level(logging.WARNING, logger="api.routers.calls"):
        await calls.ring_watchdog_tick(now=due)
    assert failed, "the failure happened"
    assert any("CALL_WATCHDOG_RETRY" in r.getMessage() and room in r.getMessage()
               for r in caplog.records)
    assert (await real(room)).state == CallState.ringing, "not settled yet - and not lost"
    await calls.ring_watchdog_tick(now=due + calls.RING_WATCHDOG_RETRY_SECONDS + 1)
    await _settled()
    assert (await real(room)).state == CallState.missed
    assert await _cards(listing_id) == ["missed"]
    assert _pushes(fcm, "missed_call", room)


@pytest.mark.asyncio
async def test_a_late_acknowledgement_cannot_bring_a_missed_call_back(client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    await _settled()
    await calls.ring_watchdog_tick(now=time.time() + calls.CALL_RING_TIMEOUT_SECONDS + 5)
    await _settled()

    # The push reached the phone after the ring had run out.
    r = await _alerted(client, room, create_call_token(seller, room), handler="background")
    assert r.status_code == 410
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(seller, room)})
    assert r.status_code == 410
    assert (await call_state.get_session(room)).state == CallState.missed
    assert not _events(caplog, "CALLEE_ALERTED")
    [refused] = _events(caplog, "CALL_ALERT_REJECTED")
    assert (refused["status"], refused["reason"]) == (410, "not_ringing")
    assert await _cards(listing_id) == ["missed"], "one missed call, not a second"


# ── Answered, connected ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_answering_and_connecting_are_each_one_line(client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _initiate(client, buyer, listing_id)
    caller, caller_task = await _open(room, buyer)
    assert (await _alerted(client, room, create_call_token(seller, room))).status_code == 200
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(seller, room)})
    assert r.status_code == 200, r.text
    await _until(lambda: bool(caller.got("callee_answered")))
    [answered] = _events(caplog, "CALL_ANSWERED")
    assert (answered["room"], answered["user"], answered["via"]) == (room, seller, "answer")

    callee, callee_task = await _open(room, seller)
    await _until(lambda: bool(caller.got("ready")))
    caller.say({"type": "state", "state": "connected"})
    callee.say({"type": "state", "state": "connected"})
    await _until(lambda: len(_events(caplog, "CALL_CONNECTED")) == 2)
    caller.say({"type": "state", "state": "connected"})   # said again: not a second connect
    for _ in range(20):
        await asyncio.sleep(0.005)
    assert sorted(e["role"] for e in _events(caplog, "CALL_CONNECTED")) == ["callee", "caller"]
    assert len(_events(caplog, "CALL_ANSWERED")) == 1, "joining after Accept is not a second answer"
    caller.say({"type": "hangup"})
    callee.drop()
    await asyncio.wait_for(asyncio.gather(caller_task, callee_task), timeout=5)
    await _settled()


# ── What the callee's phone reports ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_phones_account_of_a_ring_it_could_not_make_reaches_the_log(
        client, fcm, caplog):
    caplog.set_level(logging.INFO, logger="api.call_events")
    listing_id, seller, buyer = await _people()
    room = await _initiate(client, buyer, listing_id)
    events = [
        {"event": "CALL_RING_BLOCKED", "reason": "notifications_disabled",
         "handler": "background", "push_age_ms": 1200, "client_ts": "2026-11-15T09:00:00.000Z"},
        {"event": "CALL_ALERT_FAILED", "handler": "background", "attempt": 4, "status": 503,
         "category": "http_503", "push_age_ms": 1200},
    ]
    r = await client.post(f"/calls/{room}/events",
                          json={"call_token": create_call_token(seller, room), "events": events})
    assert r.json() == {"logged": 2}
    [blocked] = _events(caplog, "CALL_RING_BLOCKED")
    assert (blocked["role"], blocked["source"], blocked["reason"], blocked["handler"]) == (
        "callee", "client", "notifications_disabled", "background")
    [failed] = _events(caplog, "CALL_ALERT_FAILED")
    assert (failed["status"], failed["category"], failed["attempt"]) == (503, "http_503", 4)
    assert all(r.levelno == logging.WARNING for r in caplog.records
               if getattr(r, "call_event", None)
               and r.call_event["event"] in ("CALL_RING_BLOCKED", "CALL_ALERT_FAILED"))
    await call_state.transition(room, CallState.missed)


# ── Device tokens stay out of the log ───────────────────────────────────────

@pytest.mark.asyncio
async def test_a_failed_voip_push_never_logs_the_device_token(monkeypatch, caplog):
    """httpx's text for a failed request names its URL, and the URL of an
    APNs push is the device token."""
    from api.core.config import settings
    import jose.jwt as jose_jwt

    token = "VOIP_DEVICE_TOKEN_SECRET_123"

    class _Client:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, url, **kwargs):
            raise httpx.ConnectError(f"All connection attempts failed for {url}")

    before = {name: getattr(settings, name) for name in ("apns_auth_key", "apns_key_id", "apns_team_id")}
    for name in before:
        object.__setattr__(settings, name, "set-for-test")
    monkeypatch.setattr(jose_jwt, "encode", lambda *a, **k: "provider-token")
    monkeypatch.setattr(calls, "_apns_token_cache", None)
    monkeypatch.setattr(calls.httpx, "AsyncClient", _Client)
    try:
        with caplog.at_level(logging.INFO, logger="api.routers.calls"):
            assert await calls._send_voip_push(token, {"roomId": "r1"}) is False
    finally:
        for name, value in before.items():
            object.__setattr__(settings, name, value)
    assert "VoIP push failed type=ConnectError" in caplog.text
    assert token not in caplog.text
