"""Railway API processes validate schema; they never run DDL at startup."""
from unittest.mock import AsyncMock

import pytest

from api import database


@pytest.mark.asyncio
async def test_railway_development_startup_only_validates_schema(monkeypatch):
    monkeypatch.setenv("ENV", "development")
    monkeypatch.setenv("RAILWAY_ENVIRONMENT", "Broka-Development")
    monkeypatch.delenv("AUTO_MIGRATE_SCHEMA", raising=False)

    migrate = AsyncMock()
    validate = AsyncMock(return_value={"current": True})
    monkeypatch.setattr(database, "_init_db_impl", migrate)
    monkeypatch.setattr(database, "require_current_schema", validate)

    await database.init_db()

    migrate.assert_not_awaited()
    validate.assert_awaited_once()


@pytest.mark.asyncio
async def test_local_development_still_initializes_its_database(monkeypatch):
    monkeypatch.setenv("ENV", "development")
    monkeypatch.delenv("RAILWAY_ENVIRONMENT", raising=False)
    monkeypatch.delenv("AUTO_MIGRATE_SCHEMA", raising=False)

    migrate = AsyncMock()
    validate = AsyncMock(return_value={"current": True})
    monkeypatch.setattr(database, "_init_db_impl", migrate)
    monkeypatch.setattr(database, "require_current_schema", validate)

    await database.init_db()

    migrate.assert_awaited_once()
    validate.assert_awaited_once()


@pytest.mark.asyncio
async def test_explicit_auto_migrate_override_remains_available(monkeypatch):
    monkeypatch.setenv("ENV", "development")
    monkeypatch.setenv("RAILWAY_ENVIRONMENT", "Broka-Development")
    monkeypatch.setenv("AUTO_MIGRATE_SCHEMA", "true")

    migrate = AsyncMock()
    validate = AsyncMock(return_value={"current": True})
    monkeypatch.setattr(database, "_init_db_impl", migrate)
    monkeypatch.setattr(database, "require_current_schema", validate)

    await database.init_db()

    migrate.assert_awaited_once()
    validate.assert_awaited_once()


@pytest.mark.asyncio
async def test_production_startup_remains_read_only(monkeypatch):
    monkeypatch.setenv("ENV", "production")
    monkeypatch.delenv("RAILWAY_ENVIRONMENT", raising=False)
    monkeypatch.delenv("AUTO_MIGRATE_SCHEMA", raising=False)

    migrate = AsyncMock()
    validate = AsyncMock(return_value={"current": True})
    monkeypatch.setattr(database, "_init_db_impl", migrate)
    monkeypatch.setattr(database, "require_current_schema", validate)

    await database.init_db()

    migrate.assert_not_awaited()
    validate.assert_awaited_once()
