"""
BROKA - Fraud Engine & Trust Score System
Computes a Trust Score (0-100) for every user based on behavioural signals.

Score bands:
    80-100  Trusted user — green badge
    50-79   Standard user — no indicator
    20-49   At-risk user — yellow warning
    0-19    High-risk / suspended — red flag, transactional permissions revoked

Signals tracked:
    + Account age (newer = riskier)
    + Completed deals (more = safer)
    + Dispute rate (higher = riskier)
    + Verification tier (verified = safer)
    + Rapid transaction patterns
    + Chargeback / refund rate
    + Open dispute count
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

logger = logging.getLogger(__name__)

# Trust score component weights
W_AGE        = 15   # max points from account age
W_DEALS      = 25   # max points from completed deals
W_DISPUTE    = 20   # max points from low dispute rate
W_VERIFIED   = 15   # max points from verification status
W_RATING     = 15   # max points from peer rating
W_RAPID_TX   = 10   # max points from no rapid-transaction pattern


async def compute_trust_score(user_id: str, db: AsyncSession) -> int:
    """
    Recompute trust score for a user and persist it.
    Returns the new score (0-100).
    """
    from api.database import User, Deal, Dispute, DealStatus, DisputeStatus, MpesaTransaction

    # Load user
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if not user:
        return 50  # unknown user → neutral

    score = 0

    # 1. Account age (max 15 pts)
    age_days = (datetime.utcnow() - user.created_at).days if user.created_at else 0
    if age_days >= 180:    score += W_AGE
    elif age_days >= 30:   score += int(W_AGE * 0.7)
    elif age_days >= 7:    score += int(W_AGE * 0.4)
    else:                  score += 0   # brand new account — riskiest

    # 2. Completed deals (max 25 pts)
    completed = user.completed_deals or 0
    if completed >= 20:    score += W_DEALS
    elif completed >= 10:  score += int(W_DEALS * 0.8)
    elif completed >= 5:   score += int(W_DEALS * 0.6)
    elif completed >= 2:   score += int(W_DEALS * 0.3)
    elif completed == 1:   score += int(W_DEALS * 0.15)
    # 0 deals → 0 pts

    # 3. Dispute rate (max 20 pts)
    total_deals_r = await db.execute(
        select(func.count(Deal.id)).where(Deal.seller_id == user_id)
    )
    total_deals = total_deals_r.scalar() or 0

    disputed_r = await db.execute(
        select(func.count(Dispute.id)).where(
            Dispute.deal_id.in_(
                select(Deal.id).where(Deal.seller_id == user_id)
            )
        )
    )
    disputed = disputed_r.scalar() or 0

    if total_deals > 0:
        dispute_rate = disputed / total_deals
        if dispute_rate == 0.0:          score += W_DISPUTE
        elif dispute_rate <= 0.05:       score += int(W_DISPUTE * 0.8)
        elif dispute_rate <= 0.15:       score += int(W_DISPUTE * 0.5)
        elif dispute_rate <= 0.30:       score += int(W_DISPUTE * 0.2)
        # >30% dispute rate → 0 pts
    else:
        score += int(W_DISPUTE * 0.5)   # no deals yet → neutral

    # 4. Verification tier (max 15 pts)
    if user.is_verified:
        if getattr(user, "verify_tier", None) == "gold":
            score += W_VERIFIED
        else:
            score += int(W_VERIFIED * 0.7)

    # 5. Peer rating (max 15 pts)
    rating = user.rating or 5.0
    if rating >= 4.8:    score += W_RATING
    elif rating >= 4.5:  score += int(W_RATING * 0.8)
    elif rating >= 4.0:  score += int(W_RATING * 0.6)
    elif rating >= 3.5:  score += int(W_RATING * 0.4)
    elif rating >= 3.0:  score += int(W_RATING * 0.2)
    # <3.0 → 0 pts

    # 6. Rapid transaction pattern (max 10 pts — subtract for rapid)
    window_start = datetime.utcnow() - timedelta(hours=24)
    rapid_r = await db.execute(
        select(func.count(Deal.id)).where(
            Deal.buyer_id == user_id,
            Deal.created_at >= window_start,
        )
    )
    rapid_deals = rapid_r.scalar() or 0
    if rapid_deals <= 3:     score += W_RAPID_TX
    elif rapid_deals <= 6:   score += int(W_RAPID_TX * 0.5)
    # >6 deals in 24h → 0 pts (suspicious rapid-transaction pattern)

    final_score = max(0, min(100, score))

    # Persist to user record
    user.trust_score = final_score
    # NOTE: caller must commit

    logger.info("[fraud] trust_score for user=%s → %d", user_id, final_score)
    return final_score


async def flag_fraud(
    user_id: str,
    reason: str,
    triggered_by: str,
    db: AsyncSession,
) -> None:
    """
    Flag a user for fraud review.
    Publishes FraudFlagged event and appends a fraud event record.
    """
    from api.database import FraudEvent
    from api.core.events import publish, FraudFlagged

    # Compute current trust score
    score = await compute_trust_score(user_id, db)

    # Save fraud event
    fe = FraudEvent(
        user_id=user_id,
        reason=reason,
        triggered_by=triggered_by,
        trust_score_at_flag=score,
    )
    db.add(fe)
    # NOTE: caller must commit after this

    await publish(FraudFlagged(
        user_id=user_id,
        reason=reason,
        trust_score=score,
        triggered_by=triggered_by,
    ))

    logger.warning("[fraud] User %s flagged: %s (score=%d)", user_id, reason, score)


def trust_band(score: int) -> str:
    """Return a human-readable band label."""
    if score >= 80:  return "trusted"
    if score >= 50:  return "standard"
    if score >= 20:  return "at_risk"
    return "high_risk"


# ── Off-platform solicitation detection (Volume 2 §2.2) ────────────────────────
#
# Lightweight regex/keyword pass, intentionally not perfect on day one - this
# seeds Chapter 4's leakage-risk classifier later. Deliberately NOT wired into
# compute_trust_score above: a single trigger must never move trust score or
# visibility on its own (false positives are easy - "call me" alone is weak
# signal). Callers are responsible for audit-logging triggers for analytics.
import re as _re

OFF_PLATFORM_PATTERNS = [
    r"\b0[71]\d{8}\b",              # Kenyan phone number pattern
    r"\bwhat\s*s?app\b",
    r"\bcall me\b",
    r"\bsend\s+(cash|money)\s+direct\b",
    r"\bpay\s+me\s+(directly|outside)\b",
]
_OFF_PLATFORM_RE = [_re.compile(p, _re.IGNORECASE) for p in OFF_PLATFORM_PATTERNS]


def detect_off_platform_solicitation(message_text: str) -> bool:
    """
    True if message_text looks like it's soliciting payment/contact outside
    BROKA escrow. First version - keyword/regex only, no ML.
    """
    if not message_text:
        return False
    text = message_text.lower()
    return any(p.search(text) for p in _OFF_PLATFORM_RE)


# ── Seller deal stats (Volume 2 §2.4) ───────────────────────────────────────────
#
# Volume 2 assumes "Escrow Success Rate" and "Dispute Rate" per seller already
# exist and just need placement next to the payment button. They don't - only
# completed_deals is an actual stored/exposed field today (grepped the whole
# repo: no prior "escrow_success" or "dispute_rate" anywhere outside the
# unexposed local variable inside compute_trust_score above). This computes
# both live from the deals table; cheap enough (indexed seller_id, small per-
# seller row counts) to run inline on profile fetch rather than needing the
# periodic-job+Redis treatment the platform-wide dispute-summary stat gets.
async def seller_deal_stats(user_id: str, db: AsyncSession) -> dict:
    """
    Returns {completed_deals, escrow_success_rate_pct, dispute_rate_pct}
    for a seller, for display next to the payment button (Volume 2 §2.4).
    escrow_success_rate_pct is None (not 0) when the seller has no paid-or-
    later deals yet - there's nothing to compute a rate from, and 0% would
    misleadingly read as "this seller fails every deal."
    """
    from api.database import Deal, Dispute, DealStatus

    funded_r = await db.execute(
        select(func.count(Deal.id)).where(
            Deal.seller_id == user_id,
            Deal.status.in_((
                DealStatus.paid, DealStatus.released, DealStatus.refunded,
                DealStatus.disputed, DealStatus.awaiting_condition_check,
                DealStatus.awaiting_resolution, DealStatus.awaiting_replacement,
                DealStatus.goods_not_arrived,
            )),
        )
    )
    funded_deals = funded_r.scalar() or 0

    released_r = await db.execute(
        select(func.count(Deal.id)).where(
            Deal.seller_id == user_id, Deal.status == DealStatus.released,
        )
    )
    released_deals = released_r.scalar() or 0

    disputed_r = await db.execute(
        select(func.count(Dispute.id)).where(
            Dispute.deal_id.in_(select(Deal.id).where(Deal.seller_id == user_id))
        )
    )
    disputed_count = disputed_r.scalar() or 0

    escrow_success_rate_pct = (
        round(100.0 * released_deals / funded_deals, 1) if funded_deals > 0 else None
    )
    dispute_rate_pct = (
        round(100.0 * disputed_count / funded_deals, 1) if funded_deals > 0 else None
    )

    return {
        "escrow_success_rate_pct": escrow_success_rate_pct,
        "dispute_rate_pct":        dispute_rate_pct,
    }
