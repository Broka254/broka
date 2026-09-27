"""Gathering what a listing-fee quote needs from the database.

engine.py does the arithmetic; this reads the seller's deal record, their
category's trade so far and whether they are a short- or long-term seller.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, Listing, SellerTier, User
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


async def listing_fee_quote(
    db: AsyncSession, user_id: str, category_name: str, unit_price: float, quantity: int,
) -> dict:
    category = for_category(category_name)
    record = await seller_record(db, user_id)
    in_category = await category_completed_deals(db, category)
    tier = (await db.execute(select(User.seller_tier).where(User.id == user_id))).scalar()
    result = engine.quote(category, unit_price, quantity, record, in_category)
    result["featured"] = featured_options(tier)
    return result


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
            "max_fee": c.max_fee,
            "cost_to_serve": q["cost_to_serve"],
            "days_to_sell": c.days_to_sell,
            "typical_price": c.typical_price,
            "typical_list_price": q["list_price"],
            "typical_new_seller_fee": q["monthly_fee"],
            "recommended_months_at_typical_price": q["recommendation"]["months"],
        })
    return out
