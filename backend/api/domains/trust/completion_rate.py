"""
BROKA - Deal Completion Rate (Volume 2, Chapter 3)
─────────────────────────────────────────────────────────────────────────────
DCR (raw) = CompletedDeals / (CompletedDeals + LeakedDeals), recency-weighted
and Bayesian-smoothed per §3.3 so it reflects recent behaviour rather than
lifetime history, and so a brand-new seller starts at a neutral 80% rather
than 0%.

Call order (both invoked from core/workers.task_recompute_dcr_and_leaks,
matching §3.7's "flag_leaked_deals() ... runs before recompute_all_dcr() in
the same nightly job"):
    1. flag_leaked_deals(db)   - §3.2: mark deals that leaked off-platform
    2. recompute_all_dcr(db)   - §3.3/§3.4: score every seller from that data

Two deviations from the doc, made after checking against the actual schema
rather than assuming it matches - see comments at each site below:
  - No agreed_at column exists or is added; Deal.created_at already IS the
    agreement timestamp (every Deal row is created at DealStatus.agreed).
  - §3.2's three leak-detection signals are implemented as two. Signal 1
    ("listing marked sold/unavailable outside of a BROKA-mediated deal")
    has no data source - there is no listing delisting/deactivation
    endpoint anywhere in this codebase, seller-facing or otherwise, so
    there is nothing for this signal to read. Signals 2 (§2.2's
    off-platform-solicitation flag) and 3 (extended silence) are real and
    implemented.
"""
from __future__ import annotations

import math
import logging
from datetime import datetime, timedelta
from typing import List

from sqlalchemy import select, func, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus, Listing, User, SellerMetrics, NegotiationMessage, AuditLog

logger = logging.getLogger(__name__)

# ── Tunables (§3.2, §3.3 - doc's own "suggested default"s) ──────────────────
LEAK_WINDOW_DAYS    = 7    # no escrow payment within this long after agreement...
SILENCE_WINDOW_DAYS = 5    # ...plus this much further silence = leak, not just "stale"
HALF_LIFE_DAYS      = 45   # a deal's influence on DCR halves every 45 days
PRIOR_MEAN          = 0.80 # neutral starting assumption for brand-new sellers
PRIOR_WEIGHT        = 5    # pseudo-count strength of that assumption

# Deal statuses that mean "payment was actually initiated through BROKA
# escrow" - i.e. NOT leaked, regardless of how the deal later turned out
# (a legitimate dispute/refund is a totally different concern from taking
# the deal off-platform, and must not be penalised as if it were leakage).
# Same set used for "funded_deals" in core/fraud.py's seller_deal_stats -
# kept identical intentionally, both answer "did this stay on BROKA."
_FUNDED_STATUSES = (
    DealStatus.paid, DealStatus.released, DealStatus.refunded,
    DealStatus.disputed, DealStatus.awaiting_condition_check,
    DealStatus.awaiting_resolution, DealStatus.awaiting_replacement,
    DealStatus.goods_not_arrived,
)

# Ranking formula weights (§3.4) - kept as named constants so Chapter 4's
# "later phase, learned rather than guessed" replacement has one obvious
# place to change them.
W_TRUST     = 0.35
W_DCR       = 0.30
W_RESPONSE  = 0.15
W_FRESHNESS = 0.20  # applied at query time in listings/service.py, not here - see recompute_all_dcr docstring

# What a brand-new seller's rank_score WOULD be if recompute_all_dcr ran for
# them right now: trust=100 (User.trust_score's own column default) -> 1.0,
# dcr=PRIOR_MEAN (the neutral 80% starting assumption, §3.3), response=the
# same 0.7 placeholder every seller gets today. listings/service.py uses
# this as the coalesce() default for a seller with no SellerMetrics row yet
# (nightly job hasn't run, or genuinely brand new) - matches §3.5's
# cold-start fairness intent: rank like an average seller, not like a zero.
DEFAULT_RANK_SCORE_FOR_NEW_SELLER = round(W_TRUST * 1.0 + W_DCR * PRIOR_MEAN + W_RESPONSE * 0.7, 4)


def deal_weight(age_days: float) -> float:
    """A deal's influence on DCR halves every HALF_LIFE_DAYS (§3.3)."""
    return math.exp(-math.log(2) * age_days / HALF_LIFE_DAYS)


