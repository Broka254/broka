"""Add attributes column on listings for dynamic category-specific values

Revision ID: 0017
Revises: 0016
Create Date: 2026-08-08

Phase 2 of broka_mockup_actualization_spec.md (§4: "Render category-specific
attributes... Render fields from backend category metadata"). CategoryFilter
(0012) already stores the *definitions* of these fields, scoped per category
row (top-level rows for the Filter Sheet's "More Filters"; subcategory rows
for the seller form's dynamic fields per §19's data-flow section — same
table, same endpoint, two callers). This migration adds the one thing that
was still missing: somewhere on a Listing to store the *values* a seller
actually entered for those fields (e.g. {"make": "Toyota", "mileage":
"45000"}). Nullable, JSON-encoded in application code exactly like
CategoryFilter.options already is — no existing row or query is affected.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0017"
down_revision: Union[str, None] = "0016"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column("listings", sa.Column("attributes", sa.Text, nullable=True))


def downgrade() -> None:
    op.drop_column("listings", "attributes")
