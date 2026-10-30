"""Whether buyers can see a listing: while it is paid for.

Listing.paid_until (api/database.py) holds the answer; this is the one
place that reads it, so every public listing query asks the same question.
A reader that forgets live_clause() shows buyers listings nobody paid for -
and those listings are exactly the ones whose sellers will not answer.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import and_, or_

from api.core.config import settings
from api.database import Listing, ListingType

# A month of listing time. 30 days, not a calendar month, so the price of
# "3 months" does not depend on which months they are.
MONTH = timedelta(days=30)

# A listing is shown as "ending soon" - and the seller offered a renewal -
# this long before its paid time runs out.
ENDING_SOON = timedelta(days=7)


def live_clause(now: Optional[datetime] = None):
    """SQL: the listing is paid for, or no fee applies to it - its store's
    plan is paid up when store billing is on - and, while auctions are off
    (AUCTIONS_ENABLED), it is not an auction.

    The auction rule rides here because this is the filter every list a
    buyer browses shares: feeds, search, categories, stores, trending, the
    Buying Agent. A reader that forgot a separate auctions check would put
    a Bid button nobody can press in front of buyers. One listing read by
    its id (is_live) is left alone on purpose: whoever already has an
    auction open by its link still sees it and its result (auctions/
    paused.py).

    The store rule rides here for the same reason: a store's plan is what
    pays for its listings (stores/billing.py), so a store whose plan has
    lapsed disappears from every list - not just the directory - until it
    pays again. Personal listings have no store_id and are never touched
    by it."""
    now = now or datetime.utcnow()
    # Store listings carry no listing fee (fee_applies): a paid_until left
    # over from before the listing joined its store must not take it
    # offline - the store clause below is its only clock.
    paid = or_(Listing.store_id.is_not(None),
               Listing.paid_until.is_(None), Listing.paid_until > now)
    # Reported sold out by a buyer (listings/sold_out.py) rides here for the
    # same reason: out of every list until its seller says it is still there.
    paid = and_(paid, Listing.sold_out_reported_at.is_(None))
    if settings.store_billing_enabled:
        # Imported here, not at the top: stores.billing imports the payment
        # stack, and this module is loaded by the database layer itself.
        from api.domains.stores.billing import live_subscription_clause
        paid = and_(paid, or_(Listing.store_id.is_(None),
                              live_subscription_clause(Listing.store_id, now)))
    if settings.auctions_enabled:
        return paid
    # IS NULL kept: the column is nullable, NULL != 'auction' is NULL in
    # SQL, and a bare != would hide every listing saved without a type.
    return and_(paid, or_(Listing.listing_type.is_(None),
                          Listing.listing_type != ListingType.auction))


def is_live(listing: Listing, now: Optional[datetime] = None) -> bool:
    # Listing-level check only: a store listing's real gate is its store's
    # subscription (stores/billing.store_live), which callers serving store
    # products check separately.
    if getattr(listing, "store_id", None):
        return True
    paid_until = getattr(listing, "paid_until", None)
    return paid_until is None or paid_until > (now or datetime.utcnow())


def fee_applies(listing: Listing) -> bool:
    """Auctions pay through the premium plans and a 5% commission, not a
    monthly fee (PRICING.md) - an auction runs for days, not months. Store
    listings NEVER pay a listing fee (PRICING.md §5: "listings in the store
    pay no listing fee"): the store's plan is what pays for them, so they
    stay free at the listing level and are hidden or shown by the store's
    subscription (live_clause).

    This used to require STORE_BILLING_ENABLED: with billing off, posting
    into your own store suddenly demanded a per-listing M-Pesa payment -
    a seller with a shop paid twice for the same shelf. The exemption is
    the store association itself, not the billing switch."""
    if getattr(listing.listing_type, "value", listing.listing_type) == ListingType.auction.value:
        return False
    if getattr(listing, "store_id", None):
        return False
    return True


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
    # A store listing's clock is its store's subscription, not paid_until:
    # it is covered - live while the store is, with no fee of its own to
    # renew. Reporting expired off a stale paid_until (from before it
    # joined the store) would demand a payment that must never be charged.
    # The shape stays the established four keys: screens switch on them,
    # and the countdown itself rides as a sibling in the owner payload
    # (ListingService._owner_listing_dict's `time_left`), not in here.
    if getattr(listing, "store_id", None):
        return {
            "status": "store_covered",
            "live": True,
            "paid_until": paid_until.isoformat() if paid_until else None,
            "needs_payment": False,
        }
    return {
        "status": status,
        "live": status in ("free", "live", "ending"),
        "paid_until": paid_until.isoformat() if paid_until else None,
        "needs_payment": status in ("unpaid", "ending", "expired"),
    }
