"""Extend buy_agent_requests for CREATE_BUYING_REQUEST

Revision ID: 0018
Revises: 0017
Create Date: 2026-08-10

Zeno Action Engine, CREATE_BUYING_REQUEST (Broka_HomeScreen_Zeno_
BuyingAgent_Design_v2.md - reconstructed from actions.py's
SearchProductsParams rather than re-read from the source doc, which had
rolled out of the uploads mount by the time this migration was written;
noted here so a mismatch against the original doc is easy to spot and
correct). Mirrors Listing's own columns/names exactly (subcategory_id,
lat/lng/location_name, condition, attributes) rather than inventing a
parallel shape - a buying request is structurally "a saved search," so it
should look like the thing it's saving a search over. optimization_code
persists which ranking strategy (see buy_agent/actions.py) matches for
this request should use once BuyAgentService.get_active_for_buyer's
result actually gets ranked - not wired to that yet, just storage.

All nullable / no backfill: every existing row is valid with these blank,
same reasoning as 0017.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0018"
down_revision: Union[str, None] = "0017"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("buy_agent_requests", sa.Column("subcategory_id", sa.String, sa.ForeignKey("categories.id"), nullable=True))
    op.add_column("buy_agent_requests", sa.Column("min_price", sa.Float, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("location_name", sa.String, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("lat", sa.Float, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("lng", sa.Float, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("max_distance_km", sa.Float, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("condition", sa.String, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("attributes", sa.Text, nullable=True))
    op.add_column("buy_agent_requests", sa.Column("optimization_code", sa.String, nullable=True))


def downgrade() -> None:
    for col in ("optimization_code", "attributes", "condition", "max_distance_km",
                "lng", "lat", "location_name", "min_price", "subcategory_id"):
        op.drop_column("buy_agent_requests", col)
