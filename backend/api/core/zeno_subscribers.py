"""
BROKA Platform - Zeno Event Subscribers
════════════════════════════════════════════════════════════════════════════════
Zeno (Broka's AI) reacts to platform events instead of polling the database.
Each subscriber is a single-responsibility async handler that posts a
conversational message, schedules a follow-up, or enqueues a background task.

Wire at startup in main.py:
    import api.core.zeno_subscribers  # noqa: F401

Event → Zeno reaction
───────────────────────────────────────────────────────────────────────────────
LISTING.INTEREST_EXPRESSED
  → Tells seller  "A buyer wants to know if this is still available."
  → Tells buyer   "I've asked the seller to confirm."
    (If the seller stays silent, task_check_interest_nudges in workers.py
     follows up with a real SMS after ~5 minutes — this handler only sends
     the instant in-app message.)

PAYMENT.ESCROW_LOCKED
  → Tells seller  "Payment secured — you can now ship."
  → Tells buyer   "Funds are safe in escrow — awaiting delivery."

SHIPMENT.DELIVERY_CLAIMED
  → Tells buyer   "Seller says it's delivered. Confirm when you have it."
    (The countdown timer itself runs in workers.py sweep — Zeno only speaks.)

DISPUTE.OPENED
  → Tells opener  "Dispute received. Funds are safe. I'll investigate."
  → Tells other   "A dispute has been raised. Please share your side."

RATING.SUBMITTED
  → Enqueues async trust score recalculation for the reviewed seller.

FRAUD.FLAGGED
  → Enqueues trust score recalculation.
  → Logs for admin dashboard.

PAYMENT.RELEASED
  → Thanks buyer for confirming; congratulates seller on completed sale.

PAYMENT.REFUNDED
  → Informs buyer of refund and expected M-Pesa timeline.

────────────────────────────────────────────────────────────────────────────────
IMPORTANT: Zeno NEVER moves funds. It posts messages and schedules reminders.
           All actual fund movements are deterministic database operations
           performed exclusively by workers.py and the escrow service.
"""
from __future__ import annotations

import logging
from typing import Optional

from api.core.event_catalog import subscribe_to, EventType, EventEnvelope

logger = logging.getLogger(__name__)


# ══════════════════════════════════════════════════════════════════════════════
# Helpers
# ══════════════════════════════════════════════════════════════════════════════

async def _post_message(
    listing_id: str,
    recipient_role: str,
    buyer_id: str,
    content: str,
) -> None:
    """Append a broker message to the deal thread (visible in negotiate screen)."""
    try:
        from api.database import AsyncSessionLocal, NegotiationMessage
        async with AsyncSessionLocal() as session:
            msg = NegotiationMessage(
                listing_id=listing_id,
                sender_id="broker",
                role="broker",
                recipient_role=recipient_role,
                content=content,
                buyer_id=buyer_id,
                msg_type="text",
            )
            session.add(msg)
            await session.commit()
    except Exception as exc:
        logger.error("[zeno_sub] _post_message failed role=%s listing=%s: %s",
                     recipient_role, listing_id, exc)


async def _get_deal_and_users(deal_id: str):
    """Load deal + buyer + seller names. Returns (deal, buyer_first, seller_first)."""
    try:
        from api.database import AsyncSessionLocal, Deal, User
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            deal_r = await session.execute(select(Deal).where(Deal.id == deal_id))
            deal   = deal_r.scalar_one_or_none()
            if not deal:
                return None, "there", "there"
            buyer_r  = await session.execute(select(User).where(User.id == deal.buyer_id))
            seller_r = await session.execute(select(User).where(User.id == deal.seller_id))
            buyer    = buyer_r.scalar_one_or_none()
            seller   = seller_r.scalar_one_or_none()
            b_first  = (buyer.name.split()[0]  if buyer  and buyer.name  else "there")
            s_first  = (seller.name.split()[0] if seller and seller.name else "there")
        return deal, b_first, s_first
    except Exception as exc:
        logger.error("[zeno_sub] _get_deal_and_users failed deal=%s: %s", deal_id, exc)
        return None, "there", "there"


