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
import uuid
from datetime import datetime

import pytest
from sqlalchemy import inspect, text

import api.database as db_module
from api.database import init_db, reset_engine

_ORDER_TABLES = (
    "store_orders", "store_order_items", "store_order_events", "store_order_payments",
    "store_order_payment_reports", "store_order_notifications",
)
# The tables the store-order release adds to or reads from.
_TABLES = _ORDER_TABLES + ("listings", "stores", "deals", "users")
_NEW_COLUMNS = {
    "listings": ("stock_tracked", "stock_reserved", "temporarily_unavailable"),
    "stores": ("accepting_orders", "orders_pause_note"),
}


def _type_name(column_type) -> str:
    # The class and its length, not str(type): compiling a reflected
    # PostgreSQL-only type with the generic compiler can fail.
    length = getattr(column_type, "length", None)
    return f"{type(column_type).__name__}({length})" if length else type(column_type).__name__


def _shape(sync_conn, *, with_defaults: bool = True) -> dict:
    """Every column (type, nullable, default), key, index and unique rule
    of the tables above, as the database reports them."""
    insp = inspect(sync_conn)
    out = {}
    for table in _TABLES:
        out[table] = {
            "columns": {
                c["name"]: (_type_name(c["type"]), bool(c["nullable"]),
                            str(c.get("default")) if with_defaults else None)
                for c in insp.get_columns(table)
            },
            "primary_key": tuple(insp.get_pk_constraint(table)["constrained_columns"]),
            "foreign_keys": sorted(
                (tuple(fk["constrained_columns"]), fk["referred_table"], tuple(fk["referred_columns"]))
                for fk in insp.get_foreign_keys(table)
            ),
            "indexes": sorted((i["name"], tuple(i["column_names"]), bool(i["unique"]))
                              for i in insp.get_indexes(table)),
            "unique": sorted(tuple(u["column_names"]) for u in insp.get_unique_constraints(table)),
        }
    return out


def _uniques(shape: dict, table: str) -> set:
    """Column sets that must be unique, by a constraint or a unique index."""
    t = shape[table]
    return set(t["unique"]) | {cols for _, cols, unique in t["indexes"] if unique}


def _not_null(shape: dict, table: str) -> set:
    return {name for name, (_, nullable, _) in shape[table]["columns"].items() if not nullable}


async def _schema(**kwargs) -> dict:
    async with db_module.engine.connect() as connection:
        return await connection.run_sync(lambda c: _shape(c, **kwargs))

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


@pytest.mark.asyncio
async def test_a_fresh_database_has_every_store_order_rule_and_a_rerun_changes_none(tmp_path, monkeypatch):
    """Phase 5: from an empty database, the release step builds the whole
    store-order schema - its keys, uniqueness rules, indexes and required
    columns - and running it again changes nothing at all."""
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'fresh_orders.db'}")
    reset_engine()
    try:
        await init_db()
        first = await _schema()
        await init_db()
        assert await _schema() == first
        status = await db_module.schema_status()
        assert status["current"] is True and status["current_version"] == db_module.SCHEMA_VERSION

        orders = first["store_orders"]
        assert {("reference",), ("buyer_id", "idempotency_key")} <= _uniques(first, "store_orders")
        assert {
            (("store_id",), "stores", ("id",)), (("seller_id",), "users", ("id",)),
            (("buyer_id",), "users", ("id",)), (("campaign_id",), "marketing_campaigns", ("id",)),
        } <= set(orders["foreign_keys"])
        assert {
            "reference", "store_id", "seller_id", "buyer_id", "status", "currency",
            "requested_subtotal_minor", "requested_fulfilment", "fulfilment", "revision",
            "version", "idempotency_key", "request_fingerprint", "source_surface",
            "created_at", "updated_at",
        } <= _not_null(first, "store_orders")
        # What the expiry sweep looks orders up by.
        assert ("ix_store_orders_status_expires", ("status", "expires_at"), False) in orders["indexes"]

        items = first["store_order_items"]
        assert ("order_id", "listing_id") in _uniques(first, "store_order_items")
        assert {(("order_id",), "store_orders", ("id",)),
                (("listing_id",), "listings", ("id",))} <= set(items["foreign_keys"])
        assert {
            "order_id", "listing_id", "name", "requested_quantity", "requested_unit_price_minor",
            "reserved_quantity", "deducted_quantity", "stock_state",
        } <= _not_null(first, "store_order_items")
        assert ("order_id",) in _uniques(first, "store_order_payments")
        assert ("order_id", "kind") in _uniques(first, "store_order_payment_reports")
        assert ("event_id", "recipient_id") in _uniques(first, "store_order_notifications")
        assert {(("event_id",), "store_order_events", ("id",)),
                (("recipient_id",), "users", ("id",))} <= set(first["store_order_notifications"]["foreign_keys"])
        # An event's actor can be "system", so it is not a foreign key.
        assert not [fk for fk in first["store_order_events"]["foreign_keys"] if fk[0] == ("actor_id",)]
        assert set(_NEW_COLUMNS["listings"]) <= _not_null(first, "listings")
        assert "accepting_orders" in _not_null(first, "stores")
    finally:
        reset_engine()