def _compute_dcr_from_ages(completed_ages: List[float], leaked_ages: List[float]) -> float:
    """Pure function per §3.3's formula - kept separate from compute_dcr so it's testable without a DB."""
    w_completed = sum(deal_weight(a) for a in completed_ages)
    w_leaked    = sum(deal_weight(a) for a in leaked_ages)
    numerator   = w_completed + PRIOR_WEIGHT * PRIOR_MEAN
    denominator = w_completed + w_leaked + PRIOR_WEIGHT
    return round(100 * numerator / denominator, 1)


async def compute_dcr(seller_id: str, db: AsyncSession) -> float:
    """
    §3.1/§3.3: DCR for one seller, recency-weighted and Bayesian-smoothed.
    A seller with zero deal history returns exactly PRIOR_MEAN * 100 (80.0) -
    the cold-start fairness anchor §3.5 relies on.
    """
    now = datetime.utcnow()

    completed_r = await db.execute(
        select(Deal.created_at).where(
            Deal.seller_id == seller_id,
            Deal.status.in_(_FUNDED_STATUSES),
        )
    )
    completed_ages = [(now - ts).total_seconds() / 86400.0 for ts in completed_r.scalars().all()]

    leaked_r = await db.execute(
        select(Deal.created_at).where(
            Deal.seller_id == seller_id,
            Deal.leak_flag.is_(True),
        )
    )
    leaked_ages = [(now - ts).total_seconds() / 86400.0 for ts in leaked_r.scalars().all()]

    return _compute_dcr_from_ages(completed_ages, leaked_ages)


