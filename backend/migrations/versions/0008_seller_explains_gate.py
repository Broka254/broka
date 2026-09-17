"""Add seller_has_explained gate to deals

Revision ID: 0008
Revises: 0007
Create Date: 2026-06-28

Fixes a real gap found during review of 0006's "seller explains first"
design: the buyer's refund/replacement choice buttons were gated purely on
deal.status == "awaiting_resolution", but seller_explains_wrong_item /
seller_explains_damaged never changed that status - they only posted a
message. This meant the buyer could see and tap "I want a refund" /
"I want a replacement" before the seller had any chance to respond at all,
contradicting the documented design.

This column is the explicit, checkable gate: buyer_chooses_refund and
buyer_chooses_replacement should now also require seller_has_explained is
True before acting (in addition to the existing status check), and the
Flutter UI should hide those buttons until this flag is set.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0008"
down_revision: Union[str, None] = "0007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.add_column(sa.Column("seller_has_explained", sa.Boolean,
                                       server_default="0", nullable=True))


def downgrade() -> None:
    with op.batch_alter_table("deals") as batch_op:
        batch_op.drop_column("seller_has_explained")
