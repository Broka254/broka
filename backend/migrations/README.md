# Alembic in this repository — read before using it

**Alembic does not run in production, and `alembic upgrade head` does not
currently work on a fresh database.** The schema is created by `init_db()`
in `api/database.py`, called from `main.py`'s FastAPI lifespan on every
boot. That is the live mechanism; these migration files are history that
has drifted out of sync with it.

> This file previously opened with "**not invoked anywhere** in this
> codebase — checked directly (main.py, every startup script, every CI
> workflow)". That was true of `main.py` and of CI, and false of the thing
> that mattered: all three Dockerfiles ran `alembic upgrade head &&
> uvicorn ...`, so the deployed container invoked it on every boot and
> died there. The list of places that were checked did not include the
> container command. Both faults below are what that produced.

## What `init_db()` does

- **New tables** — `Base.metadata.create_all()`, unconditionally on every
  startup.
- **New columns on an existing table** — the hand-written `migrations`
  list of `ALTER TABLE ... ADD COLUMN` statements, each in its own
  SAVEPOINT so an already-present column is a no-op.
- **New indexes** — the `index_patches` list of
  `CREATE INDEX IF NOT EXISTS` statements.

See `api/core/migrations_guide.py` for the fuller explanation and the
historical Alembic command reference.

Two separate faults, both reproducible today:

### 1. The production image had no driver for this

`requirements.txt` installs `asyncpg`. `env.py` rewrites
`postgresql+asyncpg://` to `postgresql://`, whose SQLAlchemy DBAPI is
`psycopg2` — not installed. So:

```
$ DATABASE_URL="postgresql+asyncpg://..." alembic upgrade head
ModuleNotFoundError: No module named 'psycopg2'
```

The deployed container command was `alembic upgrade head && uvicorn ...`,
so this killed the container before uvicorn was reached. It is now
`uvicorn` alone.

### 2. Installing the driver would not fix it

The chain is internally inconsistent. `0001_initial_schema` creates
`mpesa_transactions` **with** `callback_processed`, and creates
`ledger_entries`. `0002_ledger_and_idempotency` then adds that same column
and creates that same table again:

```
$ DATABASE_URL="sqlite+aiosqlite:///fresh.db" alembic upgrade head
sqlalchemy.exc.OperationalError: (sqlite3.OperationalError)
duplicate column name: callback_processed
[SQL: ALTER TABLE mpesa_transactions ADD COLUMN callback_processed BOOLEAN ...]
```

This is why the fix was to stop running Alembic rather than to install
`psycopg2` — the driver only moves the failure from step 1 to step 2.

## If you want Alembic back

It is a real piece of work, not a flag:

1. Install a sync driver (`psycopg2-binary`) alongside `asyncpg`.
2. Repair the chain. The honest option is to collapse `0001`–`0021` into a
   single squashed baseline generated from the current `Base.metadata`
   (which `init_db()` already builds correctly), then `alembic stamp` every
   existing deployment to it. Patching `0002` alone is not enough — the
   chain has never been run end to end, so later revisions are unverified
   against each other too.
3. Add the upgrade to CI so the chain is exercised on a fresh database on
   every push. Nothing tests it today, which is how it drifted this far.
4. Only then put it back in the container command — and keep `init_db()`
   until the squashed baseline has been proven against a real deployment.

`tests/test_deployment_config.py` pins the current arrangement: it asserts
the container command reaches `uvicorn` without Alembic, and it reproduces
both faults above so they cannot be quietly forgotten.

## Until that work is done

Do not add files under `versions/`, and do not build anything that assumes
`alembic upgrade head` has been run. A fresh or empty database only ever
needs `init_db()`.
