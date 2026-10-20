"""Running a store: its plan, the M-Pesa prompt that pays for it, and what
a payment buys.

PRICING.md §5: a store pays a one-off opening fee (KES 299, waived when the
first payment covers 6 months or more) plus a monthly plan priced by how
many listings it holds (pricing/plans.py, one rate card per trade). The
price always comes from the card on the server, never from the app.

What "paid" buys is visibility: while a store's plan is paid for, the store
is in the directory and its listings are live everywhere
(listings/paid.live_clause); when it lapses the store keeps its profile and
its owner keeps every screen, but buyers stop seeing it - the recurring
payment is what the shop pays for.

The money moves exactly like premium's (premium/payments.py, same shape as
pricing/payments.py, and for the same reasons): a Daraja STK push, or
ZetuPay when ZETUPAY_ENABLED, settled once under a row lock by Safaricom's
callback or by the status poll asking Safaricom itself. The amount reported
is checked against the amount asked for - this is the route an
unauthenticated forged callback would take.

A store created before billing was switched on gets a grace row when the
setting first turns on (ensure_grace_subscriptions) - once, not every
startup, so the round can't reach stores created since. Those open with
their own row instead: plan_id=None and paid_until=None, made in
create_store's transaction. The opening fee is still owed either way: the
grace row keeps setup_fee_paid=False.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import mpesa_stk
from api.core.audit import record_audit
from api.core.config import settings
from api.core.zetupay import ZetuPayUnavailable
from api.database import Listing, ListingStatus
from api.domains.payments import service as zetupay_charges
from api.domains.pricing.plans import (
    STORE_PERIODS, STORE_RATE_CARDS, STORE_RATE_CARDS_BY_ID,
    STORE_SETUP_WAIVED_FROM_MONTHS, StorePlan, StoreRateCard,
)
from api.models.store import Store
from api.models.store_billing import (
    StoreBillingMeta, StorePayment, StorePaymentStatus as S, StoreSubscription,
)
from api.models.zetupay import Purpose

logger = logging.getLogger(__name__)

# A month of store time. 30 days, not a calendar month, so "3 months" costs
# the same whichever months they are (same MONTH as listings/paid.py).
MONTH = timedelta(days=30)

# The most store time that can be paid ahead: a year, plus a day of slack.
MAX_AHEAD = 12 * MONTH + timedelta(days=1)

# An unfinished prompt blocks another for the same store this long - two
# prompts both approved would take the money twice.
PENDING_WINDOW = timedelta(minutes=2)
QUERY_AFTER = timedelta(seconds=20)

_DEFAULT_API_BASE = "https://api.broka.co.ke"

# The single row in store_billing_meta that records the one-time grace
# round (ensure_grace_subscriptions). Fixed id: there is nothing to key
# the row on, only one round to remember.
GRACE_MARKER_ID = "store-billing"


def enabled() -> bool:
    return settings.store_billing_enabled


def callback_url() -> str:
    if settings.mpesa_store_callback_url:
        return settings.mpesa_store_callback_url
    base = (settings.public_api_base_url or _DEFAULT_API_BASE) + "/stores/billing/callback"
    return f"{base}/{settings.mpesa_callback_secret}" if settings.mpesa_callback_secret else base


def rate_card_for(category: Optional[str]) -> StoreRateCard:
    """The card a store pays by. Car yards and agents by their category;
    everything else by the goods card - its `categories` is empty, meaning
    "everything no other card takes", the same rule plans.store_plan_for
    uses."""
    for card in STORE_RATE_CARDS:
        if category and category in card.categories:
            return card
    return STORE_RATE_CARDS_BY_ID["goods"]


def plan_of(sub: Optional[StoreSubscription]) -> Optional[StorePlan]:
    """The plan a subscription row is on, rebuilt from its id ("goods-50"),
    so a price change never rewrites what someone already bought at the old
    rate. Grace rows have no plan_id and no plan."""
    if sub is None or not sub.plan_id:
        return None
    card_id, _, size = sub.plan_id.rpartition("-")
    card = STORE_RATE_CARDS_BY_ID.get(card_id)
    if card is None or not size.isdigit():
        return None
    return card.plan(int(size))


def live_subscription_clause(store_id_column, now: Optional[datetime] = None):
    """SQL: a paid subscription exists for the store in `store_id_column`.
    The one EXISTS every public list uses to keep an unpaid store's
    listings out (listings/paid.live_clause, stores/service.list_stores)."""
    now = now or datetime.utcnow()
    return select(StoreSubscription.id).where(
        StoreSubscription.store_id == store_id_column,
        StoreSubscription.paid_until.is_not(None),
        StoreSubscription.paid_until > now,
    ).exists()


async def subscription_for(db: AsyncSession, store_id: str) -> Optional[StoreSubscription]:
    return (await db.execute(
        select(StoreSubscription).where(StoreSubscription.store_id == store_id)
    )).scalar_one_or_none()


async def subscriptions_for(db: AsyncSession, store_ids: list[str]) -> dict[str, StoreSubscription]:
    """One query for a whole directory page - never one per store."""
    if not store_ids:
        return {}
    rows = (await db.execute(
        select(StoreSubscription).where(StoreSubscription.store_id.in_(store_ids))
    )).scalars().all()
    return {row.store_id: row for row in rows}


def is_live(sub: Optional[StoreSubscription], now: Optional[datetime] = None) -> bool:
    """Billing's half of "can buyers see this store"; the owner's pause
    switch (Store.is_active) is the other half. Billing off = always live,
    so every caller stays correct with the setting off."""
    if not enabled():
        return True
    return (sub is not None and sub.paid_until is not None
            and sub.paid_until > (now or datetime.utcnow()))


async def store_live(db: AsyncSession, store: Store, now: Optional[datetime] = None) -> bool:
    """Both halves together: the store is open and its plan is paid up."""
    if not store.is_active:
        return False
    if not enabled():
        return True
    return is_live(await subscription_for(db, store.id), now)


def state_for(sub: Optional[StoreSubscription], now: Optional[datetime] = None) -> dict:
    """The owner's view of their billing: what plan, until when, and whether
    the opening fee is already covered."""
    now = now or datetime.utcnow()
    plan = plan_of(sub)
    return {
        "active": is_live(sub, now),
        "plan_id": sub.plan_id if sub else None,
        "listings": sub.listings if sub else None,
        "monthly_price": plan.monthly_price if plan else None,
        "paid_until": sub.paid_until.isoformat() if sub and sub.paid_until else None,
        "setup_fee_paid": bool(sub.setup_fee_paid) if sub else False,
    }


async def live_listings_count(db: AsyncSession, store_id: str,
                              now: Optional[datetime] = None) -> int:
    """Active listings in the store, counting paid status but NOT the
    store's own visibility gate (live_clause): a store being paid for is
    exactly the case where live_clause hides everything, and the car-yard
    minimum must look at the stock, not at what buyers currently see."""
    now = now or datetime.utcnow()
    return (await db.execute(
        select(func.count()).select_from(Listing).where(
            Listing.store_id == store_id,
            Listing.status == ListingStatus.active,
            Listing.sold_out_reported_at.is_(None),
            or_(Listing.paid_until.is_(None), Listing.paid_until > now),
        )
    )).scalar_one()


def _periods_with_fees(plan: StorePlan, setup_fee: int, setup_fee_paid: bool) -> dict:
    """The plan's periods with the opening fee this store would actually
    be charged added: waived from 6 months, nothing once it has been paid,
    and never anything on a card with no opening fee (online stores)."""
    plan_dict = plan.to_dict(setup_fee=setup_fee)
    for period in plan_dict["periods"]:
        if setup_fee_paid:
            period["setup_fee"] = 0
        period["amount"] = period["total"] + period["setup_fee"]
    return plan_dict


async def summary(db, store: Store, listings: Optional[int] = None) -> dict:
    """The owner's billing screen: the store's card, what is owed now, and -
    when a size is asked for - that plan's priced periods. Owner checked by
    the caller (StoreService.get_owned). Any size between the card's minimum
    and maximum is sold: the seller picks how many listings they want."""
    if not enabled():
        raise HTTPException(status_code=409, detail="Online store billing isn't switched on yet.")
    card = rate_card_for(store.category)
    sub = await subscription_for(db, store.id)
    setup_paid = bool(sub.setup_fee_paid) if sub else False
    out = {
        "rate_card": card.to_dict(),
        "setup_fee": 0 if (setup_paid or card.setup_fee == 0) else card.setup_fee,
        "setup_fee_waived_from_months": STORE_SETUP_WAIVED_FROM_MONTHS,
        "min_listings": card.min_listings,
        "live_listings": await live_listings_count(db, store.id),
        "current": state_for(sub),
        "months_options": sorted(STORE_PERIODS),
    }
    if listings is not None:
        if listings < card.min_listings or listings > card.max_listings:
            raise HTTPException(status_code=422, detail=(
                f"{card.name} plans cover {card.min_listings} to {card.max_listings} listings. "
                "For more, contact BROKA and we'll price it with you."))
        out["plan"] = _periods_with_fees(card.plan(listings), card.setup_fee, setup_paid)
    return out


async def start_payment(
    db: AsyncSession, owner_id: str, store: Store, listings: int, months: int,
    phone_number: str,
) -> dict:
    if not enabled():
        raise HTTPException(status_code=409, detail="Online store billing isn't switched on yet.")
    card = rate_card_for(store.category)
    if listings < card.min_listings or listings > card.max_listings:
        raise HTTPException(status_code=422, detail=(
            f"{card.name} plans cover {card.min_listings} to {card.max_listings} listings. "
            "For more, contact BROKA and we'll price it with you."))
    if months not in STORE_PERIODS:
        raise HTTPException(status_code=400, detail="A store plan is bought for 2, 4, 6 or 12 months.")

    now = datetime.utcnow()
    sub = await subscription_for(db, store.id)
    current = plan_of(sub) if sub is not None and sub.paid_until and sub.paid_until > now else None
    if current is not None and listings < current.listings:
        raise HTTPException(status_code=409, detail=(
            f"Your store is on the {current.listings}-listing plan until "
            f"{sub.paid_until.day} {sub.paid_until:%b %Y}. You can move down when it ends."
        ))
    if (current is not None and listings == current.listings
            and sub.paid_until + months * MONTH - now > MAX_AHEAD):
        raise HTTPException(status_code=409, detail=(
            "A store plan can be paid for up to a year ahead. "
            f"Your store is already paid until {sub.paid_until.day} {sub.paid_until:%b %Y}."
        ))

    # Cards with a stock floor (online stores: 20, car yards/agents: 5)
    # are paid for stock, not for a name. An online store pays for the
    # plan size it picks, so a new shop chooses its size before its first
    # listing - the live count is not a gate, the plan size is.
    if card.id != "goods" and card.min_listings > 1:
        live = await live_listings_count(db, store.id, now)
        if live < card.min_listings:
            raise HTTPException(status_code=409, detail=(
                f"A {card.name.lower()} store holds at least {card.min_listings} live listings. "
                f"You have {live} - add {card.min_listings - live} more, then pay."
            ))

    phone = mpesa_stk.normalize_phone(phone_number)
    if phone is None:
        raise HTTPException(status_code=400, detail="Enter a Safaricom number, e.g. 0712 345 678.")

    pending = (await db.execute(
        select(StorePayment.id).where(
            StorePayment.store_id == store.id,
            StorePayment.status == S.PENDING,
        ).limit(1)
    )).scalar()
    if pending:
        raise HTTPException(status_code=409, detail=(
            "An M-Pesa prompt for your store is already on your phone. "
            "Finish it, or check the payment status before trying again."
        ))

    plan = card.plan(listings)
    if card.setup_fee == 0 or (sub is not None and sub.setup_fee_paid):
        setup_fee = 0
    else:
        setup_fee = 0 if months >= STORE_SETUP_WAIVED_FROM_MONTHS else card.setup_fee
    period = next(p for p in plan.to_dict(setup_fee=card.setup_fee)["periods"] if p["months"] == months)
    amount = period["total"] + setup_fee

    payment = StorePayment(
        store_id=store.id, user_id=owner_id, plan_id=plan.id, listings=plan.listings,
        months=months, amount=amount, setup_fee=setup_fee, phone=phone,
        status=S.PENDING, created_at=now, active_intent=f"store:{store.id}",
    )
    db.add(payment)
    try:
        await db.flush()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(status_code=409, detail=(
            "An M-Pesa prompt for your store is already on your phone. "
            "Finish it, or check the payment status before trying again."
        ))
    if zetupay_charges.enabled():
        payment.provider = zetupay_charges.PROVIDER
        try:
            await zetupay_charges.start(
                db, user_id=owner_id, purpose=Purpose.STORE, amount=payment.amount,
                phone=phone, target_id=payment.id, related_id=store.id,
                description=f"{plan.name} {months}mo",
            )
        except ZetuPayUnavailable as exc:
            raise HTTPException(status_code=502, detail=zetupay_charges.unavailable_detail(exc))
    else:
        try:
            reply = await mpesa_stk.stk_push(
                phone, payment.amount, account_reference="BROKAStore",
                description=f"{plan.name} {months}mo"[:24], callback_url=callback_url(),
            )
        except mpesa_stk.MpesaTimeout as exc:
            payment.failure_reason = "provider_outcome_unknown"
            await db.commit()
            logger.warning("[store billing] ambiguous prompt outcome payment=%s: %s", payment.id, exc)
            raise HTTPException(status_code=503, detail=(
                "M-Pesa did not confirm the request. If a prompt reaches "
                "your phone, complete it; otherwise check status before retrying."
            ))
        except mpesa_stk.MpesaUnavailable as exc:
            payment.status, payment.processed, payment.failure_reason = S.FAILED, True, "prompt_not_sent"
            payment.active_intent = None
            await db.commit()
            logger.warning("[store billing] no prompt for payment=%s: %s", payment.id, exc)
            raise HTTPException(status_code=502, detail="Couldn't reach M-Pesa. Try again in a moment.")

        payment.checkout_request_id = reply["CheckoutRequestID"]
        payment.merchant_request_id = reply.get("MerchantRequestID")
        await db.commit()
    return {
        "payment_id": payment.id, "status": payment.status, "plan_id": plan.id,
        "listings": plan.listings, "months": months, "amount": payment.amount,
        "setup_fee": payment.setup_fee,
        "message": "Check your phone and enter your M-Pesa PIN.",
    }


async def _locked_payment(db: AsyncSession, condition) -> Optional[StorePayment]:
    return (await db.execute(
        select(StorePayment).where(condition)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()


def _apply(sub: Optional[StoreSubscription], store_id: str, plan: StorePlan, months: int,
           now: datetime) -> StoreSubscription:
    """What paying for `months` of `plan` does to the store's subscription.

    Same shapes as premium's _apply (premium/payments.py): renewing early
    extends from the end, an upgrade takes effect now with the unused days
    credited at the ratio of the two prices, and a cheaper plan paid while
    a dearer one runs (the plan changed while the prompt was open) becomes
    time on the plan in force. Paying for the first time always marks the
    opening fee settled - it was either in the amount or waived by its
    length.
    """
    bought = months * MONTH
    current = plan_of(sub) if sub is not None and sub.paid_until and sub.paid_until > now else None
    if sub is None:
        sub = StoreSubscription(
            store_id=store_id, plan_id=plan.id, listings=plan.listings,
            paid_until=now + bought, created_at=now, updated_at=now,
        )
    elif current is None:
        sub.plan_id, sub.listings, sub.paid_until = plan.id, plan.listings, now + bought
    elif current.listings == plan.listings:
        sub.paid_until = sub.paid_until + bought
    elif plan.monthly_price > current.monthly_price:
        credit = (sub.paid_until - now) * (current.monthly_price / plan.monthly_price)
        sub.plan_id, sub.listings, sub.paid_until = plan.id, plan.listings, now + credit + bought
    else:
        # Fewer listings paid for while a bigger plan runs: its money
        # becomes time on the plan in force.
        sub.paid_until = sub.paid_until + bought * (plan.monthly_price / current.monthly_price)
    sub.setup_fee_paid = True
    sub.updated_at = now
    return sub


async def _settle(db: AsyncSession, payment: StorePayment, receipt: Optional[str]) -> None:
    """Apply a confirmed payment; the caller holds its lock and checked it."""
    now = datetime.utcnow()
    if receipt:
        duplicate = (await db.execute(
            select(StorePayment.id).where(
                StorePayment.mpesa_receipt == receipt,
                StorePayment.id != payment.id,
            ).limit(1)
        )).scalar()
        if duplicate:
            reason = (f"M-Pesa receipt {receipt} already belongs to store payment "
                      f"{duplicate}; payment {payment.id} was not applied")
            payment.status = S.FAILED
            payment.processed = True
            payment.failure_reason = "duplicate_receipt"
            payment.active_intent = None
            await record_audit(
                db, "system", "store_duplicate_receipt", "store",
                payment.store_id, reason,
            )
            from api.core.reconciliation import report_reconciliation
            report_reconciliation("store_duplicate_receipt", deal_id=None, reason=reason)
            await db.commit()
            return
    sub = (await db.execute(
        select(StoreSubscription).where(StoreSubscription.store_id == payment.store_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    card_id, _, size = payment.plan_id.rpartition("-")
    card = STORE_RATE_CARDS_BY_ID.get(card_id)
    plan = card.plan(payment.listings) if card is not None and size.isdigit() else None
    payment.status, payment.processed, payment.paid_at, payment.mpesa_receipt = (
        S.SUCCESS, True, now, receipt)
    payment.active_intent = None
    if plan is None:
        # A card retired while the prompt was open: the money is recorded,
        # and a person decides what it buys.
        reason = (f"Store payment {payment.id} (KES {payment.amount}) for unknown plan "
                  f"{payment.plan_id} (store {payment.store_id})")
        await record_audit(db, "system", "store_payment_unknown_plan", "store", payment.store_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("store_payment_unknown_plan", deal_id=None, reason=reason)
        await db.commit()
        return
    sub = _apply(sub, payment.store_id, plan, payment.months, now)
    db.add(sub)
    payment.period_end = sub.paid_until
    await record_audit(
        db, payment.user_id, "store_paid", "store", payment.store_id,
        f"payment={payment.id} plan={plan.id} months={payment.months} amount={payment.amount} "
        f"setup_fee={payment.setup_fee} until={sub.paid_until.isoformat()} receipt={receipt}",
    )
    await db.commit()


async def _fail(db: AsyncSession, payment: StorePayment, reason: str) -> None:
    payment.status, payment.processed, payment.failure_reason = S.FAILED, True, reason[:200]
    payment.active_intent = None
    await db.commit()


async def process_callback(db: AsyncSession, payload: dict) -> None:
    result = mpesa_stk.parse_callback(payload)
    if not result.checkout_request_id:
        return
    payment = await _locked_payment(db, StorePayment.checkout_request_id == result.checkout_request_id)
    if payment is None:
        logger.warning("[store billing] callback for unknown checkout %s", result.checkout_request_id)
        return
    if payment.processed:
        await db.rollback()
        return
    if not result.succeeded:
        await _fail(db, payment, result.description)
        return
    if not mpesa_stk.amount_matches(result, payment.amount):
        reason = (f"Store callback for payment {payment.id} reported {result.amount}, "
                  f"expected {payment.amount} (receipt {result.receipt}) - not applied")
        logger.error("[store billing] AMOUNT_MISMATCH %s", reason)
        await record_audit(db, "system", "store_amount_mismatch", "store", payment.store_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("store_amount_mismatch", deal_id=None, reason=reason)
        await _fail(db, payment, "amount_mismatch")
        return
    await _settle(db, payment, result.receipt)


async def zetupay_settled(db: AsyncSession, payment_id: str, receipt: Optional[str]) -> None:
    """ZetuPay confirmed the payment for this row (domains/payments holds
    the ZetuPay payment's lock); see pricing/payments.zetupay_settled."""
    payment = await _locked_payment(db, StorePayment.id == payment_id)
    if payment is None or payment.status == S.SUCCESS:
        return
    await _settle(db, payment, receipt)


async def zetupay_failed(db: AsyncSession, payment_id: str, reason: str) -> None:
    payment = await _locked_payment(db, StorePayment.id == payment_id)
    if payment is None or payment.processed:
        return
    await _fail(db, payment, reason)


async def payment_status(db: AsyncSession, owner_id: str, store_id: str, payment_id: str) -> dict:
    """Where a store payment stands - asking Safaricom when the callback is
    late, never writing a slow one off (premium/payments.payment_status)."""
    payment = await db.get(StorePayment, payment_id)
    if payment is None or payment.store_id != store_id or payment.user_id != owner_id:
        raise HTTPException(status_code=404, detail="Payment not found")

    if payment.status == S.PENDING and payment.provider == zetupay_charges.PROVIDER:
        await zetupay_charges.refresh(db, Purpose.STORE, payment.id)
        payment = await db.get(StorePayment, payment_id, populate_existing=True)

    if (payment.status == S.PENDING and payment.checkout_request_id
            and datetime.utcnow() - payment.created_at >= QUERY_AFTER):
        try:
            answer = await mpesa_stk.stk_query(payment.checkout_request_id)
        except mpesa_stk.MpesaUnavailable:
            answer = {}
        outcome = mpesa_stk.query_outcome(answer)
        if outcome is not None:
            locked = await _locked_payment(db, StorePayment.id == payment.id)
            if locked is not None and not locked.processed:
                if outcome:
                    await _settle(db, locked, None)
                else:
                    await _fail(db, locked, answer.get("ResultDesc") or "not completed")
            else:
                await db.rollback()
            payment = await db.get(StorePayment, payment_id, populate_existing=True)

    return {
        "payment_id": payment.id,
        "status": payment.status,
        "plan_id": payment.plan_id,
        "listings": payment.listings,
        "months": payment.months,
        "amount": payment.amount,
        "failure_reason": payment.failure_reason,
        "paid_until": payment.period_end.isoformat() if payment.period_end else None,
    }


def create_unpaid_subscription(
    db: AsyncSession, store_id: str, now: Optional[datetime] = None,
) -> StoreSubscription:
    """The row a store opens with while billing is on: no plan, no paid
    time, opening fee still owed. Made in create_store's transaction, so a
    store created since billing was switched on is never mistaken for one
    that predates it - the one-time grace round keys on the row's absence,
    and would have put this shop in front of buyers for free."""
    now = now or datetime.utcnow()
    sub = StoreSubscription(
        store_id=store_id, plan_id=None, listings=0,
        setup_fee_paid=False, paid_until=None, created_at=now, updated_at=now,
    )
    db.add(sub)
    return sub


async def ensure_grace_subscriptions() -> int:
    """When billing first turns on, give every store that predates it its
    grace time, so a seller who opened a store while billing was off keeps
    their shop running instead of finding it dark. The opening fee is NOT
    waived for them (PRICING.md §9): setup_fee_paid stays False.

    A one-time round, not a startup sweep: the marker row in
    store_billing_meta is claimed before anything is granted. That matters
    because a paid_until=None row now also means "created while billing is
    on, hasn't paid" (create_unpaid_subscription); without the marker every
    restart would read those stores as pre-billing and hand out grace,
    which is a free month for shops that never paid. Pre-billing stores
    are the ones with no row at all, which is what this round keys on.

    Safe against several workers starting at once - the marker's primary
    key settles that race, each subscription insert is its own savepoint,
    and the unique index on store_id settles the rest. Returns how many
    rows were created.
    """
    from api.database import AsyncSessionLocal

    now = datetime.utcnow()
    paid_until = now + timedelta(days=settings.store_billing_grace_days)
    created = 0
    async with AsyncSessionLocal() as db:
        claimed = (await db.execute(
            select(StoreBillingMeta.id).where(StoreBillingMeta.id == GRACE_MARKER_ID)
        )).scalar_one_or_none()
        if claimed is not None:
            return 0
        try:
            async with db.begin_nested():
                db.add(StoreBillingMeta(id=GRACE_MARKER_ID, grace_backfilled_at=now))
        except IntegrityError:
            # Another worker claimed the round between our SELECT and this
            # INSERT. The grace is that worker's to grant; ours would double it.
            return 0
        rows = (await db.execute(
            select(Store.id)
            .outerjoin(StoreSubscription, StoreSubscription.store_id == Store.id)
            .where(StoreSubscription.id.is_(None))
        )).scalars().all()
        for store_id in rows:
            try:
                async with db.begin_nested():
                    db.add(StoreSubscription(
                        store_id=store_id, plan_id=None, listings=0,
                        setup_fee_paid=False, paid_until=paid_until,
                        created_at=now, updated_at=now,
                    ))
                created += 1
            except IntegrityError:
                continue
        await db.commit()
    return created
