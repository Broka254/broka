"""Quote-replies, persisted Zeno greetings, typing presence and durable
assistant memory.

Each test fails on the old implementation: replies had no column to be
stored in, the greeting returned without writing a row, typing frames were
dropped, and the general assistant kept everything on the phone.
"""
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, ZenoTurn,
    init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_zeno_replies.db"
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
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _direct(client, sender_id, role, listing_id, content, buyer_id=None,
                  client_msg_id=None, reply_to=None):
    body = {"listing_id": listing_id, "sender_role": role, "sender_id": sender_id,
            "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    if client_msg_id:
        body["client_msg_id"] = client_msg_id
    if reply_to:
        body["reply_to_message_id"] = reply_to
    return await client.post("/negotiate/direct-message", json=body, headers=_auth(sender_id))


# ── Quote-replies ─────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_reply_to_a_text_message_is_stored_and_shown_to_both(client):
    listing_id, seller, [buyer] = await _people()
    first = (await _direct(client, buyer, "buyer", listing_id, "Is it available?")).json()["message"]
    reply = await _direct(client, seller, "seller", listing_id, "Yes, karibu",
                          buyer_id=buyer, reply_to=first["id"])
    assert reply.status_code == 200, reply.text
    body = reply.json()["message"]
    assert body["reply_to_message_id"] == first["id"]
    assert body["reply_preview"]["preview"] == "Is it available?"

    for uid, params in ((buyer, {}), (seller, {"buyer_id": buyer})):
        history = (await client.get(f"/negotiate/{listing_id}/history",
                                    params=params, headers=_auth(uid))).json()
        answered = [m for m in history if m["id"] == body["id"]]
        assert answered and answered[0]["reply_to_message_id"] == first["id"]
        assert answered[0]["reply_preview"]["preview"] == "Is it available?"


@pytest.mark.asyncio
async def test_reply_to_another_listing_is_refused(client):
    listing_a, _, [buyer] = await _people()
    listing_b, seller_b, _ = await _people()
    first = (await _direct(client, buyer, "buyer", listing_a, "Hello")).json()["message"]
    r = await _direct(client, seller_b, "seller", listing_b, "Hi",
                      buyer_id=buyer, reply_to=first["id"])
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_reply_to_another_buyers_thread_is_refused(client):
    listing_id, seller, buyers = await _people(2)
    first, second = buyers
    msg = (await _direct(client, first, "buyer", listing_id, "Mine")).json()["message"]
    r = await _direct(client, second, "buyer", listing_id, "Not mine",
                      reply_to=msg["id"])
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_reply_to_a_private_zeno_message_is_refused(client):
    listing_id, seller, [buyer] = await _people()
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer, role="buyer",
                                  content="private to Zeno", buyer_id=buyer, via_ai=True,
                                  msg_type="text"))
        await db.commit()
        private = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.via_ai.is_(True)))).scalars().first()
    r = await _direct(client, seller, "seller", listing_id, "Sneaky?",
                      buyer_id=buyer, reply_to=private.id)
    assert r.status_code == 403


@pytest.mark.asyncio
async def test_reply_to_a_deleted_message_renders_a_safe_fallback(client):
    listing_id, seller, [buyer] = await _people()
    first = (await _direct(client, buyer, "buyer", listing_id, "Typo here")).json()["message"]
    reply = (await _direct(client, seller, "seller", listing_id, "Noted",
                            buyer_id=buyer, reply_to=first["id"])).json()["message"]
    gone = await client.delete(f"/negotiate/message/{first['id']}", headers=_auth(buyer))
    assert gone.status_code == 200
    history = (await client.get(f"/negotiate/{listing_id}/history", headers=_auth(buyer))).json()
    answered = [m for m in history if m["id"] == reply["id"]]
    assert answered and answered[0]["reply_preview"]["deleted"] is True


@pytest.mark.asyncio
async def test_media_upload_carries_the_reply_reference(client):
    listing_id, seller, [buyer] = await _people()
    first = (await _direct(client, buyer, "buyer", listing_id, "Show me the back")).json()["message"]
    # A 1x1 webp; the endpoint re-encodes from pixels, any decodable bytes do.
    import base64 as _b64
    png = _b64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
    r = await client.post(
        "/media/upload",
        files={"file": ("photo.png", png, "image/png")},
        data={"listing_id": listing_id, "sender_role": "seller", "sender_id": seller,
              "content_type": "image", "buyer_id": buyer,
              "reply_to_message_id": first["id"]},
        headers=_auth(seller),
    )
    assert r.status_code == 200, r.text
    assert r.json()["reply_to_message_id"] == first["id"]
    assert r.json()["reply_preview"]["preview"] == "Show me the back"


