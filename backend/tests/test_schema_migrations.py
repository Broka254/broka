"""Schema revisions must be reproducible and fail loudly.

SQLite is the fast local suite; the same class runs under
tests/postgres_plugin.py, where the managed transaction and real NOT NULL
semantics are what production sees.
"""
from __future__ import annotations

import uuid

import pytest
import pytest_asyncio
from sqlalchemy import inspect, select, text

from api import database
from api.database import (
    AsyncSessionLocal, Listing, SCHEMA_VERSION, User,
    _apply_optional_statements, init_db, reset_engine,
)
from api.models.listing_payment import ListingPayment


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / f"test_schema_{uuid.uuid4().hex}.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


def _columns(sync_conn, table: str) -> set[str]:
    return {column["name"] for column in inspect(sync_conn).get_columns(table)}


def _indexes(sync_conn, table: str) -> set[str]:
    return {index["name"] for index in inspect(sync_conn).get_indexes(table)}


def _unique_constraints(sync_conn, table: str) -> set[str]:
    return {
        constraint["name"]
        for constraint in inspect(sync_conn).get_unique_constraints(table)
        if constraint.get("name")
    }


@pytest.mark.asyncio
async def test_fresh_database_records_every_revision_and_required_columns():
    status = await database.schema_status()
    assert status["current"] is True
    assert status["current_version"] == SCHEMA_VERSION
    assert status["missing"] == {}
    assert status["missing_indexes"] == {}
    assert [row["version"] for row in status["versions"]] == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    async with database.engine.connect() as conn:
        columns = await conn.run_sync(_columns, "mpesa_transactions")
        indexes = await conn.run_sync(_indexes, "mpesa_transactions")
        legal_columns = await conn.run_sync(_columns, "legal_acceptances")
        legal_unique = await conn.run_sync(_unique_constraints, "legal_acceptances")
    assert {"client_ref", "request_fingerprint", "active_intent", "last_error"} <= columns
    assert "uq_mpesa_transactions_active_intent" in indexes
    # Registration writes these three rows in the same transaction as the
    # user; the unique guard is what prevents duplicate evidence.
    assert {
        "user_id", "acceptance_type", "document_id", "document_version",
        "document_digest", "accepted_at",
    } <= legal_columns
    assert "uq_legal_acceptances_user_type_version" in legal_unique


@pytest.mark.asyncio
async def test_running_the_migration_again_is_a_no_op():
    before = await database.schema_status()
    await init_db()
    after = await database.schema_status()
    assert after == before


@pytest.mark.asyncio
async def test_an_older_database_gets_new_columns_and_revisions_back():
    # Remove the newest additions to model the previous release. Dropping
    # the table itself is unnecessary: create_all only creates missing
    # tables, so an existing older payment_callbacks shape is also covered
    # by the same adoption path.
    async with database.engine.begin() as conn:
        for name in (
            "uq_mpesa_transactions_deal_client_ref",
            "uq_mpesa_transactions_active_intent",
            "uq_mpesa_transactions_receipt",
            "uq_subscription_payments_active_intent",
            "uq_listing_payments_active_intent",
            "uq_store_payments_active_intent",
            "uq_subscription_payments_receipt",
            "uq_listing_payments_receipt",
            "uq_store_payments_receipt",
        ):
            await conn.execute(text(f"DROP INDEX IF EXISTS {name}"))
        for column in ("client_ref", "request_fingerprint", "active_intent", "last_error"):
            await conn.execute(text(f"ALTER TABLE mpesa_transactions DROP COLUMN {column}"))
        for table in ("subscription_payments", "listing_payments", "store_payments"):
            await conn.execute(text(f"ALTER TABLE {table} DROP COLUMN active_intent"))
        await conn.execute(text("DROP TABLE payment_callbacks"))
        # Revision 8 is a brand-new table, so an older database has none.
        # create_all() must create it on the next migrate run.
        await conn.execute(text("DROP TABLE legal_acceptances"))
        await conn.execute(text("DELETE FROM schema_migrations"))

    await database._init_db_impl()
    status = await database.schema_status()
    assert status["current"] is True
    assert [row["version"] for row in status["versions"]] == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
    async with database.engine.connect() as conn:
        columns = await conn.run_sync(_columns, "mpesa_transactions")
        indexes = await conn.run_sync(_indexes, "mpesa_transactions")
        plan_columns = await conn.run_sync(_columns, "subscription_payments")
        listing_columns = await conn.run_sync(_columns, "listing_payments")
        store_columns = await conn.run_sync(_columns, "store_payments")
        plan_indexes = await conn.run_sync(_indexes, "subscription_payments")
        listing_indexes = await conn.run_sync(_indexes, "listing_payments")
        store_indexes = await conn.run_sync(_indexes, "store_payments")
        tables = set(await conn.run_sync(lambda c: inspect(c).get_table_names()))
    assert {"client_ref", "request_fingerprint", "active_intent", "last_error"} <= columns
    assert "uq_mpesa_transactions_active_intent" in indexes
    assert "active_intent" in plan_columns
    assert "active_intent" in listing_columns
    assert "active_intent" in store_columns
    assert "uq_subscription_payments_active_intent" in plan_indexes
    assert "uq_listing_payments_active_intent" in listing_indexes
    assert "uq_store_payments_active_intent" in store_indexes
    assert "uq_subscription_payments_receipt" in plan_indexes
    assert "uq_listing_payments_receipt" in listing_indexes
    assert "uq_store_payments_receipt" in store_indexes
    assert "payment_callbacks" in tables
    assert "legal_acceptances" in tables


@pytest.mark.asyncio
async def test_a_genuine_migration_error_is_not_swallowed():
    async with database.engine.connect() as conn:
        with pytest.raises(Exception):
            await _apply_optional_statements(
                conn, ["ALTER TABLE table_that_does_not_exist ADD COLUMN value INTEGER"],
            )


@pytest.mark.asyncio
async def test_duplicate_money_identifiers_fail_the_release_without_deleting_data():
    marker = f"dup-{uuid.uuid4()}"
    async with database.engine.begin() as conn:
        await conn.execute(text("DROP INDEX IF EXISTS uq_listing_payments_active_intent"))

    async with AsyncSessionLocal() as db:
        user = User(name="Dup", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(user)
        await db.flush()
        listing = Listing(
            seller_id=user.id, name=marker, category="Electronics", price=100,
            lat=-1.29, lng=36.82,
        )
        db.add(listing)
        await db.flush()
        db.add_all([
            ListingPayment(
                user_id=user.id, listing_id=listing.id, months=1, monthly_fee=100,
                listing_amount=100, featured_amount=0, amount=100, phone="+254700000000",
                active_intent=marker,
            )
            for _ in range(2)
        ])
        await db.commit()
        user_id, listing_id = user.id, listing.id

    async with database.engine.connect() as conn:
        with pytest.raises(RuntimeError, match="uq_listing_payments_active_intent"):
            await database._preflight_unique_indexes(conn)

    # Cleanup this test's own synthetic rows, then let the normal migration
    # recreate the guard; production duplicates are never deleted by code.
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(ListingPayment).where(
            ListingPayment.active_intent == marker,
        ))).scalars().all()
        for row in rows:
            await db.delete(row)
        await db.commit()
    async with database.engine.begin() as conn:
        await conn.execute(text("DELETE FROM listings WHERE id = :id"), {"id": listing_id})
        await conn.execute(text("DELETE FROM users WHERE id = :id"), {"id": user_id})
    await database._init_db_impl()
    assert (await database.schema_status())["current"] is True
