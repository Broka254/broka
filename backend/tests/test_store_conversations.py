"""Store-general conversations land in the Inbox (regression).

"Message Store" used to borrow the store's first listing as its thread:
the conversation moved whenever that listing changed, vanished with it,
and a store with nothing live could not be messaged at all. Store threads
are now keyed by (store_id, buyer_id) with no listing.
"""
import base64
import io
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.core.message_push import build_store_notification, store_tag
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_conversations.db"
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


async def _shop(with_listing: bool = True):
    """An owner, their store, a buyer, and optionally one listing."""
    async with AsyncSessionLocal() as db:
        owner = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Keen Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([owner, buyer])
        await db.flush()
        store = Store(owner_id=owner.id, name="Clanix", slug=f"clanix-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.flush()
        listing = None
        if with_listing:
            listing = Listing(seller_id=owner.id, store_id=store.id, name="Phone",
                              category="Electronics", price=25000, lat=-1.28, lng=36.82)
            db.add(listing)
        await db.commit()
        return store.id, owner.id, buyer.id, (listing.id if listing else None)


async def _say(client, store_id, sender, role, content, buyer_id=None, client_msg_id=None):
    body = {"sender_role": role, "sender_id": sender, "content": content}
    if buyer_id:
        body["buyer_id"] = buyer_id
    if client_msg_id:
        body["client_msg_id"] = client_msg_id
    return await client.post(
        f"/negotiate/store/{store_id}/direct-message", json=body, headers=_auth(sender))


async def _say_unified(client, store_id, sender, role, content, buyer_id=None):
    """The same message through the route every new app build uses."""
    body = {
        "store_id": store_id,
        "sender_role": role,
        "sender_id": sender,
        "content": content,
    }
    if buyer_id:
        body["buyer_id"] = buyer_id
    return await client.post("/negotiate/direct-message", json=body, headers=_auth(sender))


def _image_jpeg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (30, 110, 180)).save(buf, "JPEG")
    return buf.getvalue()


async def _upload(
    client, store_id, sender, role, content_type, raw, mime, *,
    buyer_id=None, client_msg_id=None,
):
    data = {
        "store_id": store_id,
        "sender_role": role,
        "sender_id": sender,
        "content_type": content_type,
    }
    if buyer_id:
        data["buyer_id"] = buyer_id
    if client_msg_id:
        data["client_msg_id"] = client_msg_id
    if content_type == "audio":
        data["duration_secs"] = "3"
    return await client.post(
        "/media/upload", data=data,
        files={"file": ("upload.bin", raw, mime)},
        headers=_auth(sender),
    )


def test_store_push_tag_matches_the_app_thread_id():
    assert store_tag("s1", "buyer-1") == "thread_store:s1_buyer-1"


@pytest.mark.asyncio
async def test_a_store_message_is_in_both_inboxes(client):
    store_id, owner, buyer, _ = await _shop()
    r = await _say(client, store_id, buyer, "buyer", "Do you deliver to Kisumu?")
    assert r.status_code == 200, r.text

    buyer_inbox = (await client.get(f"/negotiate/inbox/{buyer}", headers=_auth(buyer))).json()
    thread = next(t for t in buyer_inbox if t.get("store_id") == store_id)
    assert thread["thread_type"] == "store"
    assert thread["listing_id"] is None
    assert thread["last_message"] == "Do you deliver to Kisumu?"
    assert thread["my_role"] == "buyer"

    owner_inbox = (await client.get(f"/negotiate/inbox/{owner}", headers=_auth(owner))).json()
    othread = next(t for t in owner_inbox if t.get("store_id") == store_id)
    assert othread["my_role"] == "seller"
    assert othread["buyer_id"] == buyer
    assert othread["unread"] == 1


@pytest.mark.asyncio
async def test_the_direct_message_route_stores_a_store_thread_without_a_listing(client):
    """The normal chat route, not a store-only one, persists store messages.

    Two separate write paths could disagree about thread identity or bypass
    the Inbox. Store conversations must use the same route as every other
    direct chat while keeping listing_id NULL so archived listings cannot
    take the thread with them.
    """
    store_id, owner, buyer, _ = await _shop(with_listing=False)
    r = await _say_unified(
        client, store_id, buyer, "buyer", "Can I pick this up today?")
    assert r.status_code == 200, r.text
    message = r.json()["message"]
    assert message["content"] == "Can I pick this up today?"

    async with AsyncSessionLocal() as db:
        row = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.id == message["id"]))).scalar_one()
        assert row.store_id == store_id
        assert row.listing_id is None
        assert row.buyer_id == buyer

    reply = await _say_unified(
        client, store_id, owner, "seller", "Yes, until 6pm.", buyer_id=buyer)
    assert reply.status_code == 200, reply.text
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in history] == [
        "Can I pick this up today?", "Yes, until 6pm."]

    thread = next(t for t in (
        await client.get(f"/negotiate/inbox/{buyer}", headers=_auth(buyer))
    ).json() if t.get("store_id") == store_id)
    assert thread["listing_id"] is None
    assert thread["thread_type"] == "store"


