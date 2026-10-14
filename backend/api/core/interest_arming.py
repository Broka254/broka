"""Arms the seller availability nudge from the buyer's own messages.

WHY THIS EXISTS
---------------
`task_check_interest_nudges` in core/workers.py is the sweep that sends a
seller the "is this still available?" SMS when a buyer has been waiting
~5 minutes. It is correct and has always been correct. It queries for
`Interest` rows whose `nudge_deadline` has passed, finds none, and returns
without logging — every 300 seconds, forever.

The reason it finds none: the only thing in the entire system that ever
set `nudge_deadline` was `ListingService.express_interest`, reached through
`POST /listings/{id}/interest`, and **no Flutter code path ever called it.**
`expressInterest` is declared twice on the client (api_service.dart:652 and
listings_repository.dart:158) and referenced from nowhere. Production logs
across a full buyer session show the thread being opened, polled, marked
read and re-opened, with no interest call anywhere:

    GET  /negotiate/{listing}/history
    GET  /negotiate/inbox/{user}
    POST /negotiate/{listing}/mark-read
    GET  /calls/pending/{listing}
    PATCH /auth/heartbeat

So the timer was never armed, and a feature that reads as implemented end
to end — model column, migration, sweep task, SMS templates, quiet-hours
handling, gender-aware wording — had no trigger attached to it.

WHY SERVER-SIDE
---------------
The obvious fix is to make the client call `/listings/{id}/interest`. That
recreates the same failure the moment any other entry point into a thread
is added, and there are already several (Zeno chat, direct chat, the
buy-agent flow). A buyer messaging a seller about a listing *is* the
expression of interest; deriving it from the message that already reaches
the server means every path arms the timer, including ones that do not
exist yet.

WHAT IT DOES NOT DO
-------------------
It does not re-arm on every message. Arming is once per (listing, buyer):
if a row already exists the deadline is left exactly as it was, so a buyer
sending five messages in a row does not push their own nudge five minutes
further away each time — which would mean the most engaged buyers are
precisely the ones whose sellers are never nudged.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta

from sqlalchemy import select

logger = logging.getLogger(__name__)

# Kept as a module constant rather than inlined so the sweep cadence in
# core/workers.py can be reasoned about against it. See NUDGE_SWEEP_SECONDS
# there: a deadline shorter than the sweep interval just waits for the next
# pass, so the two numbers need to be read together.
NUDGE_DELAY_MINUTES = 5


async def arm_availability_nudge(
    session,
    listing_id: str,
    buyer_id: str | None,
    seller_id: str | None = None,
) -> bool:
    """Ensure this (listing, buyer) has a nudge deadline running.

    Returns True if a new Interest row was created. Never raises: a failure
    to arm a reminder must not fail the buyer's message, which is the thing
    they actually asked for.

    Caller is responsible for the commit — this runs inside the request's
    existing transaction so the interest and the message land together or
    not at all.
    """
    if not listing_id or not buyer_id:
        return False
    # A seller messaging about their own listing is not a buyer lead.
    if seller_id and buyer_id == seller_id:
        return False

    try:
        from api.database import Interest

        existing = await session.execute(
            select(Interest.id).where(
                Interest.listing_id == listing_id,
                Interest.buyer_id == buyer_id,
            ).limit(1)
        )
        if existing.scalar_one_or_none() is not None:
            return False

        session.add(Interest(
            listing_id=listing_id,
            buyer_id=buyer_id,
            offer_price=None,
            nudge_deadline=datetime.utcnow() + timedelta(minutes=NUDGE_DELAY_MINUTES),
        ))
        logger.info(
            "[nudge] armed availability reminder listing=%s buyer=%s in %dm",
            listing_id, buyer_id, NUDGE_DELAY_MINUTES,
        )
        return True
    except Exception as exc:
        logger.warning(
            "[nudge] could not arm availability reminder listing=%s buyer=%s: %s",
            listing_id, buyer_id, exc,
        )
        return False
