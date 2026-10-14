"""Add auction_meta table (one-to-one with auction-type listings)

Revision ID: 0014
Revises: 0013
Create Date: 2026-08-05

Auctions remain auction-type Listing rows plus Bid rows (unchanged, Ch.6)
— this table adds only what was missing: computed status, minimum next-
bid increment, winner, and denormalized current_bid/bid_count so the
Auction House grid does not aggregate Bid on every read.

Renumbered from the design doc's proposed "0013" to "0014" for the same
reason as the previous two migrations in this plan: 0011 is already taken
in this codebase, which shifted everything after it by one.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0014"
down_revision: Union[str, None] = "0013"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "auction_meta",
        sa.Column("id",                sa.String,  primary_key=True),
        sa.Column("listing_id",        sa.String,  sa.ForeignKey("listings.id"), nullable=False, unique=True, index=True),
        sa.Column("status",            sa.String,  nullable=False, default="upcoming"),
        sa.Column("min_bid_increment", sa.Float,   nullable=False, default=500.0),
        sa.Column("current_bid",       sa.Float,   nullable=True),
        sa.Column("bid_count",         sa.Integer, nullable=False, default=0),
        sa.Column("winner_id",         sa.String,  sa.ForeignKey("users.id"), nullable=True),
    )


def downgrade() -> None:
    op.drop_table("auction_meta")
