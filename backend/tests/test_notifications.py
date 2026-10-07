"""Notifications that reach a phone whose app is closed (2026-10-07).

Reported: an incoming call rang only while the app was open, the caller's
screen assumed someone not "online" could not be reached, and messages sent
while someone was away were not there to see until they opened the app.

What was wrong on the server:

  * POST /calls/register-token raised on every call - it wrote to the dict
    get_current_user returns as if it were the User row - so no phone's
    token was ever stored and nothing could be pushed to anyone.
  * One token per user: only the newest phone got anything, and a phone
    that changed hands kept getting the previous account's pushes.
  * Chat messages were never pushed at all.
  * A call nobody answered and no phone reported left nothing behind.
  * The caller could not tell "their phone is ringing" from "it isn't".
"""
import asyncio
import time
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core import call_state, message_push, push_devices
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.push_device import PushDevice
from api.routers import calls
from api.security import create_access_token, create_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_notifications.db"
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
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Bea Buyer{i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _register(client, uid, token, token_type="fcm"):
    return await client.post("/calls/register-token", headers=_auth(uid),
                             json={"fcm_token": token, "token_type": token_type,
                                   "platform": "android"})


class _Sock:
    def __init__(self):
        self.sent = []

    async def send_json(self, payload):
        self.sent.append(payload)


@pytest.fixture
def fcm():
    """FCM as configured, with every send captured instead of made."""
    async def _send(**kwargs):
        _send.sent.append(kwargs)
        return calls.FcmResult(True)

    _send.sent = []
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield _send
    message_push._last_pushed.clear()


# ── Registering a phone ───────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_registering_a_phone_stores_its_token(client):
    _, seller, _ = await _people()
    r = await _register(client, seller, "tok-A1")
    assert r.status_code == 200, r.text
    assert r.json()["status"] == "ok"
    assert "push_enabled" in r.json()
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, seller) == ["tok-A1"]
        user = await db.get(User, seller)
        assert user.fcm_token == "tok-A1"


@pytest.mark.asyncio
async def test_a_phone_that_changes_hands_stops_getting_the_old_accounts_pushes(client):
    _, first, [second] = await _people()
    await _register(client, first, "shared-phone")
    await _register(client, second, "shared-phone")
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, first) == []
        assert await push_devices.tokens_for(db, second) == ["shared-phone"]
        assert (await db.get(User, first)).fcm_token is None


@pytest.mark.asyncio
async def test_every_phone_a_user_is_signed_in_on_is_kept(client):
    _, seller, _ = await _people()
    await _register(client, seller, "phone-1")
    await _register(client, seller, "phone-2")
    async with AsyncSessionLocal() as db:
        assert set(await push_devices.tokens_for(db, seller)) == {"phone-1", "phone-2"}


@pytest.mark.asyncio
async def test_signing_out_unhooks_only_your_own_phone(client):
    _, seller, [buyer] = await _people()
    await _register(client, seller, "seller-phone")
    # Someone else naming the token changes nothing.
    r = await client.post("/calls/unregister-token", headers=_auth(buyer),
                          json={"fcm_token": "seller-phone"})
    assert r.status_code == 200
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, seller) == ["seller-phone"]
    r = await client.post("/calls/unregister-token", headers=_auth(seller),
                          json={"fcm_token": "seller-phone"})
    assert r.status_code == 200
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, seller) == []
        assert (await db.get(User, seller)).fcm_token is None


@pytest.mark.asyncio
async def test_signing_out_everywhere_unhooks_every_phone(client):
    _, seller, _ = await _people()
    await _register(client, seller, "everywhere-1")
    await _register(client, seller, "everywhere-2")
    r = await client.post("/auth/token/revoke-all", headers=_auth(seller))
    assert r.status_code == 204, r.text
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, seller) == []


