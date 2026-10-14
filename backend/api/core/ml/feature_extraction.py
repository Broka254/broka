"""
BROKA - ML Feature Extraction (Volume 2 §4.2, §4.3)
─────────────────────────────────────────────────────────────────────────────
Pure data-access functions: pull real transaction data into the shapes
train.py and predict.py need. No modeling logic lives here - this module
only answers "what happened," never "what should happen next."

Per §4.4's explicit sequencing ("start collecting/logging features from
day one, but only switch ... over from heuristic to learned-model
implementations once each category has accumulated enough completed
deals"), count_completed_deals_by_category() is the function everything
else in core/ml/ checks before trusting a trained model over the
heuristic fallback.
"""
from __future__ import annotations

from datetime import datetime
from typing import List, Optional

from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus, Listing, NegotiationMessage, AuditLog

# Same "actually went through BROKA escrow" status set used throughout
# Chapter 3 (core/fraud.py's seller_deal_stats, domains/trust/completion_rate's
# _FUNDED_STATUSES) - kept identical on purpose, all three answer the same
# underlying question.
_FUNDED_STATUSES = (
    DealStatus.paid, DealStatus.released, DealStatus.refunded,
    DealStatus.disputed, DealStatus.awaiting_condition_check,
    DealStatus.awaiting_resolution, DealStatus.awaiting_replacement,
    DealStatus.goods_not_arrived,
)

MIN_DEALS_PER_CATEGORY_FOR_ML = 300  # §4.4's stated threshold


async def count_completed_deals_by_category(db: AsyncSession) -> dict:
    """{category: count} for every category with >=1 funded deal. §4.4 gate."""
    rows = await db.execute(
        select(Listing.category, func.count(Deal.id))
        .join(Deal, Deal.listing_id == Listing.id)
        .where(Deal.status.in_(_FUNDED_STATUSES))
        .group_by(Listing.category)
    )
    return {category: count for category, count in rows.all()}


async def extract_pricing_examples(db: AsyncSession, category: Optional[str] = None) -> List[dict]:
    """
    One row per funded deal: {category, condition, listing_price,
    agreed_price, days_to_sell}. This is train.py's training set for the
    pricing model (§4.2) and predict.py's data source for the category-
    average heuristic fallback.
    """
    q = (
        select(Listing.category, Listing.condition, Listing.price, Deal.agreed_price,
               Listing.created_at, Deal.created_at)
        .join(Deal, Deal.listing_id == Listing.id)
        .where(Deal.status.in_(_FUNDED_STATUSES))
    )
    if category:
        q = q.where(Listing.category == category)

    rows = await db.execute(q)
    examples = []
    for cat, condition, listing_price, agreed_price, listed_at, agreed_at in rows.all():
        days_to_sell = max(0.0, (agreed_at - listed_at).total_seconds() / 86400.0)
        examples.append({
            "category":       cat,
            "condition":      condition or "used",  # most common case when unset
            "listing_price":  listing_price,
            "agreed_price":   agreed_price,
            "days_to_sell":   round(days_to_sell, 2),
        })
    return examples


async def extract_leak_risk_examples(db: AsyncSession) -> List[dict]:
    """
    One row per agreed-or-later deal (both leaked and completed - a
    classifier needs both classes): {message_count, avg_response_delay_hours,
    price_band, had_solicitation_flag, label}. label=1 means Deal.leak_flag
    was set by domains/trust/completion_rate.flag_leaked_deals(); label=0
    means it funded successfully. Deals that are neither (still genuinely
    in-progress, or stale-but-unflagged per §3.2's explicit "don't
    penalise ordinary indecision" rule) are excluded - only resolved
    outcomes make valid training labels.
    """
    deals_r = await db.execute(
        select(Deal).where(
            (Deal.status.in_(_FUNDED_STATUSES)) | (Deal.leak_flag.is_(True))
        )
    )
    deals = list(deals_r.scalars().all())

    examples = []
    for deal in deals:
        # visibility-ok: selects role and timestamp only, no content column is read
        msgs_r = await db.execute(
            select(NegotiationMessage.role, NegotiationMessage.created_at)
            .where(
                NegotiationMessage.listing_id == deal.listing_id,
                NegotiationMessage.buyer_id == deal.buyer_id,
            )
            .order_by(NegotiationMessage.created_at)
        )
        msgs = msgs_r.all()
        message_count = len(msgs)

        # Average delay between a message and the next reply from the OTHER
        # party - a crude proxy for responsiveness until real response-time
        # tracking exists (see completion_rate.py's identical caveat for
        # rank_score's response_time_score component).
        delays = []
        for i in range(1, len(msgs)):
            prev_role, prev_at = msgs[i - 1]
            role, at = msgs[i]
            if role != prev_role:
                delays.append((at - prev_at).total_seconds() / 3600.0)
        avg_response_delay_hours = round(sum(delays) / len(delays), 2) if delays else None

        solicitation_r = await db.execute(
            select(func.count(AuditLog.id))
            .select_from(AuditLog)
            .join(NegotiationMessage, NegotiationMessage.id == AuditLog.resource_id)
            .where(
                AuditLog.action == "off_platform_solicitation_detected",
                NegotiationMessage.listing_id == deal.listing_id,
                NegotiationMessage.buyer_id == deal.buyer_id,
            )
        )
        had_solicitation_flag = (solicitation_r.scalar() or 0) > 0

        examples.append({
            "message_count":             message_count,
            "avg_response_delay_hours":  avg_response_delay_hours,
            "price_band":                _price_band(deal.agreed_price),
            "had_solicitation_flag":     had_solicitation_flag,
            "label":                     1 if deal.leak_flag else 0,
        })
    return examples


def _price_band(price: float) -> str:
    """Coarse KES bands - fine enough to be a useful categorical feature,
    coarse enough not to fingerprint an individual deal's exact price."""
    if price < 2_000:    return "under_2k"
    if price < 10_000:   return "2k_10k"
    if price < 50_000:   return "10k_50k"
    if price < 200_000:  return "50k_200k"
    return "over_200k"
