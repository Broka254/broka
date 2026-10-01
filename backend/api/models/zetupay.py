"""ZetuPay payments - money a user pays BROKA, never a deal's money.

ZetuPayPayment      one M-PESA charge, under its BROKA reference. The row is
                    what the reference identifies: who pays (user_id), for
                    what (purpose), how much (amount - the only amount that
                    buys anything) and the BROKA record it pays for
                    (target_id: the listing_payments, subscription_payments,
                    featured_payments or verification_payments row, which
                    keeps that domain's own state as it does for Daraja;
                    related_id: the listing, plan or badge tier bought).
ZetuPayTransaction  one row per terminal state of a ZetuPay transaction
                    BROKA has seen, from its webhook or its status endpoint.
                    Unique on (waveTransactionId, status): that constraint is
                    what makes a redelivered webhook, or a webhook racing
                    the status poll, apply once - the second insert fails.

Buyer-to-seller money is E-Confirm's (models/external_escrow.py, deals);
nothing in these tables refers to a deal. api/domains/payments/ owns every
write. Statuses are plain strings, timestamps naive UTC.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class Purpose:
    LISTING_FEE = "listing_fee"     # pricing/payments.py
    SUBSCRIPTION = "subscription"   # premium/payments.py
    BOOST = "boost"                 # routers/featured.py
    VERIFICATION = "verification"   # routers/verify.py
    TEST = "test"                   # payments/test_charge.py: KES 10, buys nothing
    ALL = (LISTING_FEE, SUBSCRIPTION, BOOST, VERIFICATION, TEST)


class ZetuPayStatus:
    INITIATED = "initiated"     # written; ZetuPay not asked yet, or not answered
    PROCESSING = "processing"   # ZetuPay accepted it (its 202): the prompt is on the phone
    SUCCESS = "success"         # a verified payment for the right amount was applied
    FAILED = "failed"           # not sent, cancelled, timed out, or the wrong amount


class ZetuPayPayment(Base):
    __tablename__ = "zetupay_payments"

    id                  = sa.Column(sa.String, primary_key=True, default=_uuid)
    reference           = sa.Column(sa.String(32), nullable=False, unique=True, index=True)
    user_id             = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    purpose             = sa.Column(sa.String(24), nullable=False)
    amount              = sa.Column(sa.Integer, nullable=False)   # KES, what the prompt asked for
    phone               = sa.Column(sa.String, nullable=False)
    description         = sa.Column(sa.String(64), nullable=True)
    # Not foreign keys: target_id is a row in one of four tables (by
    # purpose), related_id a listing id, a plan id or a badge tier.
    target_id           = sa.Column(sa.String, nullable=False, index=True)
    related_id          = sa.Column(sa.String, nullable=True)
    status              = sa.Column(sa.String(16), nullable=False, default=ZetuPayStatus.INITIATED)
    provider_payment_id = sa.Column(sa.String, nullable=True)     # ZetuPay's paymentKey, from its 202
    wave_transaction_id = sa.Column(sa.String, nullable=True)     # ZetuPay's payment id (202, then webhook)
    mpesa_receipt       = sa.Column(sa.String, nullable=True)
    failure_reason      = sa.Column(sa.String, nullable=True)
    created_at          = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at          = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    settled_at          = sa.Column(sa.DateTime, nullable=True)

    __table_args__ = (
        # The reconcile sweep: unfinished payments, oldest first.
        sa.Index("ix_zetupay_payments_status_created", "status", "created_at"),
    )


class ZetuPayTransaction(Base):
    __tablename__ = "zetupay_transactions"

    id                  = sa.Column(sa.String, primary_key=True, default=_uuid)
    wave_transaction_id = sa.Column(sa.String, nullable=False)
    status              = sa.Column(sa.String(16), nullable=False)   # success | failed
    reference           = sa.Column(sa.String(64), nullable=True)    # as ZetuPay reported it
    payment_id          = sa.Column(sa.String, sa.ForeignKey("zetupay_payments.id"), nullable=True, index=True)
    amount              = sa.Column(sa.Float, nullable=True)         # as ZetuPay reported it
    mpesa_receipt       = sa.Column(sa.String, nullable=True)
    source              = sa.Column(sa.String(16), nullable=False)   # webhook | status_query
    # applied | failed | amount_mismatch | duplicate_payment | unknown_reference | ignored
    outcome             = sa.Column(sa.String(24), nullable=False)
    received_at         = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.UniqueConstraint("wave_transaction_id", "status", name="uq_zetupay_transaction_state"),
    )
