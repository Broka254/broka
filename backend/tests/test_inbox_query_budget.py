"""The inbox's database work must not grow with the number of conversations.

GET /negotiate/inbox/{user_id} is what every open app asks for every few
seconds. It answered each conversation with its own five to eight queries -
the newest row, the watermarks, the unread count, Zeno's count twice over,
the unread message and missed call - so a seller with fifty buyers made
three to four hundred round trips per poll, on one of the process's five
pooled connections (api/core/inbox_threads.py now batches them).

This file measures it, for a seller and for a buyer with 1, 10, 30 and 50
conversations: statements per request, counted for the request alone (not
the background pushes a seeded message would set off), and its latency
over repeated requests. The numbers are printed - CI's log is where the
before-and-after comparison is read - and the regression is asserted: the
count follows the number of query batches, not the number of threads.
"""
import statistics
import time
import uuid
from contextvars import ContextVar
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import event, insert
from sqlalchemy.engine import Engine

from api import database
from api.database import (
    AsyncSessionLocal, Listing, NegotiationMessage, ThreadReadState, User, init_db,
    reset_engine,
)
from api.security import create_access_token
from main import app

THREAD_COUNTS = (1, 10, 30, 50)
REQUESTS_PER_SIZE = 12

# Statements are counted only in a context that carries a box: the request
# under measurement. A push a seeded row set off runs in its own context.
_box: ContextVar = ContextVar("inbox_budget_box", default=None)


def _count(conn, cursor, statement, parameters, context, executemany):
    box = _box.get()
    if box is not None:
        box[0] += 1


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_inbox_query_budget.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    event.listen(Engine, "before_cursor_execute", _count)
    yield
    event.remove(Engine, "before_cursor_execute", _count)
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


def _phone() -> str:
    return f"+2547{uuid.uuid4().int % 10**8:08d}"


