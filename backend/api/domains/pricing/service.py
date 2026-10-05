"""Gathering what a listing-fee quote needs from the database.

engine.py does the arithmetic; this reads the seller's deal record, their
category's trade so far and whether they are a short- or long-term seller.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import Deal, Listing, ListingStatus, ListingType, SellerTier, User
from api.domains.pricing import engine
from api.domains.pricing.categories import (
    CATEGORIES, CategoryPricing, for_category, stored_names,
)
from api.domains.trust.completion_rate import _FUNDED_STATUSES
from api.domains.trust.seller_rating import (
    MIN_COUNTABLE_DEAL_VALUE_KES, SellerSignals, quality_factor,
)


async def seller_record(db: AsyncSession, seller_id: str) -> engine.SellerRecord:
    """The seller's deals, weighted for pricing.

    "Completed" means the money went through BROKA's escrow - the same set
    of statuses the completion rate uses (trust/completion_rate.py), so a
    refunded or disputed deal still counts as one that stayed on BROKA. A
    leaked deal is one the nightly job flagged as settled elsewhere. A deal
    still being negotiated, or cancelled by the buyer, counts for nothing
    either way.

    Each deal's weight halves every `memory_days` of ITS OWN category: a
    plot sold a year ago still speaks for a land seller; a phone sold a
    year ago barely does. The pricing memory is longer than the 45 days the
    ranking uses: a fee that swings with last month's two deals is the
    constantly-moving price sellers resent.
    """
    rows = (await db.execute(
        select(Deal.created_at, Deal.status, Deal.leak_flag, Deal.agreed_price,
               Deal.buyer_id, Listing.category)
        .outerjoin(Listing, Listing.id == Deal.listing_id)
        .where(Deal.seller_id == seller_id)
    )).all()

    now = datetime.utcnow()
    completed_w = leaked_w = 0.0
    completed = leaked = countable = 0
    buyers: set[str] = set()
    for created_at, status, leak_flag, price, buyer_id, category in rows:
        funded = status in _FUNDED_STATUSES
        if not funded and not leak_flag:
            continue
        age_days = max((now - created_at).total_seconds() / 86400.0, 0.0) if created_at else 0.0
        weight = 0.5 ** (age_days / for_category(category).memory_days)
        if funded:
            completed_w += weight
            completed += 1
            buyers.add(buyer_id)
            if (price or 0) >= MIN_COUNTABLE_DEAL_VALUE_KES:
                countable += 1
        else:
            leaked_w += weight
            leaked += 1

    quality = quality_factor(SellerSignals(
        completed_deals=completed, unique_counterparties=len(buyers),
        countable_value_deals=countable,
    ))
    return engine.SellerRecord(
        completed_weight=completed_w, leaked_weight=leaked_w, quality=quality,
        completed_deals=completed, leaked_deals=leaked,
    )


async def category_completed_deals(db: AsyncSession, category: CategoryPricing) -> int:
    """Deals completed through escrow in this category, platform-wide."""
    return int((await db.execute(
        select(func.count(Deal.id))
        .join(Listing, Listing.id == Deal.listing_id)
        .where(Deal.status.in_(_FUNDED_STATUSES),
               func.lower(Listing.category).in_(stored_names(category)))
    )).scalar() or 0)


FEATURED_NOT_FOR_LONG_TERM = (
    "Featured placement is for occasional sellers. Your listings rank on your "
    "completion record, and a store is your shop window."
)


def featured_options(seller_tier: Optional[SellerTier]) -> dict:
    """Paid placement, offered with the listing fee - to short-term sellers only.

    A long-term seller's visibility is earned: their completion record lowers
    their fee and lifts their ranking, and a store gives them a shop window.
    Selling them placement too would let money outrank the record the whole
    fee system rewards. A short-term seller has no record to earn with, so
    for them placement is the one lever there is.
    """
    if seller_tier == SellerTier.long_term:
        return {
            "available": False,
            "reason": FEATURED_NOT_FOR_LONG_TERM,
            "plans": [],
        }
    from api.routers.featured import BOOST_PLANS
    return {
        "available": True,
        "reason": None,
        "plans": [
            {"id": plan_id, "label": p["label"], "days": p["days"], "price": p["price"]}
            for plan_id, p in BOOST_PLANS.items()
        ],
    }


async def free_listings_left(db: AsyncSession, seller_id: str) -> int:
    """How many more listings this seller can post free (FREE_LISTINGS_PER_SELLER).

    Counts the seller's own listings still for sale that pay no fee
    (paid_until NULL): ones posted free, and ones from before fees. Auctions
    are left out - they pay no listing fee, so they use up no free place.
    """
    allowance = settings.free_listings_per_seller
    if allowance <= 0:
        return 0
    used = (await db.execute(
        select(func.count(Listing.id)).where(
            Listing.seller_id == seller_id,
            Listing.paid_until.is_(None),
            Listing.listing_type != ListingType.auction,
            Listing.status.in_((ListingStatus.active, ListingStatus.pending)),
        )
    )).scalar() or 0
    return max(0, allowance - int(used))


@dataclass(frozen=True)
class FoundingDiscount:
    rank: int                  # 1 = the first seller to list
    percent: int               # 0-100, 0 once the offer has ended
    ends_at: datetime          # the end of this seller's offer


def tier_percent(rank: int, tiers=None) -> int:
    """The discount for the seller numbered `rank` (FOUNDING_SELLER_TIERS)."""
    seen = 0
    for count, percent in (settings.founding_seller_tiers if tiers is None else tiers):
        seen += count
        if rank <= seen:
            return percent
    return 0


async def founding_discount(
    db: AsyncSession, seller_id: str, at: Optional[datetime] = None,
    listing_id: Optional[str] = None,
) -> FoundingDiscount:
    """The founding-seller offer on this seller's FIRST listing, for listing
    time starting `at`. `listing_id` is the listing being priced; None for
    one about to be posted.

    Only the first listing: the offer gets a seller started, it does not
    carry a dealer's whole stock (PRICING.md, "The founding-seller offer").
    Sellers are numbered by that first listing, not by signing up: buyers
    never pay a listing fee, and an early buyer must not use up a place.
    Auctions don't count - they pay no fee. The offer runs
    FOUNDING_DISCOUNT_DAYS from the first listing (from now, for a seller
    about to post it); time bought from its end on is full price.
    """
    now = datetime.utcnow()
    not_auction = Listing.listing_type != ListingType.auction
    first_row = (await db.execute(
        select(Listing.id, Listing.created_at)
        .where(Listing.seller_id == seller_id, not_auction)
        .order_by(Listing.created_at, Listing.id).limit(1)
    )).first()
    firsts = (select(Listing.seller_id, func.min(Listing.created_at).label("first"))
              .where(not_auction).group_by(Listing.seller_id).subquery())
    if first_row is None:
        ahead = (await db.execute(select(func.count()).select_from(firsts))).scalar() or 0
        first, is_first_listing = now, listing_id is None
    else:
        first = first_row.created_at
        ahead = (await db.execute(
            select(func.count()).select_from(firsts).where(firsts.c.first < first)
        )).scalar() or 0
        is_first_listing = listing_id is not None and listing_id == first_row.id
    rank = int(ahead) + 1
    ends_at = first + timedelta(days=settings.founding_discount_days)
    applies = is_first_listing and (at or now) < ends_at
    return FoundingDiscount(rank=rank, percent=tier_percent(rank) if applies else 0, ends_at=ends_at)


async def listing_fee_quote(
    db: AsyncSession, user_id: str, category_name: str, unit_price: float, quantity: int,
    new_listing: bool = False, starts_at: Optional[datetime] = None,
    listing_id: Optional[str] = None,
) -> dict:
    """`starts_at`: when the time being priced begins (the end of time
    already paid, for a renewal); now when left out."""
    category = for_category(category_name)
    record = await seller_record(db, user_id)
    in_category = await category_completed_deals(db, category)
    tier = (await db.execute(select(User.seller_tier).where(User.id == user_id))).scalar()
    start = starts_at or datetime.utcnow()
    # A quote for a draft (no listing_id) is for a listing about to be posted.
    founding = await founding_discount(db, user_id, start, listing_id)
    # 100% is not priced (the fee floor would charge the cost of serving
    # the listing): the listing is posted live until the offer ends.
    founding_free = founding.percent >= 100
    result = engine.quote(category, unit_price, quantity, record, in_category,
                          discounts_apply=settings.in_app_payments_enabled,
                          seller_launch=0.0 if founding_free else founding.percent / 100)
    if 0 < founding.percent:
        # Discounted time can't run past the offer's end: six months bought
        # on its last day would otherwise be six months at founding prices.
        left = max(1, math.ceil((founding.ends_at - start) / timedelta(days=30)))
        result["options"] = [o for o in result["options"] if o["months"] <= left]
    result["founding"] = {
        "rank": founding.rank, "percent": founding.percent,
        "ends_at": founding.ends_at.isoformat(),
    }
    result["featured"] = featured_options(tier)
    # A listing about to be posted into one of the seller's free places, or
    # by a seller whose founding offer is 100%, pays nothing:
    # ListingService.create posts it live.
    free = (new_listing and settings.listing_fees_enabled
            and (founding_free or await free_listings_left(db, user_id) > 0))
    result["free_listing"] = free
    result["free_listings_per_seller"] = settings.free_listings_per_seller
    # Whether this seller is charged (LISTING_FEES_ENABLED, and not a free
    # listing). Off, the app shows no fee step and the listing goes live -
    # which is also what an app build that predates free listings needs to
    # hear, or it would ask to be paid for one that is free.
    result["fees_enabled"] = settings.listing_fees_enabled and not free
    return result


async def monthly_fees_at_prices(
    db: AsyncSession, seller_id: str, category_name: str, quantity: int, *prices: float,
) -> list[int]:
    """This seller's monthly fee for the listing at each of `prices`, as of now.

    One record and one category count for all of them, so the fees differ
    only by price - what a price change does to the fee, and nothing else
    (the seller's record may have moved since they paid).
    """
    category = for_category(category_name)
    record = await seller_record(db, seller_id)
    in_category = await category_completed_deals(db, category)
    return [engine.quote(category, p, quantity, record, in_category,
                         discounts_apply=settings.in_app_payments_enabled)["monthly_fee"]
            for p in prices]


# The category table shows the lasting price, without the launch offer:
# this many completed deals puts launch_discount() at zero.
_PAST_LAUNCH = 10_000


def category_table() -> list[dict]:
    """Every category's parameters, and what a new seller pays at its typical price."""
    out = []
    for c in CATEGORIES.values():
        q = engine.quote(c, c.typical_price, 1, engine.SellerRecord(), _PAST_LAUNCH)
        out.append({
            "category": c.name,
            "category_completion_rate": c.prior_completion,
            "new_seller_risk_coefficient": q["risk"]["coefficient"],
            "cost_to_serve": q["cost_to_serve"],
            "days_to_sell": c.days_to_sell,
            "typical_price": c.typical_price,
            "typical_list_price": q["list_price"],
            "typical_new_seller_fee": q["monthly_fee"],
            "recommended_months_at_typical_price": q["recommendation"]["months"],
        })
    return out
