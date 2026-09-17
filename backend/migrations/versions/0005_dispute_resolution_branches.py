"""Add full dispute-resolution branch columns to deals

Revision ID: 0005
Revises: 0004
Create Date: 2026-06-26

Adds the state columns needed to track the complete post-delivery dispute
resolution flow:

  Branch A1 - Goods arrived, buyer confirms OK                → release 97%
  Branch A2 - Goods arrived but wrong item                   → refund or replace
  Branch A3 - Goods arrived but damaged (image-verified)     → refund or replace
  Branch A4 - Seller ships replacement; wait for buyer ack   → re-runs A1/A2/A3
  Branch B  - Goods never arrived                            → contact seller → refund

Key design invariant preserved from earlier migrations:
  Zeno announces and explains every timer/deadline in conversation.
  Zeno NEVER holds the trigger. Every fund-moving action is a deterministic
  DB write in workers.py (task_check_deal_timers sweep) or negotiate.py
  (explicit user button-tap intent). No AI text output is ever parsed to
  decide whether money moves.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0005"
down_revision: Union[str, None] = "0004"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        # Which dispute scenario Zeno is mediating ("A1","A2","A3","A4","B")
        batch_op.add_column(sa.Column("dispute_branch", sa.String, nullable=True))
        # How many replacement cycles have been attempted (no cap)
        batch_op.add_column(sa.Column("replacement_cycle", sa.Integer, server_default="0", nullable=True))
        # When the seller last shipped a replacement (starts Branch A4)
        batch_op.add_column(sa.Column("replacement_shipped_at", sa.DateTime, nullable=True))
        # When Branch B (goods not arrived) began
        batch_op.add_column(sa.Column("goods_not_arrived_started_at", sa.DateTime, nullable=True))
        # How many 24h seller-contact attempts have fired in Branch B
        batch_op.add_column(sa.Column("goods_not_arrived_checkin_count", sa.Integer, server_default="0", nullable=True))
        # When the buyer-silence-after-expected-delivery 4-day timer began
        batch_op.add_column(sa.Column("buyer_delivery_silence_started_at", sa.DateTime, nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.drop_column("buyer_delivery_silence_started_at")
        batch_op.drop_column("goods_not_arrived_checkin_count")
        batch_op.drop_column("goods_not_arrived_started_at")
        batch_op.drop_column("replacement_shipped_at")
        batch_op.drop_column("replacement_cycle")
        batch_op.drop_column("dispute_branch")
