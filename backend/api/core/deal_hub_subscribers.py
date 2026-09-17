"""
BROKA v3.0 - Deal Hub Event Subscribers
-----------------------------------------
Wires the domain event bus to the DealHub WebSocket broadcaster.
Import this module at startup (it's imported by main.py) so the
@subscribe_to decorators register before any requests arrive.

Each handler translates an Event Catalog envelope into a DealStatusEvent
and fans it out to all WebSocket clients watching that deal.

FIX (redesign-guide audit, 2026-08-11): every handler here was registered
on the legacy api.core.events @subscribe bus, which only invokes
in-process handlers when REDIS_URL is unset (see api/core/events.py
_publish_inprocess vs _publish_redis). The moment Redis is configured -
config.py's own startup log calls that "production-grade operation", i.e.
the recommended deploy config - publish() writes to a Redis Stream instead
and nothing ever reads it back out (consume_redis_stream exists but is
never called anywhere in this codebase). So every deal-status WebSocket
update (agreed / paid / released / refunded / disputed) silently stopped
reaching clients under the recommended production config, with no
exception or log to point at it. Moved every handler to the Event Catalog
(api.core.event_catalog), whose handlers fire unconditionally inside
emit() regardless of transport. Every publish(...) call this file depends
on (escrow/service.py, routers/mpesa.py) already bridges to a catalog
EventType on every call via api.core.events._bridge_to_catalog - no other
file needs to change for this fix to take effect.

Note (found during this same audit, not fixed here - out of scope for a
redesign-guide pass and touches core dispute/payment logic): nothing in
the codebase currently calls publish(EscrowRefunded(...)),
publish(DisputeOpened(...)), or publish(DisputeResolved(...)) - grep
confirms zero call sites for all three. Those three handlers below are
wired correctly but will not fire until something in the dispute
resolution flow(s) actually publishes those events. Preserved as-is
(not deleted) since they're correct and ready the moment a call site is
added; flagging honestly rather than silently leaving the impression they
already work end-to-end.
"""
from __future__ import annotations

import logging

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.core.deal_hub import deal_hub, DealStatusEvent
from api.core.ledger import ledger

logger = logging.getLogger(__name__)


# ── Helpers ───────────────────────────────────────────────────────────────────

async def _push(deal_id: str, status: str, detail: str = "", meta: dict | None = None) -> None:
    """Create a DealStatusEvent and broadcast it to the deal room."""
    event = DealStatusEvent(
        type="deal_status",
        deal_id=deal_id,
        status=status,
        detail=detail or None,
        meta=meta,
    )
    await deal_hub.broadcast(deal_id, event)
    logger.info("[deal_hub_sub] broadcast deal=%s status=%s", deal_id, status)


# ── Subscribers ───────────────────────────────────────────────────────────────

@subscribe_to(EventType.ORDER_AGREED)
async def on_deal_finalized(envelope: EventEnvelope) -> None:
    """Seller finalised the deal — status moves to 'agreed'."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    agreed_price = float(p.get("agreed_price") or 0.0)
    commission = float(p.get("commission") or 0.0)
    await _push(
        deal_id,
        "agreed",
        detail="Deal agreed — awaiting M-Pesa payment",
        meta={
            "agreed_price": agreed_price,
            "commission":   commission,
            "total_to_pay": agreed_price + commission,
        },
    )


@subscribe_to(EventType.PAYMENT_ESCROW_LOCKED)
async def on_escrow_funded(envelope: EventEnvelope) -> None:
    """M-Pesa payment confirmed — funds now held in escrow. Also records ledger entry."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    buyer_id = p.get("buyer_id", "")
    amount = float(p.get("amount") or 0.0)
    mpesa_receipt = p.get("mpesa_receipt", "")

    # Record double-entry ledger (issue #5)
    try:
        from api.database import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            async with db.begin():
                await ledger.record_escrow_funded(
                    db, deal_id, buyer_id, amount, mpesa_receipt,
                )
    except Exception as e:
        logger.error("[ledger] EscrowFunded record failed deal=%s: %s", deal_id, e)

    await _push(
        deal_id,
        "paid",
        detail="Payment received — funds held in escrow",
        meta={
            "amount":        amount,
            "mpesa_receipt": mpesa_receipt,
        },
    )


