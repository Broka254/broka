"""The store-orders schema change on a database that predates it.

init_db() (the `python -m api.migrate` release step) adds the store's
"taking orders" switch, the listing stock columns and the sign_in OTP
purpose to an existing database. What matters is that nothing an existing
seller has changes: a store keeps its row and is taking orders, and every
listing starts untracked, unreserved and on sale.

Built through the engine reset_engine() returns, as test_store_schema_
migration.py explains: under tests/postgres_plugin.py that is a brand-new
PostgreSQL schema, so the ALTERs are proven on the database production runs.
"""
import pytest
from sqlalchemy import text

import api.database as db_module
from api.database import init_db, reset_engine

_LEGACY_STORES_DDL = (
    "CREATE TABLE stores ("
    " id VARCHAR PRIMARY KEY, owner_id VARCHAR NOT NULL, name VARCHAR NOT NULL,"
    " slug VARCHAR NOT NULL UNIQUE, category VARCHAR, description TEXT,"
    " country VARCHAR NOT NULL, county VARCHAR, subcounty VARCHAR,"
    " location_description VARCHAR, is_active BOOLEAN NOT NULL DEFAULT FALSE,"
    " created_at TIMESTAMP, updated_at TIMESTAMP)"
)
_LEGACY_STORE_ROW = (
    "INSERT INTO stores (id, owner_id, name, slug, category, country, is_active, created_at)"
    " VALUES ('legacy-shop', 'owner-1', 'Duka la Mama', 'duka-la-mama', 'Electronics',"
    " 'Kenya', TRUE, '2026-01-02 03:04:05')"
)


@pytest.mark.asyncio
async def test_an_existing_store_is_taking_orders_after_the_upgrade(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'legacy_orders.db'}")
    reset_engine()
    try:
        async with db_module.engine.begin() as connection:
            await connection.execute(text(_LEGACY_STORES_DDL))
            await connection.execute(text(_LEGACY_STORE_ROW))
        await init_db()
        # Twice: a re-run of the release step must change nothing.
        await init_db()
        async with db_module.engine.connect() as connection:
            row = (await connection.execute(text(
                "SELECT name, slug, is_active, accepting_orders, orders_pause_note"
                " FROM stores WHERE id = 'legacy-shop'"
            ))).one()
            listing_columns = {r[1] for r in (await connection.execute(
                text("PRAGMA table_info(listings)"))).all()} if connection.dialect.name == "sqlite" else None
            tables = (await connection.execute(text(
                "SELECT COUNT(*) FROM store_orders"))).scalar_one()
        assert row.name == "Duka la Mama" and row.slug == "duka-la-mama"
        assert bool(row.is_active) is True
        assert bool(row.accepting_orders) is True
        assert row.orders_pause_note is None
        if listing_columns is not None:
            assert {"stock_tracked", "stock_reserved", "temporarily_unavailable"} <= listing_columns
        assert tables == 0
    finally:
        reset_engine()


@pytest.mark.asyncio
async def test_the_sign_in_purpose_reaches_an_existing_postgres_enum(tmp_path, monkeypatch):
    """PostgreSQL stores OtpPurpose as a native enum type; an existing
    database needs the new value added in place (_add_enum_value_sql). The
    type is made in one transaction and extended in a later one - the
    position every deployed database is in - and extending it twice is a
    no-op."""
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'enum_probe.db'}")
    reset_engine()
    try:
        if db_module.engine.dialect.name != "postgresql":
            pytest.skip("native enum types exist only on PostgreSQL")
        from api.database import _add_enum_value_sql, _apply_optional_statements
        async with db_module.engine.begin() as connection:
            await connection.execute(text("CREATE TYPE store_orders_probe AS ENUM ('registration')"))
        for _ in range(2):
            async with db_module.engine.begin() as connection:
                await _apply_optional_statements(
                    connection, [_add_enum_value_sql("store_orders_probe", "sign_in")])
        async with db_module.engine.connect() as connection:
            values = (await connection.execute(text(
                "SELECT unnest(enum_range(NULL::store_orders_probe))::text"))).scalars().all()
        assert values == ["registration", "sign_in"]

        await init_db()
        async with db_module.engine.connect() as connection:
            purposes = (await connection.execute(text(
                "SELECT unnest(enum_range(NULL::otppurpose))::text"))).scalars().all()
        assert "sign_in" in purposes
    finally:
        reset_engine()
