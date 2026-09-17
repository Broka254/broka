"""Add categories/category_filters tables and subcategory_id/condition on listings

Revision ID: 0012
Revises: 0011
Create Date: 2026-08-05

Backs the marketplace density redesign (Design Journal Volume 6). Categories
were previously a free-text string on Listing with no backing table, no
subcategory concept, and no per-category filter metadata. Existing
listings.category values are NOT touched here — see
backend/migrate_categories_from_freetext.py for the one-time data pass that
runs after this schema lands.

Renumbered from the design doc's proposed "0011" to "0012": migration 0011
in this codebase is already taken by phone_first_onboarding (which also
already added users.business_name — see 0013_wishlists_and_trader_fields,
which does not repeat that column).
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0012"
down_revision: Union[str, None] = "0011"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "categories",
        sa.Column("id",        sa.String,  primary_key=True),
        sa.Column("name",      sa.String,  nullable=False),
        sa.Column("icon",      sa.String,  nullable=True),
        sa.Column("parent_id", sa.String,  sa.ForeignKey("categories.id"), nullable=True, index=True),
    )
    op.create_table(
        "category_filters",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("category_id", sa.String,  sa.ForeignKey("categories.id"), nullable=False, index=True),
        sa.Column("field_name",  sa.String,  nullable=False),
        sa.Column("field_type",  sa.String,  nullable=False),   # "text" | "number_range" | "select"
        sa.Column("options",     sa.Text,    nullable=True),    # JSON-encoded list, for "select" fields
    )
    op.add_column("listings", sa.Column("subcategory_id", sa.String, sa.ForeignKey("categories.id"), nullable=True))
    op.add_column("listings", sa.Column("condition", sa.String, nullable=True))  # "new" | "used" | "refurbished"


def downgrade() -> None:
    op.drop_column("listings", "condition")
    op.drop_column("listings", "subcategory_id")
    op.drop_table("category_filters")
    op.drop_table("categories")