@pytest.mark.asyncio
async def test_listing_negotiation_still_requires_a_listing(client):
    """The direct-chat model is wider; the AI negotiation request is not.

    Making MessageIn.listing_id optional for store chats used to let a body
    naming only a store reach POST /negotiate/message, where it was not a
    valid participant in that listing-based flow at all.
    """
    store_id, owner, buyer, _ = await _shop(with_listing=False)
    r = await client.post(
        "/negotiate/message",
        json={
            "store_id": store_id,
            "sender_role": "buyer",
            "sender_id": buyer,
            "content": "This belongs in the direct store chat",
        },
        headers=_auth(buyer),
    )
    assert r.status_code == 422, r.text
    assert "listing_id" in r.text


@pytest.mark.asyncio
async def test_store_push_opens_the_shared_direct_chat(client):
    store_id, owner, buyer, _ = await _shop(with_listing=False)
    sent = await _say_unified(
        client, store_id, buyer, "buyer", "Is this still in stock?")
    assert sent.status_code == 200, sent.text

    async with AsyncSessionLocal() as db:
        # The buyer has no unread copy of their own message; the shop owner
        # is the recipient that should actually receive this push.
        note = await build_store_notification(db, store_id, buyer, "seller")
    assert note is not None
    assert note["data"]["storeId"] == store_id
    assert note["data"]["screen"] == "chat", (
        "store conversations use the same notification route as every direct chat"
    )


@pytest.mark.asyncio
async def test_a_message_names_exactly_one_thread(client):
    store_id, owner, buyer, listing_id = await _shop()
    r = await client.post(
        "/negotiate/direct-message",
        json={
            "listing_id": listing_id,
            "store_id": store_id,
            "sender_role": "buyer",
            "sender_id": buyer,
            "content": "Which conversation is this?",
        },
        headers=_auth(buyer),
    )
    assert r.status_code == 400, r.text
    assert r.json()["detail"] == "listing_id or store_id required"


@pytest.mark.asyncio
async def test_a_store_with_no_listings_can_be_messaged(client):
    store_id, owner, buyer, listing_id = await _shop(with_listing=False)
    assert listing_id is None
    r = await _say(client, store_id, buyer, "buyer", "When do you open?")
    assert r.status_code == 200, r.text
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(owner))).json()
    assert [m["content"] for m in history] == ["When do you open?"]


@pytest.mark.asyncio
async def test_the_thread_survives_its_listings_being_archived(client):
    store_id, owner, buyer, listing_id = await _shop()
    await _say(client, store_id, buyer, "buyer", "Hello shop")
    async with AsyncSessionLocal() as db:
        listing = (await db.execute(
            select(Listing).where(Listing.id == listing_id))).scalar_one()
        listing.status = "cancelled"
        await db.commit()
    inbox = (await client.get(f"/negotiate/inbox/{buyer}", headers=_auth(buyer))).json()
    assert any(t.get("store_id") == store_id for t in inbox)
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in history] == ["Hello shop"]


@pytest.mark.asyncio
async def test_two_buyers_have_separate_store_threads(client):
    store_id, owner, buyer, _ = await _shop()
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.commit()
        other_id = other.id
    await _say(client, store_id, buyer, "buyer", "from buyer one")
    await _say(client, store_id, other_id, "buyer", "from buyer two")
    mine = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in mine] == ["from buyer one"]
    owners_view = (await client.get(
        f"/negotiate/store/{store_id}/history",
        params={"buyer_id": other_id}, headers=_auth(owner))).json()
    assert [m["content"] for m in owners_view] == ["from buyer two"]


@pytest.mark.asyncio
async def test_an_owner_reply_must_name_the_buyer_thread(client):
    """A store owner's write must never fall back to the latest shopper.

    Store history may default to the most recent buyer for convenience, but
    applying that rule to a send routes a reply to whoever wrote last. The
    owner's open chat knows its buyer; the API must require it.
    """
    store_id, owner, buyer, _ = await _shop(with_listing=False)
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}",
                     password_hash="x")
        db.add(other)
        await db.commit()
        other_id = other.id

    assert (await _say(client, store_id, buyer, "buyer", "First buyer")).status_code == 200
    assert (await _say(client, store_id, other_id, "buyer", "Newest buyer")).status_code == 200

    for sender in (
        lambda: _say(client, store_id, owner, "seller", "Wrong thread"),
        lambda: _say_unified(client, store_id, owner, "seller", "Wrong thread"),
    ):
        refused = await sender()
        assert refused.status_code == 400, refused.text
        assert refused.json()["detail"] == "buyer_id is required for a store reply"

    media = await _upload(
        client, store_id, owner, "seller", "audio", b"ID3-wrong-thread", "audio/mpeg")
    assert media.status_code == 400, media.text
    assert media.json()["detail"] == "buyer_id is required for a store reply"

    reply = await _say_unified(
        client, store_id, owner, "seller", "For the first buyer", buyer_id=buyer)
    assert reply.status_code == 200, reply.text
    first_history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    newest_history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(other_id))).json()
    assert [m["content"] for m in first_history] == ["First buyer", "For the first buyer"]
    assert [m["content"] for m in newest_history] == ["Newest buyer"]