async def flag_leaked_deals(db: AsyncSession) -> int:
    """
    §3.2: flags deals as leaked when all three hold:
      1. Reached DealStatus.agreed (true of every Deal row - see database.py).
      2. No escrow payment within LEAK_WINDOW_DAYS of that (still sitting at
         `agreed` - anything in _FUNDED_STATUSES already proves payment
         happened, so is never a leak candidate).
      3. A corroborating signal - implemented as EITHER of:
           a. §2.2's off-platform-solicitation detector fired earlier in
              this exact thread (audit_logs joined back to the
              negotiation_messages row that triggered it), OR
           b. silence from both parties for a further SILENCE_WINDOW_DAYS
              AFTER the leak window closed - i.e. genuinely 12 days of
              elapsed time from agreement, with the back half of it silent,
              not just "silent recently while also >7 days old" (those
              aren't the same thing - a deal agreed on day 0 with a last
              message on day 1 would incorrectly qualify on day 7 under
              the latter reading, 5 days earlier than intended; fixed
              after an external audit caught it against this exact code).
         (Signal "listing marked sold outside BROKA" from the doc is not
         implemented - see module docstring.)

    Both evidence queries are scoped to messages at/after this specific
    deal's own created_at. NegotiationMessage has no deal_id foreign key,
    only (listing_id, buyer_id), and nothing in the schema stops the same
    buyer+listing pair from producing a second Deal row later (no
    UniqueConstraint on Deal for that pair) - without this scoping, a
    solicitation flag or silence from an EARLIER, already-resolved deal
    between the same two parties could wrongly count as evidence against
    a newer one. Same audit finding as the timing fix above.

    An agreed deal that fails #2 but has NO corroborating signal is left
    alone entirely (neither flagged nor counted) - it's "stale", not
    "leaked", exactly per §3.2's explicit intent not to penalise ordinary
    buyer indecision.

    Returns the number of deals newly flagged this run.

    Batches evidence lookups rather than querying per-candidate: with N
    candidates, the original version ran 2 queries per deal (2N round
    trips), which scales linearly with deal volume and would make this
    nightly job progressively slower - and hold the DB session open
    progressively longer - as the platform grows. Fetches all messages
    and all solicitation flags for every (listing_id, buyer_id) pair
    across the whole candidate batch in 2 queries total, then does the
    per-deal time-scoping in memory, where it's cheap.
    """
    now = datetime.utcnow()
    # A deal can't qualify until the FULL 7-day window plus the FULL
    # further 5-day silence period have both elapsed - 12 days total from
    # agreement, not 7. See docstring above for why this isn't the same
    # as the two windows checked independently against `now`.
    full_period_cutoff = now - timedelta(days=LEAK_WINDOW_DAYS + SILENCE_WINDOW_DAYS)

    candidates_r = await db.execute(
        select(Deal).where(
            Deal.status == DealStatus.agreed,
            Deal.leak_flag.is_(False),
            Deal.created_at <= full_period_cutoff,
        )
    )
    candidates = list(candidates_r.scalars().all())
    if not candidates:
        return 0

    pairs = list({(d.listing_id, d.buyer_id) for d in candidates})

    # One query: every message timestamp for every (listing_id, buyer_id)
    # pair this batch touches. Per-deal created_at scoping happens below,
    # in memory, against this already-fetched set.
    # visibility-ok: selects ids and timestamps only for trust scoring, no content
    messages_r = await db.execute(
        select(
            NegotiationMessage.listing_id, NegotiationMessage.buyer_id,
            NegotiationMessage.created_at,
        ).where(tuple_(NegotiationMessage.listing_id, NegotiationMessage.buyer_id).in_(pairs))
    )
    messages_by_pair: dict = {}
    for listing_id, buyer_id, created_at in messages_r.all():
        messages_by_pair.setdefault((listing_id, buyer_id), []).append(created_at)

    # One query: every off-platform-solicitation-flagged message's
    # timestamp for the same set of pairs.
    # visibility-ok: selects ids and timestamps only for trust scoring, no content
    solicitation_r = await db.execute(
        select(
            NegotiationMessage.listing_id, NegotiationMessage.buyer_id,
            NegotiationMessage.created_at,
        )
        .select_from(AuditLog)
        .join(NegotiationMessage, NegotiationMessage.id == AuditLog.resource_id)
        .where(
            AuditLog.action == "off_platform_solicitation_detected",
            tuple_(NegotiationMessage.listing_id, NegotiationMessage.buyer_id).in_(pairs),
        )
    )
    solicitations_by_pair: dict = {}
    for listing_id, buyer_id, created_at in solicitation_r.all():
        solicitations_by_pair.setdefault((listing_id, buyer_id), []).append(created_at)

    flagged = 0
    for deal in candidates:
        pair = (deal.listing_id, deal.buyer_id)
        window_close = deal.created_at + timedelta(days=LEAK_WINDOW_DAYS)

        # Signal (a): off-platform solicitation fired within THIS deal's
        # own thread (created_at >= deal.created_at - see docstring above
        # on why this scoping matters).
        had_solicitation_flag = any(
            t >= deal.created_at for t in solicitations_by_pair.get(pair, ())
        )

        # Signal (b): last message at/before window_close means silence
        # has genuinely persisted for the full SILENCE_WINDOW_DAYS since
        # the window closed - not just "quiet in the last 5 days".
        relevant_messages = [t for t in messages_by_pair.get(pair, ()) if t >= deal.created_at]
        last_message_at = max(relevant_messages) if relevant_messages else None
        extended_silence = (last_message_at is None) or (last_message_at <= window_close)

        if had_solicitation_flag or extended_silence:
            deal.leak_flag = True
            deal.leak_detected_at = now
            flagged += 1

    if flagged:
        await db.commit()
    return flagged


