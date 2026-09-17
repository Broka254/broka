"""Phone-first onboarding rework (v6.1)

Revision ID: 0011
Revises: 0010
Create Date: 2026-07-27

Reworks account creation per the onboarding redesign:
  - `phone` becomes the required, unique login identifier.
  - `email` is downgraded from required+unique to optional (a large share of
    users are unfamiliar/uncomfortable with email-based signup).
  - Adds `account_type` (buyer | buyer_seller) plus the structured seller
    business-identity fields (name/category/location/description) and the
    auto-generated `business_display_name` — sellers no longer free-type a
    single display string, which avoided "Clanix-Ugunja" vs "Clanix ugunja"
    vs "CLANIX" fragmenting search/Zeno-matching for the same business.
  - Adds `phone_otps` for the registration OTP request/verify flow.

Any existing row with no phone is backfilled with a unique placeholder
(`unverified-<id>`) before the NOT NULL + UNIQUE constraint is applied, so
this is safe to run against a pre-v6.1 database that predates phone
collection. Those accounts simply won't be able to log in via phone until
support updates them - there should be none in production yet, since phone
wasn't previously required.
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0011"
down_revision: Union[str, None] = "0010"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── users: new account-type + seller-identity columns ────────────────────
    with op.batch_alter_table("users") as batch_op:
        try:
            batch_op.add_column(sa.Column("account_type", sa.String(), nullable=False,
                                           server_default="buyer"))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("business_name", sa.String(), nullable=True))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("business_category", sa.String(), nullable=True))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("business_location", sa.String(), nullable=True))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("business_description", sa.Text(), nullable=True))
        except Exception:
            pass
        try:
            batch_op.add_column(sa.Column("business_display_name", sa.String(), nullable=True))
        except Exception:
            pass

    # ── Backfill phone before enforcing NOT NULL + UNIQUE ────────────────────
    op.execute(
        "UPDATE users SET phone = 'unverified-' || id WHERE phone IS NULL OR phone = ''"
    )

    # ── phone: required + unique; email: now optional ────────────────────────
    with op.batch_alter_table("users") as batch_op:
        batch_op.alter_column("phone", existing_type=sa.String(), nullable=False)
        batch_op.alter_column("email", existing_type=sa.String(), nullable=True)
        try:
            batch_op.create_unique_constraint("uq_users_phone", ["phone"])
        except Exception:
            pass

    # ── phone_otps ────────────────────────────────────────────────────────────
    op.create_table(
        "phone_otps",
        sa.Column("id",         sa.String,   primary_key=True),
        sa.Column("phone",      sa.String,   nullable=False, index=True),
        sa.Column("code_hash",  sa.String,   nullable=False),
        sa.Column("purpose",    sa.String,   nullable=False, server_default="registration"),
        sa.Column("attempts",   sa.Integer,  nullable=False, server_default="0"),
        sa.Column("consumed",   sa.Boolean,  nullable=False, server_default="false"),
        sa.Column("expires_at", sa.DateTime, nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
    )


def downgrade() -> None:
    op.drop_table("phone_otps")
    with op.batch_alter_table("users") as batch_op:
        batch_op.drop_constraint("uq_users_phone", type_="unique")
        batch_op.alter_column("phone", existing_type=sa.String(), nullable=True)
        batch_op.alter_column("email", existing_type=sa.String(), nullable=False)
        batch_op.drop_column("business_display_name")
        batch_op.drop_column("business_description")
        batch_op.drop_column("business_location")
        batch_op.drop_column("business_category")
        batch_op.drop_column("business_name")
        batch_op.drop_column("account_type")