@pytest.mark.asyncio
async def test_an_owner_can_only_answer_a_shopper_who_started_the_thread(client):
    """Naming a buyer id is not permission to start a conversation.

    Otherwise any store owner who learned an account id could create a
    thread and push messages to someone who never visited the shop.
    """
    store_id, owner, buyer, _ = await _shop(with_listing=False)
    async with AsyncSessionLocal() as db:
        stranger = User(name="Unrelated Shopper",
                        phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(stranger)
        await db.commit()
        stranger_id = stranger.id

    text = await _say_unified(
        client, store_id, owner, "seller", "Hello stranger", buyer_id=stranger_id)
    assert text.status_code == 403, text.text
    assert text.json()["detail"] == "No existing conversation with this buyer"

    media = await _upload(
        client, store_id, owner, "seller", "audio", b"ID3-stranger", "audio/mpeg",
        buyer_id=stranger_id,
    )
    assert media.status_code == 403, media.text
    assert media.json()["detail"] == "No existing conversation with this buyer"

    # A real account is still not a thread until that shopper speaks.
    before = await _say_unified(
        client, store_id, owner, "seller", "Hello buyer", buyer_id=buyer)
    assert before.status_code == 403, before.text

    started = await _say(
        client, store_id, buyer, "buyer", "Is the shop open?")
    assert started.status_code == 200, started.text
    reply = await _say_unified(
        client, store_id, owner, "seller", "Yes, until 6pm.", buyer_id=buyer)
    assert reply.status_code == 200, reply.text

    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage.buyer_id).where(
            NegotiationMessage.store_id == store_id))).scalars().all()
    assert set(rows) == {buyer}


@pytest.mark.asyncio
async def test_the_owner_answers_and_reads_clear_the_badge(client):
    store_id, owner, buyer, _ = await _shop()
    await _say(client, store_id, buyer, "buyer", "Is the shop open?")
    r = await _say(client, store_id, owner, "seller", "Yes, until 6pm", buyer_id=buyer)
    assert r.status_code == 200, r.text
    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["content"] for m in history] == ["Is the shop open?", "Yes, until 6pm"]

    await client.post(f"/negotiate/store/{store_id}/mark-read",
                      json={}, headers=_auth(owner))
    inbox = (await client.get(f"/negotiate/inbox/{owner}", headers=_auth(owner))).json()
    thread = next(t for t in inbox if t.get("store_id") == store_id)
    assert thread["unread"] == 0


