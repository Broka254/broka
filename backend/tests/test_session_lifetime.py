"""Sign-in sessions: refresh tokens, and the schema they and the audit log need.

The app used to keep the user's password on the phone and log in again
with it whenever a refresh failed, which hid two server-side problems:

  * a refresh token expired a fixed 30 days after sign-in, however active
    the user was. Now one used after ROTATE_AFTER is exchanged for a fresh
    one (sliding), and the old one keeps working for ROTATION_GRACE in case
    the response is lost;
  * the refresh-token row was written with a timezone-aware expiry, which
    Postgres refuses: every signup and login failed with a 500 there.

The Postgres-only class checks what init_db does to a database created
before two wrong foreign keys were removed (audit_logs.actor_id, which also
holds "system"; auction_meta.deal_id, which holds a claim before its deal
exists). It runs when the suite runs on Postgres (tests/postgres_plugin.py).
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select, update

from api import database
from api.database import AsyncSessionLocal, RefreshToken, User, init_db, reset_engine
from api.domains.auth.refresh_router import ROTATE_AFTER, ROTATION_GRACE
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_session_lifetime.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
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


async def _signed_in(client) -> tuple[str, str]:
    """(user id, refresh token) for a fresh account, through the real login."""
    from api.security import hash_password
    phone = "+2547" + str(uuid.uuid4().int)[:8]
    user = User(name="U", phone=phone, password_hash=hash_password("Passw0rd!x"))
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
    r = await client.post("/auth/login", json={"phone": phone, "password": "Passw0rd!x"})
    assert r.status_code == 200, r.text
    return user.id, r.json()["refresh_token"]


async def _age_tokens(user_id: str, by: timedelta) -> None:
    async with AsyncSessionLocal() as db:
        await db.execute(update(RefreshToken).where(RefreshToken.user_id == user_id).values(
            created_at=datetime.utcnow() - by))
        await db.commit()


async def _refresh(client, token: str):
    return await client.post("/auth/token/refresh", json={"refresh_token": token})


@pytest.mark.asyncio
class TestRefreshTokens:
    async def test_the_stored_expiry_is_naive_utc(self, client):
        """Postgres refuses a timezone-aware value in a naive column."""
        user_id, _ = await _signed_in(client)
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(RefreshToken).where(RefreshToken.user_id == user_id))).scalar_one()
        assert row.expires_at.tzinfo is None
        remaining = row.expires_at - datetime.utcnow()
        assert timedelta(days=29) < remaining <= timedelta(days=30)

    async def test_a_recent_token_is_not_rotated(self, client):
        _, token = await _signed_in(client)
        r = await _refresh(client, token)
        assert r.status_code == 200
        assert "access_token" in r.json() and "refresh_token" not in r.json()

    async def test_an_older_token_is_exchanged_and_the_session_slides(self, client):
        user_id, old = await _signed_in(client)
        await _age_tokens(user_id, ROTATE_AFTER + timedelta(hours=1))

        r = await _refresh(client, old)
        assert r.status_code == 200
        new = r.json()["refresh_token"]
        assert new != old

        # The new one is good for a full lifetime from now.
        assert (await _refresh(client, new)).status_code == 200
        # The old one still works for the grace period - a lost response is
        # retried with it - and then stops.
        assert (await _refresh(client, old)).status_code == 200
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(select(RefreshToken).where(RefreshToken.user_id == user_id))).scalars().all()
        shortened = [r for r in rows if r.expires_at <= datetime.utcnow() + ROTATION_GRACE]
        assert shortened, "the replaced token's lifetime is cut to the grace period"
        async with AsyncSessionLocal() as db:
            for row in shortened:
                await db.execute(update(RefreshToken).where(RefreshToken.id == row.id).values(
                    expires_at=datetime.utcnow() - timedelta(seconds=1)))
            await db.commit()
        assert (await _refresh(client, old)).status_code == 401
        assert (await _refresh(client, new)).status_code == 200

    async def test_a_revoked_token_is_refused(self, client):
        _, token = await _signed_in(client)
        await client.post("/auth/token/revoke", json={"refresh_token": token})
        assert (await _refresh(client, token)).status_code == 401


def _on_postgres() -> bool:
    return database.DATABASE_URL.startswith("postgresql")


@pytest.mark.asyncio
@pytest.mark.skipif(not _on_postgres(), reason="Postgres only (tests/postgres_plugin.py)")
class TestForeignKeysOnAnExistingPostgresDatabase:
    async def test_init_db_removes_the_two_wrong_foreign_keys(self):
        from sqlalchemy import text
        from sqlalchemy.ext.asyncio import create_async_engine
        from sqlalchemy.pool import NullPool

        from api.database import _apply_optional_statements, _drop_foreign_key_sql

        schema = f"old_{uuid.uuid4().hex[:8]}"
        engine = create_async_engine(
            database.DATABASE_URL, poolclass=NullPool,
            connect_args={"server_settings": {"search_path": schema}},
        )
        fk_count = text(
            "SELECT count(*) FROM pg_constraint WHERE contype = 'f' "
            "AND conrelid = CAST(:t AS regclass)"
        )
        try:
            async with engine.begin() as conn:
                await conn.execute(text(f'CREATE SCHEMA "{schema}"'))
                # The tables as create_all made them before the fix.
                await conn.execute(text("CREATE TABLE users (id varchar PRIMARY KEY)"))
                await conn.execute(text("CREATE TABLE deals (id varchar PRIMARY KEY)"))
                await conn.execute(text(
                    "CREATE TABLE audit_logs (id varchar PRIMARY KEY, "
                    "actor_id varchar NOT NULL REFERENCES users(id))"))
                await conn.execute(text(
                    "CREATE TABLE auction_meta (id varchar PRIMARY KEY, deal_id varchar REFERENCES deals(id))"))
                assert (await conn.execute(fk_count, {"t": "audit_logs"})).scalar_one() == 1

                statements = [_drop_foreign_key_sql("audit_logs", "actor_id"),
                              _drop_foreign_key_sql("auction_meta", "deal_id")]
                await _apply_optional_statements(conn, statements)
                await _apply_optional_statements(conn, statements)      # every start: a no-op

                assert (await conn.execute(fk_count, {"t": "audit_logs"})).scalar_one() == 0
                assert (await conn.execute(fk_count, {"t": "auction_meta"})).scalar_one() == 0
                # What production needs to be able to write now:
                await conn.execute(text("INSERT INTO audit_logs VALUES ('a1', 'system')"))
                await conn.execute(text("INSERT INTO auction_meta VALUES ('m1', 'claimed-not-created')"))
        finally:
            async with engine.begin() as conn:
                await conn.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
            await engine.dispose()
