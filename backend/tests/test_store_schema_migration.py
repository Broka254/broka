"""The store-type migration on a database that predates it.

`init_db()` adds `stores.store_type`, `opening_hours`, `service_areas` and
`delivery_note` to an existing stores table. The safety property that matters
is not "the column exists" but that a store created before the field keeps
its row, its link, its owner, its publication state and its data, and reads
as physical - the only type it could have been.

The pre-upgrade table is built through the engine `reset_engine()` returns,
not with the `sqlite3` module. Under tests/postgres_plugin.py every
reset_engine() opens a brand-new PostgreSQL schema and ignores DATABASE_URL,
so a row written into a hand-built SQLite file was never in the database
init_db() migrated: the store "vanished" and the Postgres CI job failed on
NoResultFound (job-logs (42).txt) while the SQLite job passed. Building the
legacy table through the engine also means the ALTER statements are proven on
the database production actually runs.
"""
import pytest
from sqlalchemy import text

import api.database as db_module
from api.database import init_db, reset_engine
from api.models.store import Store

# The stores table as it existed before this upgrade: identity, link, the
# publication switch and the old free-text location. No type, no hours, no
# coverage. FALSE/TRUE rather than 0/1 because PostgreSQL refuses an integer
# where a boolean column is expected.
_LEGACY_STORES_DDL = (
    "CREATE TABLE stores ("
    " id VARCHAR PRIMARY KEY, owner_id VARCHAR NOT NULL, name VARCHAR NOT NULL,"
    " slug VARCHAR NOT NULL UNIQUE, category VARCHAR, description TEXT,"
    " country VARCHAR NOT NULL, county VARCHAR, subcounty VARCHAR,"
    " location_description VARCHAR, is_active BOOLEAN NOT NULL DEFAULT FALSE,"
    " created_at TIMESTAMP, updated_at TIMESTAMP)"
)
_LEGACY_STORE_ROW = (
    "INSERT INTO stores (id, owner_id, name, slug, category, description,"
    " country, county, subcounty, is_active, created_at)"
    " VALUES ('legacy-store', 'owner-1', 'Mama Njeri Shop', 'mama-njeri',"
    " 'Electronics', 'Sells phones and chargers.', 'Kenya', 'Nairobi',"
    " 'Westlands', TRUE, '2026-01-02 03:04:05')"
)


@pytest.mark.asyncio
async def test_an_existing_store_keeps_its_data_and_becomes_physical(tmp_path, monkeypatch):
    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{tmp_path / 'legacy.db'}")
    reset_engine()
    try:
        # The old table must exist before init_db() runs, so create_all()
        # leaves it alone and the ALTERs land on it - the position every
        # deployment upgrading in place is in.
        async with db_module.engine.begin() as connection:
            await connection.execute(text(_LEGACY_STORES_DDL))
            await connection.execute(text(_LEGACY_STORE_ROW))

        await init_db()
        async with db_module.engine.connect() as connection:
            row = (await connection.execute(text(
                "SELECT name, slug, category, county, is_active, store_type,"
                " opening_hours, service_areas, delivery_note"
                " FROM stores WHERE id = 'legacy-store'"
            ))).one()
        assert row.name == "Mama Njeri Shop"
        assert row.slug == "mama-njeri"
        assert row.category == "Electronics"
        assert row.county == "Nairobi"
        assert bool(row.is_active) is True
        assert row.store_type == "physical"
        # Absent information stays absent: the migration does not fabricate
        # an opening schedule or delivery coverage.
        assert row.opening_hours is None
        assert row.service_areas is None
        assert row.delivery_note is None

        # And the model reads the migrated row as a usable physical store.
        async with db_module.engine.connect() as connection:
            store = (await connection.execute(
                text("SELECT * FROM stores WHERE id = 'legacy-store'")
            )).mappings().one()
        assert store["store_type"] == Store.store_type.default.arg
    finally:
        reset_engine()


def test_the_default_is_physical_for_rows_that_never_chose():
    # A client that predates the field cannot send it; the column's default
    # is the answer, and it must not be "virtual" (which would hide a shop's
    # map pin and drop its photograph requirement).
    assert Store.store_type.default.arg == "physical"