async def _seed(view: str, threads: int) -> str:
    """A user with `threads` conversations, each with the mix the inbox
    reads: both sides' words, Zeno to each side, a private word to Zeno, an
    unsent message, a missed call, and watermarks on some of them. Rows are
    inserted directly - no push or delivery bookkeeping runs for them."""
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        me = User(name=f"{view.title()} Under Test", phone=_phone(), password_hash="x")
        db.add(me)
        await db.flush()
        pairs = []  # (listing_id, buyer_id, seller_id)
        if view == "seller":
            listings = [Listing(seller_id=me.id, name=f"Item {i}", category="Electronics",
                                price=1000 + i, lat=-1.28, lng=36.82)
                        for i in range(max(1, threads // 5))]
            db.add_all(listings)
            buyers = [User(name=f"Buyer {i}", phone=_phone(), password_hash="x")
                      for i in range(threads)]
            db.add_all(buyers)
            await db.flush()
            pairs = [(listings[i % len(listings)].id, b.id, me.id) for i, b in enumerate(buyers)]
        else:
            sellers = [User(name=f"Seller {i}", phone=_phone(), password_hash="x")
                       for i in range(max(1, threads // 3))]
            db.add_all(sellers)
            await db.flush()
            listings = [Listing(seller_id=sellers[i % len(sellers)].id, name=f"Item {i}",
                                category="Electronics", price=500 + i, lat=-1.28, lng=36.82)
                        for i in range(threads)]
            db.add_all(listings)
            await db.flush()
            pairs = [(l.id, me.id, l.seller_id) for l in listings]
        await db.commit()

    rows, marks = [], []
    for n, (listing_id, buyer_id, seller_id) in enumerate(pairs):
        t = now - timedelta(minutes=60 + n)

        def row(minutes, **kw):
            # Every key on every row: one executemany takes its columns
            # from the first.
            rows.append({"id": str(uuid.uuid4()), "listing_id": listing_id,
                         "buyer_id": buyer_id, "msg_type": "text", "via_ai": False,
                         "call_type": None, "deleted_at": None,
                         "created_at": t + timedelta(minutes=minutes), **kw})

        row(0, sender_id=buyer_id, role="buyer", recipient_role="seller", content="Is it available?")
        row(1, sender_id=seller_id, role="seller", recipient_role="buyer", content="Yes it is")
        row(2, sender_id="broker", role="broker", recipient_role="buyer", content="Zeno to buyer",
            via_ai=True)
        row(3, sender_id="broker", role="broker", recipient_role="seller", content="Zeno to seller",
            via_ai=True)
        row(4, sender_id=buyer_id, role="buyer", recipient_role=None, content="my max is 9000",
            via_ai=True)
        row(5, sender_id=buyer_id, role="buyer", recipient_role="seller", content="unsent",
            deleted_at=t + timedelta(minutes=6))
        row(7, sender_id=buyer_id, role="buyer", recipient_role="seller", content="missed",
            msg_type="call", call_type="audio")
        if n % 2:
            marks.append({"id": str(uuid.uuid4()), "listing_id": listing_id, "buyer_id": buyer_id,
                          "role": "seller", "last_read_at": t + timedelta(minutes=1, seconds=30),
                          "last_delivered_at": t + timedelta(minutes=3)})
            marks.append({"id": str(uuid.uuid4()), "listing_id": listing_id, "buyer_id": buyer_id,
                          "role": "buyer", "last_read_at": t + timedelta(minutes=2),
                          "last_delivered_at": t + timedelta(minutes=2)})
    async with AsyncSessionLocal() as db:
        await db.execute(insert(NegotiationMessage.__table__), rows)
        if marks:
            await db.execute(insert(ThreadReadState.__table__), marks)
        await db.commit()
    return me.id


async def _measure(client, uid: str) -> tuple[int, list[float], int]:
    """(statements for one request, latencies in seconds, threads listed)."""
    headers = _auth(uid)
    warm = await client.get(f"/negotiate/inbox/{uid}", headers=headers)
    assert warm.status_code == 200, warm.text
    box = [0]
    token = _box.set(box)
    try:
        r = await client.get(f"/negotiate/inbox/{uid}", headers=headers)
    finally:
        _box.reset(token)
    assert r.status_code == 200, r.text
    latencies = []
    for _ in range(REQUESTS_PER_SIZE):
        started = time.perf_counter()
        again = await client.get(f"/negotiate/inbox/{uid}", headers=headers)
        latencies.append(time.perf_counter() - started)
        assert again.status_code == 200
    return box[0], latencies, len(r.json())


def _p95(values: list[float]) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(0.95 * (len(ordered) - 1)))]


@pytest.mark.asyncio
@pytest.mark.parametrize("view", ["seller", "buyer"])
async def test_inbox_statements_follow_batches_not_conversations(client, view, capsys):
    measured = {}
    for threads in THREAD_COUNTS:
        uid = await _seed(view, threads)
        statements, latencies, listed = await _measure(client, uid)
        assert listed == threads, f"{threads} conversations seeded, {listed} listed"
        measured[threads] = (statements, latencies)

    dialect = database.engine.dialect.name
    with capsys.disabled():
        print(f"\n[inbox-budget] view={view} dialect={dialect} requests={REQUESTS_PER_SIZE}")
        print("[inbox-budget] threads  statements  p50_ms  p95_ms   max_ms")
        for threads, (statements, latencies) in measured.items():
            print(f"[inbox-budget] {threads:7d}  {statements:10d}  "
                  f"{statistics.median(latencies) * 1000:6.1f}  {_p95(latencies) * 1000:6.1f}  "
                  f"{max(latencies) * 1000:7.1f}")

    counts = {threads: statements for threads, (statements, _) in measured.items()}
    # Fifty conversations cost what ten do: the count follows the number of
    # grouped queries (fixed per kind of thread), not the number of threads.
    assert counts[50] <= counts[10] + 1, counts
    assert counts[50] <= 30, counts
    # And the answer stays well inside a poll's budget at fifty threads.
    assert _p95(measured[50][1]) < 1.0, measured[50][1]
