"""
BROKA v5.0 - Dispute Engine Models
===================================
Implements a full dispute case management system with:
  - DisputeCase     : the parent record, one per deal-dispute
  - DisputeEvent    : immutable append-only timeline of every action
  - DisputeEvidence : photos, voice notes, tracking screenshots
  - DisputeTimer    : cancellable timer objects (replaces scattered deal columns)

State machine for DisputeCase.state:
  open
  └── waiting_seller_explanation   (A2/A3: waiting for seller to respond)
  └── waiting_buyer_decision       (buyer choosing refund or replace)
  └── waiting_replacement          (A4: replacement shipped, awaiting arrival)
  └── waiting_return               (buyer returning wrong/damaged item)
  └── ai_review                    (AI confidence check in progress)
  └── ready_for_refund             (rule engine approved refund)
  └── ready_for_release            (rule engine approved release)
  └── escalated                    (auto-escalated, needs human review)
  └── closed_refunded
  └── closed_released

Design invariants:
  1. No AI output ever writes to DisputeCase.state directly.
  2. Every state transition is recorded as a DisputeEvent (immutable).
  3. All timers are DisputeTimer objects, not scattered deal columns.
  4. Evidence has AI analysis stored separately from the upload.
  5. fund_action (refund/release) only executes from terminal states.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from sqlalchemy import (
    Column, String, Text, DateTime, ForeignKey,
    Enum, Boolean, Float, Integer, JSON,
)
from api.database import Base, Dispute, DisputeStatus, DisputeResolution  # noqa: F401


# ── Exceptions ────────────────────────────────────────────────────────────────

class OptimisticLockError(Exception):
    """
    Raised when a concurrent write to DisputeCase is detected.
    The caller should re-fetch the case and retry the operation.
    Callers should treat this as HTTP 409 Conflict.
    """


# ── Enums ─────────────────────────────────────────────────────────────────────

class CaseState(str, enum.Enum):
    # Active investigation states
    open                       = "open"
    waiting_seller_explanation = "waiting_seller_explanation"
    waiting_buyer_decision     = "waiting_buyer_decision"
    waiting_replacement        = "waiting_replacement"
    waiting_return             = "waiting_return"
    ai_review                  = "ai_review"
    # Rule engine approved actions (pending M-Pesa execution)
    ready_for_refund           = "ready_for_refund"
    ready_for_release          = "ready_for_release"
    # Escalation
    escalated                  = "escalated"
    # Terminal
    closed_refunded            = "closed_refunded"
    closed_released            = "closed_released"

    @property
    def is_terminal(self) -> bool:
        return self in (CaseState.closed_refunded, CaseState.closed_released)

    @property
    def is_active(self) -> bool:
        return not self.is_terminal and self != CaseState.escalated


class DisputeType(str, enum.Enum):
    """
    Data-driven dispute type registry. Extend here — nothing else needs changing.

    Each value is a stable string key stored in the database.
    New types can be added without schema migrations (it's just a string column).
    The human labels and routing hints live in DISPUTE_TYPE_META below.
    """
    # ── Item condition ────────────────────────────────────────────────────────
    goods_ok            = "goods_ok"            # buyer confirms fine → release (A1)
    wrong_item          = "wrong_item"          # seller sent wrong item (A2)
    damaged             = "damaged"             # item arrived damaged (A3)
    incomplete          = "incomplete"          # missing accessories / parts
    counterfeit         = "counterfeit"         # suspected fake product
    # ── Delivery ─────────────────────────────────────────────────────────────
    not_delivered       = "not_delivered"       # never arrived (B)
    late_delivery       = "late_delivery"       # arrived but very late
    # ── Replacement flow ─────────────────────────────────────────────────────
    replacement_pending = "replacement_pending" # replacement shipped (A4)
    # ── Other ────────────────────────────────────────────────────────────────
    digital_product     = "digital_product"     # code/file dispute
    service_dispute     = "service_dispute"     # service not rendered
    payment_issue       = "payment_issue"       # M-Pesa / payment mismatch
    other               = "other"

    def to_branch(self) -> "CaseBranch":
        """Map to the legacy CaseBranch for backward compatibility."""
        return _TYPE_TO_BRANCH.get(self, CaseBranch.B)


# ── Dispute type metadata ──────────────────────────────────────────────────────
#
# This is the single place to define human labels, default behaviour, and
# routing hints. Adding a new dispute type = add a row here + a DisputeType enum
# value above. No other code changes required.
#
DISPUTE_TYPE_META: dict[DisputeType, dict] = {
    DisputeType.goods_ok: {
        "label":            "Item arrived — all good",
        "default_action":   "release",
        "requires_evidence": False,
        "ai_review":         False,   # deterministic: buyer confirmed OK
    },
    DisputeType.wrong_item: {
        "label":            "Wrong item received",
        "default_action":   "refund",
        "requires_evidence": True,
        "ai_review":         True,
    },
    DisputeType.damaged: {
        "label":            "Item arrived damaged",
        "default_action":   "refund",
        "requires_evidence": True,
        "ai_review":         True,    # Gemini image analysis
    },
    DisputeType.incomplete: {
        "label":            "Item incomplete / missing parts",
        "default_action":   "escalate",
        "requires_evidence": True,
        "ai_review":         True,
    },
    DisputeType.counterfeit: {
        "label":            "Suspected counterfeit",
        "default_action":   "refund",
        "requires_evidence": True,
        "ai_review":         True,
    },
    DisputeType.not_delivered: {
        "label":            "Item never arrived",
        "default_action":   "refund",
        "requires_evidence": False,
        "ai_review":         True,
    },
    DisputeType.late_delivery: {
        "label":            "Item delivered very late",
        "default_action":   "escalate",
        "requires_evidence": False,
        "ai_review":         True,
    },
    DisputeType.replacement_pending: {
        "label":            "Replacement shipped — awaiting arrival",
        "default_action":   None,
        "requires_evidence": False,
        "ai_review":         False,
    },
    DisputeType.digital_product: {
        "label":            "Digital product / code issue",
        "default_action":   "escalate",
        "requires_evidence": True,
        "ai_review":         True,
    },
    DisputeType.service_dispute: {
        "label":            "Service not rendered",
        "default_action":   "escalate",
        "requires_evidence": True,
        "ai_review":         True,
    },
    DisputeType.payment_issue: {
        "label":            "Payment / M-Pesa issue",
        "default_action":   "escalate",
        "requires_evidence": False,
        "ai_review":         False,
    },
    DisputeType.other: {
        "label":            "Other",
        "default_action":   "escalate",
        "requires_evidence": False,
        "ai_review":         True,
    },
}


class CaseBranch(str, enum.Enum):
    """
    Legacy branch codes — kept for backward compatibility with existing DB rows
    and the Flutter client's branch-based routing.
    New code should use DisputeType instead.
    """
    A1 = "A1"   # goods arrived, buyer confirms OK → release
    A2 = "A2"   # goods arrived, wrong item
    A3 = "A3"   # goods arrived, damaged (image verified)
    A4 = "A4"   # replacement shipped, waiting confirmation
    B  = "B"    # goods never arrived


# Mapping from new DisputeType → legacy CaseBranch (for compat)
_TYPE_TO_BRANCH: dict[DisputeType, CaseBranch] = {
    DisputeType.goods_ok:            CaseBranch.A1,
    DisputeType.wrong_item:          CaseBranch.A2,
    DisputeType.damaged:             CaseBranch.A3,
    DisputeType.incomplete:          CaseBranch.A3,
    DisputeType.counterfeit:         CaseBranch.A2,
    DisputeType.replacement_pending: CaseBranch.A4,
    DisputeType.not_delivered:       CaseBranch.B,
    DisputeType.late_delivery:       CaseBranch.B,
    DisputeType.digital_product:     CaseBranch.B,
    DisputeType.service_dispute:     CaseBranch.B,
    DisputeType.payment_issue:       CaseBranch.B,
    DisputeType.other:               CaseBranch.B,
}


class EventType(str, enum.Enum):
    """Every type of event that can appear on a case timeline."""
    # Case lifecycle
    case_opened              = "case_opened"
    case_state_changed       = "case_state_changed"
    case_escalated           = "case_escalated"
    case_closed              = "case_closed"
    # Evidence
    evidence_uploaded        = "evidence_uploaded"
    evidence_ai_analysed     = "evidence_ai_analysed"
    # Parties
    buyer_reported_issue     = "buyer_reported_issue"
    buyer_chose_refund       = "buyer_chose_refund"
    buyer_chose_replacement  = "buyer_chose_replacement"
    buyer_confirmed_ok       = "buyer_confirmed_ok"
    seller_explained         = "seller_explained"
    seller_shipped_replacement = "seller_shipped_replacement"
    # AI / rule engine
    ai_recommendation_issued = "ai_recommendation_issued"
    rule_engine_decision     = "rule_engine_decision"
    # Timers
    timer_started            = "timer_started"
    timer_cancelled          = "timer_cancelled"
    timer_fired              = "timer_fired"
    # Notifications
    notification_sent        = "notification_sent"
    sms_sent                 = "sms_sent"
    # Financial
    refund_initiated         = "refund_initiated"
    release_initiated        = "release_initiated"
    mpesa_b2c_result         = "mpesa_b2c_result"
    # Admin
    admin_note               = "admin_note"
    admin_overrode           = "admin_overrode"


class EvidenceType(str, enum.Enum):
    photo          = "photo"
    video          = "video"
    voice_note     = "voice_note"
    tracking_screenshot = "tracking_screenshot"
    invoice        = "invoice"
    courier_proof  = "courier_proof"
    packaging_photo = "packaging_photo"
    other          = "other"


class TimerKind(str, enum.Enum):
    """What happens when this timer fires."""
    auto_refund_buyer        = "auto_refund_buyer"    # seller went silent
    auto_release_seller      = "auto_release_seller"  # buyer went silent
    seller_explanation_due   = "seller_explanation_due"
    replacement_arrival_due  = "replacement_arrival_due"
    checkin_buyer            = "checkin_buyer"
    checkin_seller           = "checkin_seller"


# ── Models ────────────────────────────────────────────────────────────────────

class DisputeCase(Base):
    """
    One record per active dispute on a deal.
    A deal may have at most one open case at a time.
    Multiple closed cases are allowed (e.g. replacement cycle generates a new case).

    Never update state directly — always call transition_state() in the service
    so a DisputeEvent is written atomically.
    """
    __tablename__ = "dispute_cases"

    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id      = Column(String, ForeignKey("deals.id"), nullable=False, index=True)
    opener_id    = Column(String, ForeignKey("users.id"), nullable=False)

    # Data-driven dispute type (new) — stores DisputeType string key.
    # This is the forward-looking field. New code writes here.
    dispute_type = Column(String, nullable=True)

    # Legacy branch enum — kept for backward compat with existing data and Flutter.
    # Set automatically from dispute_type via DisputeType.to_branch() on open_case.
    branch       = Column(Enum(CaseBranch), nullable=True)

    # Current state (transitions must also write a DisputeEvent)
    state        = Column(Enum(CaseState), default=CaseState.open, nullable=False, index=True)
    prev_state   = Column(Enum(CaseState), nullable=True)

    # AI recommendation (set by rule engine, never by raw LLM output)
    ai_recommendation   = Column(String, nullable=True)   # "refund" | "release"
    ai_confidence       = Column(Float, nullable=True)    # 0.0–1.0
    ai_analysis_text    = Column(Text, nullable=True)

    # Rule engine decision (final, what actually drives fund action)
    rule_decision        = Column(String, nullable=True)  # "refund" | "release"
    rule_decision_reason = Column(Text, nullable=True)

    # Fund action result
    fund_action          = Column(String, nullable=True)  # "refunded" | "released"
    fund_amount          = Column(Float, nullable=True)   # actual KES moved
    fund_executed_at     = Column(DateTime, nullable=True)
    mpesa_conversation_id = Column(String, nullable=True)

    # ZAC code (for backward compat with execute endpoint)
    zac_code         = Column(String, nullable=True)

    # Replacement tracking
    replacement_cycle = Column(Integer, default=0)

    # Admin
    resolved_by      = Column(String, ForeignKey("users.id"), nullable=True)
    admin_note       = Column(Text, nullable=True)

    # Optimistic locking — incremented on every state transition.
    #
    # CORRECTION (dispute audit, 2026-09-14): this comment previously said
    # "the DB constraint prevents two concurrent writes from both
    # succeeding". There is no such constraint, and there never was - this
    # is a plain Integer column, nothing configures SQLAlchemy's
    # `version_id_col`, and the service compared versions in memory on an
    # object both writers had already loaded. The protection described here
    # did not exist.
    #
    # It does now, but it lives in the SERVICE, not in the schema:
    # DisputeEngineService.transition() puts this column in the WHERE clause
    # of a conditional UPDATE and treats rowcount as the verdict. The
    # payout path additionally claims itself via
    # _claim_fund_execution(), which is what actually prevents a double
    # M-Pesa B2C send.
    version      = Column(Integer, default=0, nullable=False)

    # Timestamps
    created_at   = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at   = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    closed_at    = Column(DateTime, nullable=True)


class DisputeEvent(Base):
    """
    Immutable append-only timeline. Every action on a DisputeCase
    writes a row here. Never UPDATE or DELETE.

    actor_id = "system" for sweep-fired events.
    actor_id = "zeno"   for AI-driven conversation messages.
    actor_id = user UUID for buyer/seller/admin actions.
    """
    __tablename__ = "dispute_events"

    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    case_id      = Column(String, ForeignKey("dispute_cases.id"), nullable=False, index=True)
    deal_id      = Column(String, nullable=False, index=True)  # denormalised for fast queries
    event_type   = Column(Enum(EventType), nullable=False, index=True)
    actor_id     = Column(String, nullable=False)  # user_id | "system" | "zeno"
    actor_role   = Column(String, nullable=True)   # "buyer" | "seller" | "admin" | "system"

    # State snapshot at time of event
    from_state   = Column(Enum(CaseState), nullable=True)
    to_state     = Column(Enum(CaseState), nullable=True)

    # Payload — JSON blob so event data is flexible without schema migrations
    payload      = Column(JSON, nullable=True)

    # Human-readable description (shown on timeline in UI)
    description  = Column(Text, nullable=False)

    created_at   = Column(DateTime, default=datetime.utcnow, nullable=False, index=True)


class DisputeEvidence(Base):
    """
    Evidence submitted during a dispute case.
    Each piece of evidence can have a separate AI analysis result.
    """
    __tablename__ = "dispute_evidence"

    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    case_id      = Column(String, ForeignKey("dispute_cases.id"), nullable=False, index=True)
    deal_id      = Column(String, nullable=False, index=True)
    uploader_id  = Column(String, ForeignKey("users.id"), nullable=False)
    uploader_role = Column(String, nullable=False)  # "buyer" | "seller"

    evidence_type = Column(Enum(EvidenceType), nullable=False)
    storage_url   = Column(String, nullable=False)   # GCS / S3 / Render disk URL
    file_hash     = Column(String, nullable=True)    # SHA-256 for tamper detection
    file_size_kb  = Column(Integer, nullable=True)

    # AI analysis of this piece of evidence
    ai_analysed      = Column(Boolean, default=False)
    ai_analysis      = Column(Text, nullable=True)   # Gemini vision output
    ai_confidence    = Column(Float, nullable=True)  # 0.0–1.0 if damage/fraud detected
    ai_flags_damage  = Column(Boolean, nullable=True)  # True if image shows clear damage

    description  = Column(Text, nullable=True)  # uploader's caption
    created_at   = Column(DateTime, default=datetime.utcnow, nullable=False)


class DisputeTimer(Base):
    """
    Cancellable timer object. Replaces scattered timer_type/timer_deadline columns on Deal.

    The periodic sweep (task_check_deal_timers) queries:
        WHERE fired_at IS NULL AND cancelled_at IS NULL AND fires_at <= now()
    and calls the handler for timer_kind.

    Only the sweep fires timers. Zeno only *announces* them in conversation.
    """
    __tablename__ = "dispute_timers"

    id           = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    case_id      = Column(String, ForeignKey("dispute_cases.id"), nullable=False, index=True)
    deal_id      = Column(String, nullable=False, index=True)

    timer_kind   = Column(Enum(TimerKind), nullable=False)
    fires_at     = Column(DateTime, nullable=False, index=True)

    # Checkin sequence support (buyer_silence / seller_silence 24h loops)
    checkin_index       = Column(Integer, default=0)   # which reminder number this is
    total_checkins      = Column(Integer, default=1)   # total in the sequence
    send_sms_on_index   = Column(Integer, nullable=True)  # which index triggers SMS

    # Outcome
    fired_at     = Column(DateTime, nullable=True)
    cancelled_at = Column(DateTime, nullable=True)
    cancelled_reason = Column(String, nullable=True)

    created_at   = Column(DateTime, default=datetime.utcnow, nullable=False)


# ── Legacy shim ───────────────────────────────────────────────────────────────
# The old Dispute model is kept for backward compat with existing data.
# New code uses DisputeCase exclusively.
#
# Dispute/DisputeStatus/DisputeResolution are re-exported from api.database
# (see the import at the top of this file) rather than redefined here -
# this file used to also define them locally, which crashed with
# "Table 'disputes' is already defined for this MetaData instance" since
# api.database registers the same table.
