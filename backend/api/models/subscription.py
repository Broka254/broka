"""Premium subscriptions: who has which plan until when, what they paid, and
how much of each monthly allowance they have used.

api/domains/premium/ owns every write. PRICING.md explains the plans.

Subscription      one row per user. `plan_id` and `paid_until` are the
                  plan in force; `started_at` anchors its allowance months
                  (month n runs from started_at + n x 30 days), so a plan
                  bought on the 20th renews its allowances on the 20th, not
                  on the 1st - a seller who pays mid-month gets a whole
                  month of allowance, not ten days of it.
SubscriptionPayment one M-Pesa payment for a plan, settled once
                  (`processed`), exactly like ListingPayment.
FeatureUsage      one row per user, feature and allowance month: `used` is
                  raised with an UPDATE that also checks the limit, so two
                  requests at once cannot both spend the last try.

Statuses are plain strings, not database enums, so a new one never needs
ALTER TYPE on PostgreSQL. Timestamps are naive UTC.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class Subscription(Base):
    __tablename__ = "subscriptions"

    id         = sa.Column(sa.String, primary_key=True, default=_uuid)
    user_id    = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, unique=True, index=True)
    plan_id    = sa.Column(sa.String, nullable=False)          # pricing/plans.PREMIUM_BY_ID key
    started_at = sa.Column(sa.DateTime, nullable=False)
    paid_until = sa.Column(sa.DateTime, nullable=False)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)


class SubscriptionPaymentStatus:
    PENDING = "pending"
    SUCCESS = "success"
    FAILED  = "failed"


class SubscriptionPayment(Base):
    __tablename__ = "subscription_payments"

    id                  = sa.Column(sa.String, primary_key=True, default=_uuid)
    user_id             = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    plan_id             = sa.Column(sa.String, nullable=False)
    months              = sa.Column(sa.Integer, nullable=False)
    amount              = sa.Column(sa.Integer, nullable=False)   # what the STK prompt asked for, KES
    phone               = sa.Column(sa.String, nullable=False)
    checkout_request_id = sa.Column(sa.String, nullable=True, unique=True, index=True)
    merchant_request_id = sa.Column(sa.String, nullable=True)
    mpesa_receipt       = sa.Column(sa.String, nullable=True)
    status              = sa.Column(sa.String, nullable=False, default=SubscriptionPaymentStatus.PENDING)
    provider            = sa.Column(sa.String(16), nullable=False, default="daraja", server_default="daraja")
    failure_reason      = sa.Column(sa.String, nullable=True)
    processed           = sa.Column(sa.Boolean, nullable=False, default=False)
    created_at          = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    paid_at             = sa.Column(sa.DateTime, nullable=True)
    period_end          = sa.Column(sa.DateTime, nullable=True)   # the plan's paid_until after this


class FeatureUsage(Base):
    __tablename__ = "feature_usage"

    id         = sa.Column(sa.String, primary_key=True, default=_uuid)
    user_id    = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    feature    = sa.Column(sa.String(32), nullable=False)
    # Which allowance: "<subscription start>:<month n>" for a plan's month,
    # "trial" for what someone without a plan may try once.
    period_key = sa.Column(sa.String(64), nullable=False)
    used       = sa.Column(sa.Integer, nullable=False, default=0)
    updated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.UniqueConstraint("user_id", "feature", "period_key", name="uq_feature_usage_period"),
    )
