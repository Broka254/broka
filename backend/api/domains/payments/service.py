"""Money users pay BROKA, through ZetuPay.

Listing fees, premium plans, featured boosts and verification badges. Deal
money never comes here: a buyer pays a seller through E-Confirm
(domains/escrow), and there is no purpose for it (models/zetupay.Purpose).

One payment:

  start()        The domain (pricing, premium, featured, verify) has added
                 its own pending row. This writes the ZetuPay payment under a
                 new reference and commits both, then asks ZetuPay for the
                 prompt - committed first, so a webhook that beats ZetuPay's
                 202 back still finds its reference. The 202 buys nothing:
                 the payment only moves to "processing".
  apply_event()  ZetuPay's webhook, or its status endpoint when the webhook
                 is late, says how it ended. Applied once:
                   * the transaction's (waveTransactionId, status) goes into
                     zetupay_transactions first - a unique row, so a
                     redelivered webhook, or one racing the status poll,
                     stops there;
                   * the payment is row-locked and re-read: whoever holds
                     the lock decides;
                   * only the amount asked for buys anything. Another amount,
                     a second payment for a reference already paid, or money
                     for a reference BROKA never issued is recorded, audited
                     and raised as a reconciliation alert - the payer is owed
                     it back, and a person has to send it;
                   * what a payment buys is its domain's business: the
                     domain's zetupay_settled()/zetupay_failed() run under the
                     same lock and commit with it.
  refresh()      The app's status poll, and the sweep, ask ZetuPay by the
                 payment's paymentKey. ZetuPay sends webhooks for successes
                 only, so asking is how a cancelled or failed prompt is
                 learnt of. A payment is never failed for being slow, and a
                 success that arrives after a failure - a prompt that timed
                 out here and was paid anyway, which only its webhook can
                 report - is still applied: the money is real.
"""
from __future__ import annotations

import logging
import secrets
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import zetupay
from api.core.audit import record_audit
from api.core.config import settings
from api.core.reconciliation import report_reconciliation
from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayStatus as S, ZetuPayTransaction

logger = logging.getLogger(__name__)

PROVIDER = "zetupay"

# A prompt still on the phone blocks another for the same thing this long -
# two prompts both approved would take the money twice.
PENDING_WINDOW = timedelta(minutes=2)
# The status poll asks ZetuPay once a payment is this old: ZetuPay suggests
# polling every 5 seconds for up to 2 minutes, since a failed prompt sends no
# webhook.
QUERY_AFTER = timedelta(seconds=5)
# The sweep asks about payments older than a prompt's life and younger than
# a day; past that a person reconciles from ZetuPay's dashboard.
SWEEP_AFTER = timedelta(minutes=2)
SWEEP_UNTIL = timedelta(hours=24)
SWEEP_BATCH = 100

# What start() answers when ZetuPay timed out: the prompt may still come.
TIMED_OUT = "provider_timeout"

_PREFIX = {
    Purpose.LISTING_FEE: "LF",
    Purpose.SUBSCRIPTION: "PL",
    Purpose.BOOST: "BS",
    Purpose.VERIFICATION: "VB",
    Purpose.TEST: "TS",
}
# Crockford base32: no I, L, O or U to misread off an M-PESA message.
_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def enabled() -> bool:
    """ZETUPAY_ENABLED - honoured only once core/zetupay.py's API contract
    is marked verified."""
    return settings.zetupay_enabled and zetupay.CONTRACT_VERIFIED


def new_reference(purpose: str) -> str:
    """Twelve characters, M-PESA's account-reference limit: the purpose,
    then 50 random bits (LF7K3M9Q2XAB). Unguessable, so nobody can aim a
    payment, or a forged result, at someone else's charge."""
    return _PREFIX[purpose] + "".join(secrets.choice(_ALPHABET) for _ in range(10))


def unavailable_detail(exc: zetupay.ZetuPayUnavailable) -> str:
    """What the app shows when start() raised."""
    if isinstance(exc, zetupay.ZetuPayTimeout):
        return ("M-Pesa is slow to answer. If a prompt reaches your phone you can "
                "still pay it; otherwise try again in a moment.")
    return "Couldn't reach M-Pesa. Try again in a moment."


