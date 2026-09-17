"""
BROKA v3.0 - Push Notification Event Subscribers
--------------------------------------------------
Wires the domain event bus to FCM push notifications.
Import this at startup (done in main.py) — the @subscribe_to decorators
self-register on import.

For each deal event, we:
  1. Look up the FCM token of the recipient(s) in the DB
  2. Send a notification via push_service

Notifications are fire-and-forget — failures are logged, not raised.

FIX (redesign-guide audit, 2026-08-11): every handler here was registered
on the legacy api.core.events @subscribe bus, which only invokes
in-process handlers when REDIS_URL is unset (see api/core/events.py
_publish_inprocess vs _publish_redis). The moment Redis is configured -
config.py's own startup log calls that "production-grade operation", i.e.
the recommended deploy config - publish() writes to a Redis Stream instead
and nothing ever reads it back out (consume_redis_stream exists but is
never called anywhere in this codebase). So every push notification below
(deal agreed, payment received, funds released, review received, fraud
alert...) silently stopped sending under the recommended production
config, with no exception anywhere pointing at it. Moved every handler to
the Event Catalog (api.core.event_catalog), whose handlers fire
unconditionally inside emit() regardless of transport. Every publish(...)
call this file depends on already bridges to a catalog EventType on every
call via api.core.events._bridge_to_catalog - no other file needs to
change for this fix to take effect.

Note (found during this same audit, not fixed here - out of scope for a
redesign-guide pass and touches core dispute/verification logic): nothing
in the codebase currently calls publish(EscrowRefunded(...)),
publish(DisputeOpened(...)), publish(DisputeResolved(...)), or
publish(UserVerified(...)) - grep confirms zero call sites for all four.
Those four handlers below are wired correctly but will not fire until
something in the dispute-resolution / verification-upgrade flow(s)
actually publishes those events. Preserved as-is (not deleted) since
they're correct and ready the moment a call site is added.
"""
from __future__ import annotations

import logging

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope
from api.core.push import push_service

logger = logging.getLogger(__name__)


# ── Helper ────────────────────────────────────────────────────────────────────

async def _notify(user_id: str, title: str, body: str, data: dict) -> None:
    """Fetch FCM token for user and send notification."""
    try:
        from api.database import AsyncSessionLocal, User
        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            r = await db.execute(
                select(User.fcm_token).where(User.id == user_id)
            )
            row = r.one_or_none()
            token = row[0] if row else None

        if token:
            await push_service.send(token, title, body, data)
        else:
            logger.debug("[push_sub] No FCM token for user %s", user_id)
    except Exception as e:
        logger.error("[push_sub] Notify failed user=%s: %s", user_id, e)


# ── Deal Finalized — notify buyer ─────────────────────────────────────────────

@subscribe_to(EventType.ORDER_AGREED)
async def push_deal_finalized(envelope: EventEnvelope) -> None:
    """Tell the buyer the seller has agreed and they need to pay."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    await _notify(
        p.get("buyer_id", ""),
        title="🤝 Deal Agreed!",
        body="Your deal has been agreed. Tap to complete your M-Pesa payment.",
        data={
            "type":    "deal_status",
            "deal_id": deal_id,
            "status":  "agreed",
            "screen":  "deal_status",
        },
    )


# ── Escrow Funded — notify seller ─────────────────────────────────────────────

@subscribe_to(EventType.PAYMENT_ESCROW_LOCKED)
async def push_escrow_funded(envelope: EventEnvelope) -> None:
    """Tell the seller the buyer has paid — they can now deliver."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    amount_fmt = f"KES {float(p.get('amount') or 0.0):,.0f}"
    await _notify(
        p.get("seller_id", ""),
        title="💰 Payment Received!",
        body=f"{amount_fmt} is held in escrow. Please deliver the item now.",
        data={
            "type":    "deal_status",
            "deal_id": deal_id,
            "status":  "paid",
            "screen":  "deal_status",
        },
    )


# ── Escrow Released — notify seller ──────────────────────────────────────────

@subscribe_to(EventType.PAYMENT_RELEASED)
async def push_escrow_released(envelope: EventEnvelope) -> None:
    """Tell the seller the funds have been released."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    amount_fmt = f"KES {float(p.get('amount') or 0.0):,.0f}"
    await _notify(
        p.get("seller_id", ""),
        title="✅ Funds Released!",
        body=f"{amount_fmt} has been released to you. Leave a review to build trust.",
        data={
            "type":    "deal_status",
            "deal_id": deal_id,
            "status":  "released",
            "screen":  "deal_status",
        },
    )
    # Also nudge buyer to leave a review
    await _notify(
        p.get("buyer_id", ""),
        title="🌟 Deal Complete",
        body="Your delivery is confirmed! Leave a review for the seller.",
        data={
            "type":    "deal_status",
            "deal_id": deal_id,
            "status":  "released",
            "screen":  "review",
        },
    )


# ── Escrow Refunded — notify buyer ────────────────────────────────────────────

@subscribe_to(EventType.PAYMENT_REFUNDED)
async def push_escrow_refunded(envelope: EventEnvelope) -> None:
    """Tell the buyer their refund is being processed."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    amount_fmt = f"KES {float(p.get('amount') or 0.0):,.0f}"
    await _notify(
        p.get("buyer_id", ""),
        title="↩ Refund Processed",
        body=f"Your dispute was resolved in your favour. {amount_fmt} refund is being processed.",
        data={
            "type":       "deal_status",
            "deal_id":    deal_id,
            "dispute_id": p.get("dispute_id", ""),
            "status":     "refunded",
            "screen":     "deal_status",
        },
    )
    # Tell seller too
    await _notify(
        p.get("seller_id", ""),
        title="⚖️ Dispute Resolved",
        body="The dispute was resolved. The buyer has been refunded.",
        data={
            "type":    "deal_status",
            "deal_id": deal_id,
            "status":  "refunded",
            "screen":  "deal_status",
        },
    )