# ── Persisted Zeno greetings ──────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_opening_the_same_thread_twice_stores_one_greeting(client):
    listing_id, _, [buyer] = await _people()
    body = {"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "", "intent": "opening_greeting", "client_msg_id": f"greet-{uuid.uuid4().hex[:8]}"}
    with patch("api.routers.negotiate._call_ai", new=AsyncMock(return_value="Habari!")):
        first = await client.post("/negotiate/message", json=body, headers=_auth(buyer))
        assert first.status_code == 200, first.text
        # A retry under the same client id and a plain reopen must not mint more.
        retry = await client.post("/negotiate/message", json=body, headers=_auth(buyer))
        plain = await client.post("/negotiate/message",
                                  json={**body, "client_msg_id": None},
                                  headers=_auth(buyer))
    assert retry.json()["id"] == first.json()["id"]
    assert plain.json()["id"] == first.json()["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.role == "broker"))).scalars().all()
    assert len(rows) == 1


# ── Typing presence is never stored ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_typing_broadcast_reaches_only_the_other_side_and_is_throttled():
    from api.routers import media as media_router

    received: list[dict] = []

    class _Sock:
        async def send_json(self, payload):
            received.append(payload)

    media_router._thread_connections["typingtest:buyer1"] = {"s1": "seller1", "b1": "buyer1"}
    # Patch _broadcast to capture instead of needing real sockets.
    real_sockets = media_router._thread_connections["typingtest:buyer1"]
    sent: list[tuple] = []
    orig = media_router._broadcast

    async def _fake(key, payload, exclude_uid=None):
        sent.append((key, dict(payload), exclude_uid))

    media_router._broadcast = _fake  # type: ignore
    try:
        await media_router._broadcast_typing("typingtest:buyer1", "seller1", "seller", typing=True)
        await media_router._broadcast_typing("typingtest:buyer1", "seller1", "seller", typing=True)
        await media_router._broadcast_typing("typingtest:buyer1", "seller1", "seller", typing=False)
    finally:
        media_router._broadcast = orig
        media_router._thread_connections.pop("typingtest:buyer1", None)
        media_router._typing_last.pop("typingtest:buyer1:seller1", None)
    # Second typing swallowed by the throttle; stop_typing always goes.
    assert [p["type"] for _, p, _ in sent] == ["typing", "stop_typing"]
    assert all(ex == "seller1" for _, _, ex in sent)
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == "typingtest"))).scalars().all()
    assert rows == []


# ── Zeno retries are idempotent ───────────────────────────────────────────

@pytest.mark.asyncio
async def test_zeno_retry_returns_the_stored_reply_without_a_duplicate(client):
    listing_id, _, [buyer] = await _people()
    body = {"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "This is a long question about the item condition and delivery timing that is well over sixty characters.",
            "client_msg_id": "zeno-retry-1"}
    with patch("api.routers.negotiate._call_ai", new=AsyncMock(return_value="Happy to help.")), \
         patch("api.routers.negotiate._classify_relay",
               new=AsyncMock(return_value={"needs_relay": False, "relay_summary": "",
                                           "is_availability_confirmation": False})):
        first = await client.post("/negotiate/message", json=body, headers=_auth(buyer))
        assert first.status_code == 200, first.text
        second = await client.post("/negotiate/message", json=body, headers=_auth(buyer))
    assert second.status_code == 200
    assert second.json()["id"] == first.json()["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.buyer_id == buyer))).scalars().all()
        user_rows = [r for r in rows if r.role == "buyer"]
        broker_rows = [r for r in rows if r.role == "broker"]
    assert len(user_rows) == 1
    assert len(broker_rows) == 1


# ── Durable general-Zeno memory ───────────────────────────────────────────────

@pytest.mark.asyncio
async def test_assistant_turns_are_idempotent_and_private_to_their_owner(client):
    from api.security import create_access_token as _tok
    from api.database import User as _User

    async with AsyncSessionLocal() as db:
        owner = _User(name="Zeno Fan", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        other = _User(name="Stranger", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, other])
        await db.commit()
        owner_id, other_id = owner.id, other.id

    from api.domains.zeno_assistant import persistence as _p

    async with AsyncSessionLocal() as db:
        first = await _p.append_turn(db, owner_id, "assistant", None, "user", "hello", "turn-1")
        again = await _p.append_turn(db, owner_id, "assistant", None, "user", "hello", "turn-1")
        assert again.id == first.id
        await _p.append_turn(db, owner_id, "assistant", None, "assistant", "hi there", None)
        mine = await _p.get_turns(db, owner_id, "assistant")
        buying = await _p.get_turns(db, owner_id, "buying")
        strangers = await _p.get_turns(db, other_id, "assistant")
    assert [t.content for t in mine] == ["hello", "hi there"]
    assert buying == [] and strangers == []
    async with AsyncSessionLocal() as db:
        turns = (await db.execute(select(ZenoTurn))).scalars().all()
    assert len([t for t in turns if t.content in ("hello", "hi there")]) == 2


@pytest.mark.asyncio
async def test_assistant_conversation_endpoints_restore_after_reinstall(client):
    from api.database import User as _User

    async with AsyncSessionLocal() as db:
        owner = _User(name="Restore Me", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(owner)
        await db.commit()
        owner_id = owner.id

    put = await client.post(
        "/zeno/assistant/conversation/append",
        json={"mode": "assistant", "role": "user", "content": "remember this", "client_turn_id": "r-1"},
        headers=_auth(owner_id))
    assert put.status_code == 200, put.text
    again = await client.post(
        "/zeno/assistant/conversation/append",
        json={"mode": "assistant", "role": "user", "content": "remember this", "client_turn_id": "r-1"},
        headers=_auth(owner_id))
    assert again.json()["seq"] == put.json()["seq"]

    restored = await client.get("/zeno/assistant/conversation",
                                params={"mode": "assistant"},
                                headers=_auth(owner_id))
    assert restored.status_code == 200
    assert [t["content"] for t in restored.json()["turns"]] == ["remember this"]
