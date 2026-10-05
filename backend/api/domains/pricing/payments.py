"""Paying for a listing: the M-Pesa prompt, its result, and what a paid month buys.

A seller pays 1-6 months of a listing at once (PRICING.md). The price comes
from the engine on the server, never from the app. A successful payment
moves Listing.paid_until forward by that many 30-day months - from the end
of the time already paid, so renewing early never loses days - and a
listing that was waiting for its first payment goes live and is announced
(ListingCreated) then, not when it was created.

Settlement happens once. Safaricom redelivers callbacks, and the app's
status poll asks Safaricom directly when a callback is slow; both land in
_settle(), under a row lock on the payment, and whichever arrives second
finds it processed and does nothing. The amount Safaricom reports is
checked against the amount asked for: this is the route an unauthenticated
forged callback would take (see routers/mpesa.py).

With ZETUPAY_ENABLED the prompt goes through ZetuPay instead
(domains/payments), whose webhook settles the row through
zetupay_settled() - the same _settle(), under the same lock.

This is BROKA's own revenue, not escrow: no deal, no ledger entry. Money
that arrives for a listing that has since been sold or withdrawn is still
recorded - and a person is told, through the audit log and a
reconciliation alert, so they can refund it.
"""
from __future__ import annotations

import json
import logging
import math
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import mpesa_stk
from api.core.audit import record_audit
from api.core.config import settings
from api.core.events import ListingCreated, publish
from api.core.zetupay import ZetuPayUnavailable
from api.database import Listing, ListingStatus, SellerTier, User
from api.domains.listings.paid import ENDING_SOON, MONTH, fee_applies, fee_state
from api.domains.payments import service as zetupay_charges
from api.domains.pricing import engine, service
from api.models.listing_payment import ListingPayment, ListingPaymentStatus as S
from api.models.zetupay import Purpose

logger = logging.getLogger(__name__)

# The most listing time that can be paid ahead: six months, so a sold item
# never stays up paid-for for more than half a year. A day of slack keeps a
# renewal made a few hours early from being refused.
MAX_AHEAD = engine.MAX_MONTHS * MONTH + timedelta(days=1)

# A prompt still on the seller's phone blocks another for the same listing
# this long - two prompts both approved would take the money twice. An STK
# prompt dies on the handset within about a minute.
PENDING_WINDOW = timedelta(minutes=2)

# The status poll asks Safaricom itself once a payment has waited this long
# for its callback.
QUERY_AFTER = timedelta(seconds=20)

_DEFAULT_API_BASE = "https://api.broka.co.ke"


def callback_url() -> str:
    """MPESA_LISTING_FEE_CALLBACK_URL, or the secret-protected route."""
    if settings.mpesa_listing_fee_callback_url:
        return settings.mpesa_listing_fee_callback_url
    base = (settings.public_api_base_url or _DEFAULT_API_BASE) + "/pricing/listing-fee/callback"
    return f"{base}/{settings.mpesa_callback_secret}" if settings.mpesa_callback_secret else base


def months_available(listing: Listing, now: Optional[datetime] = None) -> int:
    """Whole months that can still be paid for without going past MAX_AHEAD."""
    now = now or datetime.utcnow()
    paid_ahead = max(listing.paid_until - now, timedelta(0)) if listing.paid_until else timedelta(0)
    return max(0, min(engine.MAX_MONTHS, math.floor((MAX_AHEAD - paid_ahead) / MONTH)))


async def _owned_listing(db: AsyncSession, user_id: str, listing_id: str) -> Listing:
    listing = await db.get(Listing, listing_id)
    # Someone else's listing reads as missing: which ids exist is not the
    # caller's business.
    if listing is None or listing.seller_id != user_id:
        raise HTTPException(status_code=404, detail="Listing not found")
    return listing


def _refuse_unless_payable(listing: Listing) -> None:
    if not settings.listing_fees_enabled:
        raise HTTPException(status_code=409, detail="Listing on BROKA is free right now.")
    if not fee_applies(listing):
        raise HTTPException(status_code=409, detail="Auctions don't pay a listing fee.")
    if listing.paid_until is None:
        raise HTTPException(status_code=409, detail="This listing is free - one of your free listings, or posted before listing fees.")
    if listing.status != ListingStatus.active:
        raise HTTPException(status_code=409, detail="This listing is no longer for sale.")


