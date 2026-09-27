"""Whether buyers can see a listing: while it is paid for.

Listing.paid_until (api/database.py) holds the answer; this is the one
place that reads it, so every public listing query asks the same question.
A reader that forgets live_clause() shows buyers listings nobody paid for -
and those listings are exactly the ones whose sellers will not answer.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import or_

from api.database import Listing, ListingType

# A month of listing time. 30 days, not a calendar month, so the price of
# "3 months" does not depend on which months they are.
MONTH = timedelta(days=30)

# A listing is shown as "ending soon" - and the seller offered a renewal -
# this long before its paid time runs out.
ENDING_SOON = timedelta(days=7)


def live_clause(now: Optional[datetime] = None):
    """SQL: the listing is paid for, or no fee applies to it."""
    now = now or datetime.utcnow()
    return or_(Listing.paid_until.is_(None), Listing.paid_until > now)


def is_live(listing: Listing, now: Optional[datetime] = None) -> bool:
    paid_until = getattr(listing, "paid_until", None)
    return paid_until is None or paid_until > (now or datetime.utcnow())


def fee_applies(listing: Listing) -> bool:
    """Auctions pay through the premium plans and a 5% commission, not a
    monthly fee (PRICING.md) - an auction runs for days, not months."""
    return getattr(listing.listing_type, "value", listing.listing_type) != ListingType.auction.value


def fee_state(listing: Listing, now: Optional[datetime] = None) -> dict:
    """What the seller's own screens say about the listing's fee.

      free      no fee applies (from before fees, or an auction)
      unpaid    never paid: hidden until the first payment
      live      paid until `paid_until`
      ending    paid, but ends within ENDING_SOON - time to renew
      expired   its paid time ran out: hidden until renewed
    """
    now = now or datetime.utcnow()
    paid_until = getattr(listing, "paid_until", None)
    if paid_until is None:
        status = "free"
    elif paid_until > now:
        status = "ending" if paid_until - now <= ENDING_SOON else "live"
    elif listing.created_at is not None and paid_until <= listing.created_at:
        status = "unpaid"
    else:
        status = "expired"
    return {
        "status": status,
        "live": status in ("free", "live", "ending"),
        "paid_until": paid_until.isoformat() if paid_until else None,
        "needs_payment": status in ("unpaid", "ending", "expired"),
    }
