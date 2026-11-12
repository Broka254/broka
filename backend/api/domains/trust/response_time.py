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
`recipient_role` and `created_at`, so the metric is derivable from history
that already exists — which also means it works retroactively, from day one
of the account, rather than starting at zero the day it ships.

WHAT IS MEASURED: THE FIRST MESSAGE (since 2026-11-12)
======================================================
One wait per conversation: from the buyer's FIRST message to the seller -
almost always "is this still available?" - to the seller's first reply.

It used to be every message: each buyer message after a seller's reply
started a new clock, and one still waiting at the end of a thread was
charged as an unanswered wait. That assumed every message needs an answer.
A buyer's "ok, thanks", a "👍", or a message after the deal was done never
did, and a seller who answered the question in minutes was charged up to
48 hours for not replying to "thanks". What a buyer deciding whether to
message a seller needs to know is how long the first answer takes, so that
is the whole of it now.

The first message is what the seller can SEE asking them something:

  * the buyer's own direct message - not their private words to Zeno
    (`via_ai`, which the seller never sees), not a call card (an answered
    call is a reply nobody types, and would be charged as silence), and
    not one the buyer deleted;
  * or Zeno's message to the seller on the buyer's behalf
    (`role='broker'`, `recipient_role='seller'`) - Zeno asking whether the
    item is still available, relaying the buyer, or the Buying Agent
    opening on someone's behalf. The clock starts when that lands, not
    when the buyer typed to Zeno.

A Zeno message to the BUYER is not an obligation on the seller, and a Zeno
row with no audience is shown to nobody (PRIVACY.md, fail-closed), so
neither starts it. Any message from the seller after the first ask stops
it: typed, through Zeno, a photo, or a call they made.

A conversation whose first ask is older than the window is left out
rather than restarted at whichever message falls inside it: that message
is the middle of a conversation, not its first question.

THE TRAP: SELLERS WHO NEVER REPLY
=================================
Measuring only answered messages scores a seller who ignores everyone as
having *no* response time — and "no data" sorts better than "slow". The
seller who replies in three days looks worse than the one who never replies
at all, which inverts the whole incentive.

So a first message never answered is included as a censored observation:
the time from it until now, capped at MAX_OBSERVATION_MINUTES. It is a lower
bound on the true wait — they might still reply — and a lower bound is the
honest thing to use when it is the seller's own silence producing it.

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

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

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

# Below this many conversations the average is noise. The rating's own
# evidence-weighting handles thin data, but returning None here keeps
# "unmeasured" distinguishable from "measured and fast".
MIN_OBSERVATIONS = 3


def _is_inbound_to_seller(role: str, recipient_role: Optional[str]) -> bool:
    """Did this message ask the seller something?

    The rows reaching the walk are already only the ones the seller can see
    (asks_the_seller below); this tells those apart from the seller's own.
    """
    if role == "buyer":
        return True
    if role == "broker":
        # A NULL audience is nobody (PRIVACY.md): the seller never saw it.
        return recipient_role == "seller"
    return False


def asks_the_seller(m=NegotiationMessage):
    """SQL: a message in a thread that the seller can see asking them
    something - the buyer's own direct message, or Zeno's to the seller.

    `m` is NegotiationMessage or an alias of it.
    """
    return or_(
        and_(
            m.role == "buyer",
            # The buyer's private words to Zeno: the seller never sees them.
            or_(m.via_ai.is_(False), m.via_ai.is_(None)),
            # A call is a conversation, not a message waiting for an answer.
            or_(m.msg_type.is_(None), m.msg_type != "call"),
            m.deleted_at.is_(None),
        ),
        and_(m.role == "broker", m.recipient_role == "seller"),
    )


def thread_rows_clause(since: datetime):
    """SQL: the rows the walk needs - a seller's messages and the ones
    asking them something, inside the window, in threads whose first ask
    is inside it too.

    A thread opened before `since` is left out whole: its first in-window
    ask would be the middle of a conversation, measured as if it were the
    start - the very "every message needs an answer" this module stopped
    assuming.
    """
    m = NegotiationMessage
    earlier = aliased(NegotiationMessage)
    # visibility-ok: an existence check on ids and timestamps only, no
    # message content is selected or reaches any user
    opened_before = select(earlier.id).where(
        earlier.listing_id == m.listing_id,
        earlier.buyer_id == m.buyer_id,
        earlier.created_at < since,
        asks_the_seller(earlier),
    ).exists()
    return and_(
        m.created_at >= since,
        or_(m.role == "seller", asks_the_seller(m)),
        ~opened_before,
    )


def compute_response_times(rows: List[tuple], now: datetime) -> Dict[str, float]:
    """Average first-reply minutes per seller, from ordered message rows.

    `rows` is (seller_id, listing_id, buyer_id, role, recipient_role,
    created_at), sorted by thread then time. Pure function — no DB — so the
    censoring and threading logic can be tested against fixtures without
    standing up a database.

    The grouping key is whatever the first element is. `compute_response_times_by`
    is the same walk for a different owner of the thread (a store), so the
    store rating cannot drift from the seller rating's timing rules.
    """
    return compute_response_times_by(rows, now)


def compute_response_times_by(rows: List[tuple], now: datetime) -> Dict[str, float]:
    """`compute_response_times`, grouping by the first tuple element.

    Same algorithm, same censoring, same 48 h cap, same MIN_OBSERVATIONS
    floor. Callers pass (seller_id, ...) for the seller record, or
    (store_id, ...) for a store's own record - a shop's reply speed must be
    measured from the threads about ITS products, not from everything its
    owner happens to answer.

    One observation per thread: from its first message asking the seller
    something to the seller's first message after it. Everything later in
    the thread is the conversation itself, not a question kept waiting.
    """
    per_owner: Dict[str, List[float]] = {}
    current_thread = None
    current_owner = None
    # When the thread's first ask landed, and whether the seller has
    # answered it. Nothing after the answer is read.
    opened_at: Optional[datetime] = None
    answered = False

    def _close_thread():
        """Charge the seller for a first message still unanswered."""
        if opened_at is not None and not answered and current_owner is not None:
            waited = (now - opened_at).total_seconds() / 60.0
            per_owner.setdefault(current_owner, []).append(
                min(max(waited, 0.0), MAX_OBSERVATION_MINUTES))

    for owner_id, listing_id, buyer_id, role, recipient_role, created_at in rows:
        thread = (listing_id, buyer_id)
        if thread != current_thread:
            _close_thread()
            current_thread, current_owner = thread, owner_id
            opened_at, answered = None, False

        if answered:
            continue
        if opened_at is None:
            # A seller writing first (before any ask) is not an answer to
            # anything; the clock starts at the first ask.
            if _is_inbound_to_seller(role, recipient_role):
                opened_at = created_at
            continue
        if role == "seller":
            gap = (created_at - opened_at).total_seconds() / 60.0
            per_owner.setdefault(owner_id, []).append(
                min(max(gap, 0.0), MAX_OBSERVATION_MINUTES))
            answered = True

    _close_thread()

    return {
        sid: round(statistics.fmean(times), 1)
        for sid, times in per_owner.items()
        if len(times) >= MIN_OBSERVATIONS
    }


async def compute_all_response_times(db: AsyncSession) -> Dict[str, float]:
    """Average first-reply minutes for every seller, over the rolling window.

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
        .where(thread_rows_clause(since))
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
