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

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.core.auction_hub import auction_hub, BidUpdateEvent


@subscribe_to(EventType.ORDER_BID_PLACED)
async def on_bid_placed_broadcast(envelope: EventEnvelope) -> None:
    listing_id = envelope.payload.get("listing_id") or envelope.aggregate_id
    if not listing_id:
        return
    await auction_hub.broadcast(listing_id, BidUpdateEvent(
        type="bid_placed",
        listing_id=listing_id,
        bidder_id=envelope.payload.get("bidder_id", ""),
        amount=float(envelope.payload.get("amount") or 0.0),
    ))
