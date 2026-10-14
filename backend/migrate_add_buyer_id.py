"""
One-time migration: add `buyer_id` and `via_ai` columns to negotiation_messages.

Run once on the production database after deploying the updated backend:

    python migrate_add_buyer_id.py

Requires DATABASE_URL in the environment (same as the main app).
The script is idempotent — safe to run multiple times.
"""

import os
import asyncio
import asyncpg


async def main():
    db_url = os.environ.get("DATABASE_URL", "")
    if not db_url:
        raise RuntimeError("DATABASE_URL not set")

    # asyncpg expects postgresql:// not postgres://
    if db_url.startswith("postgres://"):
        db_url = db_url.replace("postgres://", "postgresql://", 1)

    conn = await asyncpg.connect(db_url)
    try:
        # Add buyer_id if it doesn't exist
        await conn.execute("""
            ALTER TABLE negotiation_messages
            ADD COLUMN IF NOT EXISTS buyer_id VARCHAR;
        """)
        print("✓ buyer_id column ready")

        # Add via_ai if it doesn't exist
        await conn.execute("""
            ALTER TABLE negotiation_messages
            ADD COLUMN IF NOT EXISTS via_ai BOOLEAN DEFAULT FALSE;
        """)
        print("✓ via_ai column ready")

        print("\nMigration complete. Existing rows keep NULL buyer_id and NULL via_ai,")
        print("which the app treats as legacy 'unscoped' messages (shown to everyone).")
    finally:
        await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