@pytest.mark.asyncio
async def test_a_resend_is_stored_once_and_roles_are_checked(client):
    store_id, owner, buyer, _ = await _shop()
    first = await _say(client, store_id, buyer, "buyer", "Hi", client_msg_id="s-1")
    again = await _say(client, store_id, buyer, "buyer", "Hi", client_msg_id="s-1")
    assert again.json()["message"]["id"] == first.json()["message"]["id"]
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.store_id == store_id))).scalars().all()
    assert len(rows) == 1
    assert rows[0].listing_id is None

    wrong = await _say(client, store_id, buyer, "seller", "I am not the owner")
    assert wrong.status_code == 403
    missing = await _say(client, "no-such-store", buyer, "buyer", "Hello?")
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_a_buyer_cannot_quote_another_buyers_message(client):
    store_id, owner, buyer, _ = await _shop()
    async with AsyncSessionLocal() as db:
        other = User(name="Other Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(other)
        await db.commit()
        other_id = other.id

    first = await _say(client, store_id, buyer, "buyer", "Mine")
    second = await _say(client, store_id, other_id, "buyer", "Not yours")
    assert first.status_code == 200, first.text
    assert second.status_code == 200, second.text
    my_message_id = first.json()["message"]["id"]
    other_message_id = second.json()["message"]["id"]

    # A reply id is a capability only inside its own (store, buyer) thread.
    # Accepting this would let buyer A read buyer B's private message through
    # the preview snapshot written beside buyer A's reply.
    forged = await client.post(
        "/negotiate/direct-message",
        json={
            "store_id": store_id,
            "sender_role": "buyer",
            "sender_id": buyer,
            "content": "What did they say?",
            "reply_to_message_id": other_message_id,
        },
        headers=_auth(buyer),
    )
    assert forged.status_code == 403, forged.text

    # The owner is also confined to the buyer thread they are answering.
    owner_forged = await client.post(
        "/negotiate/direct-message",
        json={
            "store_id": store_id,
            "sender_role": "seller",
            "sender_id": owner,
            "buyer_id": buyer,
            "content": "Quoting the wrong buyer",
            "reply_to_message_id": other_message_id,
        },
        headers=_auth(owner),
    )
    assert owner_forged.status_code == 403, owner_forged.text
    async with AsyncSessionLocal() as db:
        contents = (await db.execute(select(NegotiationMessage.content).where(
            NegotiationMessage.store_id == store_id))).scalars().all()
    assert "What did they say?" not in contents
    assert "Quoting the wrong buyer" not in contents

    # Even a row already persisted with a cross-buyer reference - for example
    # by an older build or a bug - must not borrow that message's preview.
    # History used to resolve reply ids across every buyer in the store.
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(
            listing_id=None,
            store_id=store_id,
            sender_id=buyer,
            role="buyer",
            recipient_role="seller",
            content="Forged history row",
            buyer_id=buyer,
            via_ai=False,
            msg_type="text",
            reply_to_message_id=other_message_id,
            reply_snapshot=None,
        ))
        await db.commit()

    mine = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    forged_row = next(m for m in mine if m["content"] == "Forged history row")
    assert forged_row["reply_preview"] is None

    # A genuine reply in this buyer's own thread still renders its text.
    valid = await client.post(
        "/negotiate/direct-message",
        json={
            "store_id": store_id,
            "sender_role": "buyer",
            "sender_id": buyer,
            "content": "A real reply",
            "reply_to_message_id": my_message_id,
        },
        headers=_auth(buyer),
    )
    assert valid.status_code == 200, valid.text
    mine = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    valid_row = next(m for m in mine if m["content"] == "A real reply")
    assert valid_row["reply_preview"]["preview"] == "Mine"


@pytest.mark.asyncio
async def test_store_photos_and_voice_notes_use_the_shared_media_thread(client):
    store_id, owner, buyer, _ = await _shop(with_listing=False)

    photo = await _upload(
        client, store_id, buyer, "buyer", "image", _image_jpeg(), "image/jpeg",
        client_msg_id="store-photo-1",
    )
    assert photo.status_code == 200, photo.text
    photo_body = photo.json()
    assert photo_body["msg_type"] == "image"
    assert photo_body["media_url"].startswith("data:image/webp;base64,")

    voice = await _upload(
        client, store_id, owner, "seller", "audio", b"ID3-store-voice", "audio/mpeg",
        buyer_id=buyer,
    )
    assert voice.status_code == 200, voice.text
    voice_body = voice.json()
    assert voice_body["msg_type"] == "voice"
    assert voice_body["duration_secs"] == 3

    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.store_id == store_id)
            .order_by(NegotiationMessage.created_at))).scalars().all()
    assert [(r.msg_type, r.buyer_id, r.listing_id) for r in rows] == [
        ("image", buyer, None),
        ("voice", buyer, None),
    ]

    history = (await client.get(
        f"/negotiate/store/{store_id}/history", headers=_auth(buyer))).json()
    assert [m["msg_type"] for m in history] == ["image", "voice"]
    voice_row = next(m for m in history if m["msg_type"] == "voice")
    assert base64.b64decode(
        voice_row["media_url"].split(",", 1)[1]) == b"ID3-store-voice"


@pytest.mark.asyncio
async def test_store_thread_info_resolves_the_other_participant(client):
    """A chat opened from the storefront has no owner id in its route.

    The public store payload intentionally omits it, so the direct-chat
    screen asks this authenticated endpoint before loading presence.
    """
    store_id, owner, buyer, _ = await _shop(with_listing=False)

    buyer_info = await client.get(
        f"/negotiate/store/{store_id}/thread-info", headers=_auth(buyer))
    assert buyer_info.status_code == 200, buyer_info.text
    assert buyer_info.json() == {
        "store_id": store_id,
        "store_name": "Clanix",
        "role": "buyer",
        "buyer_id": buyer,
        "counterpart_id": owner,
    }

    # The owner needs the buyer id to name the person they are answering;
    # it is the same thread id every other store-chat route uses.
    owner_info = await client.get(
        f"/negotiate/store/{store_id}/thread-info",
        params={"buyer_id": buyer}, headers=_auth(owner))
    assert owner_info.status_code == 200, owner_info.text
    assert owner_info.json() == {
        "store_id": store_id,
        "store_name": "Clanix",
        "role": "seller",
        "buyer_id": buyer,
        "counterpart_id": buyer,
    }
