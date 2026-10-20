"""Durable inbox for payment-provider callbacks that arrive before BROKA can
match them to its own payment row.

An STK callback can be delivered while the process that sent the prompt is
still persisting Safaricom's response. Throwing that callback away because
the CheckoutRequestID is not visible yet turns a real payment into money
BROKA never records. Rows here hold only the non-secret fields needed for
matching, never the raw provider body or the payer's phone number.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class PaymentCallbackStatus:
    PENDING = "pending"       # no payment row matched yet
    PROCESSED = "processed"   # applied to its payment row
    IGNORED = "ignored"       # duplicate or unrelated provider event


class PaymentCallback(Base):
    __tablename__ = "payment_callbacks"

    id                  = sa.Column(sa.String, primary_key=True, default=_uuid)
    provider            = sa.Column(sa.String(16), nullable=False, default="daraja")
    checkout_request_id = sa.Column(sa.String, nullable=False)
    result_code         = sa.Column(sa.String(16), nullable=True)
    amount              = sa.Column(sa.Numeric(18, 2), nullable=True)
    receipt             = sa.Column(sa.String, nullable=True)
    result_description  = sa.Column(sa.String(200), nullable=True)
    status              = sa.Column(sa.String(16), nullable=False, default=PaymentCallbackStatus.PENDING)
    attempts            = sa.Column(sa.Integer, nullable=False, default=0)
    last_error          = sa.Column(sa.String(200), nullable=True)
    received_at         = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    processed_at        = sa.Column(sa.DateTime, nullable=True)

    __table_args__ = (
        sa.UniqueConstraint("provider", "checkout_request_id", name="uq_payment_callback_provider_ref"),
        sa.Index("ix_payment_callback_status_received", "status", "received_at"),
    )
