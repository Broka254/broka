"""ListingPayment - one M-Pesa payment for a listing's monthly fee.

A seller pays for 1-6 months of a listing (PRICING.md); a successful
payment moves Listing.paid_until forward by that many 30-day months.
api/domains/pricing/payments.py owns every write.

The row keeps what the seller was quoted and agreed to - the monthly rate,
the months, the total, the optional featured add-on and the whole quote as
JSON - because the rate is locked for the period paid: a later change to
the seller's record or to the pricing constants must not change what this
payment bought.

`status` is a plain string, not a database enum, so a new state never needs
ALTER TYPE on PostgreSQL. `processed` is what makes settlement happen once:
Safaricom redelivers callbacks, and the status poll can race the callback.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class ListingPaymentStatus:
    PENDING = "pending"   # the STK prompt is on the seller's phone
    SUCCESS = "success"   # paid; the listing's time was extended
    FAILED  = "failed"    # cancelled, timed out, wrong amount, or refused


class ListingPayment(Base):
    __tablename__ = "listing_payments"

    id                  = sa.Column(sa.String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id             = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    listing_id          = sa.Column(sa.String, sa.ForeignKey("listings.id"), nullable=False, index=True)
    months              = sa.Column(sa.Integer, nullable=False)
    monthly_fee         = sa.Column(sa.Integer, nullable=False)   # the locked rate, KES
    listing_amount      = sa.Column(sa.Integer, nullable=False)   # the months' total, KES
    featured_plan       = sa.Column(sa.String, nullable=True)     # routers/featured.BOOST_PLANS key
    featured_amount     = sa.Column(sa.Integer, nullable=False, default=0)
    amount              = sa.Column(sa.Integer, nullable=False)   # what the STK prompt asked for
    phone               = sa.Column(sa.String, nullable=False)
    checkout_request_id = sa.Column(sa.String, nullable=True, unique=True, index=True)
    merchant_request_id = sa.Column(sa.String, nullable=True)
    mpesa_receipt       = sa.Column(sa.String, nullable=True)
    status              = sa.Column(sa.String, nullable=False, default=ListingPaymentStatus.PENDING)
    # Which M-Pesa rail took it: "daraja" (checkout_request_id, Safaricom's
    # callback) or "zetupay" (api/domains/payments, settled by its webhook).
    provider            = sa.Column(sa.String(16), nullable=False, default="daraja", server_default="daraja")
    failure_reason      = sa.Column(sa.String, nullable=True)
    processed           = sa.Column(sa.Boolean, nullable=False, default=False)
    quote               = sa.Column(sa.Text, nullable=True)       # the engine's quote, JSON
    period_start        = sa.Column(sa.DateTime, nullable=True)   # set when paid
    period_end          = sa.Column(sa.DateTime, nullable=True)
    created_at          = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    paid_at             = sa.Column(sa.DateTime, nullable=True)
