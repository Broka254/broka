"""Initial schema — all v3.0 tables

Revision ID: 0001
Revises:
Create Date: 2026-06-20
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0001"
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # ── users ─────────────────────────────────────────────────────────────────
    op.create_table(
        "users",
        sa.Column("id",                 sa.String,  primary_key=True),
        sa.Column("name",               sa.String,  nullable=False),
        sa.Column("nickname",           sa.String,  nullable=True),
        sa.Column("email",              sa.String,  nullable=False, unique=True, index=True),
        sa.Column("phone",              sa.String,  nullable=True),
        sa.Column("password_hash",      sa.String,  nullable=False),
        sa.Column("lat",                sa.Float,   nullable=True),
        sa.Column("lng",                sa.Float,   nullable=True),
        sa.Column("rating",             sa.Float,   default=5.0),
        sa.Column("completed_deals",    sa.Integer, default=0),
        sa.Column("is_verified",        sa.Boolean, default=False),
        sa.Column("verify_tier",        sa.String,  nullable=True),
        sa.Column("verify_expires_at",  sa.DateTime,nullable=True),
        sa.Column("preferred_language", sa.String,  default="english"),
        sa.Column("location_visible",   sa.Boolean, default=True),
        sa.Column("biometric_enrolled", sa.String,  nullable=True),
        sa.Column("profile_photo",      sa.Text,    nullable=True),
        sa.Column("fcm_token",          sa.String,  nullable=True),
        sa.Column("is_admin",           sa.Boolean, default=False),
        sa.Column("last_seen",          sa.DateTime,nullable=True),
        sa.Column("trust_score",        sa.Integer, default=100),
        sa.Column("is_flagged",         sa.Boolean, default=False),
        sa.Column("created_at",         sa.DateTime,nullable=False),
    )

    # ── refresh_tokens ────────────────────────────────────────────────────────
    op.create_table(
        "refresh_tokens",
        sa.Column("id",         sa.String,  primary_key=True),
        sa.Column("user_id",    sa.String,  sa.ForeignKey("users.id"), nullable=False, index=True),
        sa.Column("jti",        sa.String,  nullable=False, unique=True, index=True),
        sa.Column("expires_at", sa.DateTime,nullable=False),
        sa.Column("revoked_at", sa.DateTime,nullable=True),
        sa.Column("created_at", sa.DateTime,nullable=False),
    )

    # ── listings ──────────────────────────────────────────────────────────────
    op.create_table(
        "listings",
        sa.Column("id",               sa.String,  primary_key=True),
        sa.Column("seller_id",        sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("name",             sa.String,  nullable=False),
        sa.Column("description",      sa.Text,    nullable=True),
        sa.Column("category",         sa.String,  nullable=False),
        sa.Column("price",            sa.Float,   nullable=False),
        sa.Column("lat",              sa.Float,   nullable=False),
        sa.Column("lng",              sa.Float,   nullable=False),
        sa.Column("location_name",    sa.String,  nullable=True),
        sa.Column("listing_type",     sa.String,  default="direct"),
        sa.Column("status",           sa.String,  default="active"),
        sa.Column("views",            sa.Integer, default=0),
        sa.Column("target_bidders",   sa.Integer, nullable=True),
        sa.Column("auction_date",     sa.DateTime,nullable=True),
        sa.Column("reserve_price",    sa.Float,   nullable=True),
        sa.Column("verified_photos",  sa.Text,    nullable=True),
        sa.Column("verified_video",   sa.Text,    nullable=True),
        sa.Column("advert_video",     sa.Text,    nullable=True),
        sa.Column("is_featured",      sa.Boolean, default=False),
        sa.Column("featured_until",   sa.DateTime,nullable=True),
        sa.Column("created_at",       sa.DateTime,nullable=False),
    )

    # ── deals ─────────────────────────────────────────────────────────────────
    op.create_table(
        "deals",
        sa.Column("id",                      sa.String,  primary_key=True),
        sa.Column("listing_id",              sa.String,  sa.ForeignKey("listings.id")),
        sa.Column("seller_id",               sa.String,  sa.ForeignKey("users.id")),
        sa.Column("buyer_id",                sa.String,  sa.ForeignKey("users.id")),
        sa.Column("agreed_price",            sa.Float,   nullable=False),
        sa.Column("commission",              sa.Float,   nullable=False),
        sa.Column("status",                  sa.String,  default="agreed"),
        sa.Column("delivery_confirmed_at",   sa.DateTime,nullable=True),
        sa.Column("released_at",             sa.DateTime,nullable=True),
        sa.Column("refunded_at",             sa.DateTime,nullable=True),
        sa.Column("created_at",              sa.DateTime,nullable=False),
    )

    # ── mpesa_transactions ────────────────────────────────────────────────────
    op.create_table(
        "mpesa_transactions",
        sa.Column("id",                  sa.String,  primary_key=True),
        sa.Column("deal_id",             sa.String,  sa.ForeignKey("deals.id"), nullable=False),
        sa.Column("buyer_id",            sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("phone",               sa.String,  nullable=False),
        sa.Column("amount",              sa.Float,   nullable=False),
        sa.Column("checkout_request_id", sa.String,  nullable=False, unique=True, index=True),
        sa.Column("merchant_request_id", sa.String,  nullable=True),
        sa.Column("mpesa_receipt",       sa.String,  nullable=True),
        sa.Column("status",              sa.String,  default="pending"),
        sa.Column("callback_processed",  sa.Boolean, default=False),
        sa.Column("created_at",          sa.DateTime,nullable=False),
    )

    # ── ledger_entries (double-entry escrow ledger) ───────────────────────────
    op.create_table(
        "ledger_entries",
        sa.Column("id",           sa.String,  primary_key=True),
        sa.Column("deal_id",      sa.String,  nullable=False, index=True),
        sa.Column("account",      sa.String,  nullable=False),
        sa.Column("direction",    sa.String,  nullable=False),
        sa.Column("amount_kes",   sa.Numeric(18, 2), nullable=False),
        sa.Column("description",  sa.String,  nullable=False),
        sa.Column("ref_id",       sa.String,  nullable=True),
        sa.Column("created_at",   sa.DateTime,nullable=False),
    )

    # ── audit_logs ────────────────────────────────────────────────────────────
    op.create_table(
        "audit_logs",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("user_id",     sa.String,  nullable=True),
        sa.Column("action",      sa.String,  nullable=False),
        sa.Column("entity_type", sa.String,  nullable=True),
        sa.Column("entity_id",   sa.String,  nullable=True),
        sa.Column("detail",      sa.Text,    nullable=True),
        sa.Column("ip_address",  sa.String,  nullable=True),
        sa.Column("created_at",  sa.DateTime,nullable=False),
    )

    # ── fraud_events ──────────────────────────────────────────────────────────
    op.create_table(
        "fraud_events",
        sa.Column("id",           sa.String,  primary_key=True),
        sa.Column("user_id",      sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("reason",       sa.String,  nullable=False),
        sa.Column("trust_delta",  sa.Integer, default=0),
        sa.Column("new_score",    sa.Integer, nullable=False),
        sa.Column("triggered_by", sa.String,  nullable=True),
        sa.Column("created_at",   sa.DateTime,nullable=False),
    )

    # ── disputes ──────────────────────────────────────────────────────────────
    op.create_table(
        "disputes",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("deal_id",     sa.String,  sa.ForeignKey("deals.id"), nullable=False),
        sa.Column("opener_id",   sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("issue_type",  sa.String,  nullable=False),
        sa.Column("description", sa.Text,    nullable=True),
        sa.Column("status",      sa.String,  default="open"),
        sa.Column("resolution",  sa.String,  nullable=True),
        sa.Column("resolved_by", sa.String,  nullable=True),
        sa.Column("created_at",  sa.DateTime,nullable=False),
        sa.Column("resolved_at", sa.DateTime,nullable=True),
    )

    # ── reviews ───────────────────────────────────────────────────────────────
    op.create_table(
        "reviews",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("deal_id",     sa.String,  sa.ForeignKey("deals.id")),
        sa.Column("reviewer_id", sa.String,  sa.ForeignKey("users.id")),
        sa.Column("seller_id",   sa.String,  sa.ForeignKey("users.id")),
        sa.Column("rating",      sa.Integer, nullable=False),
        sa.Column("comment",     sa.Text,    nullable=True),
        sa.Column("created_at",  sa.DateTime,nullable=False),
    )

    # ── interests ─────────────────────────────────────────────────────────────
    op.create_table(
        "interests",
        sa.Column("id",          sa.String, primary_key=True),
        sa.Column("listing_id",  sa.String, sa.ForeignKey("listings.id")),
        sa.Column("buyer_id",    sa.String, sa.ForeignKey("users.id")),
        sa.Column("offer_price", sa.Float,  nullable=True),
        sa.Column("created_at",  sa.DateTime, nullable=False),
    )

    # ── negotiation_messages ──────────────────────────────────────────────────
    op.create_table(
        "negotiation_messages",
        sa.Column("id",             sa.String, primary_key=True),
        sa.Column("listing_id",     sa.String, sa.ForeignKey("listings.id")),
        sa.Column("sender_id",      sa.String, nullable=False),
        sa.Column("role",           sa.String, nullable=False),
        sa.Column("recipient_role", sa.String, nullable=True),
        sa.Column("content",        sa.Text,   nullable=True),
        sa.Column("buyer_id",       sa.String, nullable=True),
        sa.Column("via_ai",         sa.Boolean,default=False),
        sa.Column("msg_type",       sa.String, default="text"),
        sa.Column("media_url",      sa.Text,   nullable=True),
        sa.Column("duration_secs",  sa.Integer,nullable=True),
        sa.Column("created_at",     sa.DateTime, nullable=False),
    )

    # ── bids ──────────────────────────────────────────────────────────────────
    op.create_table(
        "bids",
        sa.Column("id",         sa.String, primary_key=True),
        sa.Column("listing_id", sa.String, sa.ForeignKey("listings.id")),
        sa.Column("bidder_id",  sa.String, sa.ForeignKey("users.id")),
        sa.Column("amount",     sa.Float,  nullable=False),
        sa.Column("created_at", sa.DateTime, nullable=False),
    )


def downgrade() -> None:
    for table in [
        "bids", "negotiation_messages", "interests", "reviews",
        "disputes", "fraud_events", "audit_logs", "ledger_entries",
        "mpesa_transactions", "deals", "listings", "refresh_tokens", "users",
    ]:
        op.drop_table(table)
