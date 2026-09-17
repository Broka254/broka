# Not currently used

This Alembic setup exists but is **not invoked anywhere** in this
codebase — checked directly (main.py, every startup script, every CI
workflow) rather than assumed. There is no `alembic upgrade` call in
this repository's actual startup path.

The real schema-management mechanism is `api/database.py`'s `init_db()`:

- **New tables** (like `Store` when it was added) are created by
  `Base.metadata.create_all()`, called unconditionally on every startup.
- **New columns on an already-existing table** (like `Listing.store_id`)
  go through that same function's hand-written `migrations` list of
  `ALTER TABLE ... ADD COLUMN` statements, wrapped in a try/except so a
  column that already exists is a no-op.
- **New indexes on an existing table** work the same way, via an
  `index_patches` list of `CREATE INDEX IF NOT EXISTS` statements.

See `api/core/migrations_guide.py` for the fuller explanation and the
historical Alembic command reference (kept for if/when this project
outgrows the fresh-database workflow and genuinely needs real, reversible
migrations against a populated production database).

**Until that decision is made:** do not add files under `versions/`, and
do not build anything that assumes `alembic upgrade head` has been run.
A fresh/empty database only ever needs `init_db()`.
