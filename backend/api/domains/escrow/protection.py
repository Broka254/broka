"""Buyer protection: the seller's delivery claim, refund requests, and the
seller's statement of the price.

Everything here moves money only through a deterministic rule checked
against the database - never on Zeno's say-so. Zeno announces what is
happening (chat messages, push, SMS); the five-minute sweep
(api/core/workers.py, task_check_deal_timers) is what acts when a deadline
passes. The deadlines live in policy.py, which the app is shown too.

  * Delivery claim. The seller says the item was delivered (or the
    ownership documents handed over). The buyer then has
    policy.DELIVERY_GRACE_HOURS to release the money or report a problem;
    Zeno reminds them every 12 hours and texts them on days 2 and 3. If
    they stay silent the money is released to the seller.

  * Refund request. The buyer asks for their money back. Before any
    delivery claim, the seller is told at once (chat, push, SMS) and has
    policy.REFUND_RESPONSE_HOURS to accept or contest it; silence refunds
    the buyer - this is what protects a buyer whose seller disappears. After
    a delivery claim the buyer's word alone cannot undo the deal, so the
    request becomes a dispute.

  * Price statement. A buyer can pay before the seller has confirmed the
    price, and pay in parts (service.py, "Partial payments"). The seller
    states the price they agreed to, the buyer sees the balance, and either
    pays it or asks for a refund.

E-Confirm holds an E-Confirm deal's money, and BROKA has no refund call on
E-Confirm's API. An approved refund on such a deal therefore freezes it
(status disputed, so no release path can touch it), writes an audit row and
raises a reconciliation alert for the team to return the money through
E-Confirm; POST /admin/deals/{deal_id}/econfirm-refunded closes it once they
have (AGENTS.md: never settle an E-Confirm deal as if BROKA held the money).
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.reconciliation import report_reconciliation
from api.database import Deal, DealStatus, Listing, ListingType, NegotiationMessage, User
from api.models.external_escrow import ExternalEscrow, EConfirmEscrowStatus

from . import policy

logger = logging.getLogger(__name__)


def _quiet_hours() -> bool:
    """Texts wait for the morning (core/nudge_templates.is_quiet_hours).
    A module function so tests can fix the clock."""
    from api.core.nudge_templates import is_quiet_hours
    return is_quiet_hours()


def _kes(amount: float) -> str:
    return f"KES {amount:,.0f}"


# ── Notifications ──────────────────────────────────────────────────────────

def _zeno_says(db: AsyncSession, deal: Deal, to: str, text: str) -> None:
    """A Zeno message in the deal's chat thread, shown to `to` ("buyer" or
    "seller"). Added to the session; the caller commits."""
    db.add(NegotiationMessage(
        listing_id=deal.listing_id, sender_id="broker",
        role="broker", recipient_role=to,
        content=text, buyer_id=deal.buyer_id, msg_type="text",
    ))


async def _push(db: AsyncSession, user_id: str, title: str, body: str, deal: Deal, kind: str) -> None:
    """Best-effort push. A device without FCM still sees the Zeno message
    the next time the app polls its threads."""
    try:
        token = (await db.execute(select(User.fcm_token).where(User.id == user_id))).scalar_one_or_none()
        if not token:
            return
        from api.routers.calls import _send_fcm
        await _send_fcm(token, title, body, {
            "type": kind, "dealId": deal.id, "listingId": deal.listing_id,
        })
    except Exception as exc:
        logger.warning("[protection] push %s failed for deal %s: %s", kind, deal.id, exc)


async def _sms(db: AsyncSession, user_id: str, text: str, deal: Deal) -> bool:
    """Best-effort transactional SMS (not a premium Zeno text: it is about
    the user's own money). True if the provider accepted it."""
    try:
        phone = (await db.execute(select(User.phone).where(User.id == user_id))).scalar_one_or_none()
        if not phone:
            return False
        from api.core.sms import get_sms_provider
        return bool(await get_sms_provider().send(phone, text))
    except Exception as exc:
        logger.warning("[protection] SMS failed for deal %s: %s", deal.id, exc)
        return False


async def _item_name(db: AsyncSession, deal: Deal) -> str:
    name = (await db.execute(select(Listing.name).where(Listing.id == deal.listing_id))).scalar_one_or_none()
    return name or "the item"


async def _payments(db: AsyncSession, deal_id: str) -> list[ExternalEscrow]:
    r = await db.execute(
        select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
        .order_by(ExternalEscrow.payment_no)
        .execution_options(populate_existing=True)
    )
    return list(r.scalars().all())


def _held_amount(deal: Deal, payments) -> float:
    """What the buyer has in escrow on this deal: its payments for an
    E-Confirm deal, the price for one from before E-Confirm."""
    from .service import amount_paid
    return amount_paid(payments) if payments else deal.agreed_price


# ── Loading and locking ────────────────────────────────────────────────────

async def _deal_for(db: AsyncSession, deal_id: str, user_id: str, role: str) -> Deal:
    deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one_or_none()
    if deal is None:
        raise HTTPException(status_code=404, detail="Deal not found")
    owner = deal.buyer_id if role == "buyer" else deal.seller_id
    if owner != user_id:
        raise HTTPException(status_code=403, detail=f"Only the {role} can do this")
    return deal


async def _lock(db: AsyncSession, deal_id: str, statuses: tuple) -> Deal:
    from .service import lock_deal_if_status
    locked = await lock_deal_if_status(db, deal_id, statuses)
    if locked is None:
        await db.commit()
        raise HTTPException(status_code=409, detail="This deal has just changed - please refresh")
    return locked


def _releasing(payments) -> bool:
    """A payout has been asked for: a refund can no longer stop it."""
    return any(p.status in (EConfirmEscrowStatus.RELEASE_PENDING, EConfirmEscrowStatus.COMPLETED)
               for p in payments)


async def _deal_response(db: AsyncSession, deal_id: str, user_id: str) -> dict:
    from .service import EscrowService
    return await EscrowService(db).get_deal(deal_id, user_id)


# ── Delivery claim ─────────────────────────────────────────────────────────

async def start_delivery_claim(db: AsyncSession, deal: Deal, now: datetime) -> str:
    """The seller says the item was delivered. `deal` is locked at `paid` by
    the caller, who commits. Returns "started", "running" (a claim is
    already counting down, and a second tap does not restart the clock), or
    "disputed".

    A seller answering an open refund request by claiming delivery is
    contesting it: the deal goes to a dispute, never to the countdown. If
    it started the countdown instead, a seller could answer every refund
    request with "delivered" and collect three days later.
    """
    if policy.refund_request_open(deal):
        _contest(db, deal, now, "seller_contested")
        _zeno_says(db, deal, "buyer",
                   "The seller says your item was delivered, so your refund request is now a "
                   "dispute. The money stays in escrow - nothing moves until it is resolved. "
                   "Tell me what happened, and add photos if you have them.")
        _zeno_says(db, deal, "seller",
                   "You said the item was delivered while the buyer's refund request was open, "
                   "so this is now a dispute. The money stays in escrow until it is resolved - "
                   "please share proof of delivery here.")
        return "disputed"
    if policy.auto_release_at(deal) is not None:
        return "running"
    deal.seller_claimed_delivery_at = now
    deal.checkin_count = 0
    deal.last_checkin_at = None
    deal.reminder_sms_count = 0
    deal.timer_type = "seller_claimed_delivery"
    # The sweep paces the reminders itself from seller_claimed_delivery_at;
    # a deadline at now keeps the deal in its query on every pass.
    deal.timer_deadline = now
    deal.timer_cancelled_at = None
    deal.timer_fired_at = None
    hours = policy.DELIVERY_GRACE_HOURS
    _zeno_says(db, deal, "buyer",
               f"The seller says your order has been delivered. Please check it, then release "
               f"the payment - or tell me if something is wrong (report a problem or ask for a "
               f"refund). If I don't hear from you within {hours // 24} days, the money in escrow "
               f"will be released to the seller automatically.")
    return "started"


async def mark_delivered(db: AsyncSession, deal_id: str, seller_id: str,
                         request_ip: Optional[str] = None) -> dict:
    """POST /deal/{deal_id}/mark-delivered."""
    deal = await _deal_for(db, deal_id, seller_id, "seller")
    if deal.status != DealStatus.paid:
        raise HTTPException(status_code=400,
                            detail=f"Only a paid deal can be marked delivered (this one is '{deal.status.value}')")
    deal = await _lock(db, deal_id, (DealStatus.paid,))
    now = datetime.utcnow()
    outcome = await start_delivery_claim(db, deal, now)
    await record_audit(db, seller_id, "delivery_claimed", "deal", deal_id,
                       f"outcome={outcome}", ip_address=request_ip)
    await db.commit()
    if outcome == "started":
        await _push(db, deal.buyer_id, "Your order has been delivered",
                    "The seller says it was delivered. Please confirm and release the payment, "
                    "or report a problem.", deal, "delivery_claimed")
    elif outcome == "disputed":
        await _push(db, deal.buyer_id, "Your refund request is now a dispute",
                    "The seller says the item was delivered. Open BROKA to respond.",
                    deal, "refund_contested")
    result = await _deal_response(db, deal_id, seller_id)
    result["outcome"] = outcome
    return result


async def process_delivery_claim(session: AsyncSession, deal: Deal, now: datetime) -> bool:
    """One sweep pass over a running delivery claim (deal locked at `paid`).
    Sends the reminders that are due, and releases the money when the grace
    period is over. Returns True when it is time to release - the caller
    does the release, since an E-Confirm release is a provider call that
    must not run under the sweep's row locks."""
    claimed_at = deal.seller_claimed_delivery_at
    if claimed_at is None:
        # Shouldn't happen, but fail safe - don't release without a claim.
        deal.timer_cancelled_at = now
        return False
    elapsed = policy.hours_since(claimed_at, now)
    if elapsed >= policy.DELIVERY_GRACE_HOURS:
        deal.timer_fired_at = now
        return True

    due = policy.due_count(policy.DELIVERY_REMINDER_HOURS, elapsed)
    if (deal.checkin_count or 0) < due:
        # A sweep that missed a reminder (downtime) sends one, not a burst.
        deal.checkin_count = due
        deal.last_checkin_at = now
        left = policy.DELIVERY_GRACE_HOURS - elapsed
        final = due >= len(policy.DELIVERY_REMINDER_HOURS)
        when = f"in about {round(left)} hours" if left < 24 else f"in about {round(left / 24)} day(s)"
        text = (
            ("Final reminder: " if final else "Reminder: ")
            + "the seller says your order was delivered. Please release the payment if all is "
            f"well, or report a problem. Otherwise the money will be released to the seller "
            f"automatically {when}."
        )
        _zeno_says(session, deal, "buyer", text)
        await _push(session, deal.buyer_id,
                    "Final reminder: confirm your delivery" if final else "Did your order arrive?",
                    text, deal, "delivery_checkin")

    sms_due = policy.due_count(policy.DELIVERY_SMS_HOURS, elapsed)
    if (deal.reminder_sms_count or 0) < sms_due and not _quiet_hours():
        payments = await _payments(session, deal.id)
        left_hours = round(policy.DELIVERY_GRACE_HOURS - elapsed)
        item = await _item_name(session, deal)
        text = (f"BROKA: The seller says {item} was delivered. Open BROKA to release the "
                f"payment or report a problem. {_kes(_held_amount(deal, payments))} in escrow "
                f"will be released to the seller in about {left_hours} hours if we don't hear "
                f"from you.")
        if await _sms(session, deal.buyer_id, text, deal):
            deal.reminder_sms_count = sms_due
    deal.timer_deadline = now
    return False


# ── Refund request ─────────────────────────────────────────────────────────

def _contest(db: AsyncSession, deal: Deal, now: datetime, outcome: str) -> None:
    """End a refund request in a dispute: the money is frozen (status
    disputed - nothing automatic releases or refunds it) until the dispute
    is resolved."""
    deal.refund_outcome = outcome
    deal.refund_resolved_at = now
    deal.status = DealStatus.disputed
    if deal.timer_fired_at is None:
        deal.timer_cancelled_at = now


async def approve_refund(session: AsyncSession, deal: Deal, outcome: str, now: datetime,
                         actor_id: str = "system") -> str:
    """Refund the buyer. `deal` is locked at `paid`; the caller commits (and
    publishes the session's queued events - see core/workers.py).

    Returns "refunded" when BROKA paid it, "refund_pending" when E-Confirm
    holds the money and the team returns it by hand.
    """
    deal.refund_outcome = outcome
    deal.refund_resolved_at = now
    if deal.timer_fired_at is None:
        deal.timer_cancelled_at = deal.timer_cancelled_at or now
    payments = await _payments(session, deal.id)
    held = _held_amount(deal, payments)
    if payments:
        # E-Confirm holds this money; there is no refund call to make. Frozen
        # as disputed so no release path can pay the seller meanwhile.
        deal.status = DealStatus.disputed
        reason = (f"refund approved ({outcome}) - return {_kes(held)} to the buyer through "
                  f"E-Confirm, then POST /admin/deals/{deal.id}/econfirm-refunded")
        await record_audit(session, actor_id, "econfirm_refund_required", "deal", deal.id, reason)
        report_reconciliation("econfirm_refund_required", deal_id=deal.id, reason=reason)
        result = "refund_pending"
    else:
        # A deal from before E-Confirm: the same refund the sweep's
        # seller-silence timer has always made.
        from api.core.workers import _fire_auto_refund
        await _fire_auto_refund(session, deal)
        result = "refunded"
    await record_audit(session, actor_id, "refund_approved", "deal", deal.id,
                       f"outcome={outcome} amount={held} result={result}")
    why = {
        "seller_accepted": "The seller accepted your refund request.",
        "seller_silent": "The seller did not respond to your refund request in time.",
    }.get(outcome, "Your refund request was approved.")
    when = ("It is on its way to you." if result == "refunded" else
            "Our team is returning it to you through the escrow provider - you'll get it shortly.")
    _zeno_says(session, deal, "buyer", f"{why} Your money ({_kes(held)}) is being refunded. {when}")
    _zeno_says(session, deal, "seller",
               f"The buyer's refund request was approved ({why.rstrip('.').lower()}), so the "
               f"{_kes(held)} in escrow is going back to them and this deal is closed.")
    return result


async def request_refund(db: AsyncSession, deal_id: str, buyer_id: str, reason: str,
                         request_ip: Optional[str] = None) -> dict:
    """POST /deal/{deal_id}/refund-request."""
    deal = await _deal_for(db, deal_id, buyer_id, "buyer")
    if deal.status == DealStatus.agreed:
        raise HTTPException(status_code=400, detail="Nothing has been paid on this deal yet")
    if deal.status != DealStatus.paid:
        raise HTTPException(status_code=400,
                            detail=f"A refund can't be requested on a deal that is '{deal.status.value}'")
    if policy.refund_request_open(deal):
        return await _deal_response(db, deal_id, buyer_id)
    if _releasing(await _payments(db, deal_id)):
        raise HTTPException(status_code=409, detail="The money is already being released to the seller")

    deal = await _lock(db, deal_id, (DealStatus.paid,))
    now = datetime.utcnow()
    item = await _item_name(db, deal)
    payments = await _payments(db, deal_id)
    held = _held_amount(deal, payments)
    deal.refund_requested_at = now
    deal.refund_reason = reason
    deal.refund_outcome = None
    deal.refund_resolved_at = None

    if deal.seller_claimed_delivery_at is not None:
        # The seller has said it was delivered. The buyer's word alone
        # cannot undo that, so it is a dispute (the money stays frozen until
        # it is resolved), not a countdown to a refund.
        _contest(db, deal, now, "delivery_disputed")
        _zeno_says(db, deal, "buyer",
                   "The seller has already said this was delivered, so I've opened a dispute "
                   "instead of a refund. The money stays in escrow - nothing moves until it is "
                   "resolved. Tell me what happened, and add photos if you have them.")
        _zeno_says(db, deal, "seller",
                   f"The buyer says there is a problem with {item} and has asked for their money "
                   f"back. As you'd marked it delivered, this is now a dispute: the money stays in "
                   f"escrow until it is resolved. Please explain here, with proof of delivery.")
        await record_audit(db, buyer_id, "refund_requested", "deal", deal_id,
                           "outcome=delivery_disputed", ip_address=request_ip)
        await db.commit()
        await _push(db, deal.seller_id, "The buyer has opened a dispute",
                    f"About {item}. Open BROKA to respond.", deal, "deal_disputed")
        result = await _deal_response(db, deal_id, buyer_id)
        result["outcome"] = "disputed"
        return result

    hours = policy.REFUND_RESPONSE_HOURS
    deal.timer_type = "refund_request"
    deal.timer_deadline = now
    deal.timer_cancelled_at = None
    deal.timer_fired_at = None
    deal.checkin_count = 0
    deal.last_checkin_at = None
    deal.reminder_sms_count = 0
    _zeno_says(db, deal, "seller",
               f"The buyer has asked for a refund of {_kes(held)} for {item}"
               + (f': "{reason}"' if reason else ".")
               + f" Please accept it, or explain why not, within {hours} hours. If I don't hear "
               f"from you by then, the buyer will be refunded automatically.")
    _zeno_says(db, deal, "buyer",
               f"I've told the seller you want a refund. They have {hours} hours to respond; if "
               f"they don't, I'll refund you automatically.")
    await record_audit(db, buyer_id, "refund_requested", "deal", deal_id,
                       f"amount={held}", ip_address=request_ip)
    await db.commit()

    await _push(db, deal.seller_id, "The buyer wants a refund",
                f"Respond within {hours} hours or the buyer will be refunded automatically.",
                deal, "refund_requested")
    # The first text goes now unless it is the middle of the night; the
    # sweep sends it in the morning otherwise (Deal.reminder_sms_count).
    if not _quiet_hours():
        sent = await _sms(db, deal.seller_id,
                          f"BROKA: The buyer has asked for a refund of {_kes(held)} for {item}. "
                          f"Open BROKA within {hours} hours to accept or explain, or they will be "
                          f"refunded automatically.", deal)
        if sent:
            from .service import lock_deal_if_status
            fresh = await lock_deal_if_status(db, deal_id, (DealStatus.paid,))
            if fresh is not None:
                fresh.reminder_sms_count = max(fresh.reminder_sms_count or 0, 1)
            await db.commit()
    result = await _deal_response(db, deal_id, buyer_id)
    result["outcome"] = "requested"
    return result


async def respond_to_refund(db: AsyncSession, deal_id: str, seller_id: str, accept: bool,
                            note: Optional[str] = None, request_ip: Optional[str] = None) -> dict:
    """POST /deal/{deal_id}/refund-response: the seller accepts the refund,
    or contests it (a dispute)."""
    deal = await _deal_for(db, deal_id, seller_id, "seller")
    if not policy.refund_request_open(deal):
        raise HTTPException(status_code=400, detail="There is no open refund request on this deal")
    deal = await _lock(db, deal_id, (DealStatus.paid,))
    if not policy.refund_request_open(deal):
        await db.commit()
        raise HTTPException(status_code=409, detail="This refund request has just been resolved - please refresh")
    now = datetime.utcnow()
    # The note goes to the audit record, not into the buyer's chat: it is
    # free text from one party, which the chat's own contact-leak checks
    # (core/text_guard.py) would otherwise be skipped for.
    detail = f"accept={accept}" + (f" note={note!r}" if note else "")
    if accept:
        await record_audit(db, seller_id, "refund_accepted", "deal", deal_id, detail, ip_address=request_ip)
        outcome = await approve_refund(db, deal, "seller_accepted", now, actor_id=seller_id)
    else:
        _contest(db, deal, now, "seller_contested")
        _zeno_says(db, deal, "buyer",
                   "The seller doesn't agree to the refund, so this is now a dispute. The money "
                   "stays in escrow until it is resolved - tell me what happened, and add photos "
                   "if you have them.")
        _zeno_says(db, deal, "seller",
                   "Thanks - this is now a dispute. The money stays in escrow until it is "
                   "resolved. Please explain here what was agreed and share any proof.")
        await record_audit(db, seller_id, "refund_contested", "deal", deal_id, detail, ip_address=request_ip)
        outcome = "disputed"
    await db.commit()
    from api.core.workers import _publish_queued_events
    await _publish_queued_events(db)
    await _push(db, deal.buyer_id,
                "Refund accepted" if accept else "The seller contested your refund",
                "Open BROKA for the details.", deal, "refund_response")
    result = await _deal_response(db, deal_id, seller_id)
    result["outcome"] = outcome
    return result


async def withdraw_refund(db: AsyncSession, deal_id: str, buyer_id: str,
                          request_ip: Optional[str] = None) -> dict:
    """DELETE /deal/{deal_id}/refund-request."""
    deal = await _deal_for(db, deal_id, buyer_id, "buyer")
    if not policy.refund_request_open(deal):
        raise HTTPException(status_code=400, detail="There is no open refund request on this deal")
    deal = await _lock(db, deal_id, (DealStatus.paid,))
    if not policy.refund_request_open(deal):
        await db.commit()
        raise HTTPException(status_code=409, detail="This refund request has just been resolved - please refresh")
    now = datetime.utcnow()
    deal.refund_outcome = "withdrawn"
    deal.refund_resolved_at = now
    if deal.timer_type == "refund_request" and deal.timer_fired_at is None:
        deal.timer_cancelled_at = now
    _zeno_says(db, deal, "seller", "The buyer has withdrawn their refund request. The deal carries on as before.")
    await record_audit(db, buyer_id, "refund_withdrawn", "deal", deal_id, "", ip_address=request_ip)
    await db.commit()
    return await _deal_response(db, deal_id, buyer_id)


async def process_refund_request(session: AsyncSession, deal: Deal, now: datetime) -> None:
    """One sweep pass over an open refund request (deal locked at `paid`):
    the seller's reminders, and the refund when they stayed silent."""
    if not policy.refund_request_open(deal):
        deal.timer_cancelled_at = now
        return
    elapsed = policy.hours_since(deal.refund_requested_at, now)
    if elapsed >= policy.REFUND_RESPONSE_HOURS:
        deal.timer_fired_at = now
        await approve_refund(session, deal, "seller_silent", now)
        return

    left = round(policy.REFUND_RESPONSE_HOURS - elapsed)
    due = policy.due_count(policy.REFUND_REMINDER_HOURS, elapsed)
    if (deal.checkin_count or 0) < due:
        deal.checkin_count = due
        deal.last_checkin_at = now
        text = (f"Reminder: the buyer is waiting for your answer to their refund request. "
                f"Accept it or explain why not within about {left} hours, or they will be "
                f"refunded automatically.")
        _zeno_says(session, deal, "seller", text)
        await _push(session, deal.seller_id, "Refund request: respond soon", text, deal, "refund_reminder")

    sms_due = policy.due_count(policy.REFUND_SMS_HOURS, elapsed)
    if (deal.reminder_sms_count or 0) < sms_due and not _quiet_hours():
        payments = await _payments(session, deal.id)
        item = await _item_name(session, deal)
        text = (f"BROKA: The buyer has asked for a refund of "
                f"{_kes(_held_amount(deal, payments))} for {item}. Open BROKA within about "
                f"{left} hours to accept or explain, or they will be refunded automatically.")
        if await _sms(session, deal.seller_id, text, deal):
            deal.reminder_sms_count = sms_due
    deal.timer_deadline = now


# ── Price statement (partial payments) ─────────────────────────────────────

async def set_price(db: AsyncSession, deal_id: str, seller_id: str, agreed_price: float,
                    request_ip: Optional[str] = None) -> dict:
    """POST /deal/{deal_id}/price: the seller states the price they agreed
    to. Never below what the buyer has paid or is paying (that money cannot
    be partly sent back), and not once a payout or refund is under way."""
    from .service import _commission, amount_paid, validate_agreed_price
    deal = await _deal_for(db, deal_id, seller_id, "seller")
    price = validate_agreed_price(agreed_price)
    if deal.status not in (DealStatus.agreed, DealStatus.paid):
        raise HTTPException(status_code=400,
                            detail=f"The price can't be changed on a deal that is '{deal.status.value}'")
    listing = (await db.execute(select(Listing).where(Listing.id == deal.listing_id))).scalar_one_or_none()
    if listing is not None and listing.listing_type == ListingType.auction:
        raise HTTPException(status_code=400, detail="An auction's price is the winning bid")
    if policy.refund_request_open(deal):
        raise HTTPException(status_code=409, detail="Answer the buyer's refund request first")

    deal = await _lock(db, deal_id, (DealStatus.agreed, DealStatus.paid))
    payments = await _payments(db, deal_id)
    if _releasing(payments):
        await db.commit()
        raise HTTPException(status_code=409, detail="The money is already being released")
    paid = amount_paid(payments)
    committed = paid
    in_flight = [p.amount for p in payments if p.status in EConfirmEscrowStatus.OPEN]
    if in_flight:
        # A prompt on the buyer's phone may still be paid.
        from api.core.money import add_money
        committed = add_money(paid, *in_flight)
    if price < committed:
        await db.commit()
        raise HTTPException(
            status_code=422,
            detail=f"The buyer has already paid {_kes(committed)} - the price can't be less than that",
        )
    old = deal.agreed_price
    if abs(price - old) < 0.005:
        await db.commit()
        return await _deal_response(db, deal_id, seller_id)
    deal.agreed_price = price
    deal.commission = _commission(price, listing.listing_type if listing else None)
    balance = max(price - paid, 0.0)
    _zeno_says(db, deal, "buyer",
               f"The seller says the agreed price is {_kes(price)}. You've paid {_kes(paid)} so "
               + (f"far, so the balance is {_kes(balance)} - you can pay it from the deal screen. "
                  if balance > 0 else "far, which covers it - nothing more to pay. ")
               + "If that's not what you agreed, tell me here or ask for a refund.")
    await record_audit(db, seller_id, "deal_price_stated", "deal", deal_id,
                       f"agreed_price {old} -> {price}", ip_address=request_ip)
    await db.commit()
    await _push(db, deal.buyer_id, "The seller confirmed the price",
                f"Agreed price {_kes(price)}; balance {_kes(balance)}.", deal, "deal_price")
    return await _deal_response(db, deal_id, seller_id)


async def announce_top_up(db: AsyncSession, deal_id: str, amount: float) -> None:
    """Tell the seller the buyer added a payment."""
    deal = (await db.execute(
        select(Deal).where(Deal.id == deal_id).execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if deal is None:
        return
    from .service import amount_paid, balance_due
    payments = await _payments(db, deal_id)
    paid, balance = amount_paid(payments), balance_due(deal, payments)
    text = (f"The buyer added {_kes(amount)}. Paid so far: {_kes(paid)} of {_kes(deal.agreed_price)}"
            + (f" (balance {_kes(balance)})." if balance > 0 else " - paid in full."))
    _zeno_says(db, deal, "seller", text)
    await db.commit()
    await _push(db, deal.seller_id, "Payment received", text, deal, "payment_added")


# ── Closing a refund E-Confirm returned by hand ────────────────────────────

async def mark_econfirm_refunded(db: AsyncSession, deal_id: str, admin_id: str,
                                 request_ip: Optional[str] = None) -> dict:
    """POST /admin/deals/{deal_id}/econfirm-refunded: the team has returned
    an approved refund through E-Confirm; the deal is closed as refunded and
    the ledger told."""
    from api.core.events import EscrowRefunded, publish
    deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one_or_none()
    if deal is None:
        raise HTTPException(status_code=404, detail="Deal not found")
    if deal.refund_outcome not in ("seller_accepted", "seller_silent"):
        raise HTTPException(status_code=400, detail="This deal has no approved refund")
    payments = await _payments(db, deal_id)
    if not payments:
        raise HTTPException(status_code=400, detail="This is not an E-Confirm deal")
    locked = await _lock(db, deal_id, (DealStatus.disputed,))
    now = datetime.utcnow()
    locked.status = DealStatus.refunded
    locked.refunded_at = now
    held = _held_amount(locked, payments)
    await record_audit(db, admin_id, "econfirm_refund_completed", "deal", deal_id,
                       f"amount={held}", ip_address=request_ip)
    _zeno_says(db, locked, "buyer", f"Your refund of {_kes(held)} has been sent. This deal is closed.")
    await db.commit()
    await publish(EscrowRefunded(
        deal_id=deal_id, buyer_id=locked.buyer_id, seller_id=locked.seller_id,
        amount=held, dispute_id=f"refund-request-{deal_id[:8]}",
    ))
    return {"deal_id": deal_id, "status": locked.status.value, "refunded_at": now.isoformat()}
