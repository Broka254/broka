"""Add fields missed when 0018 was written from memory (source doc had
rolled out of uploads at the time)

Revision ID: 0019
Revises: 0018
Create Date: 2026-08-10

0018's docstring flagged it was reconstructed from actions.py rather than
the original design doc. Doc is back; checked §25's exact conceptual
BuyingAgentRequest field list against what 0018 actually added. Missing:
query, optimization_configuration, negotiation_authorized, updated_at.
category_id (doc) vs the existing category string column, and location
(doc) vs location_name are NOT bugs to fix here — see api/database.py's
BuyAgentRequest docstring for why those were deliberate.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0019"
down_revision: Union[str, None] = "0018"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("buy_agent_requests", sa.Column("query", sa.String, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("optimization_configuration", sa.Text, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("negotiation_authorized", sa.Boolean, nullable=False, server_default=sa.false()))
    op.add_column("buy_agent_requests", sa.Column("updated_at", sa.DateTime, nullable=True))


def downgrade() -> None:
    for col in ("updated_at", "negotiation_authorized", "optimization_configuration", "query"):
        op.drop_column("buy_agent_requests", col)