@pytest.mark.asyncio
async def test_a_token_fcm_calls_dead_is_forgotten(client):
    _, seller, _ = await _people()
    await _register(client, seller, "dead-phone")
    await _register(client, seller, "live-phone")

    async def _send(**kwargs):
        if kwargs["token"] == "dead-phone":
            return calls.FcmResult(False, unregistered=True)
        return calls.FcmResult(True)

    with patch.object(calls, "_send_fcm", new=_send):
        sent = await push_devices.push_user(seller, title="t", body="b", data={})
    assert sent == 1
    async with AsyncSessionLocal() as db:
        assert await push_devices.tokens_for(db, seller) == ["live-phone"]
        assert (await db.get(PushDevice, "dead-phone")) is None


# ── Calls ring every phone and tell the caller when one rings ────────────────

async def _initiate(client, caller, listing_id, callee_id=None):
    body = {"listing_id": listing_id, "caller_name": "Bea", "call_type": "audio"}
    if callee_id:
        body["callee_id"] = callee_id
    r = await client.post("/calls/initiate", headers=_auth(caller), json=body)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_a_call_rings_every_phone_of_the_callee(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "s-phone-1")
    await _register(client, seller, "s-phone-2")
    out = await _initiate(client, buyer, listing_id)
    assert out["status"] == "sent"
    pushes = [p for p in fcm.sent if p["data"]["type"] == "incoming_call"]
    assert {p["token"] for p in pushes} == {"s-phone-1", "s-phone-2"}
    data = pushes[0]["data"]
    assert data["roomId"] == out["room_id"]
    assert pushes[0]["data_only"] is True
    # The callee's own call token, so a closed app can acknowledge the ring.
    from api.security import decode_call_token
    claims = decode_call_token(data["callToken"])
    assert claims["sub"] == seller and claims["room_id"] == out["room_id"]


@pytest.mark.asyncio
async def test_the_callees_phone_ringing_reaches_the_caller(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "ring-phone")
    out = await _initiate(client, buyer, listing_id)
    room_id = out["room_id"]
    caller_sock = _Sock()
    calls._rooms[room_id] = {buyer: caller_sock}
    try:
        token = create_call_token(seller, room_id)
        r = await client.post(f"/calls/{room_id}/alerted", json={"call_token": token})
        assert r.status_code == 200, r.text
        # A second phone of the callee's acknowledging is not news.
        r = await client.post(f"/calls/{room_id}/alerted", json={"call_token": token})
        assert r.status_code == 200
    finally:
        calls._rooms.pop(room_id, None)
    assert caller_sock.sent == [{"type": "callee_ringing"}]
    session = await call_state.get_session(room_id)
    assert session.callee_alerted is True


@pytest.mark.asyncio
async def test_only_the_callee_can_report_ringing(client, fcm):
    listing_id, seller, [buyer] = await _people()
    out = await _initiate(client, buyer, listing_id)
    room_id = out["room_id"]
    r = await client.post(f"/calls/{room_id}/alerted",
                          json={"call_token": create_call_token(buyer, room_id)})
    assert r.status_code == 403
    r = await client.post(f"/calls/{room_id}/alerted",
                          json={"call_token": create_call_token(seller, "another-room")})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_a_late_push_for_a_finished_call_is_told_to_stop(client, fcm):
    listing_id, seller, [buyer] = await _people()
    out = await _initiate(client, buyer, listing_id)
    room_id = out["room_id"]
    r = await client.post("/calls/log-result", headers=_auth(buyer),
                          json={"room_id": room_id, "outcome": "cancelled"})
    assert r.status_code == 200
    r = await client.post(f"/calls/{room_id}/alerted",
                          json={"call_token": create_call_token(seller, room_id)})
    assert r.status_code == 410


