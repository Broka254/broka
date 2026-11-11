"""Reply and Mark as read on a message notification, and the phone saying it
received the message (2026-11-11).

Asked for: a message notification with "Reply" (answer without opening the
app) and "Mark as read". Reported with it: the sender's ticks went from
"sent" straight to "seen" - "delivered" never showed.

Both come down to the same missing piece (NOTIFICATIONS.md, "Still open"):
everything a notification does runs in the app's background isolate, where
the access token has usually expired, and renewing it there races the app's
own renewal for the same refresh token. The phone's "I have it" receipt went
through exactly that path. A message push now carries a thread token - one
conversation, one side, one phone - and three endpoints answer to it.
"""
import asyncio
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core import message_push, push_devices
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.routers import calls
from api.security import (
    create_access_token, create_thread_token, decode_access_token, decode_thread_token,
)
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_notification_actions.db"
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


async def _register(client, uid, token):
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": token, "token_type": "fcm", "platform": "android"})
    assert r.status_code == 200, r.text


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None):
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


@pytest_asyncio.fixture
async def fcm():
    """FCM as configured, with every send captured instead of made."""
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
    message_push._last_pushed.clear()


def _message_pushes(fcm):
    return [p for p in fcm.sent if p["data"].get("type") == "new_message"]


def _token_for(seller, buyer, listing_id, phone):
    """What the seller's phone [phone] holds for this thread."""
    return create_thread_token(seller, "seller", buyer, listing_id=listing_id,
                               device=push_devices.token_fingerprint(phone))


async def _marks(listing_id, buyer, role):
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(ThreadReadState).where(
            ThreadReadState.listing_id == listing_id,
            ThreadReadState.buyer_id == buyer,
            ThreadReadState.role == role,
        ))).scalar_one_or_none()
        return (row.last_delivered_at, row.last_read_at) if row else (None, None)


# ── The token in the push ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_each_phone_gets_its_own_token_for_the_thread(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "actions-phone-1")
    await _register(client, seller, "actions-phone-2")
    await _direct(client, buyer, "buyer", listing_id, "Still available?")
    await message_push.drain()

    pushes = [p for p in _message_pushes(fcm) if p["data"]["listingId"] == listing_id]
    assert {p["token"] for p in pushes} == {"actions-phone-1", "actions-phone-2"}
    for push in pushes:
        claims = decode_thread_token(push["data"]["threadToken"])
        assert claims is not None
        assert claims["sub"] == seller and claims["role"] == "seller"
        assert claims["bid"] == buyer and claims["lid"] == listing_id
        assert claims["dev"] == push_devices.token_fingerprint(push["token"]), (
            "bound to the phone it went to - not one token for every phone")
        assert push["data"]["directUnread"] == 1
    # And it is no sign-in: nothing that takes an access token takes it.
    assert decode_access_token(pushes[0]["data"]["threadToken"]) is None


@pytest.mark.asyncio
async def test_a_thread_token_does_not_open_anything_an_access_token_does(client):
    listing_id, seller, buyer = await _people()
    token = _token_for(seller, buyer, listing_id, "any-phone")
    r = await client.get(f"/negotiate/{listing_id}/history",
                         headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401


# ── Delivered ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_phone_receiving_the_push_marks_the_thread_delivered_not_read(client):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "delivered-phone")
    await _direct(client, buyer, "buyer", listing_id, "hello")
    with patch("api.routers.media.broadcast_receipt", new=AsyncMock()) as announce:
        r = await client.post("/negotiate/notification/delivered", json={
            "thread_token": _token_for(seller, buyer, listing_id, "delivered-phone")})
    assert r.status_code == 200, r.text
    delivered, read = await _marks(listing_id, buyer, "seller")
    assert delivered is not None
    assert read is None or read < delivered, "delivered is not read"
    # The buyer's open chat turns the tick now.
    announce.assert_awaited_once()
    args, kwargs = announce.call_args
    assert args == (listing_id, buyer, "seller")
    assert kwargs["exclude_uid"] == seller
    assert kwargs["delivered_at"] is not None and kwargs["read_at"] is None


@pytest.mark.asyncio
async def test_a_phone_that_signed_out_can_no_longer_act_for_the_account(client):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "signed-out-phone")
    token = _token_for(seller, buyer, listing_id, "signed-out-phone")
    r = await client.post("/calls/unregister-token", headers=_auth(seller),
                          json={"fcm_token": "signed-out-phone"})
    assert r.status_code == 200
    for action in ("delivered", "read"):
        r = await client.post(f"/negotiate/notification/{action}", json={"thread_token": token})
        assert r.status_code == 401, action
    r = await client.post("/negotiate/notification/reply",
                          json={"thread_token": token, "content": "ok"})
    assert r.status_code == 401


@pytest.mark.asyncio
async def test_a_token_for_the_wrong_side_or_a_forgery_is_refused(client):
    listing_id, seller, buyer = await _people()
    await _register(client, buyer, "buyer-phone-x")
    # The buyer's phone claiming the seller's side.
    wrong_side = create_thread_token(buyer, "seller", buyer, listing_id=listing_id,
                                     device=push_devices.token_fingerprint("buyer-phone-x"))
    r = await client.post("/negotiate/notification/read", json={"thread_token": wrong_side})
    assert r.status_code == 403
    # An access token is not a thread token.
    r = await client.post("/negotiate/notification/read",
                          json={"thread_token": create_access_token({"sub": buyer})})
    assert r.status_code == 401


