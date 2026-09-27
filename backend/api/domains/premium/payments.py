"""Buying a plan: the M-Pesa prompt, its result, and what the payment buys.

A plan is bought for 1, 3, 6 or 12 months at the prices in
pricing/plans.py (period_prices), never at an amount the app sends.

What a payment does to the subscription (_apply):
  * no plan running    the plan starts now; its allowance months count
                       from now.
  * the same plan      its paid time is extended from where it ends, so
                       renewing early loses nothing.
  * a dearer plan      an upgrade, now: the unused days of the old plan are
                       turned into days of the new one at the ratio of their
                       prices (ten Plus days are worth ~3.4 Pro days), then
                       the months bought are added. Allowances start afresh.
  * a cheaper plan     refused while the dearer one runs - a downgrade takes
                       effect when it ends. If one is paid anyway (the plan
                       changed while the prompt was open), the money becomes
                       time on the plan in force, at the same price ratio.

Settled once, under a row lock, by Safaricom's callback or by the status
poll asking Safaricom itself - the same shape as pricing/payments.py, and
for the same reasons (see its docstring).
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import mpesa_stk
from api.core.audit import record_audit
from api.core.config import settings
from api.domains.pricing.plans import PLAN_PERIODS, PREMIUM_BY_ID, PremiumPlan, period_prices
from api.domains.premium.entitlements import MONTH, active_subscription, plan_of
from api.models.subscription import (
    Subscription, SubscriptionPayment, SubscriptionPaymentStatus as S,
)

logger = logging.getLogger(__name__)

# The most plan time that can be paid ahead: a year, plus a day of slack.
MAX_AHEAD = 12 * MONTH + timedelta(days=1)

# An unfinished prompt blocks another for the same user this long.
PENDING_WINDOW = timedelta(minutes=2)
QUERY_AFTER = timedelta(seconds=20)

_DEFAULT_API_BASE = "https://broka-dbjd.onrender.com"


def callback_url() -> str:
    if settings.mpesa_premium_callback_url:
        return settings.mpesa_premium_callback_url
    base = (settings.public_api_base_url or _DEFAULT_API_BASE) + "/premium/callback"
    return f"{base}/{settings.mpesa_callback_secret}" if settings.mpesa_callback_secret else base


def price_for(plan: PremiumPlan, months: int) -> int:
    return next(p["total"] for p in period_prices(plan.monthly_price) if p["months"] == months)


def _apply(sub: Optional[Subscription], user_id: str, plan: PremiumPlan, months: int,
           now: datetime) -> Subscription:
    """What paying for `months` of `plan` does to the subscription."""
    bought = months * MONTH
    current = plan_of(sub) if sub is not None and sub.paid_until > now else None
    if sub is None:
        sub = Subscription(user_id=user_id, plan_id=plan.id, started_at=now, paid_until=now + bought,
                           created_at=now, updated_at=now)
    elif current is None:
        sub.plan_id, sub.started_at, sub.paid_until = plan.id, now, now + bought
    elif current.id == plan.id:
        sub.paid_until = sub.paid_until + bought
    elif plan.monthly_price > current.monthly_price:
        credit = (sub.paid_until - now) * (current.monthly_price / plan.monthly_price)
        sub.plan_id, sub.started_at, sub.paid_until = plan.id, now, now + credit + bought
    else:
        # A cheaper plan paid while a dearer one runs: its money becomes time
        # on the plan in force.
        sub.paid_until = sub.paid_until + bought * (plan.monthly_price / current.monthly_price)
    sub.updated_at = now
    return sub


async def start(
    db: AsyncSession, user_id: str, plan_id: str, months: int, phone_number: str,
) -> dict:
    if not settings.premium_enabled:
        raise HTTPException(status_code=409, detail="Everything in BROKA Premium is free right now.")
    plan = PREMIUM_BY_ID.get(plan_id)
    if plan is None:
        raise HTTPException(status_code=400, detail="Choose Plus, Pro or Elite.")
    if months not in PLAN_PERIODS:
        raise HTTPException(status_code=400, detail="A plan is bought for 1, 3, 6 or 12 months.")

    now = datetime.utcnow()
    sub = await active_subscription(db, user_id, now)
    current = plan_of(sub)
    if current is not None and plan.monthly_price < current.monthly_price:
        raise HTTPException(status_code=409, detail=(
            f"You're on {current.name} until {sub.paid_until.day} {sub.paid_until:%b %Y}. "
            f"You can move to {plan.name} when it ends."
        ))
    if current is not None and current.id == plan.id and sub.paid_until + months * MONTH - now > MAX_AHEAD:
        raise HTTPException(status_code=409, detail=(
            "A plan can be paid for up to a year ahead. "
            f"{current.name} already runs until {sub.paid_until.day} {sub.paid_until:%b %Y}."
        ))

    phone = mpesa_stk.normalize_phone(phone_number)
    if phone is None:
        raise HTTPException(status_code=400, detail="Enter a Safaricom number, e.g. 0712 345 678.")

    pending = (await db.execute(
        select(SubscriptionPayment.id).where(
            SubscriptionPayment.user_id == user_id,
            SubscriptionPayment.status == S.PENDING,
            SubscriptionPayment.created_at > now - PENDING_WINDOW,
        ).limit(1)
    )).scalar()
    if pending:
        raise HTTPException(status_code=409, detail=(
            "An M-Pesa prompt for your plan is already on your phone. "
            "Finish it, or try again in two minutes."
        ))

    payment = SubscriptionPayment(
        user_id=user_id, plan_id=plan.id, months=months, amount=price_for(plan, months),
        phone=phone, status=S.PENDING, created_at=now,
    )
    db.add(payment)
    await db.flush()
    try:
        reply = await mpesa_stk.stk_push(
            phone, payment.amount, account_reference="BROKAPremium",
            description=f"{plan.name} {months}mo", callback_url=callback_url(),
        )
    except mpesa_stk.MpesaUnavailable as exc:
        payment.status, payment.processed, payment.failure_reason = S.FAILED, True, "prompt_not_sent"
        await db.commit()
        logger.warning("[premium] no prompt for payment=%s: %s", payment.id, exc)
        raise HTTPException(status_code=502, detail="Couldn't reach M-Pesa. Try again in a moment.")

    payment.checkout_request_id = reply["CheckoutRequestID"]
    payment.merchant_request_id = reply.get("MerchantRequestID")
    await db.commit()
    return {
        "payment_id": payment.id, "status": payment.status, "plan_id": plan.id,
        "months": months, "amount": payment.amount,
        "message": "Check your phone and enter your M-Pesa PIN.",
    }


async def _locked_payment(db: AsyncSession, condition) -> Optional[SubscriptionPayment]:
    return (await db.execute(
        select(SubscriptionPayment).where(condition)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()


async def _settle(db: AsyncSession, payment: SubscriptionPayment, receipt: Optional[str]) -> None:
    """Apply a confirmed payment; the caller holds its lock and checked it."""
    now = datetime.utcnow()
    sub = (await db.execute(
        select(Subscription).where(Subscription.user_id == payment.user_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    plan = PREMIUM_BY_ID.get(payment.plan_id)
    payment.status, payment.processed, payment.paid_at, payment.mpesa_receipt = S.SUCCESS, True, now, receipt
    if plan is None:
        # A plan retired while the prompt was open: the money is recorded,
        # and a person decides what it buys.
        reason = f"Premium payment {payment.id} (KES {payment.amount}) for unknown plan {payment.plan_id}"
        await record_audit(db, "system", "premium_payment_unknown_plan", "user", payment.user_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("premium_payment_unknown_plan", deal_id=None, reason=reason)
        await db.commit()
        return
    sub = _apply(sub, payment.user_id, plan, payment.months, now)
    db.add(sub)
    payment.period_end = sub.paid_until
    await record_audit(
        db, payment.user_id, "premium_paid", "user", payment.user_id,
        f"payment={payment.id} plan={plan.id} months={payment.months} amount={payment.amount} "
        f"now={sub.plan_id} until={sub.paid_until.isoformat()} receipt={receipt}",
    )
    await db.commit()


async def _fail(db: AsyncSession, payment: SubscriptionPayment, reason: str) -> None:
    payment.status, payment.processed, payment.failure_reason = S.FAILED, True, reason[:200]
    await db.commit()


async def process_callback(db: AsyncSession, payload: dict) -> None:
    result = mpesa_stk.parse_callback(payload)
    if not result.checkout_request_id:
        return
    payment = await _locked_payment(db, SubscriptionPayment.checkout_request_id == result.checkout_request_id)
    if payment is None:
        logger.warning("[premium] callback for unknown checkout %s", result.checkout_request_id)
        return
    if payment.processed:
        await db.rollback()
        return
    if not result.succeeded:
        await _fail(db, payment, result.description)
        return
    if not mpesa_stk.amount_matches(result, payment.amount):
        reason = (f"Premium callback for payment {payment.id} reported {result.amount}, "
                  f"expected {payment.amount} (receipt {result.receipt}) - not applied")
        logger.error("[premium] AMOUNT_MISMATCH %s", reason)
        await record_audit(db, "system", "premium_amount_mismatch", "user", payment.user_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation("premium_amount_mismatch", deal_id=None, reason=reason)
        await _fail(db, payment, "amount_mismatch")
        return
    await _settle(db, payment, result.receipt)


async def payment_status(db: AsyncSession, user_id: str, payment_id: str) -> dict:
    """Where a plan payment stands - asking Safaricom when the callback is
    late, never writing a slow one off (see pricing/payments.py)."""
    payment = await db.get(SubscriptionPayment, payment_id)
    if payment is None or payment.user_id != user_id:
        raise HTTPException(status_code=404, detail="Payment not found")

    if (payment.status == S.PENDING and payment.checkout_request_id
            and datetime.utcnow() - payment.created_at >= QUERY_AFTER):
        try:
            answer = await mpesa_stk.stk_query(payment.checkout_request_id)
        except mpesa_stk.MpesaUnavailable:
            answer = {}
        outcome = mpesa_stk.query_outcome(answer)
        if outcome is not None:
            locked = await _locked_payment(db, SubscriptionPayment.id == payment.id)
            if locked is not None and not locked.processed:
                if outcome:
                    await _settle(db, locked, None)
                else:
                    await _fail(db, locked, answer.get("ResultDesc") or "not completed")
            else:
                await db.rollback()
            payment = await db.get(SubscriptionPayment, payment_id, populate_existing=True)

    return {
        "payment_id": payment.id,
        "status": payment.status,
        "plan_id": payment.plan_id,
        "months": payment.months,
        "amount": payment.amount,
        "failure_reason": payment.failure_reason,
        "paid_until": payment.period_end.isoformat() if payment.period_end else None,
    }