def _domain(purpose: str):
    """The module that owns what `purpose` buys. Imported here, not at the
    top: each of them imports this module."""
    if purpose == Purpose.LISTING_FEE:
        from api.domains.pricing import payments as module
    elif purpose == Purpose.SUBSCRIPTION:
        from api.domains.premium import payments as module
    elif purpose == Purpose.BOOST:
        from api.routers import featured as module
    elif purpose == Purpose.VERIFICATION:
        from api.routers import verify as module
    elif purpose == Purpose.TEST:
        from api.domains.payments import test_charge as module
    else:
        raise ValueError(f"no domain for purpose {purpose!r}")
    return module


async def _locked(db: AsyncSession, condition) -> Optional[ZetuPayPayment]:
    """The payment, row-locked and re-read: whoever holds the lock decides."""
    return (await db.execute(
        select(ZetuPayPayment).where(condition)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()


async def prompt_pending(db: AsyncSession, user_id: str, purpose: str, related_id: str) -> bool:
    """Whether a prompt for the same thing is probably still on the phone."""
    return (await db.execute(
        select(ZetuPayPayment.id).where(
            ZetuPayPayment.user_id == user_id,
            ZetuPayPayment.purpose == purpose,
            ZetuPayPayment.related_id == related_id,
            ZetuPayPayment.status.in_((S.INITIATED, S.PROCESSING)),
            ZetuPayPayment.created_at > datetime.utcnow() - PENDING_WINDOW,
        ).limit(1)
    )).scalar() is not None


async def start(
    db: AsyncSession, *, user_id: str, purpose: str, amount: int, phone: str,
    target_id: str, related_id: Optional[str], description: str,
    reference: Optional[str] = None,
) -> ZetuPayPayment:
    """Charge `amount` KES for the domain row `target_id`, which the caller
    has added to `db` and not committed.

    Raises ZetuPayUnavailable when no prompt was sent, or ZetuPay did not
    say; the payment and the domain row are then failed (a payment that
    arrives anyway is still applied).
    """
    if purpose not in Purpose.ALL:
        raise ValueError(f"not a BROKA charge: {purpose!r}")
    now = datetime.utcnow()
    payment = ZetuPayPayment(
        reference=reference or new_reference(purpose), user_id=user_id, purpose=purpose,
        amount=int(amount), phone=phone, description=description[:64],
        target_id=target_id, related_id=related_id, status=S.INITIATED,
        created_at=now, updated_at=now,
    )
    db.add(payment)
    await db.commit()

    try:
        accepted = await zetupay.stk_push(phone, payment.amount, payment.reference)
    except zetupay.ZetuPayUnavailable as exc:
        logger.warning("[zetupay] no prompt for %s (%s): %s", payment.reference, purpose, exc)
        locked = await _locked(db, ZetuPayPayment.id == payment.id)
        # Unless the webhook got there first - a prompt answered while our
        # request timed out.
        if locked is not None and locked.status == S.INITIATED:
            reason = TIMED_OUT if isinstance(exc, zetupay.ZetuPayTimeout) else "prompt_not_sent"
            await _fail(db, locked, reason)
        await db.commit()
        raise

    locked = await _locked(db, ZetuPayPayment.id == payment.id)
    if locked.status == S.INITIATED:
        locked.status = S.PROCESSING
    locked.provider_payment_id = locked.provider_payment_id or accepted.payment_key
    locked.wave_transaction_id = locked.wave_transaction_id or accepted.wave_transaction_id
    locked.updated_at = datetime.utcnow()
    await db.commit()
    return locked


async def _fail(db: AsyncSession, payment: ZetuPayPayment, reason: str) -> None:
    payment.status = S.FAILED
    payment.failure_reason = reason[:200]
    payment.updated_at = datetime.utcnow()
    await _domain(payment.purpose).zetupay_failed(db, payment.target_id, payment.failure_reason)


async def _settle(db: AsyncSession, payment: ZetuPayPayment, event: zetupay.ZetuPayEvent) -> None:
    now = datetime.utcnow()
    payment.status = S.SUCCESS
    payment.wave_transaction_id = event.wave_transaction_id or payment.wave_transaction_id
    payment.mpesa_receipt = event.receipt
    payment.failure_reason = None
    payment.settled_at = payment.updated_at = now
    await record_audit(
        db, payment.user_id, "zetupay_payment_settled", "zetupay_payment", payment.id,
        f"reference={payment.reference} purpose={payment.purpose} amount={payment.amount} "
        f"target={payment.target_id} wave={event.wave_transaction_id} receipt={event.receipt}",
    )
    await _domain(payment.purpose).zetupay_settled(db, payment.target_id, event.receipt)


async def _flag(db: AsyncSession, kind: str, resource_id: str, reason: str,
                event: zetupay.ZetuPayEvent) -> None:
    """Money a person has to give back or match by hand: an audit row (the
    durable record) and a reconciliation alert (how a person hears)."""
    logger.error("[zetupay] %s: %s", kind, reason)
    await record_audit(db, "system", kind, "zetupay_payment", resource_id, reason)
    report_reconciliation(kind, deal_id=None, reason=reason,
                          provider_transaction_id=event.wave_transaction_id)


def _outcome(payment: Optional[ZetuPayPayment], event: zetupay.ZetuPayEvent) -> str:
    if payment is None:
        return "unknown_reference" if event.status == zetupay.SUCCESS else "ignored"
    if event.status == zetupay.FAILED:
        return "failed" if payment.status in (S.INITIATED, S.PROCESSING) else "ignored"
    if not zetupay.amount_matches(event, payment.amount):
        return "amount_mismatch"
    if payment.status != S.SUCCESS:
        return "applied"
    if (event.wave_transaction_id and payment.wave_transaction_id
            and event.wave_transaction_id != payment.wave_transaction_id):
        return "duplicate_payment"
    return "ignored"


async def apply_event(db: AsyncSession, event: zetupay.ZetuPayEvent, source: str) -> str:
    """Apply what ZetuPay says happened. Returns the outcome: applied,
    failed, amount_mismatch, duplicate_payment, unknown_reference, ignored,
    or duplicate (this transaction state was already handled)."""
    if event.status == zetupay.PENDING:
        return "ignored"

    ledger = None
    if event.wave_transaction_id:
        ledger = ZetuPayTransaction(
            wave_transaction_id=event.wave_transaction_id, status=event.status,
            reference=(event.reference or "")[:64] or None, amount=event.amount,
            mpesa_receipt=event.receipt, source=source, outcome="received",
            received_at=datetime.utcnow(),
        )
        db.add(ledger)
        try:
            await db.flush()
        except IntegrityError:
            await db.rollback()
            return "duplicate"

    payment = await _locked(db, ZetuPayPayment.reference == event.reference) if event.reference else None
    outcome = _outcome(payment, event)
    if ledger is not None:
        # Set before acting: the domain handlers commit.
        ledger.payment_id = payment.id if payment is not None else None
        ledger.outcome = outcome

    if outcome == "applied":
        await _settle(db, payment, event)
    elif outcome == "failed":
        await _fail(db, payment, event.reason)
    elif outcome == "amount_mismatch":
        await _flag(db, "zetupay_amount_mismatch", payment.id, (
            f"ZetuPay {event.wave_transaction_id or '-'} for {payment.reference} ({payment.purpose}) "
            f"reported {event.amount} {event.currency or 'KES'}, expected KES {payment.amount} "
            f"(receipt {event.receipt}) - not applied, refund the payer"), event)
        if payment.status != S.SUCCESS:
            await _fail(db, payment, "amount_mismatch")
    elif outcome == "duplicate_payment":
        await _flag(db, "zetupay_duplicate_payment", payment.id, (
            f"Second ZetuPay payment {event.wave_transaction_id} (KES {event.amount}, receipt "
            f"{event.receipt}) for {payment.reference} ({payment.purpose}), already paid by "
            f"{payment.wave_transaction_id} - not applied, refund the payer"), event)
    elif outcome == "unknown_reference":
        await _flag(db, "zetupay_unknown_reference",
                    event.wave_transaction_id or event.reference or "unknown", (
            f"ZetuPay payment {event.wave_transaction_id or '-'} (KES {event.amount}, receipt "
            f"{event.receipt}) for reference {event.reference!r}, which BROKA never issued - "
            "nothing applied, refund the payer or match it by hand"), event)
    await db.commit()
    if outcome != "ignored":
        logger.info("[zetupay] %s %s via %s: %s", event.reference, event.status, source, outcome)
    return outcome


async def _ask(db: AsyncSession, reference: str, payment_key: str) -> Optional[str]:
    try:
        event = await zetupay.transaction_status(payment_key, reference)
    except zetupay.ZetuPayUnavailable as exc:
        logger.info("[zetupay] status of %s not known: %s", reference, exc)
        return None
    if event is None:
        return None
    return await apply_event(db, event, source="status_query")


async def refresh(db: AsyncSession, purpose: str, target_id: str) -> None:
    """For a domain's status poll: ask ZetuPay how the payment for its row
    stands, once the webhook is late."""
    payment = (await db.execute(
        select(ZetuPayPayment).where(
            ZetuPayPayment.purpose == purpose, ZetuPayPayment.target_id == target_id,
        )
    )).scalar_one_or_none()
    if (payment is None or not payment.provider_payment_id
            or payment.status not in (S.INITIATED, S.PROCESSING)
            or datetime.utcnow() - payment.created_at < QUERY_AFTER):
        return
    await _ask(db, payment.reference, payment.provider_payment_id)


async def status_by_reference(db: AsyncSession, reference: str) -> Optional[ZetuPayPayment]:
    """The payment under `reference`, after asking ZetuPay if it is still
    unfinished. For the admin lookup; re-read, since asking can roll back."""
    row = (await db.execute(
        select(ZetuPayPayment.status, ZetuPayPayment.provider_payment_id)
        .where(ZetuPayPayment.reference == reference)
    )).one_or_none()
    if row is None:
        return None
    status, payment_key = row
    if status in (S.INITIATED, S.PROCESSING) and payment_key:
        await _ask(db, reference, payment_key)
    return (await db.execute(
        select(ZetuPayPayment).where(ZetuPayPayment.reference == reference)
        .execution_options(populate_existing=True)
    )).scalar_one()


def payment_dict(payment: ZetuPayPayment) -> dict:
    return {
        "reference": payment.reference,
        "purpose": payment.purpose,
        "amount": payment.amount,
        "status": payment.status,
        "payment_key": payment.provider_payment_id,
        "wave_transaction_id": payment.wave_transaction_id,
        "mpesa_receipt": payment.mpesa_receipt,
        "failure_reason": payment.failure_reason,
        "created_at": payment.created_at.isoformat() if payment.created_at else None,
        "settled_at": payment.settled_at.isoformat() if payment.settled_at else None,
    }


async def reconcile_stale(db: AsyncSession, now: Optional[datetime] = None) -> int:
    """The sweep: ask ZetuPay about unfinished payments nobody is polling -
    a lost webhook, or a prompt cancelled after the app stopped asking.
    Returns how many it settled or failed. A prompt that timed out here has
    no paymentKey to ask about; its success webhook still lands."""
    now = now or datetime.utcnow()
    rows = (await db.execute(
        select(ZetuPayPayment.reference, ZetuPayPayment.provider_payment_id).where(
            ZetuPayPayment.created_at <= now - SWEEP_AFTER,
            ZetuPayPayment.created_at >= now - SWEEP_UNTIL,
            ZetuPayPayment.status.in_((S.INITIATED, S.PROCESSING)),
            ZetuPayPayment.provider_payment_id.is_not(None),
        ).order_by(ZetuPayPayment.created_at).limit(SWEEP_BATCH)
    )).all()
    changed = 0
    for reference, payment_key in rows:
        if await _ask(db, reference, payment_key) in ("applied", "failed", "amount_mismatch"):
            changed += 1
    return changed
