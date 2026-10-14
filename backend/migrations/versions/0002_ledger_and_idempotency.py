"""Add callback_processed idempotency + ledger_entries table to existing DBs

Revision ID: 0002
Revises: 0001
Create Date: 2026-06-20

Run this against an existing production database that was created before v3.0.
New deployments should run: alembic upgrade head (which applies 0001 then 0002).
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0002"
down_revision: Union[str, None] = "0001"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── Idempotency: callback_processed on mpesa_transactions (issue #6) ──────
    op.add_column(
        "mpesa_transactions",
        sa.Column("callback_processed", sa.Boolean, nullable=False, server_default="false"),
    )

    # ── Refresh tokens table (issue #8) ──────────────────────────────────────
    op.create_table(
        "refresh_tokens",
        sa.Column("id",         sa.String,  primary_key=True),
        sa.Column("user_id",    sa.String,  sa.ForeignKey("users.id"), nullable=False, index=True),
        sa.Column("jti",        sa.String,  nullable=False, unique=True, index=True),
        sa.Column("expires_at", sa.DateTime,nullable=False),
        sa.Column("revoked_at", sa.DateTime,nullable=True),
        sa.Column("created_at", sa.DateTime,nullable=False),
    )

    # ── Double-entry ledger (issue #5) ────────────────────────────────────────
    op.create_table(
        "ledger_entries",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("deal_id",     sa.String,  nullable=False, index=True),
        sa.Column("account",     sa.String,  nullable=False),
        sa.Column("direction",   sa.String,  nullable=False),
        sa.Column("amount_kes",  sa.Numeric(18, 2), nullable=False),
        sa.Column("description", sa.String,  nullable=False),
        sa.Column("ref_id",      sa.String,  nullable=True),
        sa.Column("created_at",  sa.DateTime,nullable=False),
    )

    # ── Trust score + fraud flag on users (if not already added by init_db) ───
    # These are safe to run even if the columns already exist
    # (use batch_alter_table for SQLite compatibility)
    with op.batch_alter_table("users") as batch_op:
        try:
            batch_op.add_column(sa.Column("trust_score", sa.Integer, default=100))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("is_flagged", sa.Boolean, default=False))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("fcm_token", sa.String, nullable=True))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("is_admin", sa.Boolean, default=False))
        except Exception:
            pass


def downgrade() -> None:
    op.drop_table("ledger_entries")
    op.drop_table("refresh_tokens")
    with op.batch_alter_table("mpesa_transactions") as batch_op:
        batch_op.drop_column("callback_processed")