@pytest.mark.asyncio
async def test_a_database_from_before_store_orders_upgrades_without_changing_a_row(tmp_path, monkeypatch):
    """Phase 5: the path every deployed database took. A seller's user,
    store, listing and paid-out deal are written, the schema is put back
    to where it was before revision 19 (no store-order tables, no stock or
    "taking orders" columns, revision 19 unrecorded), and the release step
    runs - twice. Every existing value is unchanged, the new columns read
    as nothing having changed (untracked, nothing reserved, on sale, taking
    orders), and the result has the same store-order schema as a fresh
    database."""
    from api.database import Deal, DealStatus, Listing, ListingStatus, User
    from api.models.store import Store

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'before_orders.db'}")
    reset_engine()
    try:
        await init_db()
        tag = uuid.uuid4().hex[:8]
        async with db_module.AsyncSessionLocal() as db:
            seller = User(name="Mama Mboga", phone=f"+25471{tag[:7]}", password_hash="x")
            buyer = User(name="Brian Buyer", phone=f"+25472{tag[:7]}", password_hash="x")
            db.add_all([seller, buyer])
            await db.flush()
            store = Store(owner_id=seller.id, name="Duka la Mama", slug=f"duka-{tag}")
            db.add(store)
            await db.flush()
            listing = Listing(seller_id=seller.id, store_id=store.id, name="Sukuma wiki", category="Food",
                              price=50, lat=-1.29, lng=36.82, status=ListingStatus.active, quantity=40)
            db.add(listing)
            await db.flush()
            deal = Deal(listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id, agreed_price=150,
                        commission=10, status=DealStatus.released, quantity=3,
                        released_at=datetime(2026, 9, 1, 10, 0, 0))
            db.add(deal)
            await db.commit()
            rows = {"users": seller.id, "stores": store.id, "listings": listing.id, "deals": deal.id}

        async with db_module.engine.begin() as connection:
            for table in reversed(_ORDER_TABLES):    # the rows that point at others first
                await connection.execute(text(f"DROP TABLE {table}"))
            for table, columns in _NEW_COLUMNS.items():
                for column in columns:
                    await connection.execute(text(f"ALTER TABLE {table} DROP COLUMN {column}"))
            await connection.execute(text("DELETE FROM schema_migrations WHERE version >= 19"))

        async def read(table: str) -> dict:
            async with db_module.engine.connect() as connection:
                return dict((await connection.execute(
                    text(f"SELECT * FROM {table} WHERE id = :id"), {"id": rows[table]})).mappings().one())

        before = {table: await read(table) for table in rows}
        assert not set(_NEW_COLUMNS["listings"]) & set(before["listings"])

        for _ in range(2):
            await db_module._init_db_impl()
            assert (await db_module.require_current_schema())["current_version"] == db_module.SCHEMA_VERSION
            for table in rows:
                after = await read(table)
                assert {k: after[k] for k in before[table]} == before[table], table
        after_listing, after_store = await read("listings"), await read("stores")
        assert (bool(after_listing["stock_tracked"]), after_listing["stock_reserved"],
                bool(after_listing["temporarily_unavailable"])) == (False, 0, False)
        assert (bool(after_store["accepting_orders"]), after_store["orders_pause_note"]) == (True, None)
        async with db_module.engine.connect() as connection:
            for table in _ORDER_TABLES:
                assert (await connection.execute(text(f"SELECT COUNT(*) FROM {table}"))).scalar_one() == 0
        upgraded = await _schema(with_defaults=False)

        # The same store-order schema a fresh database gets. Defaults aside:
        # create_all gives these columns the model's Python default, the
        # upgrade's ALTER a database default for the rows already there.
        monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'fresh_compare.db'}")
        reset_engine()
        await init_db()
        fresh = await _schema(with_defaults=False)
        for table in _ORDER_TABLES:
            assert upgraded[table] == fresh[table], table
        for table, columns in _NEW_COLUMNS.items():
            for column in columns:
                assert upgraded[table]["columns"][column] == fresh[table]["columns"][column], column
    finally:
        reset_engine()