async def listing_quote(db: AsyncSession, user_id: str, listing_id: str) -> dict:
    """The quote for one of the seller's own listings, as it stands."""
    listing = await _owned_listing(db, user_id, listing_id)
    quote = await service.listing_fee_quote(
        db, user_id, listing.category, float(listing.price), listing.quantity or 1,
        starts_at=max(datetime.utcnow(), listing.paid_until or datetime.utcnow()),
        listing_id=listing.id,
    )
    available = months_available(listing)
    quote["options"] = [o for o in quote["options"] if o["months"] <= available]
    quote["months_available"] = available
    quote["listing_id"] = listing.id
    quote["listing_fee"] = fee_state(listing)
    return quote


async def start_payment(
    db: AsyncSession, user_id: str, listing_id: str, months: int, phone_number: str,
    featured_plan: Optional[str] = None,
) -> dict:
    listing = await _owned_listing(db, user_id, listing_id)
    _refuse_unless_payable(listing)

    now = datetime.utcnow()
    available = months_available(listing, now)
    if months > available:
        raise HTTPException(status_code=409, detail=(
            "A listing can be paid for up to 6 months ahead. "
            + (f"You can add up to {available} more." if available else "This one already is.")
        ))

    phone = mpesa_stk.normalize_phone(phone_number)
    if phone is None:
        raise HTTPException(status_code=400, detail="Enter a Safaricom number, e.g. 0712 345 678.")

    pending = (await db.execute(
        select(ListingPayment.id).where(
            ListingPayment.listing_id == listing.id,
            ListingPayment.status == S.PENDING,
            ListingPayment.created_at > now - PENDING_WINDOW,
        ).limit(1)
    )).scalar()
    if pending:
        raise HTTPException(status_code=409, detail=(
            "An M-Pesa prompt for this listing is already on your phone. "
            "Finish it, or try again in two minutes."
        ))

    quote = await service.listing_fee_quote(
        db, user_id, listing.category, float(listing.price), listing.quantity or 1,
        starts_at=max(datetime.utcnow(), listing.paid_until or datetime.utcnow()),
        listing_id=listing.id,
    )
    option = next((o for o in quote["options"] if o["months"] == months), None)
    if option is None:
        # The founding offer sells discounted time only up to its end.
        raise HTTPException(status_code=409, detail=(
            f"Your founding-seller price covers up to {len(quote['options'])} "
            f"month{'s' if len(quote['options']) != 1 else ''} from now. Choose fewer months."
        ))

    featured_amount = 0
    if featured_plan:
        from api.routers.featured import BOOST_PLANS
        tier = (await db.execute(select(User.seller_tier).where(User.id == user_id))).scalar()
        if tier == SellerTier.long_term:
            raise HTTPException(status_code=403, detail=service.FEATURED_NOT_FOR_LONG_TERM)
        plan = BOOST_PLANS.get(featured_plan)
        if plan is None:
            raise HTTPException(status_code=400, detail="Unknown featured plan.")
        featured_amount = int(plan["price"])

    payment = ListingPayment(
        user_id=user_id, listing_id=listing.id, months=months,
        monthly_fee=quote["monthly_fee"], listing_amount=option["total"],
        featured_plan=featured_plan or None, featured_amount=featured_amount,
        amount=option["total"] + featured_amount, phone=phone,
        status=S.PENDING, quote=json.dumps(quote), created_at=now,
    )
    db.add(payment)
    await db.flush()

    if zetupay_charges.enabled():
        # Settled by ZetuPay's webhook (domains/payments), never by
        # Safaricom's callback: the row has no checkout_request_id to match.
        payment.provider = zetupay_charges.PROVIDER
        try:
            await zetupay_charges.start(
                db, user_id=user_id, purpose=Purpose.LISTING_FEE, amount=payment.amount,
                phone=phone, target_id=payment.id, related_id=listing.id,
                description=f"BROKA listing {months}mo",
            )
        except ZetuPayUnavailable as exc:
            raise HTTPException(status_code=502, detail=zetupay_charges.unavailable_detail(exc))
    else:
        try:
            reply = await mpesa_stk.stk_push(
                phone, payment.amount, account_reference="BROKAListing",
                description=f"List {months}mo", callback_url=callback_url(),
            )
        except mpesa_stk.MpesaUnavailable as exc:
            payment.status = S.FAILED
            payment.processed = True
            payment.failure_reason = "prompt_not_sent"
            await db.commit()
            logger.warning("[listing_fee] no prompt for payment=%s: %s", payment.id, exc)
            raise HTTPException(status_code=502, detail="Couldn't reach M-Pesa. Try again in a moment.")

        payment.checkout_request_id = reply["CheckoutRequestID"]
        payment.merchant_request_id = reply.get("MerchantRequestID")
        await db.commit()
    return {
        "payment_id": payment.id,
        "status": payment.status,
        "amount": payment.amount,
        "months": months,
        "monthly_fee": payment.monthly_fee,
        "featured_plan": payment.featured_plan,
        "message": "Check your phone and enter your M-Pesa PIN.",
    }


