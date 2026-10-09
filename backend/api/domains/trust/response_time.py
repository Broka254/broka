"""Seller response time — measured, not guessed.

WHY THIS MODULE EXISTS
======================
`completion_rate.py` has scored every seller's response term at a hardcoded
0.7 since it was written, and says so in its own docstring:

    RESPONSE_TIME_SCORE_PLACEHOLDER = 0.7  # no response-time tracking exists yet

That constant is 15% of `rank_score` — which decides listing order for every
buyer on the platform — and 25% of the new Overall Rating. A quarter of the
number a seller is judged on has been the same value for all of them, which
makes it not a measurement but a rounding error with a name.

NO NEW INSTRUMENTATION
======================
Every message already carries `listing_id`, `buyer_id`, `role`,
`recipient_role` and `created_at`. A response time is the gap between a
message the seller owed an answer to and their next message in that thread,
so the whole metric is derivable from history that already exists — which
also means it works retroactively, from day one of the account, rather than
starting at zero the day it ships.

WHAT COUNTS AS "OWING AN ANSWER"
================================
Two kinds of inbound, because the buyer does not always reach the seller
directly:

  * a message from the buyer (direct chat), and
  * a Zeno message addressed to the seller (`role='broker'` and
    `recipient_role` of 'seller' or NULL) — in the mediated room the buyer
    talks to Zeno, Zeno relays, and the clock the seller controls starts
    when the relay lands, not when the buyer typed.

A Zeno message addressed to the BUYER is not an obligation on the seller and
is excluded, or every relay would start a clock the seller never saw.

THE TRAP: SELLERS WHO NEVER REPLY
=================================
Measuring only answered messages scores a seller who ignores everyone as
having *no* response time — and "no data" sorts better than "slow". The
seller who replies in three days looks worse than the one who never replies
at all, which inverts the whole incentive.

So an unanswered inbound is included as a censored observation: the time
from that message until now, capped at MAX_OBSERVATION_MINUTES. It is a
lower bound on the true wait — they might still reply — and a lower bound is
the honest thing to use when it is the seller's own silence producing it.

AVERAGE, NOT MEDIAN (since 2026-10-09)
======================================
The number is the seller's average response time: the mean of every
observation in the window. It used to be the median, which people read as
an average anyway, and which hid a seller's slow replies as long as most
were quick - half their buyers could wait a day and the figure would not
move. The mean counts every wait. The 48h cap (MAX_OBSERVATION_MINUTES) is
what keeps one abandoned thread from swamping it.

The field is still called `median_response_minutes` wherever it is stored
or sent (metric snapshots, the API, and older app builds read it by that
name); the value in it is the average.
"""
from __future__ import annotations

import logging
import statistics
from datetime import datetime, timedelta
from typing import Dict, List, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, NegotiationMessage

logger = logging.getLogger(__name__)

# Rolling window. Long enough to survive a quiet week, short enough that
# improving this month actually moves the number — which is the point of
# putting it in front of sellers at all.
WINDOW_DAYS = 30

# An unanswered thread stops accruing here. Beyond two days the exact
# figure adds nothing ("ignored for 3 days" and "ignored for 30" are the
# same signal to a buyer) and an uncapped value would let one abandoned
# thread dominate the average.
MAX_OBSERVATION_MINUTES = 2880.0   # 48h

# Below this many observations the average is noise. The rating's own
# evidence-weighting handles thin data, but returning None here keeps
# "unmeasured" distinguishable from "measured and fast".
MIN_OBSERVATIONS = 3


def _is_inbound_to_seller(role: str, recipient_role: Optional[str]) -> bool:
    """Did this message put the ball in the seller's court?"""
    if role == "buyer":
        return True
    if role == "broker":
        # NULL recipient = addressed to both, which includes the seller.
        return recipient_role in (None, "seller")
    return False


def compute_response_times(rows: List[tuple], now: datetime) -> Dict[str, float]:
    """Average response minutes per seller, from ordered message rows.

    `rows` is (seller_id, listing_id, buyer_id, role, recipient_role,
    created_at), sorted by thread then time. Pure function — no DB — so the
    censoring and threading logic can be tested against fixtures without
    standing up a database.
    """
    per_seller: Dict[str, List[float]] = {}
    # Thread state: the timestamp of the oldest inbound message still
    # waiting for a reply, or None if the seller is caught up.
    pending_since: Optional[datetime] = None
    current_thread = None
    current_seller = None

    def _close_thread():
        """Charge the seller for anything still unanswered in this thread."""
        if pending_since is not None and current_seller is not None:
            waited = (now - pending_since).total_seconds() / 60.0
            per_seller.setdefault(current_seller, []).append(
                min(waited, MAX_OBSERVATION_MINUTES))

    for seller_id, listing_id, buyer_id, role, recipient_role, created_at in rows:
        thread = (listing_id, buyer_id)
        if thread != current_thread:
            _close_thread()
            current_thread, current_seller, pending_since = thread, seller_id, None

        if _is_inbound_to_seller(role, recipient_role):
            # Only the FIRST unanswered inbound starts the clock. A buyer
            # sending five messages in a row is one wait, not five — and
            # counting each would punish the seller for the buyer's habits.
            if pending_since is None:
                pending_since = created_at
        elif role == "seller":
            if pending_since is not None:
                gap = (created_at - pending_since).total_seconds() / 60.0
                per_seller.setdefault(seller_id, []).append(
                    min(max(gap, 0.0), MAX_OBSERVATION_MINUTES))
                pending_since = None

    _close_thread()

    return {
        sid: round(statistics.fmean(times), 1)
        for sid, times in per_seller.items()
        if len(times) >= MIN_OBSERVATIONS
    }


async def compute_all_response_times(db: AsyncSession) -> Dict[str, float]:
    """Average response minutes for every seller, over the rolling window.

    One query for the whole platform, ordered so `compute_response_times`
    can walk it thread by thread in a single pass. Per-seller queries here
    would be the same N+1 that recompute_all_dcr was rewritten to avoid.
    """
    since = datetime.utcnow() - timedelta(days=WINDOW_DAYS)

    # visibility-ok: reads role/recipient_role/timestamps for timing only,
    # no message content is selected or returned to any user
    result = await db.execute(
        select(
            Listing.seller_id,
            NegotiationMessage.listing_id,
            NegotiationMessage.buyer_id,
            NegotiationMessage.role,
            NegotiationMessage.recipient_role,
            NegotiationMessage.created_at,
        )
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(NegotiationMessage.created_at >= since)
        .order_by(
            NegotiationMessage.listing_id,
            NegotiationMessage.buyer_id,
            NegotiationMessage.created_at,
        )
    )
    rows = result.all()
    if not rows:
        return {}

    medians = compute_response_times(rows, datetime.utcnow())
    logger.info("[response-time] measured %d sellers over %d days",
                len(medians), WINDOW_DAYS)
    return medians


def response_time_score(median_minutes: Optional[float]) -> float:
    """0-1 for completion_rate.py's rank formula.

    Delegates to the rating module so ranking and the seller-facing number
    cannot drift apart — two separate curves for the same concept is how a
    seller ends up improving their rating while their listings sink.
    """
    from api.domains.trust.seller_rating import response_score
    return response_score(median_minutes)
