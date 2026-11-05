"""Normalised production-cost tracking: catalogue, usage, pricing, entries.

WHY THIS EXISTS ALONGSIDE api/models/platform_cost.py
===================================================
`PlatformCost` is the original append-only spend ledger: one coarse row per
SMS/AI call, consumed by api/core/revenue.py. It answers "what did we spend
this month" but cannot answer the questions an operator actually asks of it -
which provider, which model, how many segments, was the rate billed or
assumed, what did an administrator override it to, and what was the price at
the time of the call.

These tables are that answer, and they are deliberately normalised:

  service_catalog        one row per external service (billable or free)
  service_usage_events   one row per provider operation, with an idempotency
                         key and a SNAPSHOT of the price applied at the time
  service_pricing        effective-dated unit prices (history is never edited
                         retroactively; a new price closes the old row)
  service_cost_entries   billing-period money a person or invoice supplied
  service_cost_adjustments  every manual change, with the original estimate
  service_usage_daily    rolled-up old usage, so retention never loses history

FINANCIAL RULES ENCODED HERE
============================
* Amounts are INTEGER minor currency units (KES cents). No floats.
* Every amount carries its currency. Nothing converts between currencies.
* An unknown cost is NULL, never 0. Zero means free (a real, known charge).
* A usage event stores the unit price that was effective when it happened, so
  changing a price today cannot rewrite last month's report.
* `operation_id` is unique per service. A retried provider callback, a
  redelivered webhook and a duplicated retry therefore record once.
* Cost entries never delete usage. A manual override is an adjustment row
  beside the estimate, not a replacement for it.
"""
from __future__ import annotations

from datetime import date, datetime

import sqlalchemy as sa

from api.database import Base


class ServiceCategory:
    """Categories the admin dashboard groups services by."""

    MESSAGING = "messaging"
    AI_INFERENCE = "ai_inference"
    IMAGE_GENERATION = "image_generation"
    EMAIL = "email"
    PUSH = "push"
    VOICE = "voice"
    PAYMENTS = "payments"
    ESCROW = "escrow"
    STORAGE = "storage"
    HOSTING = "hosting"
    DATABASE = "database"
    CACHE = "cache"
    MONITORING = "monitoring"
    OTHER = "other"

    ALL = (
        MESSAGING, AI_INFERENCE, IMAGE_GENERATION, EMAIL, PUSH, VOICE,
        PAYMENTS, ESCROW, STORAGE, HOSTING, DATABASE, CACHE, MONITORING, OTHER,
    )


class PricingModel:
    """How a service's cost is derived.

    PER_UNIT     quantity x effective unit price (SMS segments, images)
    PER_TOKEN    token counts x configured model rates (priced by
                 api/core/cost_ledger.ai_cost_minor, recorded explicitly)
    PER_REQUEST  a flat price for each accepted request
    FREE         genuinely free: effective cost is a known 0
    MANUAL       only a person or an invoice can price it (hosting, Redis)
    TIERED       a provider's plan/band pricing; priced manually
    """

    PER_UNIT = "per_unit"
    PER_TOKEN = "per_token"
    PER_REQUEST = "per_request"
    FREE = "free"
    MANUAL = "manual"
    TIERED = "tiered"

    ALL = (PER_UNIT, PER_TOKEN, PER_REQUEST, FREE, MANUAL, TIERED)


class UsageStatus:
    SUCCESS = "success"
    FAILED = "failed"
    REJECTED = "rejected"
    #: Provider accepted the instruction but the final outcome is not known
    #: yet (an STK prompt on the phone, a queued image generation).
    ACCEPTED = "accepted"

    ALL = (SUCCESS, FAILED, REJECTED, ACCEPTED)
    #: Statuses whose quantity counts as delivered service.
    SUCCEEDED = (SUCCESS,)


class CostBasis:
    """Why an event's amount is what it is - never inferred at report time."""

    PROVIDER_REPORTED = "provider_reported"
    CONFIGURED_RATE = "configured_rate"
    DERIVED_RATE = "derived_rate"
    FREE_TIER = "free_tier"
    MANUAL = "manual"
    INVOICE = "invoice"
    UNPRICED = "unpriced"

    ALL = (
        PROVIDER_REPORTED, CONFIGURED_RATE, DERIVED_RATE, FREE_TIER,
        MANUAL, INVOICE, UNPRICED,
    )


class CostConfidence:
    EXACT = "exact"
    ESTIMATED = "estimated"
    MANUAL = "manual"
    UNKNOWN = "unknown"

    ALL = (EXACT, ESTIMATED, MANUAL, UNKNOWN)


