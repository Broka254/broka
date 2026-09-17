"""Add thread_read_state table (unread counts + message seen ticks)

Revision ID: 0010
Revises: 0009
Create Date: 2026-07-12

Backs two related, previously-missing features:
  - The inbox's per-thread "unread" count, which existed in the response
    shape (and the Flutter UI already rendered badges for it) but was
    hardcoded to 0 server-side - it was never actually computed.
  - Per-message "seen" ticks in the direct-chat thread, so a sender can see
    whether the other party has read what they sent.

One row per (listing, buyer, role): the timestamp up to which that side has
read the thread. See ThreadReadState in database.py for why a watermark
rather than a per-message read flag.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0010"
down_revision: Union[str, None] = "0009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "thread_read_state",
        sa.Column("id",            sa.String,   primary_key=True),
        sa.Column("listing_id",    sa.String,   sa.ForeignKey("listings.id"), nullable=False, index=True),
        sa.Column("buyer_id",      sa.String,   nullable=False, index=True),
        sa.Column("role",          sa.String,   nullable=False),
        sa.Column("last_read_at",  sa.DateTime, nullable=False),
        sa.UniqueConstraint("listing_id", "buyer_id", "role", name="uq_thread_read_state"),
    )


def downgrade() -> None:
    op.drop_table("thread_read_state")