# ══════════════════════════════════════════════════════════════════════════════
# LISTING.INTEREST_EXPRESSED
# A buyer tapped "interested" on a listing. Zeno immediately asks the seller
# to confirm availability, and lets the buyer know they've reached out.
# nudge_deadline is set deterministically in ListingService.express_interest
# (not here) — if the seller stays silent, task_check_interest_nudges (the
# workers.py sweep) follows up with a real SMS after ~5 minutes. This
# handler only sends the instant in-app message.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.LISTING_INTEREST)
async def zeno_on_interest_expressed(envelope: EventEnvelope) -> None:
    payload    = envelope.payload
    listing_id = payload.get("listing_id") or envelope.aggregate_id
    buyer_id   = payload.get("buyer_id") or envelope.actor

    if not listing_id or not buyer_id:
        return

    try:
        from api.database import AsyncSessionLocal, Listing, User
        from sqlalchemy import select
        async with AsyncSessionLocal() as session:
            listing_r = await session.execute(select(Listing).where(Listing.id == listing_id))
            listing = listing_r.scalar_one_or_none()
            if not listing:
                return
            seller_r = await session.execute(select(User).where(User.id == listing.seller_id))
            buyer_r  = await session.execute(select(User).where(User.id == buyer_id))
            seller   = seller_r.scalar_one_or_none()
            buyer    = buyer_r.scalar_one_or_none()
            if not seller or not buyer:
                return
            s_first = seller.name.split()[0] if seller.name else "there"
            b_first = buyer.name.split()[0]  if buyer.name  else "A buyer"
            listing_name = listing.name

        await _post_message(
            listing_id     = listing_id,
            recipient_role = "seller",
            buyer_id       = buyer_id,
            content        = (
                f"{s_first}, {b_first} is interested in your listing '{listing_name}' "
                f"and wants to know: is it still available? Reply here to let them know — "
                f"if I don't hear back in a few minutes I'll follow up with you by SMS too."
            ),
        )

        await _post_message(
            listing_id     = listing_id,
            recipient_role = "buyer",
            buyer_id       = buyer_id,
            content        = (
                f"{b_first}, I've asked {s_first} to confirm this item is still available. "
                f"I'll let you know as soon as they reply."
            ),
        )

        logger.info("[zeno_sub] LISTING.INTEREST_EXPRESSED → listing=%s seller asked, buyer notified",
                     listing_id)
    except Exception as exc:
        logger.error("[zeno_sub] LISTING.INTEREST_EXPRESSED handler failed listing=%s: %s",
                     listing_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# PAYMENT.ESCROW_LOCKED
# Seller can now ship. Buyer's money is safe. Both parties get reassurance.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.PAYMENT_ESCROW_LOCKED)
async def zeno_on_escrow_locked(envelope: EventEnvelope) -> None:
    """
    Escrow has been funded. Zeno messages both parties:
      Seller → "Payment secured, you can ship now."
      Buyer  → "Funds are in escrow, awaiting delivery confirmation."
    """
    payload   = envelope.payload
    deal_id   = payload.get("deal_id") or envelope.aggregate_id
    amount    = payload.get("amount", 0)

    if not deal_id:
        return

    deal, b_first, s_first = await _get_deal_and_users(deal_id)
    if not deal:
        return

    try:
        from api.core.workflow import get_spec
        spec = get_spec(getattr(deal, "workflow_version", None))
        if not spec.zeno_auto_message_on_escrow:
            return

        # Message to seller
        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "seller",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{s_first}, great news — the buyer's payment of KES {amount:,.0f} "
                f"has been secured in escrow. "
                f"You can now ship or hand over the item safely. "
                f"Once the buyer confirms receipt, the funds will be released to you."
            ),
        )

        # Message to buyer
        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "buyer",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{b_first}, your payment of KES {amount:,.0f} has been secured in escrow. "
                f"The seller has been notified and will arrange delivery. "
                f"Once you receive the item, let me know and I'll release the funds."
            ),
        )

        logger.info("[zeno_sub] PAYMENT.ESCROW_LOCKED → deal=%s both parties messaged", deal_id)
    except Exception as exc:
        logger.error("[zeno_sub] PAYMENT.ESCROW_LOCKED handler failed deal=%s: %s", deal_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# SHIPMENT.DELIVERY_CLAIMED
# Seller says the item has been delivered. Zeno asks the buyer to confirm.
# The countdown timer is owned by workers.py — Zeno only provides the voice.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.SHIPMENT_DELIVERY_CLAIMED)
async def zeno_on_delivery_claimed(envelope: EventEnvelope) -> None:
    """
    Seller has claimed delivery. Zeno posts a conversational message
    prompting the buyer to confirm or raise a concern.
    """
    payload = envelope.payload
    deal_id = payload.get("deal_id") or envelope.aggregate_id

    if not deal_id:
        return

    deal, b_first, s_first = await _get_deal_and_users(deal_id)
    if not deal:
        return

    try:
        from api.core.workflow import get_spec
        spec = get_spec(getattr(deal, "workflow_version", None))
        if not spec.zeno_auto_message_on_delivery:
            return

        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "buyer",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{b_first}, {s_first} says your item has been delivered or is ready for pickup. "
                f"Please confirm once you have it so I can release the funds. "
                f"If there's any problem with the item, let me know immediately — "
                f"your escrow funds are protected until you're satisfied."
            ),
        )

        logger.info("[zeno_sub] SHIPMENT.DELIVERY_CLAIMED → deal=%s buyer notified", deal_id)
    except Exception as exc:
        logger.error("[zeno_sub] SHIPMENT.DELIVERY_CLAIMED handler failed deal=%s: %s", deal_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# DISPUTE.OPENED
# A dispute has been filed. Zeno reassures both parties immediately.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.DISPUTE_OPENED)
async def zeno_on_dispute_opened(envelope: EventEnvelope) -> None:
    """
    Dispute filed. Zeno posts to both parties:
      Opener → funds are safe, investigation underway
      Other  → asked to provide their side of the story
    """
    payload   = envelope.payload
    deal_id   = payload.get("deal_id") or envelope.aggregate_id
    opener_id = payload.get("opener_id") or envelope.actor

    if not deal_id:
        return

    deal, b_first, s_first = await _get_deal_and_users(deal_id)
    if not deal:
        return

    try:
        opener_is_buyer = (opener_id == deal.buyer_id)
        opener_first = b_first if opener_is_buyer else s_first
        other_first  = s_first if opener_is_buyer else b_first
        opener_role  = "buyer"  if opener_is_buyer else "seller"
        other_role   = "seller" if opener_is_buyer else "buyer"

        # Opener: reassurance
        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = opener_role,
            buyer_id       = deal.buyer_id,
            content        = (
                f"{opener_first}, I've received your dispute. "
                f"The funds in escrow are completely safe and will not move until this is resolved. "
                f"I've notified {other_first} and asked them to respond. "
                f"I'll review all the evidence and give you a fair outcome."
            ),
        )

        # Other party: asked to engage
        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = other_role,
            buyer_id       = deal.buyer_id,
            content        = (
                f"{other_first}, {opener_first} has raised a dispute on this deal. "
                f"Please share your side of the story so I can investigate fairly. "
                f"The escrow funds are on hold until we reach a resolution."
            ),
        )

        logger.info("[zeno_sub] DISPUTE.OPENED → deal=%s both parties notified", deal_id)
    except Exception as exc:
        logger.error("[zeno_sub] DISPUTE.OPENED handler failed deal=%s: %s", deal_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# PAYMENT.RELEASED
# Deal complete. Zeno thanks the buyer and congratulates the seller.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.PAYMENT_RELEASED)
async def zeno_on_payment_released(envelope: EventEnvelope) -> None:
    payload    = envelope.payload
    deal_id    = payload.get("deal_id") or envelope.aggregate_id
    amount     = payload.get("amount", 0)

    if not deal_id:
        return

    deal, b_first, s_first = await _get_deal_and_users(deal_id)
    if not deal:
        return

    try:
        net = amount * (1 - 0.03)  # approximate; exact figure from payload if available

        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "seller",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{s_first}, your payment of KES {amount:,.0f} has been released. "
                f"KES {net:,.0f} (after the platform commission) is on its way to your M-Pesa. "
                f"Thank you for completing the deal — your reputation has been updated."
            ),
        )

        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "buyer",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{b_first}, the deal is complete! "
                f"Funds have been released to the seller. "
                f"You can leave a review for {s_first} from your profile. "
                f"Thank you for using Broka."
            ),
        )

        logger.info("[zeno_sub] PAYMENT.RELEASED → deal=%s completion messages sent", deal_id)
    except Exception as exc:
        logger.error("[zeno_sub] PAYMENT.RELEASED handler failed deal=%s: %s", deal_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# PAYMENT.REFUNDED
# Escrow refunded. Zeno tells the buyer and informs the seller.
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.PAYMENT_REFUNDED)
async def zeno_on_payment_refunded(envelope: EventEnvelope) -> None:
    payload    = envelope.payload
    deal_id    = payload.get("deal_id") or envelope.aggregate_id
    amount     = payload.get("amount", 0)
    dispute_id = payload.get("dispute_id")

    if not deal_id:
        return

    deal, b_first, s_first = await _get_deal_and_users(deal_id)
    if not deal:
        return

    try:
        context = "following your dispute" if dispute_id else "as agreed"

        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "buyer",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{b_first}, your refund of KES {amount:,.0f} has been processed {context}. "
                f"It should arrive on your M-Pesa within a few minutes. "
                f"If you don't receive it within 24 hours, please contact support."
            ),
        )

        await _post_message(
            listing_id     = deal.listing_id,
            recipient_role = "seller",
            buyer_id       = deal.buyer_id,
            content        = (
                f"{s_first}, this deal has been refunded to {b_first} {context}. "
                f"If you believe this is an error, please contact Broka support with "
                f"your evidence and reference the deal ID."
            ),
        )

        logger.info("[zeno_sub] PAYMENT.REFUNDED → deal=%s refund messages sent", deal_id)
    except Exception as exc:
        logger.error("[zeno_sub] PAYMENT.REFUNDED handler failed deal=%s: %s", deal_id, exc)


