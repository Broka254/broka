"""Subscribes to BidPlaced and pushes it to every socket watching that
listing_id. Import this module for its side effect at startup (main.py
registration) — same pattern as deal_hub_subscribers.py.

FIX (redesign-guide audit, 2026-08-11): was registered via the legacy
api.core.events @subscribe bus. That bus only invokes in-process handlers
when REDIS_URL is unset (api/core/events.py _publish_inprocess) — the
moment Redis is configured, publish() routes to Redis Streams instead and
nothing ever reads the stream back out (consume_redis_stream exists but is
never called anywhere in the codebase), so this handler silently stopped
firing in exactly the "production-grade" config config.py's own startup
log recommends. Every publish(BidPlaced(...)) call (api/routers/auction.py)
already bridges to the Event Catalog via api.core.events._bridge_to_catalog
regardless of transport, and EventType.ORDER_BID_PLACED's catalog handlers
fire synchronously and unconditionally inside emit() — so migrating just
this file's registration (no call-site changes needed anywhere else) is
enough to restore live bid broadcasts under Redis.
"""
from __future__ import annotations

import logging
from datetime import datetime

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.core.auction_hub import auction_hub, BidUpdateEvent

logger = logging.getLogger(__name__)


@subscribe_to(EventType.ORDER_BID_PLACED)
async def on_bid_placed_broadcast(envelope: EventEnvelope) -> None:
    listing_id = envelope.payload.get("listing_id") or envelope.aggregate_id
    if not listing_id:
        return

    # Read the auction's real state back out rather than broadcasting only
    # the amount from the event. A watcher then gets current_bid, bid_count
    # and the next valid bid from one frame - and a client that missed a
    # frame is corrected by the next one instead of drifting.
    state = await _auction_state(listing_id)

    await auction_hub.broadcast(listing_id, BidUpdateEvent(
        type="bid_placed",
        listing_id=listing_id,
        bidder_id=envelope.payload.get("bidder_id", ""),
        amount=float(envelope.payload.get("amount") or 0.0),
        **state,
    ))


async def _auction_state(listing_id: str) -> dict:
    """Best-effort snapshot for a broadcast frame.

    Its own session: this runs inside emit(), which may be called from a
    request whose session is mid-transaction, and a broadcast must never
    interfere with the transaction that produced the event. Any failure
    returns an empty dict, so the client still gets the amount - a
    degraded frame beats no frame.
    """
    try:
        from sqlalchemy import select
        from api.database import AsyncSessionLocal, AuctionMeta, Listing
        from api.domains.auctions import lifecycle

        async with AsyncSessionLocal() as db:
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
            )).scalar_one_or_none()
            if meta is None:
                return {}
            listing = (await db.execute(
                select(Listing).where(Listing.id == listing_id)
            )).scalar_one_or_none()
            return {
                "current_bid": meta.current_bid,
                "bid_count": meta.bid_count or 0,
                "status": lifecycle.effective_status(meta),
                "min_next_bid": lifecycle.minimum_next_bid(meta),
                "reserve_met": lifecycle.reserve_met(
                    meta, listing.reserve_price if listing else None
                ),
                "server_time": datetime.utcnow().isoformat(),
            }
    except Exception as exc:
        logger.warning("[auction_hub] state snapshot failed listing=%s: %s", listing_id, exc)
        return {}


@subscribe_to(EventType.AUCTION_WON)
async def on_auction_won_broadcast(envelope: EventEnvelope) -> None:
    await _broadcast_close(envelope, outcome="won")


@subscribe_to(EventType.AUCTION_NO_SALE)
async def on_auction_no_sale_broadcast(envelope: EventEnvelope) -> None:
    await _broadcast_close(envelope, outcome=envelope.payload.get("outcome") or "no_sale")


async def _broadcast_close(envelope: EventEnvelope, outcome: str) -> None:
    """Tell everyone still watching that the auction is over.

    This is what makes the Flutter countdown safe to treat as decoration:
    the moment the server closes an auction, every connected watcher is
    told, regardless of what their local timer says. Clients that are NOT
    connected learn the same thing from the push notification and from the
    next read of the auction - the socket is the fast path, never the only
    one.
    """
    p = envelope.payload
    listing_id = p.get("listing_id") or envelope.aggregate_id
    if not listing_id:
        return
    await auction_hub.broadcast(listing_id, BidUpdateEvent(
        type="auction_closed",
        listing_id=listing_id,
        bidder_id="",
        amount=float(p.get("amount") or 0.0),
        status="ended",
        outcome=outcome,
        winner_id=p.get("user_id") if outcome == "won" else None,
        winning_amount=float(p["amount"]) if outcome == "won" and p.get("amount") else None,
        server_time=datetime.utcnow().isoformat(),
    ))
