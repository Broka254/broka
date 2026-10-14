"""An answered call is never lost, never "missed", never keeps anyone busy
(2026-10-09).

Reported from phones: "When I click Accept the app takes long to open and
then the call gets disconnected and is counted as a missed call - and when
I try calling back, the app says I'm already in a call."

  * `accepted` cannot become `missed`, so when the caller's screen gave up
    on a callee still opening BROKA and reported "cancelled", the session
    stayed `accepted` - which counts as being on a call - and the socket
    heartbeat had stretched it to the 4-hour connected TTL. Calling back
    answered 409 CALLER_BUSY.
  * The outcome was recorded as missed: a "Missed call" card and push for
    the call the callee had answered.
  * The callee's join window counted from when the call was placed, not
    from Accept.
  * A call answered from a closed app fetched its TURN credentials with an
    access token that had expired while the app was closed - two more round
    trips before the call could start connecting.
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
from api.core.call_state import CallSession, CallState
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.routers import calls
from api.security import create_access_token, create_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_answered_call_not_lost.db"
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
        await message_push.drain()
        await asyncio.gather(*list(calls._background), return_exceptions=True)


class _Sock:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


async def _people():
    """A seller with a listing and a buyer who has written to them, so
    either may call the other."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
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


async def _initiate(client, caller, listing_id, callee_id=None):
    body = {"listing_id": listing_id, "caller_name": "Caller", "call_type": "audio"}
    if callee_id:
        body["callee_id"] = callee_id
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


def _pushes(fcm, kind, room):
    return [p for p in fcm.sent if p["data"].get("type") == kind and p["data"].get("roomId") == room]


# ── Answered, then the call never connected ──────────────────────────────────

@pytest.mark.asyncio
async def test_calling_back_after_an_answered_call_failed_is_not_busy(client, fcm):
    """The reported case: the buyer called, the seller pressed Accept on a
    closed app, the call never connected, and the seller calls back."""
    listing_id, seller, buyer = await _people()
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    # The caller's screen gave up waiting and reported it.
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room, "outcome": "cancelled"})
    assert r.status_code == 200, r.text
    assert call_state.is_terminal((await call_state.get_session(room)).state), (
        "an answered call that never connected is over once its outcome is in - "
        "it used to stay `accepted`, which is being on a call")

    r = await _initiate(client, seller, listing_id, callee_id=buyer)
    assert r.status_code == 200, r.text
    await call_state.update_state(r.json()["room_id"], CallState.missed)


@pytest.mark.asyncio
async def test_a_call_answered_then_left_does_not_block_calling_back(client, fcm):
    """Even with no outcome reported at all (the callee's app died opening
    the call), the person who left it can call back: placing a call is proof
    they are not on one. The caller's screen, still waiting, is told."""
    listing_id, seller, buyer = await _people()
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    waiting = _Sock()
    calls._rooms[room] = {buyer: waiting}
    try:
        r = await _initiate(client, seller, listing_id, callee_id=buyer)
        assert r.status_code == 200, r.text
        await asyncio.gather(*list(calls._background), return_exceptions=True)
        assert {"type": "hangup", "reason": "superseded"} in waiting.sent
        assert (await call_state.get_session(room)).state == CallState.ended
        await call_state.update_state(r.json()["room_id"], CallState.missed)
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_a_call_someone_is_still_on_keeps_them_busy(client, fcm):
    """What `_left` must not catch: a socket of theirs in the call."""
    listing_id, seller, buyer = await _people()
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    calls._rooms[room] = {buyer: _Sock(), seller: _Sock()}
    await call_state.update_state(room, CallState.connecting)
    try:
        r = await _initiate(client, seller, listing_id, callee_id=buyer)
        assert r.status_code == 409
        assert r.json()["detail"]["code"] == "CALLER_BUSY"
    finally:
        calls._rooms.pop(room, None)
        await call_state.update_state(room, CallState.ended)