# ══════════════════════════════════════════════════════════════════════════════
# RATING.SUBMITTED → trigger async reputation recalculation
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.RATING_SUBMITTED)
async def zeno_on_rating_submitted(envelope: EventEnvelope) -> None:
    """Enqueue trust score recalculation for the reviewed seller."""
    seller_id = envelope.payload.get("seller_id") or envelope.aggregate_id
    if not seller_id:
        return
    try:
        from api.core.workers import enqueue, task_recompute_trust_score
        from api.core.config import settings
        await enqueue(
            "fraud", task_recompute_trust_score,
            user_id=seller_id, db_url=settings.database_url,
        )
        logger.info("[zeno_sub] RATING.SUBMITTED → trust score recalc enqueued seller=%s", seller_id)
    except Exception as exc:
        logger.error("[zeno_sub] RATING.SUBMITTED trust score enqueue failed: %s", exc)


# ══════════════════════════════════════════════════════════════════════════════
# FRAUD.FLAGGED → enqueue trust score recalculation + admin alert
# ══════════════════════════════════════════════════════════════════════════════

@subscribe_to(EventType.FRAUD_FLAGGED)
async def zeno_on_fraud_flagged(envelope: EventEnvelope) -> None:
    """
    A fraud signal has been raised.
    Enqueues trust score recalculation.
    Logs the event prominently for admin visibility.
    """
    user_id = envelope.payload.get("user_id") or envelope.aggregate_id
    reason  = envelope.payload.get("reason", "unspecified")
    score   = envelope.payload.get("trust_score")

    if not user_id:
        return

    logger.warning(
        "[zeno_sub] FRAUD.FLAGGED user=%s reason=%s trust_score=%s",
        user_id, reason, score,
    )

    try:
        from api.core.workers import enqueue, task_recompute_trust_score
        from api.core.config import settings
        await enqueue(
            "fraud", task_recompute_trust_score,
            user_id=user_id, db_url=settings.database_url,
        )
    except Exception as exc:
        logger.error("[zeno_sub] FRAUD.FLAGGED trust score enqueue failed: %s", exc)