@pytest.mark.asyncio
async def test_one_request_finds_a_ringing_call_on_any_listing(client, fcm):
    listing_id, seller, [buyer] = await _people()
    out = await _initiate(client, buyer, listing_id)
    r = await client.get("/calls/incoming", headers=_auth(seller))
    body = r.json()
    assert body["has_call"] is True
    assert body["room_id"] == out["room_id"]
    assert body["listing_id"] == listing_id
    assert body["listing_name"] == "Samsung A54"
    assert body["buyer_id"] == buyer
    assert body["caller_id"] == buyer
    assert body["call_token"]
    # Never your own outgoing call.
    assert (await client.get("/calls/incoming", headers=_auth(buyer))).json() == {"has_call": False}
    await client.post("/calls/log-result", headers=_auth(buyer),
                      json={"room_id": out["room_id"], "outcome": "cancelled"})
    assert (await client.get("/calls/incoming", headers=_auth(seller))).json() == {"has_call": False}


# ── Nobody answered and no phone said so ──────────────────────────────────────

@pytest.mark.asyncio
async def test_an_unanswered_unreported_call_becomes_a_missed_call(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "missed-phone")
    out = await _initiate(client, buyer, listing_id)
    room_id = out["room_id"]
    caller_sock = _Sock()
    calls._rooms[room_id] = {buyer: caller_sock}
    try:
        settled = await calls.ring_watchdog_tick(now=time.time() + 3600)
    finally:
        calls._rooms.pop(room_id, None)
    assert settled >= 1

    assert {"type": "hangup", "reason": "no_answer"} in caller_sock.sent
    missed = [p for p in fcm.sent if p["data"]["type"] == "missed_call"
              and p["data"]["roomId"] == room_id]
    assert [p["token"] for p in missed] == ["missed-phone"]
    async with AsyncSessionLocal() as db:
        cards = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all()
    assert [(c.content, c.buyer_id) for c in cards] == [("missed", buyer)]
    assert (await call_state.get_session(room_id)).state == call_state.CallState.missed


@pytest.mark.asyncio
async def test_the_watchdog_leaves_a_call_a_phone_already_reported(client, fcm):
    listing_id, seller, [buyer] = await _people()
    out = await _initiate(client, buyer, listing_id)
    await client.post("/calls/log-result", headers=_auth(buyer),
                      json={"room_id": out["room_id"], "outcome": "cancelled"})
    await calls.ring_watchdog_tick(now=time.time() + 3600)
    async with AsyncSessionLocal() as db:
        cards = (await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.msg_type == "call",
        ))).scalars().all()
    assert cards == ["cancelled"]


@pytest.mark.asyncio
async def test_the_watchdog_leaves_an_answered_call_alone(client, fcm):
    listing_id, seller, [buyer] = await _people()
    out = await _initiate(client, buyer, listing_id)
    await call_state.update_state(out["room_id"], call_state.CallState.accepted)
    assert await calls.ring_watchdog_tick(now=time.time() + 3600) == 0
    assert (await call_state.get_session(out["room_id"])).state == call_state.CallState.accepted


# ── Chat messages are pushed ──────────────────────────────────────────────────

async def _direct(client, sender_id, role, listing_id, content, buyer_id=None):
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r


def _message_pushes(fcm):
    return [p for p in fcm.sent if p["data"].get("type") == "new_message"]


@pytest.mark.asyncio
async def test_a_message_is_pushed_to_the_other_side(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "seller-msg-phone")
    await _direct(client, buyer, "buyer", listing_id, "Is it still available?")
    await message_push.drain()

    [push] = _message_pushes(fcm)
    assert push["token"] == "seller-msg-phone"
    assert push["title"] == "Bea Buyer0 · Samsung A54"
    assert push["body"] == "Is it still available?"
    # Visible (Android draws it with the app closed), one per conversation.
    assert not push.get("data_only")
    assert push["android_tag"] == f"thread_{listing_id}_{buyer}"
    assert push["android_channel_id"] == "broka_messages"
    assert push.get("ttl_seconds") is None
    data = push["data"]
    assert data["listingId"] == listing_id and data["buyerId"] == buyer
    assert data["myRole"] == "seller" and data["screen"] == "chat"


