"""Add delivery-confirmation lifecycle fields to deals

Revision ID: 0004
Revises: 0003
Create Date: 2026-06-25

Supports the negotiated-delivery-date check-in flow: Zeno asks for expected
delivery at finalization, checks in around that date, and only allows an
auto-release after the seller claims delivery AND a full sequence of active
buyer check-ins (with real push notifications) goes unanswered.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0004"
down_revision: Union[str, None] = "0003"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.add_column(sa.Column("expected_delivery_date", sa.DateTime, nullable=True))
        batch_op.add_column(sa.Column("seller_claimed_delivery_at", sa.DateTime, nullable=True))
        batch_op.add_column(sa.Column("checkin_count", sa.Integer, server_default="0"))
        batch_op.add_column(sa.Column("last_checkin_at", sa.DateTime, nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.drop_column("last_checkin_at")
        batch_op.drop_column("checkin_count")
        batch_op.drop_column("seller_claimed_delivery_at")
        batch_op.drop_column("expected_delivery_date")
