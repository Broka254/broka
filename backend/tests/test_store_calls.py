"""Store-general calls use the same session, card and history path as chats.

A store conversation has no listing, so its calls must be keyed by the store
and buyer instead. Losing that identity left store calls ringing nowhere,
missing from call history, and absent from the conversation they belonged to.
"""
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_calls.db"
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


async def _shop():
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}",
                     password_hash="x", profile_photo="b3duZXI=")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}",
                     password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix Electronics",
                      slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.commit()
        return store.id, owner.id, buyer.id


async def _start_conversation(store_id: str, buyer_id: str) -> None:
    """The relationship /initiate requires before a seller may ring a buyer."""
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=None, store_id=store_id, sender_id=buyer_id, role="buyer",
            recipient_role="seller", content="Is the shop open?", buyer_id=buyer_id,
            via_ai=False, msg_type="text",
        ))
        await db.commit()


@pytest.mark.asyncio
async def test_a_store_call_rings_the_owner_and_records_its_thread(client):
    store_id, owner, buyer = await _shop()

    started = await client.post(
        "/calls/initiate", headers=_auth(buyer),
        json={
            "store_id": store_id,
            "caller_name": "Keen Buyer",
            "listing_name": "Clanix Electronics",
            "call_type": "video",
        },
    )
    assert started.status_code == 200, started.text
    room_id = started.json()["room_id"]

    pending = await client.get(
        f"/calls/pending/store/{store_id}", headers=_auth(owner))
    assert pending.status_code == 200, pending.text
    incoming = pending.json()
    assert incoming["has_call"] is True
    assert incoming["room_id"] == room_id
    assert incoming["store_id"] == store_id
    assert incoming["listing_id"] is None
    assert incoming["caller_id"] == buyer

    # The caller gives up. The owner is the callee, so it is a missed call
    # for them, with a store-keyed card in the shared conversation.
    push = AsyncMock(return_value=1)
    with patch("api.routers.calls.push_devices.push_user", new=push):
        logged = await client.post(
            "/calls/log-result", headers=_auth(buyer),
            json={"room_id": room_id, "outcome": "cancelled"},
        )
    assert logged.status_code == 200, logged.text

    owner_calls = (await client.get(
        "/calls/history", headers=_auth(owner))).json()["calls"]
    call = next(c for c in owner_calls if c["id"] and c["store_id"] == store_id)
    assert call["listing_id"] is None
    assert call["store_name"] == "Clanix Electronics"
    assert call["listing_name"] == "Clanix Electronics"
    assert call["direction"] == "incoming"
    assert call["missed"] is True
    assert call["call_type"] == "video"

    buyer_calls = (await client.get(
        "/calls/history", headers=_auth(buyer))).json()["calls"]
    seen_by_buyer = next(c for c in buyer_calls if c["id"] == call["id"])
    assert seen_by_buyer["direction"] == "outgoing"
    assert seen_by_buyer["missed"] is False
    assert seen_by_buyer["store_id"] == store_id

    history = (await client.get(
        f"/negotiate/store/{store_id}/history",
        params={"buyer_id": buyer}, headers=_auth(owner))).json()
    card = next(m for m in history if m["msg_type"] == "call")
    assert card["content"] == "cancelled"
    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == card["id"]))).scalar_one()
        assert row.store_id == store_id
        assert row.listing_id is None

    assert push.await_count == 1
    data = push.await_args.kwargs["data"]
    assert data["storeId"] == store_id
    assert data["listingId"] == ""
    assert data["myRole"] == "seller"
    assert push.await_args.kwargs["android_tag"] == f"missed_store:{store_id}_{buyer}"


@pytest.mark.asyncio
async def test_the_owner_can_call_a_buyer_from_their_store_thread(client):
    store_id, owner, buyer = await _shop()
    await _start_conversation(store_id, buyer)

    started = await client.post(
        "/calls/initiate", headers=_auth(owner),
        json={
            "store_id": store_id,
            "callee_id": buyer,
            "caller_name": "Shop Owner",
            "listing_name": "Clanix Electronics",
            "call_type": "audio",
        },
    )
    assert started.status_code == 200, started.text
    room_id = started.json()["room_id"]

    pending = await client.get(
        f"/calls/pending/store/{store_id}", headers=_auth(buyer))
    assert pending.status_code == 200, pending.text
    incoming = pending.json()
    assert incoming["has_call"] is True
    assert incoming["room_id"] == room_id
    assert incoming["store_id"] == store_id
    assert incoming["listing_id"] is None
    assert incoming["caller_id"] == owner
