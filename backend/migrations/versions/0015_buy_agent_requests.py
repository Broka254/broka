"""Add buy_agent_requests table; add is_agent_initiated to negotiation_messages

Revision ID: 0015
Revises: 0014
Create Date: 2026-08-05

Backs Zeno as Buying Agent (Design Journal Volume 5, Ch.10; wired into the
new homescreen per Volume 6, Ch.8). One active row per buyer is enforced
in buy_agent/service.py, not by a DB constraint - "active" depends on
status, not existence.

Also adds negotiation_messages.is_agent_initiated, which the doc's own
migration draft did not include but Chapter 22 requires: when Zeno opens a
negotiation on a buyer's behalf (via buy_agent_subscribers.py), the first
message must be visibly disclosed as agent-initiated
(negotiate_screen.dart), which needs a flag on the message to render.

Renumbered from the design doc's proposed "0014" to "0015" for the same
reason as the three migrations before it in this plan: 0011 is already
taken in this codebase.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0015"
down_revision: Union[str, None] = "0014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "buy_agent_requests",
        sa.Column("id",                 sa.String,   primary_key=True),
        sa.Column("buyer_id",           sa.String,   sa.ForeignKey("users.id"), nullable=False, index=True),
        sa.Column("category",           sa.String,   nullable=False),
        sa.Column("max_price",          sa.Float,    nullable=False),
        sa.Column("must_have_features", sa.Text,     nullable=True),
        sa.Column("status",             sa.String,   nullable=False, default="active"),
        sa.Column("created_at",         sa.DateTime, nullable=False),
    )
    op.add_column("negotiation_messages", sa.Column("is_agent_initiated", sa.Boolean, nullable=True))


def downgrade() -> None:
    op.drop_column("negotiation_messages", "is_agent_initiated")
    op.drop_table("buy_agent_requests")