@pytest.mark.asyncio
async def test_a_burst_of_messages_is_one_notification_with_the_count(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "burst-phone")
    with patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0.3):
        for text in ("Hello", "Is it new?", "Last price?"):
            await _direct(client, buyer, "buyer", listing_id, text)
        await message_push.drain()
    [push] = _message_pushes(fcm)
    assert push["body"] == "3 new messages · Last price?"
    assert push["data"]["count"] == 3


@pytest.mark.asyncio
async def test_nothing_is_pushed_for_a_thread_already_read(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "read-phone")
    with patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0.3):
        await _direct(client, buyer, "buyer", listing_id, "hi")
        r = await client.post(f"/negotiate/{listing_id}/mark-read", headers=_auth(seller),
                              json={"buyer_id": buyer})
        assert r.status_code == 200, r.text
        await message_push.drain()
    assert _message_pushes(fcm) == []


@pytest.mark.asyncio
async def test_a_buyers_private_words_to_zeno_are_never_pushed_to_the_seller(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "private-phone")
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=listing_id, sender_id=buyer, role="buyer", recipient_role=None,
            content="is this seller legit?", buyer_id=buyer, via_ai=True, msg_type="text"))
        await db.commit()
    await message_push.drain()
    assert _message_pushes(fcm) == []


@pytest.mark.asyncio
async def test_zenos_message_is_pushed_only_to_the_side_it_is_for(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "zeno-seller-phone")
    await _register(client, buyer, "zeno-buyer-phone")
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=listing_id, sender_id="broker", role="broker", recipient_role="seller",
            content="A buyer asks if the phone is still available.", buyer_id=buyer,
            msg_type="text"))
        await db.commit()
    await message_push.drain()
    [push] = _message_pushes(fcm)
    assert push["token"] == "zeno-seller-phone"
    assert push["title"].startswith("Zeno")
    assert push["data"]["screen"] == "zeno"
    assert push["data"]["myRole"] == "seller"


@pytest.mark.asyncio
async def test_a_call_card_is_not_pushed_as_a_message(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "card-phone")
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=listing_id, sender_id=buyer, role="buyer", recipient_role=None,
            content="completed", buyer_id=buyer, via_ai=False, msg_type="call"))
        await db.commit()
    await message_push.drain()
    assert _message_pushes(fcm) == []


@pytest.mark.asyncio
async def test_a_message_that_was_rolled_back_is_not_pushed(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, seller, "rollback-phone")
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=listing_id, sender_id=buyer, role="buyer", recipient_role="seller",
            content="never sent", buyer_id=buyer, via_ai=False, msg_type="text"))
        await db.flush()
        await db.rollback()
    await message_push.drain()
    assert _message_pushes(fcm) == []


@pytest.mark.asyncio
async def test_a_photo_is_announced_as_a_photo(client, fcm):
    listing_id, seller, [buyer] = await _people()
    await _register(client, buyer, "photo-phone")
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=listing_id, sender_id=seller, role="seller", recipient_role="buyer",
            content="data:image/webp;base64,AAAA", buyer_id=buyer, via_ai=False,
            msg_type="image"))
        await db.commit()
    await message_push.drain()
    [push] = _message_pushes(fcm)
    assert push["body"] == "\U0001F4F7 Photo"
    assert push["data"]["myRole"] == "buyer"


def test_who_a_message_is_for_follows_the_history_rules():
    r = message_push.recipients_of
    assert r("buyer", "seller", False, "text") == {"seller"}
    assert r("seller", "buyer", None, "voice") == {"buyer"}
    assert r("buyer", None, True, "text") == set()          # private, to Zeno
    assert r("buyer", None, False, "call") == set()         # a call card
    assert r("broker", "buyer", True, "text") == {"buyer"}
    assert r("broker", None, True, "text") == {"buyer", "seller"}
