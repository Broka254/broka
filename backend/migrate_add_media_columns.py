"""
BROKA - Migration: add msg_type, media_url, duration_secs to negotiation_messages

Run this once against your production DB (SQLite or PostgreSQL).
SQLite: python migrate_add_media_columns.py
Postgres: DATABASE_URL=postgresql+asyncpg://... python migrate_add_media_columns.py
"""

import os
import asyncio
from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy import text


def _build_db_url() -> str:
    url = os.getenv("DATABASE_URL", "sqlite+aiosqlite:///./broka.db")
    if url.startswith("postgres://"):
        url = url.replace("postgres://", "postgresql+asyncpg://", 1)
    elif url.startswith("postgresql://") and "+asyncpg" not in url:
        url = url.replace("postgresql://", "postgresql+asyncpg://", 1)
    return url


async def migrate():
    engine = create_async_engine(_build_db_url(), echo=True)
    is_sqlite = "sqlite" in str(engine.url)

    async with engine.begin() as conn:
        if is_sqlite:
            # SQLite: ALTER TABLE only supports ADD COLUMN (no IF NOT EXISTS)
            for col, defn in [
                ("msg_type",      "VARCHAR DEFAULT 'text'"),
                ("media_url",     "TEXT"),
                ("duration_secs", "INTEGER"),
            ]:
                try:
                    await conn.execute(
                        text(f"ALTER TABLE negotiation_messages ADD COLUMN {col} {defn}")
                    )
                    print(f"  [OK] Added column: {col}")
                except Exception as e:
                    if "duplicate column" in str(e).lower():
                        print(f"  [SKIP] Column already exists: {col}")
                    else:
                        raise
        else:
            # PostgreSQL supports IF NOT EXISTS
            for col, defn in [
                ("msg_type",      "VARCHAR DEFAULT 'text'"),
                ("media_url",     "TEXT"),
                ("duration_secs", "INTEGER"),
            ]:
                await conn.execute(text(
                    f"ALTER TABLE negotiation_messages ADD COLUMN IF NOT EXISTS {col} {defn}"
                ))
                print(f"  [OK] Column: {col}")

    await engine.dispose()
    print("\nMigration complete.")


if __name__ == "__main__":
    asyncio.run(migrate())