@pytest.mark.asyncio
async def test_an_answered_call_is_never_recorded_as_missed(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    await _answer(client, room, seller)
    # The callee's own screen, failing to connect, used to say "missed".
    r = await client.post("/calls/log-result", headers=_auth(seller),
                          json={"room_id": room, "outcome": "missed"})
    assert r.status_code == 200, r.text
    await asyncio.gather(*list(calls._background), return_exceptions=True)
    assert await _cards(listing_id) == ["completed"], "the card says Answered, not Missed"
    assert _pushes(fcm, "missed_call", room) == [], "nobody is told they missed a call they answered"


@pytest.mark.asyncio
async def test_an_unanswered_call_is_still_missed(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room, "outcome": "cancelled"})
    assert r.status_code == 200, r.text
    assert await _cards(listing_id) == ["cancelled"]
    assert len(_pushes(fcm, "missed_call", room)) == 1


# ── The callee's window to join ──────────────────────────────────────────────

@pytest.mark.asyncio
async def test_answering_gives_the_callee_the_whole_join_window():
    """Answered 110 seconds into a 120-second window, a phone starting BROKA
    from cold had ten seconds left to join."""
    room = f"room-{uuid.uuid4().hex}"
    await call_state.create_session(room_id=room, caller_id="a", callee_id="b",
                                    listing_id="l", call_type="audio", caller_name="A",
                                    ttl_seconds=10)
    await call_state.update_state(room, CallState.ringing)
    session = await call_state.mark_answered(room)
    assert session.state == CallState.accepted and session.answered
    assert session.expires_at >= time.time() + call_state.ESTABLISHMENT_SESSION_TTL_SECONDS - 2


@pytest.mark.asyncio
async def test_the_heartbeat_keeps_an_unjoined_answered_call_short():
    """Renewing used to give an `accepted` call the 4-hour connected TTL:
    one that never connected stayed "on a call" for hours."""
    room = f"room-{uuid.uuid4().hex}"
    await call_state.create_session(room_id=room, caller_id="a", callee_id="b",
                                    listing_id="l", call_type="audio", caller_name="A")
    await call_state.update_state(room, CallState.ringing)
    await call_state.mark_answered(room)
    session = await call_state.renew_session(room)
    assert session.expires_at <= time.time() + call_state.ESTABLISHMENT_SESSION_TTL_SECONDS + 2

    # Once both are in, a long call keeps its session as before.
    await call_state.update_state(room, CallState.connecting)
    session = await call_state.renew_session(room)
    assert session.expires_at >= time.time() + call_state.CONNECTED_SESSION_TTL_SECONDS - 2


def test_a_session_written_by_a_newer_build_still_reads():
    raw = CallSession(room_id="r", caller_id="a", callee_id="b", listing_id="l",
                      call_type="audio", caller_name="A", state=CallState.ringing,
                      created_at=1.0, expires_at=2.0).to_json()
    newer = raw[:-1] + ', "something_new": 1}'
    assert CallSession.from_json(newer).room_id == "r"


# ── TURN credentials with the call's own token ───────────────────────────────

@pytest.mark.asyncio
async def test_turn_credentials_with_the_call_token(client, fcm):
    listing_id, seller, buyer = await _people()
    room = (await _initiate(client, buyer, listing_id)).json()["room_id"]
    servers = {"ice_servers": [{"urls": ["turn:turn.cloudflare.com:3478"]}], "expires_in": 3600}
    with patch("api.core.cloudflare_turn_client.generate_ice_servers", return_value=servers):
        r = await client.post(f"/calls/{room}/turn-credentials",
                              json={"call_token": create_call_token(seller, room)})
        assert r.status_code == 200, r.text
        assert r.json() == servers

        other = f"room-{uuid.uuid4().hex}"
        r = await client.post(f"/calls/{room}/turn-credentials",
                              json={"call_token": create_call_token(seller, other)})
        assert r.status_code == 401, "a token for another call opens nothing"

        r = await client.post(f"/calls/{room}/turn-credentials",
                              json={"call_token": create_call_token("stranger", room)})
        assert r.status_code == 403

        await call_state.update_state(room, CallState.missed)
        r = await client.post(f"/calls/{room}/turn-credentials",
                              json={"call_token": create_call_token(seller, room)})
        assert r.status_code == 410


def test_a_callee_may_ask_for_a_fresh_offer():
    """Switching a voice call to video from the callee's side: only the
    caller offers, so the callee asks it to."""
    assert "renegotiate" in calls.WS_RELAYABLE_TYPES
