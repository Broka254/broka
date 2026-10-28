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
    # The listing/buyer ids are known only after the rows below are stored;
    # the gate reads them through this cell, set before any gated build for
    # this thread can run.
    thread: dict = {}
    gated_builds = 0

    async def _gated_build(db, *args, **kwargs):
        nonlocal gated_builds
        # Only the test thread's own builds take part in the gate. The
        # re-push that /calls/register-token schedules runs on its own task
        # and builds through this same patched function; counting it as
        # "the first build" held the wrong task (or, when the two builds
        # overlapped inside real_build and a shared counter was read after
        # the await, held NEITHER - built_first was never set and the test
        # timed out). That overlap is why the Backend Tests (PostgreSQL 16)
        # job failed this test three runs straight with TimeoutError while
        # the SQLite job - where the queries are fast enough that the builds
        # never overlap - stayed green. The claim happens BEFORE the await:
        # two of this thread's builds can also overlap, and the number must
        # be fixed while this task still owns it.
        listing_arg = args[0] if args else kwargs.get("listing_id")
        buyer_arg = args[1] if len(args) > 1 else kwargs.get("buyer_id")
        mine = bool(thread) and listing_arg == thread.get("listing_id") \
            and buyer_arg == thread.get("buyer_id")
        my_build = 0
        if mine:
            gated_builds += 1
            my_build = gated_builds
        note = await real_build(db, *args, **kwargs)
        if my_build == 1:
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
    thread["listing_id"] = listing_id
    thread["buyer_id"] = buyer_id

    r = await client.post("/calls/register-token", headers=_auth(seller_id),
                          json={"fcm_token": f"tok-{uuid.uuid4().hex}", "token_type": "fcm"})
    assert r.status_code == 200, r.text
    # The registration above schedules an unread re-push on its own task.
    # Let it finish BEFORE the gate is installed: otherwise its build runs
    # through _gated_build, and under load it can still be in flight when
    # the first message's build starts - which is exactly the overlap the
    # per-thread claim above has to defend against. Draining here removes
    # the overlap at its source instead of only surviving it.
    await message_push.drain()

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
