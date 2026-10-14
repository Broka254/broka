"""Add wishlists and user_specializations tables

Revision ID: 0013
Revises: 0012
Create Date: 2026-08-05

Traders are not a new identity (Design Journal Volume 6, Ch.5) — existing
sellers, re-presented. business_name is nullable and falls back to `name`
in the API layer when unset. user_specializations is populated by
trader_specialization_subscribers.py on every ListingCreated event, not
self-declared.

Renumbered from the design doc's proposed "0012" to "0013" for the same
reason as 0012_categories_and_listing_fields: 0011 is already taken in
this codebase. This migration also does NOT add users.business_name,
unlike the doc's draft — 0011_phone_first_onboarding already added that
column, so re-adding it here would fail against a real database.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0013"
down_revision: Union[str, None] = "0012"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "wishlists",
        sa.Column("id",         sa.String,   primary_key=True),
        sa.Column("user_id",    sa.String,   sa.ForeignKey("users.id"),    nullable=False, index=True),
        sa.Column("listing_id", sa.String,   sa.ForeignKey("listings.id"), nullable=False, index=True),
        sa.Column("created_at", sa.DateTime, nullable=False),
        sa.UniqueConstraint("user_id", "listing_id", name="uq_wishlist_user_listing"),
    )
    op.create_table(
        "user_specializations",
        sa.Column("id",            sa.String,  primary_key=True),
        sa.Column("user_id",       sa.String,  sa.ForeignKey("users.id"),      nullable=False, index=True),
        sa.Column("category_id",   sa.String,  sa.ForeignKey("categories.id"), nullable=False, index=True),
        sa.Column("listing_count", sa.Integer, nullable=False, default=0),
        sa.UniqueConstraint("user_id", "category_id", name="uq_specialization_user_category"),
    )


def downgrade() -> None:
    op.drop_table("user_specializations")
    op.drop_table("wishlists")
