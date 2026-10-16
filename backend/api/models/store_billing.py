"""Store billing: what an online store's plan is, until when, and every
payment that bought it.

PRICING.md §9: a store pays a one-off opening fee (waived when the first
payment covers 6 months or more) plus a monthly plan priced by how many
listings it holds. api/domains/stores/billing.py owns every write.

StoreSubscription  one row per store. plan_id is the plan in force
                   ("goods-50": rate card + size); paid_until is what makes
                   the store visible - buyers see a store while its plan is
                   paid for, and no longer. A store created before billing
                   was switched on gets a row with plan_id=None and grace
                   paid_until (stores/billing.ensure_grace_subscriptions);
                   setup_fee_paid stays False, so its first real payment
                   still carries the opening fee.
StorePayment       one M-Pesa payment for a store plan, settled once
                   (`processed`), exactly like SubscriptionPayment.

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


class StoreSubscription(Base):
    __tablename__ = "store_subscriptions"

    id         = sa.Column(sa.String, primary_key=True, default=_uuid)
    store_id   = sa.Column(sa.String, sa.ForeignKey("stores.id"), nullable=False, unique=True, index=True)
    # pricing/plans.StorePlan.id ("goods-50"), or NULL for a grace row.
    plan_id    = sa.Column(sa.String, nullable=True)
    # Listings the plan in force covers; 0 on a grace row.
    listings   = sa.Column(sa.Integer, nullable=False, default=0)
    # True once a payment has settled - the opening fee is either in it or
    # waived by its length. Grace rows keep False: the fee still applies.
    setup_fee_paid = sa.Column(sa.Boolean, nullable=False, default=False)
    paid_until = sa.Column(sa.DateTime, nullable=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)


class StorePaymentStatus:
    PENDING = "pending"
    SUCCESS = "success"
    FAILED  = "failed"


class StorePayment(Base):
    __tablename__ = "store_payments"

    id                  = sa.Column(sa.String, primary_key=True, default=_uuid)
    store_id            = sa.Column(sa.String, sa.ForeignKey("stores.id"), nullable=False, index=True)
    user_id             = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    plan_id             = sa.Column(sa.String, nullable=False)
    listings            = sa.Column(sa.Integer, nullable=False)
    months              = sa.Column(sa.Integer, nullable=False)
    # What the STK prompt asked for, KES: the plan's price for those months
    # plus `setup_fee` when it was owed.
    amount              = sa.Column(sa.Integer, nullable=False)
    setup_fee           = sa.Column(sa.Integer, nullable=False, default=0)
    phone               = sa.Column(sa.String, nullable=False)
    checkout_request_id = sa.Column(sa.String, nullable=True, unique=True, index=True)
    merchant_request_id = sa.Column(sa.String, nullable=True)
    mpesa_receipt       = sa.Column(sa.String, nullable=True)
    status              = sa.Column(sa.String, nullable=False, default=StorePaymentStatus.PENDING)
    provider            = sa.Column(sa.String(16), nullable=False, default="daraja", server_default="daraja")
    failure_reason      = sa.Column(sa.String, nullable=True)
    processed           = sa.Column(sa.Boolean, nullable=False, default=False)
    created_at          = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    paid_at             = sa.Column(sa.DateTime, nullable=True)
    period_end          = sa.Column(sa.DateTime, nullable=True)   # the store's paid_until after this
