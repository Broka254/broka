"""Add buy_agent_requests.match_count — the column the model has had all along

Revision ID: 0020
Revises: 0019
Create Date: 2026-09-17

BuyAgentRequest.match_count was added straight to the model
(api/database.py) during the redesign-guide audit with no migration to go
with it. Production deploys run `alembic upgrade head` and nothing else
(backend/Dockerfile's CMD), so on any database that already existed the
column was simply never created - and because SQLAlchemy selects every
mapped column, that is not a degraded feature, it is every single query
against buy_agent_requests failing outright: creating a standing request,
GET /buy-agent-requests/me, matching, cancelling. The whole Buying Agent
feature, 500ing.

init_db() does carry an "ALTER TABLE buy_agent_requests ADD COLUMN
match_count ..." line in its forward-compat list, which is why this was
invisible in dev: on SQLite each statement there is its own implicit
transaction, so the ones that fail ("column already exists") cost nothing.
On PostgreSQL that list runs inside one `engine.begin()` transaction, and
the first already-exists failure aborts it - every later statement, this
column among them, then fails with InFailedSqlTransaction and is swallowed
by the same `except Exception: pass`. That has been fixed separately (each
statement now runs in its own SAVEPOINT, see api/database.py), but a
startup patcher is a safety net, not the schema of record. This migration
is the schema of record.

Idempotent on purpose: deployments that already picked the column up via
init_db()'s patch list must not fail here.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa

revision: str = "0020"
down_revision: Union[str, None] = "0019"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _has_match_count() -> bool:
    bind = op.get_bind()
    cols = sa.inspect(bind).get_columns("buy_agent_requests")
    return any(c["name"] == "match_count" for c in cols)


def upgrade() -> None:
    if _has_match_count():
        return
    op.add_column(
        "buy_agent_requests",
        sa.Column("match_count", sa.Integer, nullable=False, server_default=sa.text("0")),
    )


def downgrade() -> None:
    if _has_match_count():
        op.drop_column("buy_agent_requests", "match_count")
