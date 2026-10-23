"""The store-type migration on a database that predates it.

`init_db()` adds `stores.store_type`, `opening_hours`, `service_areas` and
`delivery_note` to an existing stores table. The safety property that matters
is not "the column exists" but that a store created before the field keeps
its row, its link, its owner, its publication state and its data, and reads
as physical - the only type it could have been.
"""
import sqlite3

import pytest
from sqlalchemy import text

import api.database as db_module
from api.database import init_db, reset_engine
from api.models.store import Store


@pytest.mark.asyncio
async def test_an_existing_store_keeps_its_data_and_becomes_physical(tmp_path, monkeypatch):
    db_path = tmp_path / "legacy.db"
    # The stores table as it existed before this upgrade: identity, link,
    # the publication switch and the old free-text location. No type, no
    # hours, no coverage.
    conn = sqlite3.connect(db_path)
    conn.execute(
        "CREATE TABLE stores ("
        " id VARCHAR PRIMARY KEY, owner_id VARCHAR NOT NULL, name VARCHAR NOT NULL,"
        " slug VARCHAR NOT NULL UNIQUE, category VARCHAR, description TEXT,"
        " country VARCHAR NOT NULL, county VARCHAR, subcounty VARCHAR,"
        " location_description VARCHAR, is_active BOOLEAN NOT NULL DEFAULT 1,"
        " created_at DATETIME, updated_at DATETIME)"
    )
    conn.execute(
        "INSERT INTO stores (id, owner_id, name, slug, category, description, country,"
        " county, subcounty, is_active, created_at)"
        " VALUES ('legacy-store', 'owner-1', 'Mama Njeri Shop', 'mama-njeri',"
        " 'Electronics', 'Sells phones and chargers.', 'Kenya', 'Nairobi',"
        " 'Westlands', 1, '2026-01-02 03:04:05')"
    )
    conn.commit()
    conn.close()

    monkeypatch.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    try:
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
