"""DATABASE_URL as Azure and Supabase print it, and what GET /ready reports.

Two connection strings a hosting dashboard hands out stopped the backend:

* `?sslmode=require` (and Supabase's `?pgbouncer=true`). asyncpg takes every
  query parameter as a keyword argument and raised TypeError on the first
  connection, so startup died before the port opened. Azure Container Apps
  then keeps serving the previous revision with the previous settings, and
  the new DATABASE_URL - with every other variable changed alongside it -
  looked ignored.
* Supabase's transaction pooler (port 6543). init_db() passed, then queries
  failed with 'prepared statement "__asyncpg_stmt_..." does not exist' or
  '... already exists' (reproduced through PgBouncer in transaction mode).

GET /ready now says which revision answered and what it was configured
with, so the first case shows from a browser.
"""
from __future__ import annotations

import asyncpg
import pytest
from httpx import ASGITransport, AsyncClient

import api.database as database
from api.core.config import Settings


class _Stop(Exception):
    pass


class TestConnectionArguments:
    @pytest.fixture(autouse=True)
    def _real_engine_factory(self):
        if database._build_engine_and_factory.__module__ != "api.database":
            pytest.skip("tests.postgres_plugin replaces the engine factory")

    async def _asyncpg_kwargs(self, monkeypatch, url: str) -> dict:
        """The keyword arguments asyncpg.connect receives for `url`."""
        seen = {}

        async def fake_connect(*args, **kwargs):
            seen.update(kwargs)
            raise _Stop

        monkeypatch.setattr(asyncpg, "connect", fake_connect)
        engine, _ = database._build_engine_and_factory(url)
        try:
            with pytest.raises(_Stop):
                async with engine.connect():
                    pass
        finally:
            await engine.dispose()
        return seen

    async def test_sslmode_reaches_asyncpg_as_ssl(self, monkeypatch):
        kwargs = await self._asyncpg_kwargs(
            monkeypatch,
            "postgresql+asyncpg://u:pw@broka.postgres.database.azure.com:5432/db?sslmode=require",
        )
        assert "sslmode" not in kwargs
        assert kwargs["ssl"] == "require"

    async def test_transaction_pooler_turns_statement_caching_off(self, monkeypatch):
        url = "postgresql+asyncpg://postgres.abc:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres"
        kwargs = await self._asyncpg_kwargs(monkeypatch, url)
        assert kwargs["statement_cache_size"] == 0

        _, args = database._asyncpg_url_and_args(url)
        assert args["prepared_statement_cache_size"] == 0
        name = args["prepared_statement_name_func"]
        assert name() != name()

    async def test_pgbouncer_flag_is_removed_and_means_a_pooler(self, monkeypatch):
        kwargs = await self._asyncpg_kwargs(
            monkeypatch,
            "postgresql+asyncpg://postgres.abc:pw@aws-0-eu-central-1.pooler.supabase.com:5432/postgres?pgbouncer=true",
        )
        assert "pgbouncer" not in kwargs
        assert kwargs["statement_cache_size"] == 0

    async def test_a_direct_connection_is_left_alone(self, monkeypatch):
        # Render's and Azure's own databases: nothing changes for them.
        kwargs = await self._asyncpg_kwargs(
            monkeypatch, "postgresql+asyncpg://u:pw@dpg-abc123-a:5432/broka",
        )
        assert "statement_cache_size" not in kwargs
        assert "ssl" not in kwargs

    async def test_an_encoded_password_survives_the_rewrite(self, monkeypatch):
        kwargs = await self._asyncpg_kwargs(
            monkeypatch,
            "postgresql+asyncpg://u:p%40ss%2Fw%3Ard%23@db.abc.supabase.co:5432/postgres?sslmode=require",
        )
        assert kwargs["password"] == "p@ss/w:rd#"

    def test_a_pasted_newline_is_stripped(self, monkeypatch):
        monkeypatch.setenv("DATABASE_URL", "postgresql://u:pw@db.abc.supabase.co:5432/postgres\n")
        assert database._build_db_url() == "postgresql+asyncpg://u:pw@db.abc.supabase.co:5432/postgres"


@pytest.mark.parametrize("url, provider", [
    ("postgresql://postgres.abc:pw@aws-0-eu-central-1.pooler.supabase.com:6543/postgres", "supabase"),
    ("postgresql://postgres:pw@db.abc.supabase.co:5432/postgres", "supabase"),
    ("postgresql://u:pw@broka.postgres.database.azure.com:5432/db?sslmode=require", "azure"),
    ("postgresql://u:pw@dpg-abc123-a/broka", "render"),
    ("postgresql://u:pw@dpg-abc123-a.oregon-postgres.render.com/broka", "render"),
    ("postgresql+asyncpg://u:pw@10.0.0.5:5432/broka", "postgres"),
    ("sqlite+aiosqlite:///./broka.db", "sqlite"),
])
def test_database_provider(url, provider):
    assert Settings(database_url=url).database_provider == provider


async def test_ready_names_the_revision_and_its_configuration(monkeypatch):
    import main

    monkeypatch.setenv("CONTAINER_APP_REVISION", "broka-api--abc123")
    monkeypatch.setattr(main, "settings", Settings(
        env="production",
        database_url="postgresql://postgres.abc:s3cret-pw@aws-0-eu-central-1.pooler.supabase.com:5432/postgres",
        redis_url="",
        gemini_api_key="gemini-key-value", openrouter_api_key="", deepseek_api_key="",
        mobitech_api_key="", mobitech_sender_name="", at_username="", at_api_key="",
        resend_api_key="resend-key-value", resend_from="BROKA <noreply@broka.co.ke>",
    ))
    async with AsyncClient(transport=ASGITransport(app=main.app), base_url="http://test") as client:
        response = await client.get("/ready")

    body = response.json()
    assert body["revision"] == "broka-api--abc123"
    assert body["config"] == {
        "env": "production", "database": "supabase", "ai": True, "sms": False, "email": True,
    }
    # Names and yes/no only: the endpoint is public.
    for secret in ("s3cret-pw", "gemini-key-value", "resend-key-value", "pooler.supabase.com"):
        assert secret not in response.text
