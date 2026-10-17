"""Message-push ordering: a slow first send must not land after the fresh one.

Regression test for the CI failure in
test_call_answer_and_faces.py::test_a_message_push_carries_the_senders_photo,
where the taken push previewed 'hi' instead of 'Last price?'.

Two push tasks for one thread can overlap: the first builds its note from a
snapshot taken before the second message exists, the second sends the fresh
text first, and the stale first must then stand down. Android collapses one
thread's notifications by tag, so whatever lands last wins - a stale send
landing second overwrites the fresh notification with old text. The
generation guard in api/core/message_push.py suppresses exactly that send;
this test holds the first task between building and sending, lets the second
message's task send, and asserts only the fresh push goes out.
"""
import asyncio
import uuid
from unittest.mock import patch

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
    db_path = tmp_path_factory.mktemp("data") / "test_message_push_ordering.db"
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


@pytest.mark.asyncio
async def test_a_stale_send_stands_down_once_the_fresh_push_is_out(client):
    sent = []

    async def _send(**kwargs):
        sent.append(kwargs)
        return calls.FcmResult(True)

    real_build = message_push.build_notification
    built_first = asyncio.Event()
    release_first = asyncio.Event()
    builds = 0

    async def _gated_build(db, *args, **kwargs):
        nonlocal builds
        builds += 1
        note = await real_build(db, *args, **kwargs)
        if builds == 1:
            # The first task built its note from the pre-second-message
            # snapshot; hold its send until the fresh push has landed.
            built_first.set()
            await asyncio.wait_for(release_first.wait(), timeout=30)
        return note

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

    r = await client.post("/calls/register-token", headers=_auth(seller_id),
                          json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm"})
    assert r.status_code == 200, r.text

    with patch.object(calls, "_get_fcm", lambda: object()), \
         patch.object(calls, "_send_fcm", new=_send), \
         patch.object(message_push, "PUSH_DEBOUNCE_SECONDS", 0), \
         patch.object(message_push, "build_notification", new=_gated_build):
        async with AsyncSessionLocal() as db:
            db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer_id, role="buyer",
                                      recipient_role="seller", content="hi", buyer_id=buyer_id,
                                      via_ai=False, msg_type="text"))
            await db.commit()
        await asyncio.wait_for(built_first.wait(), timeout=30)

        async with AsyncSessionLocal() as db:
            db.add(NegotiationMessage(listing_id=listing_id, sender_id=buyer_id, role="buyer",
                                      recipient_role="seller", content="Last price?",
                                      buyer_id=buyer_id, via_ai=False, msg_type="text"))
            await db.commit()

        # The second message's task sends the fresh text while the first is held.
        for _ in range(200):
            if any(p["data"].get("preview") == "Last price?" for p in sent):
                break
            await asyncio.sleep(0.05)
        assert any(p["data"].get("preview") == "Last price?" for p in sent), (
            "the fresh message's push never went out")

        release_first.set()
        await message_push.drain()

    previews = [p["data"].get("preview") for p in sent]
    assert previews == ["Last price?"], (
        f"the stale first send must stand down, got {previews!r}")
