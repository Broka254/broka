"""What an acknowledgement of something untracked says (2026-11-14).

Railway's log carried many `MESSAGE_DELIVERY_ACK_RECEIVED result=unknown
source=chat` lines. The open chat acknowledges every message from the other
side that it shows - and among them are call cards (never tracked: a call
sends its own missed-call push), messages written before delivery tracking
existed or pruned since, and Zeno's legacy shared replies. None of those is
a delivery failure, and none may be counted delivered. They are now one
MESSAGE_DELIVERY_ACK_UNTRACKED line per acknowledgement, by reason; an id
that is no message, or a message in someone else's conversation, is logged
on its own at WARNING.

And a photo is delivered the way a text is: tracked when saved, pushed,
handed out by the sync until the phone acknowledges it, and only then
DELIVERED - never because Firebase took the push.
"""
import asyncio
import io
import logging
import uuid
from unittest.mock import patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import delete, select

from api.core import message_push
from api.database import AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine
from api.models.message_delivery import MessageDelivery
from api.routers import calls
from api.security import create_access_token
from main import app

LOGGER = "api.core.message_delivery"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_message_ack_untracked.db"
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


@pytest_asyncio.fixture(autouse=True)
async def _pushes_settled():
    yield
    loop = asyncio.get_running_loop()
    while True:
        pending = [t for t in list(message_push._inflight)
                   if t.get_loop() is loop and not t.done()]
        if not pending:
            return
        await asyncio.gather(*pending, return_exceptions=True)


class FakeFcm:
    def __init__(self):
        self.sent: list[dict] = []

    async def __call__(self, **kwargs):
        self.sent.append(kwargs)
        return calls.FcmResult(True, message_id=f"projects/broka/messages/{len(self.sent)}")


@pytest_asyncio.fixture
async def fcm():
    fake = FakeFcm()
    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=fake), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0):
        yield fake
        await message_push.drain()
    message_push._last_pushed.clear()


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


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None) -> dict:
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    r = await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))
    assert r.status_code == 200, r.text
    return r.json()["message"]


async def _ack(client, uid, ids, source="chat"):
    r = await client.post("/negotiate/sync/ack", json={"message_ids": ids, "source": source},
                          headers=_auth(uid))
    assert r.status_code == 200, r.text
    return r.json()


async def _status(message_id: str):
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(MessageDelivery.status).where(
            MessageDelivery.message_id == message_id))).scalars().all()
    return rows[0] if len(rows) == 1 else rows


async def _call_card(listing_id, seller_id, buyer_id) -> str:
    async with AsyncSessionLocal() as db:
        card = NegotiationMessage(listing_id=listing_id, sender_id=seller_id, role="seller",
                                  recipient_role=None, content="missed", buyer_id=buyer_id,
                                  via_ai=False, msg_type="call", call_type="audio")
        db.add(card)
        await db.commit()
        return card.id


def _lines(caplog, event):
    return [r.getMessage() for r in caplog.records
            if r.name == LOGGER and r.getMessage().startswith(event + " ")]


@pytest.mark.asyncio
async def test_a_call_card_acknowledged_by_the_chat_is_untracked_not_delivered(client, caplog):
    listing_id, seller, buyer = await _people()
    card = await _call_card(listing_id, seller, buyer)
    message = await _direct(client, seller, "seller", listing_id, "Call me back", buyer_id=buyer)
    with caplog.at_level(logging.INFO, logger=LOGGER):
        ack = await _ack(client, buyer, [card, message["id"]])
    assert ack["unknown"] == [card] and ack["delivered"] == [message["id"]]
    assert await _status(message["id"]) == "DELIVERED"
    async with AsyncSessionLocal() as db:
        assert (await db.execute(select(MessageDelivery).where(
            MessageDelivery.message_id == card))).first() is None, "nothing written for it"
    [line] = _lines(caplog, "MESSAGE_DELIVERY_ACK_UNTRACKED")
    assert "call_card=1" in line and "count=1" in line and "source=chat" in line
    assert not any("result=unknown" in l for l in _lines(caplog, "MESSAGE_DELIVERY_ACK_RECEIVED")), (
        "no line per id for what was never tracked")
    assert not [r for r in caplog.records if r.levelno >= logging.WARNING and r.name == LOGGER]


