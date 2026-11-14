"""What the log says about the database (api/database.py's timing).

DB_POOL_SATURATED and DB_CONNECTION_HELD said the pool was full or a
connection was kept. Neither said whether a slow request spent its time
running SQL or queueing for a connection, or which statement was slow, or
how many statements an endpoint runs - the inbox ran hundreds per poll for
months and no log line said so. Now:

  * every statement is timed; one past DB_SLOW_QUERY_MS is DB_SLOW_QUERY,
    named by a label (verb and BROKA table names) and a fingerprint, never
    by its text or values;
  * a checkout's wait for a free connection is timed apart from the SQL
    (DB_POOL_WAIT past DB_POOL_WAIT_WARN_MS);
  * every request's [http] line carries its statement count, their time
    and its queueing, with its request id; DB_REQUEST_HEAVY names an
    endpoint running DB_REQUEST_QUERY_WARN statements or more;
  * release_connection ends a read transaction before a slow call, and
    refuses one holding unsaved writes or row locks.
"""
import asyncio
import logging
import re
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, text, update
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
from sqlalchemy.orm import sessionmaker

from api import database
from api.core import observability
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_db_instrumentation.db"
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


async def _user() -> User:
    async with AsyncSessionLocal() as db:
        u = User(name="Instrumented", phone=f"+2547{uuid.uuid4().int % 10**8:08d}",
                 password_hash="x")
        db.add(u)
        await db.commit()
        return u


# ── Labels and fingerprints carry no values ──────────────────────────────────

def test_a_label_names_the_verb_and_only_known_tables():
    sql = ("SELECT negotiation_messages.id FROM negotiation_messages "
           "JOIN thread_read_state ON thread_read_state.buyer_id = negotiation_messages.buyer_id "
           "LEFT OUTER JOIN thread_clears AS thread_clears_1 ON 1 = 1")
    assert database.statement_label(sql) == (
        "SELECT negotiation_messages,thread_read_state,thread_clears")
    # Nothing but BROKA's own table names gets through, whatever follows FROM.
    assert database.statement_label("SELECT x FROM 'secret-0712345678'") == "SELECT -"
    assert database.statement_label(
        "UPDATE deals SET status=$1 WHERE deals.id = $2") == "UPDATE deals"
    assert database.statement_label('INSERT INTO "users" (id) VALUES (?)') == "INSERT users"


def test_a_fingerprint_is_the_query_shape_not_its_values():
    a = "SELECT * FROM users WHERE users.phone = '+254712345678' AND id IN ($1, $2, $3)"
    b = "SELECT *  FROM users WHERE users.phone = '+254799999999' AND id IN ($1)"
    c = "SELECT * FROM deals WHERE deals.id = $1"
    assert database.statement_fingerprint(a) == database.statement_fingerprint(b)
    assert database.statement_fingerprint(a) != database.statement_fingerprint(c)
    assert re.fullmatch(r"[0-9a-f]{12}", database.statement_fingerprint(a))


@pytest.mark.asyncio
async def test_a_slow_statement_is_logged_by_label_never_by_its_text(monkeypatch, caplog):
    monkeypatch.setattr(database, "SLOW_QUERY_MS", 0.0)
    secret = "+254700SECRET42"
    with caplog.at_level(logging.WARNING, logger="api.database"):
        async with AsyncSessionLocal() as db:
            await db.execute(select(User.id).where(User.phone == secret))
            await db.execute(text("SELECT :token AS t"), {"token": "Bearer-abc.def.ghi"})
    lines = [r.getMessage() for r in caplog.records if "DB_SLOW_QUERY" in r.getMessage()]
    assert any("label=SELECT users" in line and "fingerprint=" in line for line in lines), lines
    assert secret not in caplog.text and "SECRET42" not in caplog.text
    assert "Bearer-abc" not in caplog.text
    assert "WHERE" not in caplog.text, "no statement text reaches the log"


# ── Statements, queueing and the request they belong to ──────────────────────

@pytest.mark.asyncio
async def test_each_request_line_carries_its_statements_and_request_id(client, caplog):
    u = await _user()
    with caplog.at_level(logging.INFO, logger="api.core.observability"):
        r = await client.get(f"/negotiate/inbox/{u.id}", headers={
            **_auth(u.id), "X-Request-ID": "rid-inbox-42"})
    assert r.status_code == 200
    assert r.headers["x-request-id"] == "rid-inbox-42"
    [line] = [rec.getMessage() for rec in caplog.records
              if rec.getMessage().startswith("[http] GET /negotiate/inbox/")]
    match = re.search(r"db_queries=(\d+) db_ms=([\d.]+) db_wait_ms=([\d.]+) rid=rid-inbox-42$", line)
    assert match, line
    assert int(match.group(1)) >= 1


