"""One call at a time (2026-10-08).

Reported from phones: "multiple calls arriving at the same time even when
another call is going on / ringing". /calls/initiate never refused a call:

  * a second caller rang a phone already on a call or already ringing;
  * a caller tapping Call again (or calling again after the first attempt
    seemed to fail) left the first call ringing beside the second - two
    rings, two Accept/Decline notifications, a missed call for the first;
  * two people calling each other at the same moment both rang, and both
    sat on "Calling..." waiting for the other;
  * a caller who hung up while it still rang left the callee's phone
    ringing for its full 45 seconds, with no record of the call.
"""
import asyncio
import time
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from unittest.mock import patch

from api.core import call_state, message_push
from api.core.call_state import CallState
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.routers import calls
from api.security import create_access_token, create_call_token, decode_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_one_call_at_a_time.db"
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


@pytest_asyncio.fixture
async def fcm():
    """FCM as configured, every send captured instead of made."""
    async def _send(**kwargs):
        _send.sent.append(kwargs)
        return calls.FcmResult(True)

    _send.sent = []
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield _send
        # Pushes started in the background (a message's, a ring stopped
        # on other phones) finish inside the test that started them: one
        # cut off when its event loop closes holds SQLite's lock, and the
        # next test's writes fail with "database is locked".
        await message_push.drain()
        await asyncio.gather(*list(calls._background), return_exceptions=True)


async def _people(n_buyers: int = 1, *, with_threads: bool = True):
    """A seller with a listing, and buyers who have written to them (so the
    seller may call them back)."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Bea{i} Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        if with_threads:
            for b in buyers:
                db.add(NegotiationMessage(listing_id=listing.id, sender_id=b.id, role="buyer",
                                          recipient_role="seller", content="hi", buyer_id=b.id,
                                          via_ai=False, msg_type="text"))
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _register(client, uid, token):
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": token, "token_type": "fcm"})
    assert r.status_code == 200, r.text


async def _initiate(client, caller, listing_id, callee_id=None):
    body = {"listing_id": listing_id, "caller_name": "Caller", "call_type": "audio"}
    if callee_id:
        body["callee_id"] = callee_id
    return await client.post("/calls/initiate", headers=_auth(caller), json=body)


async def _connect(room_id: str, *uids):
    """As if these participants had joined the call's signaling room."""
    calls._rooms[room_id] = {uid: _Sock() for uid in uids}
    await call_state.update_state(room_id, CallState.accepted)
    await call_state.update_state(room_id, CallState.connecting)
    await call_state.update_state(room_id, CallState.connected)
    return calls._rooms[room_id]


class _Sock:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


def _pushes(fcm, kind):
    return [p for p in fcm.sent if p["data"].get("type") == kind]


async def _cards(listing_id):
    async with AsyncSessionLocal() as db:
        return list((await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all())


# ── A busy phone is busy ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_second_caller_gets_busy_while_the_phone_rings(client, fcm):
    listing_id, seller, [b1, b2] = await _people(2)
    await _register(client, seller, f"tok-{uuid.uuid4().hex[:6]}")
    first = await _initiate(client, b1, listing_id)
    assert first.status_code == 200, first.text
    second = await _initiate(client, b2, listing_id)
    assert second.status_code == 409, second.text
    assert second.json()["detail"]["code"] == "CALLEE_BUSY"
    assert "Sam is on another call" in second.json()["detail"]["message"]
    assert len(_pushes(fcm, "incoming_call")) == 1, "the second call must not ring"
    incoming = (await client.get("/calls/incoming", headers=_auth(seller))).json()
    assert incoming["room_id"] == first.json()["room_id"]


@pytest.mark.asyncio
async def test_a_second_caller_gets_busy_during_a_call(client, fcm):
    listing_id, seller, [b1, b2] = await _people(2)
    first = (await _initiate(client, b1, listing_id)).json()
    await _connect(first["room_id"], b1, seller)
    try:
        r = await _initiate(client, b2, listing_id)
    finally:
        calls._rooms.pop(first["room_id"], None)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "CALLEE_BUSY"


@pytest.mark.asyncio
async def test_the_phone_is_free_again_once_the_call_ends(client, fcm):
    listing_id, seller, [b1, b2] = await _people(2)
    first = (await _initiate(client, b1, listing_id)).json()
    r = await client.post("/calls/log-result", headers=_auth(seller),
                          json={"room_id": first["room_id"], "outcome": "declined"})
    assert r.status_code == 200
    assert (await _initiate(client, b2, listing_id)).status_code == 200


@pytest.mark.asyncio
async def test_a_call_whose_phones_vanished_does_not_leave_anyone_busy(client, fcm):
    """Judged by sockets, not state: a connected call whose sockets are gone
    (the server lost them, an app was killed) stays "connected" until its
    TTL - four hours - and must not refuse calls to those people."""
    listing_id, seller, [b1, b2] = await _people(2)
    first = (await _initiate(client, b1, listing_id)).json()
    await _connect(first["room_id"], b1, seller)
    calls._rooms.pop(first["room_id"], None)          # the sockets are gone
    assert (await call_state.get_session(first["room_id"])).state == CallState.connected
    assert (await _initiate(client, b2, listing_id)).status_code == 200


@pytest.mark.asyncio
async def test_someone_on_a_call_cannot_place_another(client, fcm):
    listing_id, seller, [b1, b2] = await _people(2)
    first = (await _initiate(client, b1, listing_id)).json()
    await _connect(first["room_id"], b1, seller)
    try:
        # The seller, mid-call, calls another buyer.
        r = await _initiate(client, seller, listing_id, callee_id=b2)
    finally:
        calls._rooms.pop(first["room_id"], None)
    assert r.status_code == 409
    assert r.json()["detail"]["code"] == "CALLER_BUSY"


# ── Calling again replaces the call still ringing ─────────────────────────────

@pytest.mark.asyncio
async def test_calling_again_replaces_the_call_still_ringing(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, f"tok-{uuid.uuid4().hex[:6]}")
    room1 = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    caller_sock = _Sock()
    calls._rooms[room1] = {buyer: caller_sock}
    try:
        r = await _initiate(client, buyer, listing_id)
    finally:
        calls._rooms.pop(room1, None)
    assert r.status_code == 200, r.text
    room2 = r.json()["room_id"]

    # The first call stops ringing before the second starts.
    kinds = [(p["data"]["type"], p["data"].get("roomId")) for p in fcm.sent]
    assert kinds.index(("call_over", room1)) < kinds.index(("incoming_call", room2))
    assert _pushes(fcm, "incoming_call")[-1]["data"]["replacesRoomId"] == room1
    assert {"type": "hangup", "reason": "superseded"} in caller_sock.sent
    # One ring, one call: no missed call and no card for the first attempt.
    assert _pushes(fcm, "missed_call") == []
    assert await _cards(listing_id) == []
    assert (await call_state.get_session(room1)).state == CallState.missed
    incoming = (await client.get("/calls/incoming", headers=_auth(seller))).json()
    assert incoming["room_id"] == room2
    # The first call is over for every path that might still act on it.
    r = await client.post(f"/calls/{room1}/alerted",
                          json={"call_token": create_call_token(seller, room1)})
    assert r.status_code == 410
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room1, "outcome": "cancelled"})
    assert r.status_code == 409


