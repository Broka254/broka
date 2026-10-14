"""Answering from a closed app, and faces on notifications (2026-10-08).

Reported from phones:

  * Accepting a call from the notification while BROKA was closed opened
    the app slowly, and the call dropped as it appeared. The caller's
    screen hangs up after 45 seconds unless the callee's socket has joined
    the call, and nothing told it the callee had pressed Accept - a phone
    starting BROKA from cold, then opening the call, needed longer than
    whatever was left of those 45 seconds. /answer now tells the caller.
  * Calls and messages should show the face of the person calling or
    writing. The pushes carry the URL of their profile photo (a picture
    would not fit: FCM carries 4KB), which the app draws onto the
    notification.
"""
import asyncio
import json
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from unittest.mock import patch

from api.core import call_state, message_push
from api.core.call_state import CallState
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.domains.media.service import avatar_url
from api.models.media import MediaAsset
from api.routers import calls
from api.security import create_access_token, create_call_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_call_answer_and_faces.db"
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


async def _avatar_asset(owner_id: str) -> str:
    asset_id = str(uuid.uuid4())
    async with AsyncSessionLocal() as db:
        # Keyed as create_image_asset keys them: by the asset's own id.
        asset = MediaAsset(
            id=asset_id, owner_id=owner_id, purpose="avatar", storage="db", width=480,
            height=480, sha256="x", variants=json.dumps({
                "thumb": {"key": f"img/{asset_id}/thumb.webp", "w": 480, "h": 480},
            }),
        )
        db.add(asset)
        await db.commit()
        return asset.id


