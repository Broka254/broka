"""Explicit database release step.

Run this once per deployment, before starting new API replicas:

    python -m api.migrate

It applies the versioned schema revisions and records them in
``schema_migrations``. The API process itself only validates the version in
production, so a rolling deploy cannot have several replicas racing to
ALTER the same tables.
"""
from __future__ import annotations

import asyncio
import os
import sys

# Migrations may legitimately build an index for longer than an API request
# is allowed to run. Disable only the per-command cap for this one-shot
# release process; connect and pool waits stay bounded. An operator or CI
# timeout remains the outer bound on the release command.
os.environ.setdefault("DB_COMMAND_TIMEOUT_SECONDS", "0")

from api.database import SCHEMA_VERSION, _init_db_impl, require_current_schema


async def _main() -> int:
    await _init_db_impl()
    status = await require_current_schema()
    print(
        f"schema is current: version={status['current_version']} "
        f"(required {SCHEMA_VERSION})"
    )
    return 0


def main() -> int:
    try:
        return asyncio.run(_main())
    except Exception as exc:
        # No traceback by default: migration failures often contain DSNs or
        # row data. The exception type and message are enough for an operator
        # to act on and are deliberately the only output.
        print(f"schema migration failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