async def _locked_payment(db: AsyncSession, condition) -> Optional[ListingPayment]:
    """The payment, row-locked and re-read: whoever holds the lock decides."""
    return (await db.execute(
        select(ListingPayment).where(condition)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()


async def _settle(db: AsyncSession, payment: ListingPayment, receipt: Optional[str]) -> None:
    """Apply a confirmed payment. The caller holds the payment's row lock and
    has checked it is unprocessed."""
    now = datetime.utcnow()
    listing = (await db.execute(
        select(Listing).where(Listing.id == payment.listing_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()

    payment.status = S.SUCCESS
    payment.processed = True
    payment.paid_at = now
    payment.mpesa_receipt = receipt
    if listing is None:
        await db.commit()
        return

    first_payment = (listing.paid_until is not None and listing.created_at is not None
                     and listing.paid_until <= listing.created_at)
    start = max(now, listing.paid_until or now)
    payment.period_start = start
    payment.period_end = listing.paid_until = start + payment.months * MONTH

    if payment.featured_plan:
        from api.routers.featured import BOOST_PLANS
        days = BOOST_PLANS.get(payment.featured_plan, {"days": 7})["days"]
        base = listing.featured_until if (listing.featured_until and listing.featured_until > now) else now
        listing.is_featured = True
        listing.featured_until = base + timedelta(days=days)

    await record_audit(
        db, payment.user_id, "listing_fee_paid", "listing", listing.id,
        f"payment={payment.id} amount={payment.amount} months={payment.months} "
        f"until={payment.period_end.isoformat()} receipt={receipt}",
    )
    if listing.status != ListingStatus.active:
        # Sold or withdrawn while the prompt was open. The money is BROKA's
        # to give back, and a person has to do it.
        reason = (f"Listing fee KES {payment.amount} ({receipt or payment.checkout_request_id}) "
                  f"paid for listing {listing.id} in status "
                  f"{getattr(listing.status, 'value', listing.status)} - refund the seller")
        await record_audit(db, "system", "listing_fee_on_inactive_listing", "listing", listing.id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("listing_fee_on_inactive_listing", deal_id=None, reason=reason)
    await db.commit()

    # After commit, so the Buying Agent reads a listing buyers can see.
    if first_payment and listing.status == ListingStatus.active:
        await publish(ListingCreated(
            listing_id=listing.id, seller_id=listing.seller_id,
            price=float(listing.price), category=listing.category,
        ))


async def _fail(db: AsyncSession, payment: ListingPayment, reason: str) -> None:
    payment.status = S.FAILED
    payment.processed = True
    payment.failure_reason = reason[:200]
    await db.commit()


async def process_callback(db: AsyncSession, payload: dict) -> None:
    result = mpesa_stk.parse_callback(payload)
    if not result.checkout_request_id:
        return
    payment = await _locked_payment(db, ListingPayment.checkout_request_id == result.checkout_request_id)
    if payment is None:
        logger.warning("[listing_fee] callback for unknown checkout %s", result.checkout_request_id)
        return
    if payment.processed:
        await db.rollback()
        return

    if not result.succeeded:
        await _fail(db, payment, result.description)
        return

    if not mpesa_stk.amount_matches(result, payment.amount):
        # The amount asked for is the authority; a callback's figure is a
        # claim. A forged callback claiming KES 1 must not buy six months.
        reason = (f"Listing fee callback for payment {payment.id} reported {result.amount}, "
                  f"expected {payment.amount} (receipt {result.receipt}) - not applied")
        logger.error("[listing_fee] AMOUNT_MISMATCH %s", reason)
        await record_audit(db, "system", "listing_fee_amount_mismatch", "listing", payment.listing_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("listing_fee_amount_mismatch", deal_id=None, reason=reason)
        await _fail(db, payment, "amount_mismatch")
        return
    await _settle(db, payment, result.receipt)


async def zetupay_settled(db: AsyncSession, payment_id: str, receipt: Optional[str]) -> None:
    """ZetuPay confirmed the payment for this row (domains/payments holds
    the ZetuPay payment's lock). A row failed earlier - its prompt timed out
    here, then was paid - is settled too: the money arrived."""
    payment = await _locked_payment(db, ListingPayment.id == payment_id)
    if payment is None or payment.status == S.SUCCESS:
        return
    await _settle(db, payment, receipt)


async def zetupay_failed(db: AsyncSession, payment_id: str, reason: str) -> None:
    payment = await _locked_payment(db, ListingPayment.id == payment_id)
    if payment is None or payment.processed:
        return
    await _fail(db, payment, reason)


def _payment_dict(payment: ListingPayment, listing: Optional[Listing]) -> dict:
    return {
        "payment_id": payment.id,
        "status": payment.status,
        "amount": payment.amount,
        "months": payment.months,
        "featured_plan": payment.featured_plan,
        "failure_reason": payment.failure_reason,
        "paid_until": payment.period_end.isoformat() if payment.period_end else None,
        "listing_fee": fee_state(listing) if listing is not None else None,
    }


async def payment_status(db: AsyncSession, user_id: str, payment_id: str) -> dict:
    """Where a payment stands - asking Safaricom when its callback is late.

    Never marks a payment failed for taking long: a callback can arrive
    minutes late, and one arriving after the payment was written off would
    find it processed and be dropped - money taken, listing not extended.
    """
    payment = await db.get(ListingPayment, payment_id)
    if payment is None or payment.user_id != user_id:
        raise HTTPException(status_code=404, detail="Payment not found")

    if payment.status == S.PENDING and payment.provider == zetupay_charges.PROVIDER:
        await zetupay_charges.refresh(db, Purpose.LISTING_FEE, payment.id)
        payment = await db.get(ListingPayment, payment_id, populate_existing=True)

    if (payment.status == S.PENDING and payment.checkout_request_id
            and datetime.utcnow() - payment.created_at >= QUERY_AFTER):
        try:
            answer = await mpesa_stk.stk_query(payment.checkout_request_id)
        except mpesa_stk.MpesaUnavailable:
            answer = {}
        outcome = mpesa_stk.query_outcome(answer)
        if outcome is not None:
            locked = await _locked_payment(db, ListingPayment.id == payment.id)
            if locked is not None and not locked.processed:
                if outcome:
                    # Our own authenticated question about our own prompt,
                    # whose amount the payer cannot change.
                    await _settle(db, locked, None)
                else:
                    await _fail(db, locked, answer.get("ResultDesc") or "not completed")
            else:
                await db.rollback()
            payment = await db.get(ListingPayment, payment_id, populate_existing=True)

    listing = await db.get(Listing, payment.listing_id, populate_existing=True)
    return _payment_dict(payment, listing)


async def listings_needing_payment(db: AsyncSession, user_id: str) -> list[dict]:
    """The seller's listings buyers can't see yet, or soon won't: unpaid,
    run out, or ending within a week. Hidden from every public read, so
    this is the only list they appear on."""
    from api.domains.listings.service import ListingService, load_listing_media

    now = datetime.utcnow()
    rows = (await db.execute(
        select(Listing).where(
            Listing.seller_id == user_id,
            Listing.status == ListingStatus.active,
            Listing.paid_until.is_not(None),
            Listing.paid_until <= now + ENDING_SOON,
        ).order_by(Listing.paid_until).limit(100)
    )).scalars().all()
    if not rows:
        return []
    seller = await db.get(User, user_id)
    assets = await load_listing_media(db, rows, [seller])
    return [ListingService._owner_listing_dict(l, seller=seller, assets=assets) for l in rows]