@pytest.mark.asyncio
async def test_an_endpoint_running_many_statements_is_named(client, caplog, monkeypatch):
    monkeypatch.setattr(observability, "DB_REQUEST_QUERY_WARN", 1)
    u = await _user()
    with caplog.at_level(logging.WARNING, logger="api.database"):
        r = await client.get(f"/negotiate/inbox/{u.id}", headers=_auth(u.id))
    assert r.status_code == 200
    heavy = [rec.getMessage() for rec in caplog.records if "DB_REQUEST_HEAVY" in rec.getMessage()]
    assert heavy and "endpoint=get_inbox" in heavy[0], heavy


@pytest.mark.asyncio
async def test_queueing_for_a_connection_is_told_apart_from_running_sql(
        tmp_path, monkeypatch, caplog):
    """A pool of one: while one session holds the connection (running no
    SQL), the next waits for it. The wait is DB_POOL_WAIT and the request's
    db_wait_ms; its own statement's time stays small."""
    monkeypatch.setattr(database, "POOL_WAIT_WARN_MS", 100.0)
    engine = create_async_engine(
        f"sqlite+aiosqlite:///{tmp_path / 'pool.db'}", poolclass=database.MeteredAsyncQueuePool,
        pool_size=1, max_overflow=0, pool_timeout=5, connect_args={"check_same_thread": False})
    Session = sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

    async def hold():
        async with Session() as db:
            await db.execute(text("SELECT 1"))
            await asyncio.sleep(0.3)
            await db.commit()

    async def wait():
        await asyncio.sleep(0.05)
        token = observability.request_id_var.set("rid-waiter")
        stats, stats_token = database.start_request_stats()
        try:
            async with Session() as db:
                await db.execute(text("SELECT 2"))
                await db.commit()
        finally:
            database.end_request_stats(stats_token)
            observability.request_id_var.reset(token)
        return stats

    try:
        with caplog.at_level(logging.WARNING, logger="api.database"):
            _, stats = await asyncio.gather(hold(), wait())
    finally:
        await engine.dispose()
    assert stats.pool_waits == 1
    assert stats.pool_wait_seconds >= 0.2, stats.pool_wait_seconds
    assert stats.queries == 1 and stats.query_seconds < 0.15
    waits = [r.getMessage() for r in caplog.records if "DB_POOL_WAIT" in r.getMessage()]
    assert waits and "rid=rid-waiter" in waits[0], waits


@pytest.mark.asyncio
async def test_work_after_the_request_answered_is_not_counted_to_it():
    stats, token = database.start_request_stats()
    answered = asyncio.Event()

    async def started_by_the_request():
        # A task the request started keeps its context, and so the stats -
        # but must not grow figures that were already logged.
        await answered.wait()
        async with AsyncSessionLocal() as db:
            await db.execute(text("SELECT 1"))

    task = asyncio.create_task(started_by_the_request())
    async with AsyncSessionLocal() as db:
        await db.execute(text("SELECT 1"))
    database.end_request_stats(token)
    answered.set()
    await task
    assert stats.queries == 1


def test_the_api_pool_is_the_metered_one_at_the_same_size(monkeypatch):
    if database._build_engine_and_factory.__module__ != "api.database":
        pytest.skip("the PostgreSQL test plugin builds its own NullPool engines")
    for name in ("DB_POOL_SIZE", "DB_MAX_OVERFLOW", "DB_POOL_TIMEOUT_SECONDS"):
        monkeypatch.delenv(name, raising=False)
    engine, _factory = database._build_engine_and_factory(
        "postgresql+asyncpg://user:pw@127.0.0.1:1/never_connected")
    pool = engine.sync_engine.pool
    assert isinstance(pool, database.MeteredAsyncQueuePool)
    assert (pool.size(), pool._max_overflow, pool._timeout) == (3, 2, 10)
    status = database.pool_status()
    for key in ("queries", "slow_queries", "pool_waits", "slow_pool_waits"):
        assert key in status


# ── Giving a connection back before a slow call ──────────────────────────────

@pytest.mark.asyncio
async def test_release_ends_a_read_and_refuses_writes_and_locks(caplog):
    u = await _user()
    async with AsyncSessionLocal() as db:
        (await db.execute(select(User).where(User.id == u.id))).scalar_one()
        assert db.in_transaction()
        assert await database.release_connection(db, before="test.read") is True
        assert not db.in_transaction()

        loaded = (await db.execute(select(User).where(User.id == u.id))).scalar_one()
        loaded.name = "Changed"
        await db.flush()
        with caplog.at_level(logging.WARNING, logger="api.database"):
            assert await database.release_connection(db, before="test.flushed") is False
        assert db.in_transaction(), "an unsaved write is not committed along the way"
        await db.rollback()

        await db.execute(update(User).where(User.id == u.id).values(name="Bulk"))
        assert await database.release_connection(db, before="test.dml") is False
        await db.rollback()

        (await db.execute(select(User).where(User.id == u.id).with_for_update())).scalar_one()
        assert await database.release_connection(db, before="test.locked") is False
        await db.rollback()
    refused = [r.getMessage() for r in caplog.records if "DB_RELEASE_REFUSED" in r.getMessage()]
    assert refused and "before=test.flushed" in refused[0]
    async with AsyncSessionLocal() as db:
        assert (await db.get(User, u.id)).name == "Instrumented"
