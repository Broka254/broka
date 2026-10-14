"""Run the backend test suite against PostgreSQL instead of SQLite.

    POSTGRES_TEST_URL=postgresql+asyncpg://user:pass@host:5432/db \\
        python -m pytest tests/ -p tests.postgres_plugin

Production runs on Postgres; the suite normally runs on SQLite, which
doesn't enforce foreign keys and accepts timezone-aware datetimes in
naive columns. Both hid real bugs: every signup and login failed with a
500 on Postgres, and so did every "system" audit row (taking an E-Confirm
payment's status change down with it). CI runs the suite both ways.

Each engine the suite builds (every module's reset_engine() call) gets a
fresh schema, so modules stay as isolated as their separate SQLite files
were. Connections aren't pooled: tests run on several event loops, and an
asyncpg connection belongs to the loop that opened it.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import itertools
import os
import uuid

import pytest

_URL = os.environ.get("POSTGRES_TEST_URL", "")
_counter = itertools.count()


def _plain_dsn(url: str) -> str:
    return url.replace("postgresql+asyncpg://", "postgresql://", 1)


def _create_schema(name: str) -> None:
    async def create() -> None:
        import asyncpg
        conn = await asyncpg.connect(_plain_dsn(_URL))
        try:
            await conn.execute(f'CREATE SCHEMA "{name}"')
        finally:
            await conn.close()

    # A thread of its own: this may be called while an event loop is running.
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        pool.submit(asyncio.run, create()).result()


def _engine_and_factory(_ignored_url: str):
    from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine
    from sqlalchemy.orm import sessionmaker
    from sqlalchemy.pool import NullPool

    schema = f"t_{uuid.uuid4().hex[:8]}_{next(_counter)}"
    _create_schema(schema)
    engine = create_async_engine(
        _URL, poolclass=NullPool, connect_args={"server_settings": {"search_path": schema}},
    )
    return engine, sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


def pytest_configure(config: pytest.Config) -> None:
    if not _URL.startswith("postgresql+asyncpg://"):
        raise pytest.UsageError(
            "tests.postgres_plugin needs POSTGRES_TEST_URL=postgresql+asyncpg://..."
        )
    import api.database as database

    database._build_db_url = lambda: _URL
    database._build_engine_and_factory = _engine_and_factory
    database.reset_engine()