# ── Dispute Opened — notify the other party ───────────────────────────────────

@subscribe_to(EventType.DISPUTE_OPENED)
async def push_dispute_opened(envelope: EventEnvelope) -> None:
    """Notify the non-opener party that a dispute was filed."""
    # We don't know which party is the "other" without DB lookup.
    # The deal_hub_subscribers already know both parties — here we notify both
    # and let the app decide whether to show it.
    # In practice: opener already knows; we just notify the other side.
    # Without DB lookup here (to keep it light), we log and let the WS handle it.
    p = envelope.payload
    logger.info("[push_sub] Dispute opened deal=%s opener=%s",
                p.get("deal_id") or envelope.aggregate_id, p.get("opener_id"))


# ── Dispute Resolved — notify both parties ───────────────────────────────────

@subscribe_to(EventType.DISPUTE_RESOLVED)
async def push_dispute_resolved(envelope: EventEnvelope) -> None:
    """Notify both buyer and seller of the dispute outcome."""
    p = envelope.payload
    deal_id = p.get("deal_id") or envelope.aggregate_id
    resolution = p.get("resolution", "")
    resolution_labels = {
        "release": "Funds released to seller",
        "refund":  "Buyer refunded",
        "split":   "Funds split between parties",
    }
    body = resolution_labels.get(resolution, f"Outcome: {resolution}")

    # Look up deal to get both parties
    try:
        from api.database import AsyncSessionLocal, Deal
        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            r = await db.execute(select(Deal).where(Deal.id == deal_id))
            deal = r.scalar_one_or_none()

        if deal:
            for uid in {deal.buyer_id, deal.seller_id}:
                await _notify(
                    uid,
                    title="⚖️ Dispute Resolved",
                    body=body,
                    data={
                        "type":       "deal_status",
                        "deal_id":    deal_id,
                        "dispute_id": p.get("dispute_id", ""),
                        "status":     "dispute_resolved",
                        "screen":     "deal_status",
                    },
                )
    except Exception as e:
        logger.error("[push_sub] dispute_resolved notify error: %s", e)


# ── Review Submitted — notify seller ─────────────────────────────────────────

@subscribe_to(EventType.RATING_SUBMITTED)
async def push_review_submitted(envelope: EventEnvelope) -> None:
    p = envelope.payload
    rating = int(p.get("rating") or 0)
    stars = "⭐" * rating
    await _notify(
        p.get("seller_id", ""),
        title=f"New Review {stars}",
        body=f"Someone left you a {rating}-star review. Check your profile!",
        data={
            "type":   "review",
            "screen": "profile",
        },
    )


# ── User Verified — notify user ───────────────────────────────────────────────

@subscribe_to(EventType.AUTH_USER_VERIFIED)
async def push_user_verified(envelope: EventEnvelope) -> None:
    p = envelope.payload
    tier_labels = {
        "basic": "BROKA Verified",
        "gold":  "BROKA Gold",
    }
    label = tier_labels.get(p.get("tier", ""), "Verified")
    await _notify(
        p.get("user_id", ""),
        title=f"✅ {label} Badge Activated!",
        body="Your badge is now live on all your listings. Buyers trust verified sellers more.",
        data={
            "type":   "verification",
            "screen": "profile",
        },
    )


# ── Fraud Flagged — notify user ───────────────────────────────────────────────

@subscribe_to(EventType.FRAUD_FLAGGED)
async def push_fraud_flagged(envelope: EventEnvelope) -> None:
    """Warn user that their trust score was impacted."""
    p = envelope.payload
    trust_score = int(p.get("trust_score") or 0)
    user_id = p.get("user_id", "")
    if trust_score < 20:
        await _notify(
            user_id,
            title="⚠️ Account Restricted",
            body="Your account has been restricted. Contact BROKA support for assistance.",
            data={
                "type":   "fraud_flag",
                "screen": "profile",
            },
        )
    elif trust_score < 50:
        await _notify(
            user_id,
            title="⚠️ Trust Score Alert",
            body="Your trust score has dropped. Complete deals honestly to recover it.",
            data={
                "type":   "fraud_flag",
                "screen": "profile",
            },
        )