class CostSource:
    """Which figure an effective cost came from, for the dashboard's badge."""

    INVOICE = "invoice"
    MANUAL = "manual"
    ADJUSTED = "adjusted"
    ESTIMATE_ENTRY = "estimate_entry"
    USAGE_ESTIMATE = "usage_estimate"
    NONE = "unpriced"

    ALL = (INVOICE, MANUAL, ADJUSTED, ESTIMATE_ENTRY, USAGE_ESTIMATE, NONE)


class ServiceCatalog(Base):
    __tablename__ = "service_catalog"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_key = sa.Column(sa.String(64), nullable=False, unique=True, index=True)
    service_name = sa.Column(sa.String(120), nullable=False)
    provider = sa.Column(sa.String(120), nullable=False)
    category = sa.Column(sa.String(40), nullable=False, index=True)
    usage_unit = sa.Column(sa.String(40), nullable=False)
    pricing_model = sa.Column(
        sa.String(24), nullable=False, default=PricingModel.MANUAL
    )
    #: False for a service BROKA uses but is not billed for directly (FCM on
    #: the free tier, Edge TTS). Still catalogued, so its volume is visible.
    is_billable = sa.Column(sa.Boolean, nullable=False, default=True)
    billing_currency = sa.Column(sa.String(8), nullable=False, default="KES")
    #: The default confidence when no per-event figure exists.
    cost_confidence = sa.Column(
        sa.String(16), nullable=False, default=CostConfidence.UNKNOWN
    )
    #: A multiplier (basis points, 10000 = 1.0) applied to the estimate to
    #: produce the "estimated maximum" figure. DeepSeek is 20000 because
    #: peak-hour pricing is exactly double off-peak.
    max_cost_multiplier_bps = sa.Column(
        sa.Integer, nullable=False, default=10000
    )
    reporting_notes = sa.Column(sa.Text, nullable=True)
    active = sa.Column(sa.Boolean, nullable=False, default=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow
    )


class ServiceUsageEvent(Base):
    __tablename__ = "service_usage_events"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_catalog.id"), nullable=False, index=True
    )
    #: Caller-supplied idempotency key, unique per service. NULL on events
    #: that genuinely have no provider reference (and must not dedupe).
    operation_id = sa.Column(sa.String(160), nullable=True)
    provider_reference = sa.Column(sa.String(200), nullable=True, index=True)
    operation_type = sa.Column(sa.String(64), nullable=False)
    status = sa.Column(
        sa.String(16), nullable=False, default=UsageStatus.SUCCESS, index=True
    )
    quantity = sa.Column(sa.Integer, nullable=True)
    input_tokens = sa.Column(sa.Integer, nullable=True)
    output_tokens = sa.Column(sa.Integer, nullable=True)
    usage_unit = sa.Column(sa.String(40), nullable=True)
    #: Price snapshot. NULL when no rate existed at the time - which is why
    #: the report can honestly say "unpriced" instead of showing zero.
    unit_price_minor = sa.Column(sa.Integer, nullable=True)
    estimated_cost_minor = sa.Column(sa.Integer, nullable=True)
    currency = sa.Column(sa.String(8), nullable=True)
    cost_basis = sa.Column(
        sa.String(24), nullable=False, default=CostBasis.UNPRICED
    )
    cost_confidence = sa.Column(
        sa.String(16), nullable=False, default=CostConfidence.UNKNOWN
    )
    #: First day of the event's UTC month. Denormalised so a period filter is
    #: one indexed comparison rather than a function on every row.
    reporting_period_start = sa.Column(sa.DateTime, nullable=False, index=True)
    meta = sa.Column("metadata", sa.JSON, nullable=True)
    occurred_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, index=True
    )
    created_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, index=True
    )

    __table_args__ = (
        sa.UniqueConstraint(
            "service_id", "operation_id", name="uq_service_usage_operation"
        ),
        sa.Index("ix_service_usage_service_time", "service_id", "occurred_at"),
        sa.Index("ix_service_usage_status_time", "status", "occurred_at"),
    )


