"""Emitting auction lifecycle events.

Kept out of lifecycle.py so that module stays purely about auction rules
and database state - and so a notification failure can never roll back a
bid or a close. Every function here is fire-and-forget: it is called after
the transaction that made the fact true has already committed.

These are Event Catalog emits (api.core.event_catalog), not the legacy
publish() bus, for the reason auction_hub_subscribers.py's own docstring
records: catalog handlers fire unconditionally inside emit() regardless of
whether Redis is configured, whereas the legacy bus silently stops
invoking in-process handlers the moment REDIS_URL is set - i.e. in
production.
"""
from __future__ import annotations

import logging
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.event_catalog import EventType, emit
from api.database import Bid

logger = logging.getLogger(__name__)


async def _safe_emit(event_type: EventType, **kwargs) -> bool:
    """Emit without ever raising. Returns whether it worked.

    Fire-and-forget is right for most of these - a push that fails must not
    roll back the bid or close that caused it - but "never raises" and
    "nobody can tell it failed" are different things, and the ending-soon
    reminder needs the second one: its sweep retries a failed delivery, and
    it can only do that if it is told. Callers that genuinely do not care
    ignore the return value, exactly as before.
    """
    try:
        await emit(event_type, **kwargs)
        return True
    except Exception as exc:
        logger.error("[auction] event emit failed type=%s: %s", event_type.value, exc)
        return False


async def emit_outbid(
    listing_id: str, listing_name: str, outbid_user_id: str, new_amount: float,
) -> None:
    await _safe_emit(
        EventType.AUCTION_OUTBID,
        aggregate="listing",
        aggregate_id=listing_id,
        actor="system",
        payload={
            "listing_id": listing_id,
            "listing_name": listing_name,
            "user_id": outbid_user_id,
            "amount": new_amount,
        },
    )


async def emit_ending_soon(
    listing_id: str, listing_name: str, user_ids: list[str], minutes_left: int,
) -> bool:
    """Returns True only if the event was actually emitted.

    The ending-soon sweep uses this to decide whether the reminder is still
    owed - see lifecycle.confirm_ending_soon_sent.
    """
    return await _safe_emit(
        EventType.AUCTION_ENDING_SOON,
        aggregate="listing",
        aggregate_id=listing_id,
        actor="system",
        payload={
            "listing_id": listing_id,
            "listing_name": listing_name,
            "user_ids": user_ids,
            "minutes_left": minutes_left,
        },
    )


async def emit_close_outcome(
    db: AsyncSession,
    listing_id: str,
    listing_name: str,
    seller_id: str,
    outcome: str,
    winner_id: Optional[str],
    winning_amount: Optional[float],
    deal_id: Optional[str],
    payment_deadline_iso: Optional[str],
) -> None:
    """One close, up to three audiences: the winner, everyone who lost, and
    the seller when nothing sold."""
    from .lifecycle import OUTCOME_WON

    bidder_ids = set((await db.execute(
        select(Bid.bidder_id).where(Bid.listing_id == listing_id)
    )).scalars().all())

    if outcome == OUTCOME_WON and winner_id:
        await _safe_emit(
            EventType.AUCTION_WON,
            aggregate="listing",
            aggregate_id=listing_id,
            actor="system",
            payload={
                "listing_id": listing_id,
                "listing_name": listing_name,
                "user_id": winner_id,
                "amount": winning_amount,
                "deal_id": deal_id or "",
                "payment_deadline": payment_deadline_iso or "",
            },
        )
        bidder_ids.discard(winner_id)

    if bidder_ids:
        await _safe_emit(
            EventType.AUCTION_LOST,
            aggregate="listing",
            aggregate_id=listing_id,
            actor="system",
            payload={
                "listing_id": listing_id,
                "listing_name": listing_name,
                "user_ids": sorted(bidder_ids),
                "outcome": outcome,
            },
        )

    if outcome != OUTCOME_WON:
        # The seller is the one who needs to know an auction produced no
        # sale, and why - "nobody bid" and "the bidding never reached your
        # reserve" are different problems with different next moves.
        await _safe_emit(
            EventType.AUCTION_NO_SALE,
            aggregate="listing",
            aggregate_id=listing_id,
            actor="system",
            payload={
                "listing_id": listing_id,
                "listing_name": listing_name,
                "user_id": seller_id,
                "outcome": outcome,
            },
        )


async def emit_payment_lapsed(
    listing_id: str, listing_name: str, seller_id: str, winner_id: Optional[str],
) -> None:
    await _safe_emit(
        EventType.AUCTION_PAYMENT_LAPSED,
        aggregate="listing",
        aggregate_id=listing_id,
        actor="system",
        payload={
            "listing_id": listing_id,
            "listing_name": listing_name,
            "seller_id": seller_id,
            "winner_id": winner_id or "",
        },
    )
