"""Offline-to-online recovery: a message sent while a phone was away must
still be announced when that phone becomes reachable again.

Three holes are pinned here:

  * A push that reached no phone (recipient offline, token not yet
    registered, transient FCM failure) was recorded in
    `message_push._last_pushed` *before* it was sent, so the one message
    that mattered could never be pushed again for that thread.
  * Registering a phone said nothing about what was already waiting:
    unread threads stayed silent until some *new* message arrived.
  * The inbox carried no listing photo, so the app could only draw a
    generic category icon for the conversation group.

  A fourth, later: two push tasks for the same thread (a debounce run
  racing a register-time re-push) both passed the _last_pushed guard and
  both sent, because the FCM await yielded between the check and the
  record. push_thread now holds a per-thread lock across guard-and-send.
"""
import asyncio
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.core import message_push
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.routers import calls
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_offline_recovery.db"
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


async def _thread(content="Is this still available?", *, photo=None):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(
            seller_id=seller.id, name="Airtel 5G router", category="Electronics",
            price=1500, lat=-1.28, lng=36.82, verified_photos=photo,
        )
        db.add(listing)
        await db.flush()
        db.add(NegotiationMessage(
            listing_id=listing.id, sender_id=buyer.id, role="buyer",
            recipient_role="seller", content=content, buyer_id=buyer.id,
            via_ai=False, msg_type="text",
        ))
        await db.commit()
        return listing.id, seller.id, buyer.id


@pytest.mark.asyncio
async def test_a_push_that_reached_no_phone_is_not_recorded_as_pushed():
    listing_id, seller_id, buyer_id = await _thread()
    message_push._last_pushed.pop((listing_id, buyer_id, "seller"), None)
    with patch("api.core.push_devices.push_user", new=AsyncMock(return_value=0)):
        sent = await message_push.push_thread(listing_id, buyer_id, "seller")
    assert sent == 0
    assert message_push._last_pushed.get((listing_id, buyer_id, "seller")) is None, (
        "a push nobody received must not suppress the next attempt for this message"
    )
    # And the next attempt really can go out for the same message.
    with patch("api.core.push_devices.push_user", new=AsyncMock(return_value=1)) as send:
        sent = await message_push.push_thread(listing_id, buyer_id, "seller")
    assert sent == 1
    assert send.await_count == 1


@pytest.mark.asyncio
async def test_two_racing_pushes_send_only_once():
    listing_id, seller_id, buyer_id = await _thread()
    key = (listing_id, buyer_id, "seller")
    message_push._last_pushed.pop(key, None)
    entered = 0

    async def _send(*args, **kwargs):
        nonlocal entered
        entered += 1
        # Yield mid-send: without the per-thread lock, the second task
        # passes the guard while the first is parked here, and both send.
        await asyncio.sleep(0.05)
        return 1

    with patch("api.core.push_devices.push_user", new=_send):
        sent_a, sent_b = await asyncio.gather(
            message_push.push_thread(listing_id, buyer_id, "seller"),
            message_push.push_thread(listing_id, buyer_id, "seller"),
        )
    assert entered == 1, "two racing tasks must not both send"
    assert sorted((sent_a, sent_b)) == [0, 1]


@pytest.mark.asyncio
async def test_registering_a_new_phone_announces_what_is_already_unread(client):
    listing_id, seller_id, buyer_id = await _thread("Sent while you were offline")
    sent = []

    async def _send(**kwargs):
        sent.append(kwargs)
        return calls.FcmResult(True)

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        r = await client.post(
            "/calls/register-token", headers=_auth(seller_id),
            json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm",
                  "platform": "android"})
        assert r.status_code == 200, r.text
        await message_push.drain()
    previews = [s.get("data", {}).get("preview") for s in sent]
    assert "Sent while you were offline" in previews, (
        f"a phone that registers must be told about unread threads, got {previews!r}"
    )

    # Registering the same phone again (an ordinary app start) must not
    # buzz it all over again.
    sent.clear()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        async with AsyncSessionLocal() as db:
            from api.models.push_device import PushDevice
            from sqlalchemy import select
            token = (await db.execute(
                select(PushDevice.token).where(PushDevice.user_id == seller_id)
            )).scalars().first()
        r = await client.post(
            "/calls/register-token", headers=_auth(seller_id),
            json={"fcm_token": token, "token_type": "fcm", "platform": "android"})
        assert r.status_code == 200, r.text
        await message_push.drain()
        await asyncio.sleep(0)
    assert sent == [], "re-registering the same phone must not re-announce old news"


