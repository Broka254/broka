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
async def test_inbox_carries_the_listing_photo(client):
    photo = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="
    listing_id, seller_id, buyer_id = await _thread(photo=photo)
    r = await client.get(f"/negotiate/inbox/{seller_id}", headers=_auth(seller_id))
    assert r.status_code == 200, r.text
    threads = [t for t in r.json() if t["listing_id"] == listing_id]
    assert threads, "the seller's thread is in their inbox"
    assert threads[0].get("listing_image") == photo