@pytest.mark.asyncio
async def test_a_double_tap_leaves_one_call_ringing(client, fcm):
    listing_id, seller, [buyer] = await _people()
    a, b = await asyncio.gather(_initiate(client, buyer, listing_id),
                                _initiate(client, buyer, listing_id))
    assert a.status_code == b.status_code == 200
    states = [(await call_state.get_session(r.json()["room_id"])).state for r in (a, b)]
    assert sorted(s.value for s in states) == ["missed", "ringing"]


@pytest.mark.asyncio
async def test_calling_someone_else_leaves_the_first_a_missed_call(client, fcm):
    listing_id, seller, [b1, b2] = await _people(2)
    room1 = (await _initiate(client, seller, listing_id, callee_id=b1)).json()["room_id"]
    r = await _initiate(client, seller, listing_id, callee_id=b2)
    assert r.status_code == 200, r.text
    assert (await call_state.get_session(room1)).state == CallState.missed
    assert await _cards(listing_id) == ["cancelled"]


# ── Two people calling each other ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_calling_someone_who_is_calling_you_answers_their_call(client, fcm):
    listing_id, seller, [buyer] = await _people()
    room1 = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    r = await _initiate(client, seller, listing_id, callee_id=buyer)
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert detail["code"] == "CALL_CROSSED"
    assert detail["call"]["room_id"] == room1
    claims = decode_call_token(detail["call"]["call_token"])
    assert claims["sub"] == seller and claims["room_id"] == room1
    assert len(_pushes(fcm, "incoming_call")) <= 1
    assert (await call_state.get_session(room1)).state == CallState.ringing


@pytest.mark.asyncio
async def test_calling_each_other_at_the_same_moment_makes_one_call(client, fcm):
    listing_id, seller, [buyer] = await _people()
    a, b = await asyncio.gather(_initiate(client, buyer, listing_id),
                                _initiate(client, seller, listing_id, callee_id=buyer))
    codes = sorted([a.status_code, b.status_code])
    assert codes == [200, 409]
    refused = a if a.status_code == 409 else b
    assert refused.json()["detail"]["code"] == "CALL_CROSSED"


# ── Answering, and hanging up before an answer ────────────────────────────────

@pytest.mark.asyncio
async def test_answering_stops_the_call_being_reported_as_ringing(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, f"tok-a-{uuid.uuid4().hex[:6]}")
    await _register(client, seller, f"tok-b-{uuid.uuid4().hex[:6]}")
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(buyer, room)})
    assert r.status_code == 403, "only the person called can answer"
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(seller, room)})
    assert r.status_code == 200
    assert (await call_state.get_session(room)).state == CallState.accepted
    assert (await client.get("/calls/incoming", headers=_auth(seller))).json() == {"has_call": False}
    for _ in range(20):                     # the ring-over push is sent in the background
        if _pushes(fcm, "call_over"):
            break
        await asyncio.sleep(0.05)
    assert {p["data"]["roomId"] for p in _pushes(fcm, "call_over")} == {room}
    # Answered calls are not settled as missed by the watchdog.
    await calls.ring_watchdog_tick(now=time.time() + 3600)
    assert (await call_state.get_session(room)).state == CallState.accepted


@pytest.mark.asyncio
async def test_a_caller_hanging_up_mid_ring_stops_the_ring_and_leaves_a_missed_call(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, f"tok-{uuid.uuid4().hex[:6]}")
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    session = await call_state.get_session(room)
    await calls._settle_unanswered(session, by=buyer)
    assert [p["data"]["roomId"] for p in _pushes(fcm, "missed_call")] == [room]
    assert await _cards(listing_id) == ["cancelled"]
    assert (await call_state.get_session(room)).state == CallState.missed
    # Settled once, whoever reports it next.
    await calls._settle_unanswered(session, by=buyer)
    assert await _cards(listing_id) == ["cancelled"]
