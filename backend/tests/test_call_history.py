"""Call history (2026-10-02): GET /calls/history, the app's list of calls.

Asked for from a phone along with a better call screen. Calls were already
recorded - log-result writes a call card into the thread - but only inside
each chat, so "who called me?" meant opening every conversation.

  * Each side sees its own direction: the card stores the CALLER's role,
    and whichever side logged the result first is the sender - often the
    callee - so the sender is not who called.
  * A missed call is missed for the person called, whether the ring ran
    out ("missed") or the caller gave up first ("cancelled").
  * Nobody sees calls from a thread they are not in.
  * The other person's name and photo come once per person, not per call.
"""
import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.core import call_state
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_call_history.db"
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
    """A seller, their listing, and [n_buyers] buyers."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}",
                      password_hash="x", profile_photo="c2VsbGVy")
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(n_buyers)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Airtel 5G router", category="Electronics",
                          price=4500, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


async def _log(client, listing_id, caller, callee, logged_by, outcome,
               call_type="audio", duration=None):
    """A real call: the session /calls/initiate would create, then its result."""
    room_id = f"room-{uuid.uuid4().hex[:10]}"
    await call_state.create_session(
        room_id=room_id, caller_id=caller, callee_id=callee, listing_id=listing_id,
        call_type=call_type, caller_name="whoever",
    )
    body = {"room_id": room_id, "outcome": outcome}
    if duration is not None:
        body["duration_secs"] = duration
    with patch("api.routers.calls._send_fcm", new=AsyncMock(return_value=True)):
        r = await client.post("/calls/log-result", headers=_auth(logged_by), json=body)
    assert r.status_code == 200, r.text


async def _history(client, uid, **params):
    r = await client.get("/calls/history", headers=_auth(uid), params=params)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.mark.asyncio
async def test_each_side_sees_the_call_in_its_own_direction(client):
    listing_id, seller, [buyer] = await _people()
    # The seller rang; the BUYER's app happened to log the result, so the
    # card's sender is the buyer - who did not place the call.
    await _log(client, listing_id, caller=seller, callee=buyer, logged_by=buyer,
               outcome="completed", duration=95)

    mine = (await _history(client, seller))["calls"]
    theirs = (await _history(client, buyer))["calls"]
    assert len(mine) == len(theirs) == 1
    assert mine[0]["direction"] == "outgoing"
    assert theirs[0]["direction"] == "incoming"
    for c in (mine[0], theirs[0]):
        assert c["outcome"] == "completed"
        assert c["missed"] is False
        assert c["duration_secs"] == 95
        assert c["listing_id"] == listing_id
        assert c["listing_name"] == "Airtel 5G router"
        assert c["buyer_id"] == buyer
        assert c["created_at"].endswith("Z")
    assert mine[0]["my_role"] == "seller" and mine[0]["peer_id"] == buyer
    assert theirs[0]["my_role"] == "buyer" and theirs[0]["peer_id"] == seller


@pytest.mark.asyncio
@pytest.mark.parametrize("outcome", ["missed", "cancelled"])
async def test_an_unanswered_call_is_missed_for_the_person_called_only(client, outcome):
    listing_id, seller, [buyer] = await _people()
    await _log(client, listing_id, caller=buyer, callee=seller, logged_by=buyer,
               outcome=outcome, call_type="video")

    called = (await _history(client, seller))["calls"][0]
    caller = (await _history(client, buyer))["calls"][0]
    assert called["missed"] is True and called["direction"] == "incoming"
    assert caller["missed"] is False and caller["direction"] == "outgoing"
    assert called["call_type"] == caller["call_type"] == "video"
    assert called["outcome"] == outcome


@pytest.mark.asyncio
async def test_names_and_photos_come_once_per_person(client):
    listing_id, seller, [buyer] = await _people()
    for _ in range(3):
        await _log(client, listing_id, caller=buyer, callee=seller, logged_by=seller,
                   outcome="declined")
    body = await _history(client, buyer)
    assert len(body["calls"]) == 3
    assert set(body["people"]) == {seller}
    assert body["people"][seller]["name"] == "Sam Seller"
    assert body["people"][seller]["photo"] == "c2VsbGVy"
    assert "is_online" in body["people"][seller]
    # The seller is shown the buyer's real name - the call screen and the
    # chat used to say "Buyer".
    seller_view = await _history(client, seller)
    assert seller_view["people"][buyer]["name"] == "Buyer 0"


@pytest.mark.asyncio
async def test_a_seller_sees_every_buyer_but_a_buyer_sees_only_their_own(client):
    listing_id, seller, [b1, b2] = await _people(2)
    await _log(client, listing_id, caller=b1, callee=seller, logged_by=b1, outcome="completed")
    await _log(client, listing_id, caller=seller, callee=b2, logged_by=seller, outcome="cancelled")

    seller_calls = (await _history(client, seller))["calls"]
    assert {c["peer_id"] for c in seller_calls} == {b1, b2}
    b1_calls = (await _history(client, b1))["calls"]
    b2_calls = (await _history(client, b2))["calls"]
    assert [c["buyer_id"] for c in b1_calls] == [b1]
    assert [c["buyer_id"] for c in b2_calls] == [b2]
    # The seller gave up before b2 answered: a missed call to b2.
    assert b2_calls[0]["missed"] is True


@pytest.mark.asyncio
async def test_chat_messages_and_strangers_calls_are_not_in_the_history(client):
    listing_id, seller, [buyer] = await _people()
    _, _, [other_buyer] = await _people()
    async with AsyncSessionLocal() as db:
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer, role="buyer",
                                  content="hello", buyer_id=buyer, msg_type="text"))
        # A legacy card with no thread: shown to nobody.
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer, role="buyer",
                                  content="missed", buyer_id=None, msg_type="call"))
        await db.commit()
    assert (await _history(client, buyer))["calls"] == []
    assert (await _history(client, seller))["calls"] == []
    assert (await _history(client, other_buyer))["calls"] == []


@pytest.mark.asyncio
async def test_newest_first_in_pages(client):
    listing_id, seller, [buyer] = await _people()
    base = datetime(2026, 9, 1, 12, 0, 0)
    async with AsyncSessionLocal() as db:
        for i in range(5):
            db.add(NegotiationMessage(
                listing_id=listing_id, sender_id=buyer, role="buyer", content="completed",
                buyer_id=buyer, msg_type="call", call_type="audio", duration_secs=i,
                created_at=base + timedelta(minutes=i)))
        await db.commit()

    first = await _history(client, buyer, limit=2)
    assert [c["duration_secs"] for c in first["calls"]] == [4, 3]
    assert first["next_before"] == first["calls"][-1]["created_at"]
    second = await _history(client, buyer, limit=2, before=first["next_before"])
    assert [c["duration_secs"] for c in second["calls"]] == [2, 1]
    last = await _history(client, buyer, limit=2, before=second["next_before"])
    assert [c["duration_secs"] for c in last["calls"]] == [0]
    assert last["next_before"] is None


@pytest.mark.asyncio
async def test_bad_paging_input_is_refused(client):
    _, _, [buyer] = await _people()
    r = await client.get("/calls/history", headers=_auth(buyer), params={"before": "yesterday"})
    assert r.status_code == 422
    r = await client.get("/calls/history", headers=_auth(buyer), params={"limit": 1000})
    assert r.status_code == 422


@pytest.mark.asyncio
async def test_signed_out_is_refused(client):
    r = await client.get("/calls/history")
    assert r.status_code in (401, 403)


# ── Mobile data (2026-11-08) ─────────────────────────────────────────────────
# The app opens the call history from the Inbox, often, and the answer is
# nearly always the one it already has: it now revalidates with the last
# ETag and gets an empty 304. Lean answers send a stored photo as its small
# URL instead of the base64 selfie, once per open.

@pytest.mark.asyncio
async def test_an_unchanged_call_history_is_a_304_and_a_new_call_is_not(client):
    listing_id, seller, (buyer,) = await _people()
    await _log(client, listing_id, buyer, seller, seller, "completed", duration=30)
    first = await client.get("/calls/history", headers=_auth(seller))
    assert first.status_code == 200
    etag = first.headers["etag"]
    again = await client.get("/calls/history", headers={**_auth(seller), "If-None-Match": etag})
    assert again.status_code == 304
    assert again.content == b""

    await _log(client, listing_id, buyer, seller, seller, "missed")
    changed = await client.get("/calls/history", headers={**_auth(seller), "If-None-Match": etag})
    assert changed.status_code == 200
    assert len(changed.json()["calls"]) == 2


@pytest.mark.asyncio
async def test_the_call_history_tag_ignores_the_last_seen_clock(client):
    listing_id, seller, (buyer,) = await _people()
    await _log(client, listing_id, buyer, seller, seller, "completed", duration=5)
    async with AsyncSessionLocal() as db:
        await db.execute(User.__table__.update().where(User.id == buyer)
                         .values(last_seen=datetime.utcnow() - timedelta(hours=3)))
        await db.commit()
    first = await client.get("/calls/history", headers=_auth(seller))
    async with AsyncSessionLocal() as db:
        await db.execute(User.__table__.update().where(User.id == buyer)
                         .values(last_seen=datetime.utcnow() - timedelta(hours=5)))
        await db.commit()
    again = await client.get("/calls/history",
                             headers={**_auth(seller), "If-None-Match": first.headers["etag"]})
    assert again.status_code == 304, "only the 'Active 3h ago' text moved"


@pytest.mark.asyncio
async def test_lean_sends_a_stored_photo_as_its_url_and_older_builds_get_base64(client):
    import json as _json
    from api.models.media import MediaAsset
    listing_id, seller, (buyer,) = await _people()
    await _log(client, listing_id, buyer, seller, buyer, "completed", duration=5)
    asset_id = str(uuid.uuid4())
    async with AsyncSessionLocal() as db:
        db.add(MediaAsset(
            id=asset_id, owner_id=seller, purpose="avatar", storage="db", width=480,
            height=480, sha256="x", variants=_json.dumps({
                "thumb": {"key": f"img/{asset_id}/thumb.webp", "w": 480, "h": 480},
            })))
        await db.execute(User.__table__.update().where(User.id == seller)
                         .values(profile_photo_id=asset_id))
        await db.commit()

    lean = (await client.get("/calls/history", headers=_auth(buyer),
                             params={"lean": "true"})).json()["people"][seller]
    assert lean["photo"] is None
    assert lean["photo_url"].endswith(f"{asset_id}/thumb.webp")

    full = (await client.get("/calls/history", headers=_auth(buyer))).json()["people"][seller]
    assert full["photo"] == "c2VsbGVy"
    assert "photo_url" not in full


@pytest.mark.asyncio
async def test_lean_keeps_an_unconverted_selfie(client):
    listing_id, seller, (buyer,) = await _people()
    await _log(client, listing_id, buyer, seller, buyer, "completed", duration=5)
    person = (await client.get("/calls/history", headers=_auth(buyer),
                               params={"lean": "true"})).json()["people"][seller]
    assert person["photo"] == "c2VsbGVy"
    assert person["photo_url"] is None