async def _people(*, seller_photo: bool = False, buyer_photo: bool = False):
    """A seller with a listing and a buyer who has written to them. A photo
    is an image asset; without one, the buyer has only a base64 selfie that
    was never converted - which must never be pushed."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
                     profile_photo="/9j/" + "A" * 4000)
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
        ids = listing.id, seller.id, buyer.id
    for wanted, uid in ((seller_photo, ids[1]), (buyer_photo, ids[2])):
        if wanted:
            asset_id = await _avatar_asset(uid)
            async with AsyncSessionLocal() as db:
                user = await db.get(User, uid)
                user.profile_photo_id = asset_id
                await db.commit()
    return ids


async def _photo_of(uid: str):
    async with AsyncSessionLocal() as db:
        return await avatar_url(db, uid)


async def _register(client, uid):
    r = await client.post("/calls/register-token", headers=_auth(uid),
                          json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm"})
    assert r.status_code == 200, r.text


async def _call(client, caller, listing_id, callee_id=None):
    body = {"listing_id": listing_id, "caller_name": "Bea Buyer", "call_type": "audio"}
    if callee_id:
        body["callee_id"] = callee_id
    r = await client.post("/calls/initiate", headers=_auth(caller), json=body)
    assert r.status_code == 200, r.text
    return r.json()["room_id"]


def _pushes(fcm, kind):
    return [p for p in fcm.sent if p["data"].get("type") == kind]


# ── Accept reaches the caller ─────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_accept_tells_the_caller_at_once(client, fcm):
    listing_id, seller, buyer = await _people()
    room = await _call(client, buyer, listing_id)
    caller_socket = _Sock()
    calls._rooms[room] = {buyer: caller_socket}
    try:
        r = await client.post(f"/calls/{room}/answer",
                              json={"call_token": create_call_token(seller, room)})
        assert r.status_code == 200
        assert {"type": "callee_answered"} in caller_socket.sent, (
            "the caller's screen stops waiting for an answer the moment Accept "
            "is pressed, not when the callee's app has opened the call")
        # Said once: a second /answer (the call screen's, after the
        # notification's) is not news.
        r = await client.post(f"/calls/{room}/answer",
                              json={"call_token": create_call_token(seller, room)})
        assert r.status_code == 200
        assert caller_socket.sent.count({"type": "callee_answered"}) == 1
    finally:
        calls._rooms.pop(room, None)


@pytest.mark.asyncio
async def test_accepting_a_call_that_is_over_says_so(client, fcm):
    listing_id, seller, buyer = await _people()
    room = await _call(client, buyer, listing_id)
    await call_state.update_state(room, CallState.missed)
    r = await client.post(f"/calls/{room}/answer",
                          json={"call_token": create_call_token(seller, room)})
    assert r.status_code == 410, "the app closes the call it opened instead of connecting to nothing"


# ── Faces ─────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_the_ringing_push_carries_the_callers_photo(client, fcm):
    listing_id, seller, buyer = await _people(buyer_photo=True)
    await _register(client, seller)
    room = await _call(client, buyer, listing_id)
    photo = await _photo_of(buyer)
    assert photo and photo.endswith("/thumb.webp")
    [push] = [p for p in _pushes(fcm, "incoming_call") if p["data"]["roomId"] == room]
    assert push["data"]["callerPhoto"] == photo

    # The app's sweep and the per-listing check find the same face.
    incoming = (await client.get("/calls/incoming", headers=_auth(seller))).json()
    assert incoming["room_id"] == room and incoming["caller_photo"] == photo
    pending = (await client.get(f"/calls/pending/{listing_id}", headers=_auth(seller))).json()
    assert pending["room_id"] == room and pending["caller_photo"] == photo

    # And so does the missed call, if nobody answers.
    async with AsyncSessionLocal() as db:
        session = await call_state.get_session(room)
        listing = await db.get(Listing, listing_id)
        await calls._push_missed_call(db, session, listing, buyer)
    [missed] = [p for p in _pushes(fcm, "missed_call") if p["data"]["roomId"] == room]
    assert missed["data"]["callerPhoto"] == photo
    await call_state.update_state(room, CallState.missed)


@pytest.mark.asyncio
async def test_no_photo_is_an_empty_string_never_the_selfie_itself(client, fcm):
    # The buyer's selfie is base64 the backfill never converted: megabytes,
    # where FCM carries 4KB. Data values are strings, so "none" must be "".
    listing_id, seller, buyer = await _people()
    await _register(client, seller)
    room = await _call(client, buyer, listing_id)
    [push] = [p for p in _pushes(fcm, "incoming_call") if p["data"]["roomId"] == room]
    assert push["data"]["callerPhoto"] == ""
    assert (await client.get("/calls/incoming", headers=_auth(seller))).json()["caller_photo"] is None
    await call_state.update_state(room, CallState.missed)


@pytest.mark.asyncio
async def test_a_photo_saved_as_a_url_by_an_older_app_is_found():
    listing_id, seller, buyer = await _people()
    asset_id = await _avatar_asset(buyer)
    async with AsyncSessionLocal() as db:
        from api.domains.media.service import asset_urls, load_assets
        url = asset_urls((await load_assets(db, [asset_id]))[asset_id])["thumb"]
        user = await db.get(User, buyer)
        user.profile_photo = url
        user.profile_photo_id = ""      # the backfill's "could not convert"
        await db.commit()
    assert await _photo_of(buyer) == url


@pytest.mark.asyncio
async def test_a_message_push_carries_the_senders_photo(client, fcm):
    listing_id, seller, buyer = await _people(buyer_photo=True, seller_photo=True)
    await _register(client, seller)
    await _register(client, buyer)
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer, role="buyer",
                                  recipient_role="seller", content="Last price?", buyer_id=buyer,
                                  via_ai=False, msg_type="text"))
        await db.commit()
    await message_push.drain()
    to_seller = [p for p in _pushes(fcm, "new_message")
                 if p["data"]["listingId"] == listing_id and p["data"]["myRole"] == "seller"][-1]
    assert to_seller["data"]["preview"] == "Last price?"
    assert to_seller["data"]["senderPhoto"] == await _photo_of(buyer)

    # Zeno has no profile photo: nothing is sent for one.
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id="broker", role="broker",
                                  recipient_role="buyer", content="The seller replied.",
                                  buyer_id=buyer, via_ai=True, msg_type="text"))
        await db.commit()
    await message_push.drain()
    [to_buyer] = [p for p in _pushes(fcm, "new_message")
                  if p["data"]["listingId"] == listing_id and p["data"]["myRole"] == "buyer"]
    assert to_buyer["data"]["senderName"] == "Zeno"
    assert "senderPhoto" not in to_buyer["data"]
