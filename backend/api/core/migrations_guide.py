"""
⚠️  STATUS AS OF THIS HARDENING PASS (2026-09) — READ THIS FIRST  ⚠️
─────────────────────────────────────────────────────────────────────
This file's own "Rules" below say "Every schema change → Alembic" and
"Never call create_all() in production." Neither statement is true of
this codebase today, and hasn't been since well before the Store
feature. Verified by checking what actually runs, not what this file
claims:

  - api/database.py's init_db() calls Base.metadata.create_all()
    UNCONDITIONALLY, every startup, with no environment gate - not just
    in tests. That's how every table in this database, Store included,
    actually gets created.
  - New COLUMNS on an already-existing table (most recently,
    Listing.store_id) go through that same function's own hand-written
    `migrations` list of raw `ALTER TABLE ... ADD COLUMN` statements
    (wrapped in try/except so a column that already exists is a no-op),
    plus an `index_patches` list for retroactive indexes. Also inside
    init_db(), also unconditional.
  - Nothing in main.py, any Docker/Render startup command, or any CI
    workflow ever invokes `alembic upgrade`, `alembic revision`, or
    imports anything from this backend/migrations/ directory. Checked
    directly (grepped the whole repo for "alembic") rather than assumed.

So there are not three competing schema mechanisms in practice - there's
one (create_all + the two manual lists above), and one historical,
currently-unused Alembic setup (backend/migrations/, alembic.ini) sitting
alongside it. This guide's commands below are kept as reference syntax
in case the project ever does move to real migrations later (once a
populated production database can no longer just be recreated from
models) - but until that decision is made, do NOT add files under
backend/migrations/versions/, and do NOT gate anything on `alembic
upgrade` having been run. A fresh/empty database only ever needs
init_db() to run.
─────────────────────────────────────────────────────────────────────

BROKA v4.0 — Alembic Migration Quick Reference
───────────────────────────────────────────────
Commands:
  # Generate migration after schema change
  alembic revision --autogenerate -m "add_idempotency_key_to_mpesa"

  # Apply all pending migrations (dev)
  alembic upgrade head

  # Apply to production
  DATABASE_URL=postgresql+asyncpg://... alembic upgrade head

  # Show current revision
  alembic current

  # Rollback one step
  alembic downgrade -1

  # Generate SQL for review (do this before prod)
  alembic upgrade head --sql > migration.sql

Rules (historical intent — see the status note above for what actually
happens today):
  1. Every schema change → Alembic, no exceptions in production.
  2. Never call create_all() in production. Only in in-memory tests.
  3. Keep migrations small and reversible.
  4. Name migrations descriptively: add_trust_score_to_users, not revision_001.
"""
