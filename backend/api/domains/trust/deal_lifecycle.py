"""Deal lifecycle — what stage a deal is really at, and whose turn it is.

THE PROBLEM
===========
"Pending deals" drags a seller's rating, and `Deal.status == agreed` is a
poor definition of pending. A deal sits in that state whether:

  * the buyer and seller are actively negotiating,
  * the buyer asked one question and vanished,
  * the buyer found the item cheaper elsewhere and never said so,
  * or a competitor opened threads specifically to inflate a rival's backlog.

Only the first is the seller's problem. The other three punish a seller for
somebody else's behaviour, and the last is a cheap, deliberate attack on a
metric that feeds ranking — which makes it worth designing against rather
than hoping nobody notices.

MOST OF THIS NEEDS NO AI
========================
The user's instinct — classify deals with a model, triggered by message
count or elapsed time — is the right shape for the hard cases and the wrong
tool for the common ones. The message record already answers the question
that matters:

    Who spoke last, and how long ago?

If the last message was inbound to the seller and they have not replied, the
seller is the blocker. If the last message was the seller's and the buyer
has gone quiet, the buyer is. That is a timestamp comparison: free, instant,
deterministic, and auditable — a seller can be shown exactly why a deal was
attributed the way it was, which is not true of a model's opinion.

So this follows the same shape as `negotiation_actions.detect_action_fast`:
resolve what can be resolved cheaply, and reserve the model for the genuine
remainder. The estimate below is that Tier 1 settles the large majority of
deals, and the model is called only where both parties are recently active
with no escrow — the one case where "are they close to agreeing?" cannot be
read off the record.

WHY ATTRIBUTION MATTERS MORE THAN STAGE
=======================================
A precise stage ladder is useful for display. But the rating only needs one
question answered: *is this seller the reason the deal has not moved?* Stage
matters to that question only insofar as it says what the seller owes.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import Enum
from typing import Dict, List, Optional, Tuple

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)


class DealStage(str, Enum):
    """How far a deal actually got. Ordered; later stages imply earlier ones."""
    inquiry          = "inquiry"           # contact made, nothing agreed
    negotiating      = "negotiating"       # active back-and-forth
    agreed           = "agreed"            # a price both sides accepted
    awaiting_payment = "awaiting_payment"  # escrow initiated, not funded
    funded           = "funded"            # money held
    closed           = "closed"            # released / refunded / cancelled


class StallReason(str, Enum):
    """Whose turn it is — the part the rating actually depends on."""
    active         = "active"          # both parties recently engaged
    seller_blocked = "seller_blocked"  # buyer is waiting on the seller
    buyer_blocked  = "buyer_blocked"   # seller is waiting on the buyer
    abandoned      = "abandoned"       # neither has spoken in a long time
    closed         = "closed"          # terminal, not stalled at all


# A thread with no message from either side for this long is not a pending
# deal, it is a dead one. Two weeks is long enough that a slow but real
# negotiation survives it, and short enough that a ghost does not sit on a
# seller's record for a month.
ABANDONED_AFTER_DAYS = 14

# How long an unanswered inbound message may sit before the seller is
# considered the blocker. Shorter than ABANDONED_AFTER_DAYS on purpose:
# being slow is the seller's problem long before the deal is dead.
SELLER_BLOCKED_AFTER_HOURS = 24

# How long after the SELLER's last message before the buyer counts as quiet.
#
# Separate from SELLER_BLOCKED_AFTER_HOURS and longer, because the two are
# not symmetric: a seller owes a reply as a matter of service, while a buyer
# owes nothing at all and is entitled to think about it for a day.
BUYER_QUIET_AFTER_HOURS = 48

# Only deals that reached at least this stage can count against the seller.
#
# An inquiry that went nowhere is not a failed deal - it is a conversation
# that did not become one, and most of them never will. Counting them would
# mean a popular listing generating many casual questions looks worse than
# an ignored one, which inverts the incentive completely.
MIN_STAGE_FOR_BACKLOG = DealStage.negotiating

_STAGE_ORDER = [
    DealStage.inquiry, DealStage.negotiating, DealStage.agreed,
    DealStage.awaiting_payment, DealStage.funded, DealStage.closed,
]


def _at_least(stage: DealStage, minimum: DealStage) -> bool:
    return _STAGE_ORDER.index(stage) >= _STAGE_ORDER.index(minimum)


@dataclass(frozen=True)
class DealAssessment:
    deal_id: str
    stage: DealStage
    stall: StallReason
    last_message_at: Optional[datetime]
    last_message_role: Optional[str]
    message_count: int
    # True when this deal should count toward the seller's backlog penalty.
    counts_against_seller: bool
    # Set when the deterministic pass could not settle the stage and a model
    # classification would help. Nothing calls the model automatically.
    needs_ai_review: bool
    reason: str      # human-readable, shown to the seller if they ask


def assess(
    deal_status: str,
    escrow_funded: bool,
    messages: List[Tuple[str, datetime]],   # (role, created_at), oldest first
    now: Optional[datetime] = None,
) -> Tuple[DealStage, StallReason, bool, str]:
    """Stage, stall reason, whether it counts, and why. Pure function.

    `messages` carries only role and timestamp — no content. That is
    deliberate: attribution must not depend on reading what people said, so
    this stays cheap, testable, and free of the privacy questions that come
    with touching message bodies.
    """
    now = now or datetime.utcnow()

    # ── Terminal states settle everything ────────────────────────────────
    if deal_status in ("released", "refunded", "cancelled"):
        return (DealStage.closed, StallReason.closed, False,
                "This deal is finished.")
    if deal_status == "disputed":
        return (DealStage.funded, StallReason.closed, False,
                "Under dispute — handled separately from your backlog.")

    # ── Stage from hard facts first ──────────────────────────────────────
    if escrow_funded or deal_status == "paid":
        # Money is in escrow. Whatever happens next is delivery and
        # confirmation, not negotiation - so it is not a stalled deal and
        # must never count toward a backlog penalty. Returning early keeps
        # the message-based attribution below from mislabelling it as
        # "the buyer has gone quiet".
        return (DealStage.funded, StallReason.closed, False,
                "Payment is held in escrow — this is waiting on delivery, "
                "not on either of you to reply.")
    if deal_status == "agreed":
        stage = DealStage.agreed
    elif len(messages) >= 4:
        # Four messages is a conversation, not an enquiry. Deliberately a
        # count rather than a model call: "have they gone back and forth"
        # is exactly the kind of question a counter answers correctly and a
        # model answers expensively.
        stage = DealStage.negotiating
    else:
        stage = DealStage.inquiry

    if not messages:
        return (stage, StallReason.abandoned, False,
                "No conversation on this deal yet.")

    last_role, last_at = messages[-1][0], messages[-1][1]
    idle = now - last_at

    # ── Abandonment beats everything below it ────────────────────────────
    if idle > timedelta(days=ABANDONED_AFTER_DAYS):
        return (stage, StallReason.abandoned, False,
                f"No messages for {idle.days} days — treated as abandoned, "
                f"and it does not count against you.")

    # ── Whose turn is it? ────────────────────────────────────────────────
    #
    # Inbound to the seller = buyer or a Zeno relay addressed to them.
    seller_owes = last_role in ("buyer", "broker")

    if seller_owes:
        if idle > timedelta(hours=SELLER_BLOCKED_AFTER_HOURS):
            counts = _at_least(stage, MIN_STAGE_FOR_BACKLOG)
            return (stage, StallReason.seller_blocked, counts,
                    f"The buyer has been waiting {idle.days} day(s) for your "
                    f"reply." if counts else
                    "Waiting on your reply, but this never got past an "
                    "enquiry — it does not count against you.")
        return (stage, StallReason.active, False,
                "Waiting on your reply — still well within a normal "
                "response window.")

    # Seller spoke last. Whether that is "the buyer went quiet" or simply
    # "the conversation is in progress" depends on how long ago.
    if idle <= timedelta(hours=BUYER_QUIET_AFTER_HOURS):
        return (stage, StallReason.active, False,
                "Conversation in progress — the ball is with the buyer.")
    return (stage, StallReason.buyer_blocked, False,
            f"You replied and the buyer has been quiet for {idle.days} day(s). "
            f"This does not count against you.")


def needs_model_review(
    stage: DealStage, stall: StallReason, message_count: int,
    last_reviewed_at: Optional[datetime], now: Optional[datetime] = None,
) -> bool:
    """Should this deal be handed to the model?

    Only for the case the record cannot settle: both parties recently
    active, no escrow, and enough conversation that "did they agree a price
    and simply not press the button" is a real possibility. Everything else
    is already decided above, for free.

    Triggered on the thresholds described in the brief - a message-count
    step, or elapsed time - but gated by `last_reviewed_at` so a busy thread
    cannot bill repeatedly. That gate is what keeps this affordable: without
    it, a lively negotiation would re-classify on every message.
    """
    now = now or datetime.utcnow()

    if stall in (StallReason.closed, StallReason.abandoned):
        return False
    if stage in (DealStage.funded, DealStage.awaiting_payment, DealStage.closed):
        return False          # escrow already answered the question
    if message_count < 6:
        return False          # too little to read anything out of
    if last_reviewed_at and (now - last_reviewed_at) < timedelta(hours=24):
        return False          # one review per deal per day, at most

    return stall == StallReason.active


async def assess_seller_deals(
    db: AsyncSession, seller_id: str, now: Optional[datetime] = None,
) -> List[DealAssessment]:
    """Assess every open deal for one seller. One query for messages.

    Returns assessments in no particular order; callers that need the
    backlog count can filter on `counts_against_seller`.
    """
    from api.database import Deal, NegotiationMessage

    now = now or datetime.utcnow()

    deals_r = await db.execute(
        select(Deal).where(
            Deal.seller_id == seller_id,
            Deal.status.notin_(("released", "refunded", "cancelled")),
        ))
    deals = deals_r.scalars().all()
    if not deals:
        return []

    listing_ids = {d.listing_id for d in deals}
    buyer_ids = {d.buyer_id for d in deals}

    # visibility-ok: selects role and timestamp only, no message content is
    # read or returned - attribution deliberately never looks at what was said
    msgs_r = await db.execute(
        select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id,
               NegotiationMessage.role, NegotiationMessage.created_at)
        .where(NegotiationMessage.listing_id.in_(listing_ids),
               NegotiationMessage.buyer_id.in_(buyer_ids))
        .order_by(NegotiationMessage.created_at.asc()))

    threads: Dict[Tuple[str, str], List[Tuple[str, datetime]]] = {}
    for lid, bid, role, created in msgs_r.all():
        threads.setdefault((lid, bid), []).append((role, created))

    out: List[DealAssessment] = []
    for d in deals:
        msgs = threads.get((d.listing_id, d.buyer_id), [])
        status = d.status.value if hasattr(d.status, "value") else str(d.status)
        funded = status in ("paid", "disputed")
        stage, stall, counts, reason = assess(status, funded, msgs, now)
        out.append(DealAssessment(
            deal_id=d.id,
            stage=stage,
            stall=stall,
            last_message_at=msgs[-1][1] if msgs else None,
            last_message_role=msgs[-1][0] if msgs else None,
            message_count=len(msgs),
            counts_against_seller=counts,
            needs_ai_review=needs_model_review(
                stage, stall, len(msgs), None, now),
            reason=reason,
        ))
    return out


def fair_backlog_count(assessments: List[DealAssessment]) -> int:
    """Open deals the seller is actually the blocker on.

    This is what should feed the rating's backlog term, replacing a raw
    count of `status == agreed`. A seller cannot be held responsible for a
    buyer who stopped replying, and should not be punished by anyone who
    opens threads with no intention of buying.
    """
    return sum(1 for a in assessments if a.counts_against_seller)