# ── Mark as read ──────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_mark_as_read_reads_the_thread_and_tells_the_sender(client):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "read-action-phone")
    await _direct(client, buyer, "buyer", listing_id, "Last price?")
    with patch("api.routers.media.broadcast_receipt", new=AsyncMock()) as announce:
        r = await client.post("/negotiate/notification/read", json={
            "thread_token": _token_for(seller, buyer, listing_id, "read-action-phone")})
    assert r.status_code == 200, r.text
    _, read = await _marks(listing_id, buyer, "seller")
    assert read is not None
    status = (await client.get(f"/negotiate/{listing_id}/read-status",
                               params={"buyer_id": buyer}, headers=_auth(seller))).json()
    assert status["unread"] == 0
    args, kwargs = announce.call_args
    assert args == (listing_id, buyer, "seller")
    assert kwargs["read_at"] is not None


# ── Reply ─────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_reply_from_the_notification_is_a_direct_message_and_reads_the_thread(client):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "reply-phone")
    await _direct(client, buyer, "buyer", listing_id, "Is it still available?")
    token = _token_for(seller, buyer, listing_id, "reply-phone")
    with patch("api.routers.media.broadcast_text_message", new=AsyncMock()) as relayed:
        r = await client.post("/negotiate/notification/reply", json={
            "thread_token": token, "content": "  Yes, come today  ",
            "client_msg_id": "notif-reply-1"})
    assert r.status_code == 200, r.text
    msg = r.json()["message"]
    assert msg["content"] == "Yes, come today"
    assert msg["role"] == "seller" and msg["client_msg_id"] == "notif-reply-1"
    # Delivered like any direct message: the buyer's open chat gets it now.
    relayed.assert_awaited_once()
    # In the buyer's thread, from the seller.
    history = (await client.get(f"/negotiate/{listing_id}/history",
                                headers=_auth(buyer))).json()
    assert [(m["role"], m["content"]) for m in history] == [
        ("buyer", "Is it still available?"), ("seller", "Yes, come today")]
    # Answering it read it.
    _, read = await _marks(listing_id, buyer, "seller")
    assert read is not None
    # A retry after a lost answer is the same message, not a second one.
    again = await client.post("/negotiate/notification/reply", json={
        "thread_token": token, "content": "Yes, come today",
        "client_msg_id": "notif-reply-1"})
    assert again.status_code == 200
    assert again.json()["message"]["id"] == msg["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.role == "seller"))).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_an_empty_reply_is_refused(client):
    listing_id, seller, buyer = await _people()
    await _register(client, seller, "empty-reply-phone")
    r = await client.post("/negotiate/notification/reply", json={
        "thread_token": _token_for(seller, buyer, listing_id, "empty-reply-phone"),
        "content": "   "})
    assert r.status_code == 400


@pytest.mark.asyncio
async def test_a_buyer_replies_into_their_store_conversation(client):
    from api.models.store import Store

    _, owner, buyer = await _people()
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner, name=f"Clanix {uuid.uuid4().hex[:6]}",
                      slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        store_id = store.id
    await _register(client, buyer, "store-buyer-phone")
    r = await client.post("/negotiate/direct-message", headers=_auth(buyer), json={
        "store_id": store_id, "sender_role": "buyer", "sender_id": buyer,
        "content": "Hello"})
    assert r.status_code == 200, r.text
    r = await client.post("/negotiate/direct-message", headers=_auth(owner), json={
        "store_id": store_id, "sender_role": "seller", "sender_id": owner,
        "content": "Welcome", "buyer_id": buyer})
    assert r.status_code == 200, r.text
    token = create_thread_token(buyer, "buyer", buyer, store_id=store_id,
                                device=push_devices.token_fingerprint("store-buyer-phone"))
    r = await client.post("/negotiate/notification/reply",
                          json={"thread_token": token, "content": "Do you deliver?"})
    assert r.status_code == 200, r.text
    assert r.json()["message"]["role"] == "buyer"
    history = (await client.get(f"/negotiate/store/{store_id}/history",
                                headers=_auth(owner), params={"buyer_id": buyer})).json()
    assert history[-1]["content"] == "Do you deliver?"


# ── Albums in the push ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_photos_sent_together_are_announced_as_one_album(client, fcm):
    listing_id, seller, buyer = await _people()
    await _register(client, buyer, "album-push-phone")
    with patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0.3):
        async with AsyncSessionLocal() as db:
            for _ in range(3):
                db.add(NegotiationMessage(
                    listing_id=listing_id, sender_id=seller, role="seller",
                    recipient_role="buyer", content=None,
                    media_url="data:image/webp;base64,AAAA", buyer_id=buyer,
                    via_ai=False, msg_type="image", album_id="album-1"))
            await db.commit()
        await message_push.drain()
    [push] = [p for p in _message_pushes(fcm) if p["data"]["listingId"] == listing_id]
    assert push["body"] == "\U0001F4F7 3 photos"
    assert push["data"]["preview"] == "\U0001F4F7 3 photos"
    assert push["data"]["count"] == 3