class ServicePricing(Base):
    __tablename__ = "service_pricing"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_catalog.id"), nullable=False, index=True
    )
    pricing_unit = sa.Column(sa.String(40), nullable=False)
    unit_price_minor = sa.Column(sa.Integer, nullable=False)
    currency = sa.Column(sa.String(8), nullable=False, default="KES")
    effective_from = sa.Column(sa.DateTime, nullable=False)
    #: NULL means "still the current price". A new price sets this to its own
    #: effective_from, so the old row stays readable for history.
    effective_until = sa.Column(sa.DateTime, nullable=True)
    pricing_source = sa.Column(sa.String(160), nullable=False)
    cost_confidence = sa.Column(
        sa.String(16), nullable=False, default=CostConfidence.ESTIMATED
    )
    created_by = sa.Column(sa.String, nullable=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.Index(
            "ix_service_pricing_service_effective",
            "service_id", "effective_from",
        ),
    )


class ServiceCostEntry(Base):
    __tablename__ = "service_cost_entries"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_catalog.id"), nullable=False, index=True
    )
    #: Half-open [period_start, period_end), the same convention as every
    #: usage query, so an event on a boundary belongs to exactly one period.
    period_start = sa.Column(sa.DateTime, nullable=False, index=True)
    period_end = sa.Column(sa.DateTime, nullable=False, index=True)
    actual_cost_minor = sa.Column(sa.Integer, nullable=True)
    estimated_cost_minor = sa.Column(sa.Integer, nullable=True)
    manually_entered_cost_minor = sa.Column(sa.Integer, nullable=True)
    currency = sa.Column(sa.String(8), nullable=False, default="KES")
    cost_source = sa.Column(sa.String(24), nullable=False)
    confidence = sa.Column(sa.String(16), nullable=False)
    notes = sa.Column(sa.Text, nullable=True)
    invoice_reference = sa.Column(sa.String(160), nullable=True)
    #: An admin user id, or "system" for an import. Deliberately not a
    #: foreign key: an audit trail must survive an account being removed.
    entered_by = sa.Column(sa.String, nullable=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, onupdate=datetime.utcnow
    )

    __table_args__ = (
        # One entry per source per period: a second POST is a 409 instead of a
        # silent duplicate invoice that would double the effective cost.
        sa.UniqueConstraint(
            "service_id", "period_start", "period_end", "cost_source",
            name="uq_service_cost_entry_period",
        ),
    )


class ServiceCostAdjustment(Base):
    __tablename__ = "service_cost_adjustments"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_catalog.id"), nullable=False, index=True
    )
    entry_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_cost_entries.id"), nullable=True
    )
    period_start = sa.Column(sa.DateTime, nullable=False)
    period_end = sa.Column(sa.DateTime, nullable=False)
    #: What the system believed before the person changed it. Retained so the
    #: dashboard can show the estimate and the override side by side.
    original_estimate_minor = sa.Column(sa.Integer, nullable=True)
    adjusted_amount_minor = sa.Column(sa.Integer, nullable=False)
    currency = sa.Column(sa.String(8), nullable=False, default="KES")
    reason = sa.Column(sa.Text, nullable=True)
    adjusted_by = sa.Column(sa.String, nullable=False)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.Index(
            "ix_service_adjustment_service_period",
            "service_id", "period_start", "period_end",
        ),
    )


class ServiceUsageDaily(Base):
    """Rolled-up usage for days older than the rollup window.

    Raw events stay for detail and recent reporting; once a day is old
    enough this row carries its totals and the raw events are pruned. The
    unique key makes a re-run idempotent, so a crash between insert and
    delete cannot count the day twice or lose it.
    """

    __tablename__ = "service_usage_daily"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    service_id = sa.Column(
        sa.Integer, sa.ForeignKey("service_catalog.id"), nullable=False, index=True
    )
    day = sa.Column(sa.Date, nullable=False, index=True)
    status = sa.Column(sa.String(16), nullable=False)
    event_count = sa.Column(sa.Integer, nullable=False, default=0)
    quantity = sa.Column(sa.Integer, nullable=False, default=0)
    input_tokens = sa.Column(sa.Integer, nullable=False, default=0)
    output_tokens = sa.Column(sa.Integer, nullable=False, default=0)
    estimated_cost_minor = sa.Column(sa.Integer, nullable=False, default=0)
    unpriced_count = sa.Column(sa.Integer, nullable=False, default=0)
    #: Empty string, never NULL: NULLs do not collide in a unique constraint,
    #: which would let a re-run insert the same unpriced day twice.
    currency = sa.Column(sa.String(8), nullable=False, default="")
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.UniqueConstraint(
            "service_id", "day", "status", "currency",
            name="uq_service_usage_daily",
        ),
        # `day` already gets index=True on the column; a second Index with the
        # same name made create_all() fail with "index ... already exists".
    )