async def recompute_all_dcr(db: AsyncSession) -> int:
    """
    §3.3/§3.4: recomputes dcr_score + rank_score for every seller who has at
    least one listing (sellers with none have nothing to rank in search, so
    are skipped rather than given a meaningless SellerMetrics row).

    rank_score stores the SUM of the formula's first 3 weighted terms -
    W_TRUST*trust + W_DCR*dcr + W_RESPONSE*response, i.e. 0-0.80, NOT
    renormalised to 0-1. That's deliberate: it lets listings/service.py add
    its own W_FRESHNESS*freshness term at query time and get the exact
    same number §3.4's formula specifies (0.35*trust + 0.30*dcr +
    0.15*response + 0.20*freshness), rather than an approximation. The 4th
    component is inherently per-LISTING, not per-seller, so it can't live
    on this seller-level table - but the other three can be pre-computed
    here (the expensive, cross-deal-history part) while still summing to
    the real formula once freshness joins in at query time.

    (An earlier version of this function renormalised to a clean 0-1 scale
    and left listings/service.py to use it as an ORDER BY tiebreaker behind
    freshness. That was a mistake beyond just being an approximation: rank_
    score is a float, ties are rare, so a tiebreaker rarely actually fires -
    freshness had almost no practical effect on ordering at all. Caught by
    an external audit, fixed here by summing the true weighted terms
    instead of hiding one behind a tiebreaker.)

    response_time_score is a neutral placeholder (0.7) for every seller:
    despite the doc calling "average response time" an "existing metric,"
    grepping the repo turned up no such tracking anywhere - building it is
    a real, separate feature, not something this pass silently invented a
    half version of. The formula's shape is complete; this one input isn't
    live yet.

    Batches the DCR-computation queries across every seller in this run (2
    queries total) rather than calling compute_dcr() per seller (2 queries
    each, 2M round trips for M sellers) - same N+1 concern, and same fix
    shape, as flag_leaked_deals() above. compute_dcr() itself is untouched
    and still correct for a single ad-hoc lookup outside this batch path;
    this function just doesn't call it in a loop anymore. One smaller,
    lower-priority per-seller query remains below (db.get(SellerMetrics,
    user_id), to decide insert-vs-update) - left as-is rather than batched
    into a bulk upsert, since that would need Postgres-specific
    ON CONFLICT syntax and break on this app's SQLite dev default, for a
    cheap indexed primary-key lookup that isn't the expensive part of this
    function.
    """
    sellers_r = await db.execute(
        select(User.id, User.trust_score)
        .join(Listing, Listing.seller_id == User.id)
        .distinct()
    )
    sellers = sellers_r.all()
    if not sellers:
        return 0

    seller_ids = [s[0] for s in sellers]
    now = datetime.utcnow()

    completed_r = await db.execute(
        select(Deal.seller_id, Deal.created_at).where(
            Deal.seller_id.in_(seller_ids),
            Deal.status.in_(_FUNDED_STATUSES),
        )
    )
    completed_ages_by_seller: dict = {}
    for seller_id, created_at in completed_r.all():
        completed_ages_by_seller.setdefault(seller_id, []).append(
            (now - created_at).total_seconds() / 86400.0
        )

    leaked_r = await db.execute(
        select(Deal.seller_id, Deal.created_at).where(
            Deal.seller_id.in_(seller_ids),
            Deal.leak_flag.is_(True),
        )
    )
    leaked_ages_by_seller: dict = {}
    for seller_id, created_at in leaked_r.all():
        leaked_ages_by_seller.setdefault(seller_id, []).append(
            (now - created_at).total_seconds() / 86400.0
        )

    # Real response times, replacing the 0.7 placeholder that stood here
    # since this function was written.
    #
    # That constant was 15% of rank_score - which orders listings for every
    # buyer on the platform - and it was identical for all sellers, so a
    # sixth of the ranking signal carried no information at all. Sellers who
    # answered in minutes and sellers who never answered ranked the same on
    # the term that was supposed to separate them.
    #
    # Falls back to the old placeholder per-seller when there is not enough
    # message history to measure (domains/trust/response_time.MIN_OBSERVATIONS),
    # so a seller with three threads is not scored on one of them.
    from api.domains.trust.response_time import (
        compute_all_response_times, response_time_score,
    )
    RESPONSE_TIME_SCORE_PLACEHOLDER = 0.7  # still used where unmeasurable
    try:
        response_medians = await compute_all_response_times(db)
    except Exception as exc:
        logger.warning("[dcr] response-time measurement failed (%s) - "
                       "falling back to the neutral placeholder", exc)
        response_medians = {}

    processed = 0
    for user_id, trust_score in sellers:
        dcr = _compute_dcr_from_ages(
            completed_ages_by_seller.get(user_id, []),
            leaked_ages_by_seller.get(user_id, []),
        )

        trust_norm = (trust_score if trust_score is not None else 100) / 100.0
        dcr_norm = dcr / 100.0
        median_minutes = response_medians.get(user_id)
        response_norm = (response_time_score(median_minutes)
                         if median_minutes is not None
                         else RESPONSE_TIME_SCORE_PLACEHOLDER)
        rank_score = (
            W_TRUST * trust_norm + W_DCR * dcr_norm + W_RESPONSE * response_norm
        )  # deliberately NOT divided by combined_weight - see docstring

        existing = await db.get(SellerMetrics, user_id)
        if existing:
            existing.dcr_score  = dcr
            existing.rank_score = round(rank_score, 4)
            existing.updated_at = datetime.utcnow()
        else:
            db.add(SellerMetrics(
                user_id=user_id, dcr_score=dcr, rank_score=round(rank_score, 4),
            ))
        processed += 1

    await db.commit()
    logger.info("[completion_rate] recomputed DCR/rank_score for %d sellers", processed)
    return processed