@subscribe_to(EventType.PAYMENT_RELEASED)
async def on_escrow_released(envelope: EventEnvelope) -> None:
    """Buyer confirmed delivery — funds released to seller. Also records ledger entry."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    amount = float(p.get("amount") or 0.0)

    try:
        from api.database import AsyncSessionLocal, Deal
        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            r = await db.execute(select(Deal).where(Deal.id == deal_id))
            deal = r.scalar_one_or_none()
            commission = deal.commission if deal else 0.0
            async with db.begin():
                await ledger.record_escrow_released(
                    db, deal_id, amount, commission
                )
    except Exception as e:
        logger.error("[ledger] EscrowReleased record failed deal=%s: %s", deal_id, e)

    await _push(
        deal_id,
        "released",
        detail="Delivery confirmed — funds released to seller ✓",
        meta={"amount": amount},
    )


@subscribe_to(EventType.PAYMENT_REFUNDED)
async def on_escrow_refunded(envelope: EventEnvelope) -> None:
    """Dispute resolved with refund — money returned to buyer. Also records ledger entry."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    amount = float(p.get("amount") or 0.0)
    dispute_id = p.get("dispute_id", "")

    try:
        from api.database import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            async with db.begin():
                await ledger.record_escrow_refunded(
                    db, deal_id, amount, dispute_id
                )
    except Exception as e:
        logger.error("[ledger] EscrowRefunded record failed deal=%s: %s", deal_id, e)

    await _push(
        deal_id,
        "refunded",
        detail="Dispute resolved — buyer refunded",
        meta={"amount": amount, "dispute_id": dispute_id},
    )


@subscribe_to(EventType.DISPUTE_OPENED)
async def on_dispute_opened(envelope: EventEnvelope) -> None:
    """A dispute was opened — funds frozen."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    issue_type = p.get("issue_type", "")
    dispute_id = p.get("dispute_id", "")
    await _push(
        deal_id,
        "disputed",
        detail=f"Dispute opened ({issue_type}) — funds frozen pending review",
        meta={"dispute_id": dispute_id},
    )


@subscribe_to(EventType.DISPUTE_RESOLVED)
async def on_dispute_resolved(envelope: EventEnvelope) -> None:
    """Admin resolved the dispute."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    resolution = p.get("resolution", "")
    dispute_id = p.get("dispute_id", "")
    resolution_labels = {
        "release": "Dispute resolved — funds released to seller",
        "refund":  "Dispute resolved — buyer refunded",
        "split":   "Dispute resolved — funds split between parties",
    }
    detail = resolution_labels.get(
        resolution,
        f"Dispute resolved ({resolution})",
    )
    await _push(
        deal_id,
        "dispute_resolved",
        detail=detail,
        meta={"resolution": resolution, "dispute_id": dispute_id},
    )


@subscribe_to(EventType.PAYMENT_MPESA_CALLBACK)
async def on_mpesa_callback(envelope: EventEnvelope) -> None:
    """
    M-Pesa STK callback arrived. We don't know the deal_id here directly
    (the callback gives us the checkout_request_id), so the mpesa router
    must also emit EscrowFunded after confirming the deal.
    This handler is a no-op but kept for observability logging.
    """
    p = envelope.payload
    logger.info(
        "[deal_hub_sub] M-Pesa callback cid=%s code=%s receipt=%s amount=%s",
        p.get("checkout_request_id"), p.get("result_code"),
        p.get("mpesa_receipt"), p.get("amount"),
    )