@pytest.mark.asyncio
async def test_untracked_ids_say_why_and_only_faults_are_warnings(client, caplog):
    listing_id, seller, buyer = await _people()
    other_listing, other_seller, other_buyer = await _people()
    mine = await _direct(client, buyer, "buyer", listing_id, "Is it available?")
    theirs = await _direct(client, seller, "seller", listing_id, "Yes", buyer_id=buyer)
    # Written before delivery tracking existed (or pruned since).
    legacy = await _direct(client, seller, "seller", listing_id, "Still there?", buyer_id=buyer)
    async with AsyncSessionLocal() as db:
        await db.execute(delete(MessageDelivery).where(MessageDelivery.message_id == legacy["id"]))
        await db.commit()
    elsewhere = await _direct(client, other_buyer, "buyer", other_listing, "Not yours")
    bogus = str(uuid.uuid4())

    with caplog.at_level(logging.INFO, logger=LOGGER):
        ack = await _ack(client, buyer, [mine["id"], theirs["id"], legacy["id"],
                                         elsewhere["id"], bogus])
    assert ack["delivered"] == [theirs["id"]]
    assert set(ack["unknown"]) == {mine["id"], legacy["id"], elsewhere["id"], bogus}
    assert await _status(elsewhere["id"]) == "SAVED", "another account's message is untouched"
    [line] = _lines(caplog, "MESSAGE_DELIVERY_ACK_UNTRACKED")
    for part in ("count=4", "own_message=1", "untracked=1", "not_recipient=1", "not_found=1"):
        assert part in line, line
    rejected = [r.getMessage() for r in caplog.records
                if r.levelno == logging.WARNING and "MESSAGE_DELIVERY_ACK_REJECTED" in r.getMessage()]
    assert len(rejected) == 2
    assert any(f"message_id={elsewhere['id']}" in l and "reason=not_recipient" in l for l in rejected)
    assert any(f"message_id={bogus}" in l and "reason=not_found" in l for l in rejected)


@pytest.mark.asyncio
async def test_a_photo_is_delivered_the_way_a_text_is(client, fcm):
    listing_id, seller, buyer = await _people()
    r = await client.post("/calls/register-token", headers=_auth(seller),
                          json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm"})
    assert r.status_code == 200, r.text
    await message_push.drain()

    buf = io.BytesIO()
    Image.new("RGB", (640, 480), (40, 120, 200)).save(buf, "JPEG")
    r = await client.post(
        "/media/upload", headers=_auth(buyer),
        data={"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
              "content_type": "image"},
        files={"file": ("photo.jpg", buf.getvalue(), "image/jpeg")},
    )
    assert r.status_code == 200, r.text
    photo = r.json()["id"]
    await message_push.drain()

    assert [p["data"].get("type") for p in fcm.sent] == ["new_message"]
    assert await _status(photo) == "PUSH_ACCEPTED", "Firebase taking the push is not delivery"
    synced = (await client.get("/negotiate/sync", headers=_auth(seller))).json()["messages"]
    out = next(m for m in synced if m["id"] == photo)
    assert out["msg_type"] == "image"
    assert await _status(photo) == "PUSH_ACCEPTED", "handed out is not delivered either"
    ack = await _ack(client, seller, [photo], source="sync")
    assert ack["delivered"] == [photo]
    assert await _status(photo) == "DELIVERED"
    again = (await client.get("/negotiate/sync", headers=_auth(seller))).json()["messages"]
    assert photo not in [m["id"] for m in again], "delivered: not handed out again"


@pytest.mark.asyncio
async def test_a_message_for_a_phone_that_is_off_stays_pending_until_its_app_has_it(client):
    """No push route at all: the message waits, the sync hands it out on
    every pass until acknowledged, and an acknowledgement by anyone else
    changes nothing."""
    listing_id, seller, buyer = await _people()
    message = await _direct(client, buyer, "buyer", listing_id, "Are you there?")
    assert await _status(message["id"]) == "SAVED"
    for _ in range(2):
        pending = (await client.get("/negotiate/sync", headers=_auth(seller))).json()["messages"]
        assert message["id"] in [m["id"] for m in pending]
    assert (await _ack(client, buyer, [message["id"]]))["unknown"] == [message["id"]]
    assert await _status(message["id"]) == "SAVED"
    await _ack(client, seller, [message["id"]], source="sync")
    assert await _status(message["id"]) == "DELIVERED"
