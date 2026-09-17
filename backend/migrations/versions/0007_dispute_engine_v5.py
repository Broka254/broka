"""Dispute Engine v5.0 - Case/Event/Evidence/Timer tables

Revision ID: 0007
Revises: 0006
Create Date: 2026-06-27

Introduces four new tables that form the enterprise dispute engine:

  dispute_cases    - Parent record per dispute (replaces monolithic disputes table)
  dispute_events   - Immutable append-only timeline (every action recorded)
  dispute_evidence - Evidence items with AI analysis results
  dispute_timers   - Cancellable timer objects (replaces scattered Deal columns)

The legacy 'disputes' table is preserved for backward compat.
New code uses dispute_cases exclusively.

Design invariants:
  1. dispute_events is NEVER updated or deleted — compensating events only
  2. Timers are cancelled by writing cancelled_at; never by deleting rows
  3. Fund actions only execute from closed_refunded/closed_released states
  4. No LLM text output ever triggers a state transition directly

State machine (CaseState):
  open → waiting_seller_explanation → waiting_buyer_decision
       → waiting_replacement → waiting_return
       → ai_review → ready_for_refund / ready_for_release
       → escalated (human review required)
       → closed_refunded / closed_released
"""
from typing import Sequence, Union
from alembic import op
import sqlalchemy as sa

revision: str = "0007"
down_revision: Union[str, None] = "0006"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

CASE_STATES = [
    "open", "waiting_seller_explanation", "waiting_buyer_decision",
    "waiting_replacement", "waiting_return", "ai_review",
    "ready_for_refund", "ready_for_release", "escalated",
    "closed_refunded", "closed_released",
]
CASE_BRANCHES  = ["A1", "A2", "A3", "A4", "B"]
EVENT_TYPES    = [
    "case_opened", "case_state_changed", "case_escalated", "case_closed",
    "evidence_uploaded", "evidence_ai_analysed",
    "buyer_reported_issue", "buyer_chose_refund", "buyer_chose_replacement",
    "buyer_confirmed_ok", "seller_explained", "seller_shipped_replacement",
    "ai_recommendation_issued", "rule_engine_decision",
    "timer_started", "timer_cancelled", "timer_fired",
    "notification_sent", "sms_sent",
    "refund_initiated", "release_initiated", "mpesa_b2c_result",
    "admin_note", "admin_overrode",
]
EVIDENCE_TYPES = [
    "photo", "video", "voice_note", "tracking_screenshot",
    "invoice", "courier_proof", "packaging_photo", "other",
]
TIMER_KINDS = [
    "auto_refund_buyer", "auto_release_seller", "seller_explanation_due",
    "replacement_arrival_due", "checkin_buyer", "checkin_seller",
]


def upgrade() -> None:
    op.create_table(
        "dispute_cases",
        sa.Column("id",           sa.String,  primary_key=True),
        sa.Column("deal_id",      sa.String,  sa.ForeignKey("deals.id"), nullable=False, index=True),
        sa.Column("opener_id",    sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("branch",       sa.String,  nullable=True),
        sa.Column("state",        sa.String,  nullable=False, default="open"),
        sa.Column("prev_state",   sa.String,  nullable=True),
        sa.Column("ai_recommendation",   sa.String,  nullable=True),
        sa.Column("ai_confidence",       sa.Float,   nullable=True),
        sa.Column("ai_analysis_text",    sa.Text,    nullable=True),
        sa.Column("rule_decision",       sa.String,  nullable=True),
        sa.Column("rule_decision_reason", sa.Text,   nullable=True),
        sa.Column("fund_action",         sa.String,  nullable=True),
        sa.Column("fund_amount",         sa.Float,   nullable=True),
        sa.Column("fund_executed_at",    sa.DateTime, nullable=True),
        sa.Column("mpesa_conversation_id", sa.String, nullable=True),
        sa.Column("zac_code",            sa.String,  nullable=True),
        sa.Column("replacement_cycle",   sa.Integer, default=0),
        sa.Column("resolved_by",         sa.String,  nullable=True),
        sa.Column("admin_note",          sa.Text,    nullable=True),
        sa.Column("created_at",          sa.DateTime, nullable=False),
        sa.Column("updated_at",          sa.DateTime, nullable=True),
        sa.Column("closed_at",           sa.DateTime, nullable=True),
    )

    op.create_table(
        "dispute_events",
        sa.Column("id",          sa.String,  primary_key=True),
        sa.Column("case_id",     sa.String,  sa.ForeignKey("dispute_cases.id"), nullable=False, index=True),
        sa.Column("deal_id",     sa.String,  nullable=False, index=True),
        sa.Column("event_type",  sa.String,  nullable=False, index=True),
        sa.Column("actor_id",    sa.String,  nullable=False),
        sa.Column("actor_role",  sa.String,  nullable=True),
        sa.Column("from_state",  sa.String,  nullable=True),
        sa.Column("to_state",    sa.String,  nullable=True),
        sa.Column("payload",     sa.JSON,    nullable=True),
        sa.Column("description", sa.Text,    nullable=False),
        sa.Column("created_at",  sa.DateTime, nullable=False, index=True),
    )

    op.create_table(
        "dispute_evidence",
        sa.Column("id",              sa.String,  primary_key=True),
        sa.Column("case_id",         sa.String,  sa.ForeignKey("dispute_cases.id"), nullable=False, index=True),
        sa.Column("deal_id",         sa.String,  nullable=False, index=True),
        sa.Column("uploader_id",     sa.String,  sa.ForeignKey("users.id"), nullable=False),
        sa.Column("uploader_role",   sa.String,  nullable=False),
        sa.Column("evidence_type",   sa.String,  nullable=False),
        sa.Column("storage_url",     sa.String,  nullable=False),
        sa.Column("file_hash",       sa.String,  nullable=True),
        sa.Column("file_size_kb",    sa.Integer, nullable=True),
        sa.Column("ai_analysed",     sa.Boolean, default=False),
        sa.Column("ai_analysis",     sa.Text,    nullable=True),
        sa.Column("ai_confidence",   sa.Float,   nullable=True),
        sa.Column("ai_flags_damage", sa.Boolean, nullable=True),
        sa.Column("description",     sa.Text,    nullable=True),
        sa.Column("created_at",      sa.DateTime, nullable=False),
    )

    op.create_table(
        "dispute_timers",
        sa.Column("id",                sa.String,  primary_key=True),
        sa.Column("case_id",           sa.String,  sa.ForeignKey("dispute_cases.id"), nullable=False, index=True),
        sa.Column("deal_id",           sa.String,  nullable=False, index=True),
        sa.Column("timer_kind",        sa.String,  nullable=False),
        sa.Column("fires_at",          sa.DateTime, nullable=False, index=True),
        sa.Column("checkin_index",     sa.Integer,  default=0),
        sa.Column("total_checkins",    sa.Integer,  default=1),
        sa.Column("send_sms_on_index", sa.Integer,  nullable=True),
        sa.Column("fired_at",          sa.DateTime, nullable=True),
        sa.Column("cancelled_at",      sa.DateTime, nullable=True),
        sa.Column("cancelled_reason",  sa.String,   nullable=True),
        sa.Column("created_at",        sa.DateTime, nullable=False),
    )


def downgrade() -> None:
    op.drop_table("dispute_timers")
    op.drop_table("dispute_evidence")
    op.drop_table("dispute_events")
    op.drop_table("dispute_cases")
