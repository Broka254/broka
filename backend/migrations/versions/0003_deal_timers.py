"""Add auto-resolution timer fields to deals

Revision ID: 0003
Revises: 0002
Create Date: 2026-06-24

Supports Zeno-announced, backend-enforced timers (e.g. "I'll refund you in
48h if the seller doesn't respond"). Zeno only communicates the deadline -
a periodic sweep (task_check_deal_timers, see api/core/workers.py) is the
sole thing that checks the deadline and fires the action.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0003"
down_revision: Union[str, None] = "0002"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.add_column(sa.Column("timer_type", sa.String, nullable=True))
        batch_op.add_column(sa.Column("timer_deadline", sa.DateTime, nullable=True))
        batch_op.add_column(sa.Column("timer_cancelled_at", sa.DateTime, nullable=True))
        batch_op.add_column(sa.Column("timer_fired_at", sa.DateTime, nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.drop_column("timer_fired_at")
        batch_op.drop_column("timer_cancelled_at")
        batch_op.drop_column("timer_deadline")
        batch_op.drop_column("timer_type")
