# Database schema changes

Production API processes do **not** repair the schema on startup. A release
must run the explicit migration command once, against the target database,
before new replicas start:

```bash
cd backend
DATABASE_URL='postgresql+asyncpg://...' python -m api.migrate
```

The command applies the ordered revisions in `api/database.py`, records them
in `schema_migrations`, validates the critical columns and indexes, and exits
non-zero on any genuine failure. Running it again is a no-op. API startup in
production calls `require_current_schema()`; it reports the required command
and refuses readiness rather than silently altering a partially upgraded
database.

## Fresh and existing databases

`api.migrate` creates missing tables from SQLAlchemy metadata and adopts a
database that predates a revision by adding only the missing columns and
indexes. This is deliberately safe to repeat:

- an existing column is skipped after live-schema inspection, not by
  suppressing an `ALTER TABLE` error;
- dialect-specific statements are translated explicitly (`DATETIME` to
  `TIMESTAMP`, numeric boolean defaults to `FALSE`/`TRUE`) or skipped on
  SQLite where PostgreSQL catalogue operations do not apply;
- every executable statement's failure remains visible and stops the release;
- before any unique money guard is created, a preflight query checks for
  historical duplicate checkout ids, receipts or active intents. If duplicates
  exist, the command names the index and table and stops. It never deletes or
  merges financial rows automatically; reconciliation is a human decision.

For a pre-existing database, take a backup and run `python -m api.migrate`
against a restored copy first. Confirm `GET /ready` reports `schema: ok` and
`schema_version` equal to `schema_required` before pointing application
traffic at it.

## Why Alembic is not the active mechanism

`migrations/versions/` is historical and is not run. Its chain is internally
inconsistent (`0001` creates objects that `0002` creates again) and its
`env.py` uses a synchronous driver that production does not install. Do not
add revisions there or reintroduce `alembic upgrade head` into a container
command. The explicit command above is the supported release path. A future
move to Alembic requires a verified squashed baseline and an adoption/stamp
procedure for existing databases, tested on PostgreSQL in CI.

## Configuration

- `DATABASE_URL` must point at the release target.
- `AUTO_MIGRATE_SCHEMA` exists only as a local/test escape hatch. It is off by
  default and should not be enabled in production.
- No migration needs to run in every API replica. Run it as a Railway/Azure
  pre-deploy command or a one-off release job, then start/drain replicas.

## Verification

CI runs `python -m api.migrate` twice on fresh PostgreSQL, runs the complete
backend suite on SQLite and PostgreSQL, and includes
`backend/tests/test_schema_migrations.py`, which covers fresh creation,
re-running, legacy-column adoption, duplicate preflight failure and
failure visibility.