@pytest.mark.asyncio
async def test_a_register_time_repush_does_not_repeat_a_message_already_announced(client):
    """CI (Backend Tests, PostgreSQL 16): test_a_photo_is_announced_as_a_photo
    found two pushes for one photo. The phone registered, the photo landed
    before the registration's re-push read the thread, and the re-push then
    announced it a second time on top of the photo's own debounced push.
    A phone already told about a message must not be told again."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Samsung A54", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        listing_id, seller_id, buyer_id = listing.id, seller.id, buyer.id
    sent = []

    async def _send(**kwargs):
        sent.append(kwargs)
        return calls.FcmResult(True)

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        r = await client.post(
            "/calls/register-token", headers=_auth(buyer_id),
            json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm",
                  "platform": "android"})
        assert r.status_code == 200, r.text
        # The registration alone has nothing to announce: no threads yet.
        await message_push.drain()
        assert sent == []

        async with AsyncSessionLocal() as db:
            db.add(NegotiationMessage(
                listing_id=listing_id, sender_id=seller_id, role="seller",
                recipient_role="buyer", content="data:image/webp;base64,AAAA",
                buyer_id=buyer_id, via_ai=False, msg_type="image"))
            await db.commit()
        # The photo's own push goes out...
        await message_push.drain()
        assert len(sent) == 1, f"the photo's push must go out, got {len(sent)}"
        # ...and the registration's re-push arrives afterwards, as it did in CI.
        await message_push.push_unread_for_user(buyer_id)

    pushes = [p for p in sent if p["data"].get("type") == "new_message"]
    assert len(pushes) == 1, (
        f"one photo must be announced once, got {len(pushes)} pushes")


@pytest.mark.asyncio
async def test_inbox_carries_the_listing_photo(client):
    photo = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
    listing_id, seller_id, buyer_id = await _thread(photo=photo)
    r = await client.get(f"/negotiate/inbox/{seller_id}", headers=_auth(seller_id))
    assert r.status_code == 200, r.text
    threads = [t for t in r.json() if t["listing_id"] == listing_id]
    assert threads, "the seller's thread is in their inbox"
    assert threads[0].get("listing_image") == photo


@pytest.mark.asyncio
async def test_two_devices_sending_with_one_client_id_store_one_message(client):
    """A phone and a tablet flushing the same queued message: the second
    arrival is recognised by client_msg_id, not stored twice."""
    listing_id, seller_id, buyer_id = await _thread()
    body = {"listing_id": listing_id, "sender_role": "buyer",
            "sender_id": buyer_id, "content": "Still there?",
            "client_msg_id": "two-devices-one-id"}
    first = await client.post("/negotiate/direct-message", json=body,
                              headers=_auth(buyer_id))
    second = await client.post("/negotiate/direct-message", json=body,
                               headers=_auth(buyer_id))
    assert first.status_code == 200 and second.status_code == 200
    assert first.json()["message"]["id"] == second.json()["message"]["id"]
    async with AsyncSessionLocal() as db:
        from sqlalchemy import select as _select
        rows = (await db.execute(_select(NegotiationMessage).where(
            NegotiationMessage.client_msg_id == "two-devices-one-id"))).scalars().all()
    assert len(rows) == 1


@pytest.mark.asyncio
async def test_history_orders_messages_despite_out_of_order_arrival(client):
    """Three sends racing each other still read back oldest-first: the
    thread never shows a shuffled conversation."""
    import asyncio as _asyncio
    listing_id, seller_id, buyer_id = await _thread()

    async def send(i: int):
        body = {"listing_id": listing_id, "sender_role": "buyer",
                "sender_id": buyer_id, "content": f"msg {i}",
                "client_msg_id": f"ooo-{uuid.uuid4().hex[:8]}"}
        r = await client.post("/negotiate/direct-message", json=body,
                              headers=_auth(buyer_id))
        assert r.status_code == 200

    await _asyncio.gather(*[send(i) for i in range(3)])
    history = (await client.get(f"/negotiate/{listing_id}/history",
                                headers=_auth(buyer_id))).json()
    mine = [m for m in history if m["content"].startswith("msg ")]
    # Each arrival stored exactly once, and the thread reads back in
    # created_at order: racing sends share a timestamp down to the
    # microsecond, so request order is not a contract - stable
    # oldest-first display is (the phone sorts the same way).
    assert sorted(m["content"] for m in mine) == [f"msg {i}" for i in range(3)]
    stamps = [m["created_at"] for m in history]
    assert stamps == sorted(stamps)
