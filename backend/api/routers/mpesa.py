"""
BROKA - M-Pesa Router (Daraja API v2 - M-Pesa Express / STK Push)

ENV VARS REQUIRED (set in the host's dashboard - Railway):
  MPESA_CONSUMER_KEY    - from Safaricom Daraja portal (BROKA sandbox app)
  MPESA_CONSUMER_SECRET - from Safaricom Daraja portal (BROKA sandbox app)
  MPESA_SHORTCODE       - 174379 (sandbox default)
  MPESA_PASSKEY         - bfb279f9aa9bdbcf158e97dd71a467cd2e0c893059b10f78e6b72ada1ed2c919
  MPESA_CALLBACK_URL    - https://api.broka.co.ke/mpesa/callback
  MPESA_ENV             - sandbox | production
"""

import os
import base64
import hashlib
import httpx
import logging
from datetime import datetime, timezone, timedelta
from decimal import Decimal
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from pydantic import BaseModel

from api.database import get_db, Deal, DealStatus, User, MpesaTransaction, MpesaStatus
from api.security import get_current_user, verify_password_async
from api.core.events import publish, EscrowFunded, MpesaCallbackReceived
from api.core.audit import record_audit
from api.core.rate_limit import stk_limiter
from api.models.payment_callback import PaymentCallback, PaymentCallbackStatus
from api.domains.pricing.safe_payment import require_in_app_payments

logger = logging.getLogger(__name__)
router = APIRouter()

# ── Config ────────────────────────────────────────────────────────────────────

MPESA_ENV      = os.getenv("MPESA_ENV", "sandbox")
CONSUMER_KEY   = os.getenv("MPESA_CONSUMER_KEY", "")
CONSUMER_SECRET= os.getenv("MPESA_CONSUMER_SECRET", "")
SHORTCODE      = os.getenv("MPESA_SHORTCODE", "174379")
PASSKEY        = os.getenv("MPESA_PASSKEY", "")

# Safaricom's callback protocol has no way to sign/verify the webhook body,
# so the callback endpoint is authenticated by a secret path segment instead
# (this is the standard mitigation for Daraja integrations). Without this,
# ANYONE who knows/discovers the fixed `/mpesa/callback` URL - including a
# buyer replaying their own CheckoutRequestID from a legitimate /stk-push
# call they made themselves - could POST a fabricated "payment succeeded"
# callback and get a deal marked `paid` with no real money having moved.
#
# If MPESA_CALLBACK_SECRET is set, the callback URL Safaricom is told to use
# defaults to the protected `/mpesa/callback/{secret}` path; the old
# unauthenticated `/mpesa/callback` route is kept working (unless you have
# already registered a custom MPESA_CALLBACK_URL, in which case that exact
# value is always respected) so nothing breaks for existing deployments that
# haven't set the secret yet. See mpesa_callback()/mpesa_callback_secured()
# below.
CALLBACK_SECRET = os.getenv("MPESA_CALLBACK_SECRET", "")
_DEFAULT_CALLBACK_BASE = "https://api.broka.co.ke/mpesa/callback"
if os.getenv("MPESA_CALLBACK_URL"):
    # Deployer set this explicitly - always respect it verbatim.
    CALLBACK_URL = os.getenv("MPESA_CALLBACK_URL", _DEFAULT_CALLBACK_BASE)
elif CALLBACK_SECRET:
    CALLBACK_URL = f"{_DEFAULT_CALLBACK_BASE}/{CALLBACK_SECRET}"
else:
    CALLBACK_URL = _DEFAULT_CALLBACK_BASE

BASE_URL  = "https://api.safaricom.co.ke" if MPESA_ENV == "production" else "https://sandbox.safaricom.co.ke"
OAUTH_URL = f"{BASE_URL}/oauth/v1/generate?grant_type=client_credentials"
STK_URL   = f"{BASE_URL}/mpesa/stkpush/v1/processrequest"
QUERY_URL = f"{BASE_URL}/mpesa/stkpushquery/v1/query"


# ── Helpers ───────────────────────────────────────────────────────────────────

async def _get_access_token() -> str:
    credentials = base64.b64encode(f"{CONSUMER_KEY}:{CONSUMER_SECRET}".encode()).decode()
    # OAuth responses contain a bearer token and error bodies can echo request
    # credentials. Log only routing/status facts; never the configured key,
    # response body, or the token itself.
    logger.info("M-Pesa OAuth attempt - ENV=%s SHORTCODE=%s URL=%s",
                MPESA_ENV, SHORTCODE, OAUTH_URL)
    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.get(OAUTH_URL, headers={"Authorization": f"Basic {credentials}"})
    logger.info("M-Pesa OAuth response - status=%s", resp.status_code)
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail="M-Pesa authentication failed")
    try:
        return resp.json()["access_token"]
    except (KeyError, TypeError, ValueError) as exc:
        logger.error("M-Pesa OAuth response missing access_token (status=%s)", resp.status_code)
        raise HTTPException(status_code=502, detail="M-Pesa authentication failed") from exc


def _generate_password() -> tuple[str, str]:
    # Daraja requires the timestamp in Nairobi local time (EAT, UTC+3).
    # Servers run UTC, so derive EAT explicitly instead of using datetime.now().
    nairobi = datetime.now(timezone.utc) + timedelta(hours=3)
    timestamp = nairobi.strftime("%Y%m%d%H%M%S")
    raw       = f"{SHORTCODE}{PASSKEY}{timestamp}"
    password  = base64.b64encode(raw.encode()).decode()
    return timestamp, password


def _normalize_phone(phone: str) -> str:
    """Convert 07XXXXXXXX → 2547XXXXXXXX"""
    phone = phone.strip().replace(" ", "").replace("-", "")
    if phone.startswith("0"):
        phone = "254" + phone[1:]
    elif phone.startswith("+"):
        phone = phone[1:]
    return phone


# ── Schemas ───────────────────────────────────────────────────────────────────

class StkPushRequest(BaseModel):
    deal_id:      str
    phone_number: str   # 07XX or 2547XX
    password:     str   # user's BROKA account password for authorization


class StkQueryRequest(BaseModel):
    checkout_request_id: str


def _request_fingerprint(deal_id: str, phone: str, amount: int) -> str:
    """The request an idempotency key belongs to. Reusing the key with a
    different phone, deal or amount is a conflict, not a retry."""
    raw = f"{deal_id}\n{phone}\n{amount:.2f}".encode()
    return hashlib.sha256(raw).hexdigest()


def _txn_response(txn: MpesaTransaction) -> dict:
    return {
        "checkout_request_id": txn.checkout_request_id,
        "merchant_request_id": txn.merchant_request_id,
        "amount": txn.amount,
        "status": txn.status.value,
        "customer_message": (
            "This payment request is already in progress. Check your phone; "
            "do not start another payment."
        ),
    }


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/stk-push", dependencies=[Depends(require_in_app_payments)])
async def initiate_stk_push(
    data: StkPushRequest,
    current_user=Depends(get_current_user),
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
    db: AsyncSession = Depends(get_db),
):
    """
    Trigger M-Pesa STK push to buyer's phone for the BROKA commission.
    Requires the user's BROKA password as a second-factor authorization.
    Only the buyer of the deal may initiate.
    """
    # 1. Verify user's password before doing anything
    user_result = await db.execute(select(User).where(User.id == current_user["id"]))
    user = user_result.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    if not await verify_password_async(data.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Incorrect password")

    # Keyed on the authenticated user, never the phone or deal supplied in
    # the body: a caller-chosen value is no limit at all.
    await stk_limiter.check_and_record(current_user["id"])

    # 2. Load and validate deal
    deal_result = await db.execute(select(Deal).where(Deal.id == data.deal_id))
    deal = deal_result.scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    if deal.buyer_id != current_user["id"]:
        raise HTTPException(status_code=403, detail="Only the buyer can pay the commission")
    if deal.status not in (DealStatus.agreed,):
        raise HTTPException(status_code=400, detail="Deal is not in 'agreed' state")

    # 3. Calculate amount (whole KES, minimum 1)
    amount = max(1, int(round(deal.commission)))
    phone  = _normalize_phone(data.phone_number)

    client_ref = (x_idempotency_key or "").strip() or None
    if client_ref and len(client_ref) > 200:
        raise HTTPException(status_code=400, detail="X-Idempotency-Key is too long")
    fingerprint = _request_fingerprint(deal.id, phone, amount)

    # A retry of the SAME logical request replays the intent. A different
    # request reusing the key is refused. Both checks happen before the
    # provider call, so neither can create a second prompt.
    if client_ref:
        earlier = (await db.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.deal_id == deal.id,
                MpesaTransaction.client_ref == client_ref,
            )
        )).scalar_one_or_none()
        if earlier is not None:
            if earlier.request_fingerprint != fingerprint:
                raise HTTPException(status_code=409, detail="Idempotency key reused with a different payment request")
            return _txn_response(earlier)

    open_intent = (await db.execute(
        select(MpesaTransaction).where(
            MpesaTransaction.deal_id == deal.id,
            MpesaTransaction.status == MpesaStatus.pending,
            MpesaTransaction.callback_processed.is_(False),
        ).order_by(MpesaTransaction.created_at.desc()).limit(1)
    )).scalar_one_or_none()
    if open_intent is not None:
        if open_intent.checkout_request_id:
            return _txn_response(open_intent)
        raise HTTPException(
            status_code=409,
            detail=("A payment request for this deal already reached M-Pesa, but "
                    "its outcome is not yet confirmed. Do not start another payment; "
                    "check the deal status or contact support."),
        )

    # Persist the intent BEFORE calling Safaricom. `active_intent` is unique,
    # so two concurrent requests cannot both own the right to prompt; the
    # loser gets a 409 instead of a second STK push.
    txn = MpesaTransaction(
        deal_id=deal.id,
        buyer_id=current_user["id"],
        phone=phone,
        amount=amount,
        checkout_request_id=None,
        status=MpesaStatus.pending,
        active_intent=deal.id,
        client_ref=client_ref,
        request_fingerprint=fingerprint,
    )
    db.add(txn)
    try:
        await db.commit()
    except IntegrityError:
        await db.rollback()
        raise HTTPException(
            status_code=409,
            detail="A payment request for this deal is already in progress. Check your phone.",
        )

    # 4. Get Safaricom access token
    try:
        token = await _get_access_token()
    except Exception as exc:
        # No prompt can have been sent: authentication happens before the
        # STK request. The intent is safely terminal and can be retried.
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = f"oauth failed: {type(exc).__name__}"
        await db.commit()
        raise
    timestamp, password = _generate_password()

    # 5. STK Push payload
    payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          password,
        "Timestamp":         timestamp,
        "TransactionType":   "CustomerPayBillOnline",
        "Amount":            amount,
        "PartyA":            phone,
        "PartyB":            SHORTCODE,
        "PhoneNumber":       phone,
        "CallBackURL":       CALLBACK_URL,
        "AccountReference":  f"BROKA-{deal.id[:8].upper()}",
        "TransactionDesc":   f"BROKA commission for deal {deal.id[:8]}",
    }

    try:
        async with httpx.AsyncClient(timeout=30) as client:
            resp = await client.post(
                STK_URL,
                json=payload,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            )
    except httpx.TimeoutException as exc:
        # Safaricom may have accepted the prompt. Leave the intent pending so
        # a retry cannot send a second one; the callback or reconciliation
        # decides what actually happened.
        txn.last_error = f"provider timeout: {type(exc).__name__}"
        await db.commit()
        logger.error("[mpesa] STK outcome ambiguous for deal=%s (timeout)", deal.id)
        raise HTTPException(
            status_code=503,
            detail=("M-Pesa did not answer in time. If a prompt reaches your phone, "
                    "complete it; otherwise check the deal status before trying again."),
        )
    except httpx.HTTPError as exc:
        txn.last_error = f"provider transport error: {type(exc).__name__}"
        await db.commit()
        raise HTTPException(status_code=502, detail="Couldn't reach M-Pesa. Check the deal status before retrying.")

    if resp.status_code != 200:
        # Status only in the log, fixed text to the client: the upstream body
        # is Safaricom's, not ours to forward, and can carry request details.
        logger.warning("[mpesa] STK push HTTP %s for deal=%s", resp.status_code, deal.id)
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = f"provider HTTP {resp.status_code}"
        await db.commit()
        raise HTTPException(status_code=502, detail="M-Pesa is not accepting payment requests right now. Please try again.")

    body = resp.json()
    if body.get("ResponseCode") != "0":
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = "provider rejected request"
        await db.commit()
        raise HTTPException(
            status_code=400,
            detail=body.get("ResponseDescription", "M-Pesa rejected the request"),
        )

    # 6. Record the provider's identifiers on the intent we already own.
    txn.checkout_request_id = body["CheckoutRequestID"]
    txn.merchant_request_id = body["MerchantRequestID"]
    txn.last_error = None
    await db.commit()

    # A callback may have arrived between the provider accepting the prompt
    # and this commit. Drain it now that the CheckoutRequestID is visible.
    await _drain_callback_inbox(db, txn.checkout_request_id)

    return {
        "checkout_request_id":  body["CheckoutRequestID"],
        "merchant_request_id":  body["MerchantRequestID"],
        "response_description": body.get("ResponseDescription", ""),
        "customer_message":     body.get("CustomerMessage", "Check your phone to complete payment"),
        "amount":               amount,
    }


@router.post("/query")
async def query_payment_status(
    data: StkQueryRequest,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Poll Safaricom for STK push result.

    Only the buyer who started the push may poll it - it used to accept any
    CheckoutRequestID from any signed-in user. A confirmed success is applied
    through _settle_successful_stk, the same guarded path the callback uses,
    rather than by writing `deal.status = paid` directly: the direct write
    skipped the agreed-only guard (so it could revive a cancelled or released
    deal) and published nothing, which meant a query that beat the callback
    left the deal paid with NO ledger entry - the callback then saw a paid
    deal and stood down.
    """
    txn = (await db.execute(
        select(MpesaTransaction).where(
            MpesaTransaction.checkout_request_id == data.checkout_request_id
        )
    )).scalar_one_or_none()
    if txn is None or txn.buyer_id != current_user["id"]:
        # One answer for both, so the endpoint can't be used to probe which
        # checkout ids exist.
        raise HTTPException(status_code=404, detail="Payment not found")

    token = await _get_access_token()
    timestamp, password = _generate_password()

    payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          password,
        "Timestamp":         timestamp,
        "CheckoutRequestID": data.checkout_request_id,
    }

    async with httpx.AsyncClient(timeout=15) as client:
        resp = await client.post(
            QUERY_URL,
            json=payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )

    body = resp.json()

    # Mirror a FINAL result to the DB, once. Safaricom's query is answered
    # to us over our own authenticated call, so ResultCode 0 for our own
    # CheckoutRequestID is trustworthy, and the amount is the one we
    # requested (an STK prompt's amount cannot be changed by the payer).
    # Re-read under the row lock: the callback may have landed while the
    # provider request was in flight.
    txn = (await db.execute(
        select(MpesaTransaction).where(MpesaTransaction.id == txn.id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one()
    if not txn.callback_processed:
        result_code = body.get("ResultCode")
        if str(result_code) == "0":
            # A query response has no M-Pesa receipt. Do not mark the intent
            # fully processed yet: the callback carries the receipt, and it
            # must still be able to attach that evidence after this path has
            # already funded the deal.
            await _settle_successful_stk(db, txn, mark_processed=bool(txn.mpesa_receipt))
        elif result_code is not None and str(result_code) != "":
            txn.status = MpesaStatus.failed
            txn.callback_processed = True
            txn.active_intent = None
            await db.commit()

    return body


@router.post("/callback")
async def mpesa_callback(request: Request, db: AsyncSession = Depends(get_db)):
    """
    Legacy path, kept only for deployments that registered this exact URL
    with Safaricom before MPESA_CALLBACK_SECRET existed. Update your Daraja
    app / M-Pesa dashboard to call /mpesa/callback/<secret> instead, then
    this route stops accepting anything at all - see the check below.

    SECURITY: this route used to log a warning and process the callback
    anyway once a secret was configured, which meant the warning did
    nothing - anyone could still POST a forged {"ResultCode": 0, ...}
    body with a guessed/observed CheckoutRequestID and have a deal marked
    paid, or a seller's rating bumped, with no real M-Pesa payment having
    happened. Fixed: once CALLBACK_SECRET is set, this route rejects
    outright rather than merely logging. It only still processes
    callbacks when NO secret is configured at all (i.e. local/sandbox
    setups that haven't set MPESA_CALLBACK_SECRET yet) - and
    validate_startup() now refuses to start in production without one
    set, so this permissive path cannot exist in a real deployment.
    """
    if CALLBACK_SECRET:
        logger.warning(
            "Rejected M-Pesa callback on the UNPROTECTED /mpesa/callback "
            "route - MPESA_CALLBACK_SECRET is configured, so only "
            "/mpesa/callback/<secret> is accepted. Update Safaricom's "
            "registered callback URL."
        )
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_mpesa_callback(request, db)


@router.post("/callback/{secret}")
async def mpesa_callback_secured(secret: str, request: Request, db: AsyncSession = Depends(get_db)):
    """Secret-protected Safaricom webhook - this is the one MPESA_CALLBACK_URL
    should point to once MPESA_CALLBACK_SECRET is set."""
    if not CALLBACK_SECRET or secret != CALLBACK_SECRET:
        # Deliberately vague/404-shaped rather than 403, so a guesser can't
        # distinguish "wrong secret" from "route doesn't exist".
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_mpesa_callback(request, db)


async def _settle_successful_stk(
    db: AsyncSession, txn: MpesaTransaction, *, mark_processed: bool = True,
) -> None:
    """Apply a CONFIRMED successful STK payment to its transaction and deal.

    The one place a legacy M-Pesa payment moves a deal, shared by the
    Safaricom callback and /mpesa/query so the two can never disagree:

      * the deal moves agreed -> paid only, under the deal row lock
        (lock_deal_if_status). Without the guard a late or replayed result
        could drag a released/refunded/cancelled deal back to `paid`,
        re-opening a settled deal for a second release;
      * the escrow ledger is written in the SAME transaction as the deal
        status. It used to be written by a post-commit event subscriber
        whose errors were only logged, so a committed payment could have no
        ledger entry and nothing would retry it;
      * EscrowFunded is published after commit only for the WebSocket
        broadcast (the subscriber sees the ledger row already exists);
      * callback_processed marks the transaction done, so whichever of the
        callback and the query arrives second is a no-op.

    Deliberately NOT here: `seller.completed_deals += 1` and a +0.05 rating
    bump, both removed earlier. completed_deals is credited once, at
    release; and a rating that raises itself on payment is a fabricated
    review on a marketplace whose whole value is trust.
    """
    from api.core.audit import record_audit
    from api.domains.escrow.service import _FUNDED_OR_LATER, lock_deal_if_status

    txn.status = MpesaStatus.success
    txn.active_intent = None
    deal = await lock_deal_if_status(db, txn.deal_id, (DealStatus.agreed,))
    if deal is None:
        current = (await db.execute(
            select(Deal).where(Deal.id == txn.deal_id)
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        status_now = current.status if current is not None else None
        if mark_processed:
            txn.callback_processed = True
        txn.active_intent = None
        if status_now in _FUNDED_OR_LATER:
            logger.warning(
                "[mpesa] payment for deal=%s in status=%s - recording the "
                "payment but not changing deal status",
                txn.deal_id, status_now.value,
            )
        else:
            # Money for a deal that is cancelled (or gone). Somebody has to
            # refund this by hand: the audit row is the durable record
            # (GET /admin/audit-logs) and report_reconciliation raises the
            # Sentry alert that tells a person.
            reason = (
                f"M-Pesa payment {txn.mpesa_receipt or txn.checkout_request_id} "
                f"of KES {txn.amount} received for deal in status "
                f"{status_now.value if status_now else 'missing'}"
            )
            await record_audit(
                db, "system", "mpesa_payment_on_inactive_deal", "deal", txn.deal_id, reason,
            )
            from api.core.reconciliation import report_reconciliation
            report_reconciliation(
                "mpesa_payment_on_inactive_deal", deal_id=txn.deal_id,
                reason=f"{reason} - refund the buyer by hand",
                checkout_request_id=txn.checkout_request_id,
            )
        await db.commit()
        return

    deal.status = DealStatus.paid
    if mark_processed:
        txn.callback_processed = True

    # Atomic with the deal transition. If this raises, the callback returns
    # 500 and neither the status change nor a partial ledger pair commits.
    from api.core.ledger import ledger
    await ledger.record_escrow_funded(
        db, deal.id, deal.buyer_id, txn.amount,
        txn.mpesa_receipt or txn.checkout_request_id or txn.id,
    )
    await db.commit()

    # After commit, so subscribers see a consistent database.
    await publish(EscrowFunded(
        deal_id=deal.id,
        buyer_id=deal.buyer_id,
        seller_id=deal.seller_id,
        amount=txn.amount,
        mpesa_receipt=txn.mpesa_receipt or "",
    ))


def _callback_fields(body: dict) -> tuple[Optional[str], Optional[str], Optional[Decimal], Optional[str], str]:
    """The non-secret fields needed to apply an STK callback.

    Deliberately excludes the payer's phone number and the raw provider
    body: those have no role in matching and must not end up in the durable
    inbox or a log line.
    """
    stk = ((body or {}).get("Body") or {}).get("stkCallback") or {}
    items = {i.get("Name"): i.get("Value")
             for i in ((stk.get("CallbackMetadata") or {}).get("Item") or [])}
    amount = None
    try:
        if items.get("Amount") is not None:
            amount = Decimal(str(items.get("Amount")))
    except (TypeError, ValueError, ArithmeticError):
        amount = None
    receipt = str(items.get("MpesaReceiptNumber") or "").strip() or None
    raw_code = stk.get("ResultCode")
    result_code = None if raw_code is None or str(raw_code).strip() == "" else str(raw_code)
    return (
        stk.get("CheckoutRequestID") or None,
        result_code,
        amount,
        receipt,
        str(stk.get("ResultDesc") or ""),
    )


async def _remember_callback(
    db: AsyncSession, checkout_id: str, result_code: str,
    amount: Optional[Decimal], receipt: Optional[str], description: str,
) -> PaymentCallback:
    """Persist the callback before matching it.

    This is the durability boundary for a callback that beats the STK
    response. A duplicate delivery is recognised by the unique
    (provider, checkout_request_id) key rather than by application reads.
    """
    existing = (await db.execute(
        select(PaymentCallback).where(
            PaymentCallback.provider == "daraja",
            PaymentCallback.checkout_request_id == checkout_id,
        )
    )).scalar_one_or_none()
    if existing is not None:
        return existing

    row = PaymentCallback(
        provider="daraja", checkout_request_id=checkout_id,
        result_code=result_code, amount=amount, receipt=receipt,
        result_description=description[:200],
        status=PaymentCallbackStatus.PENDING,
    )
    db.add(row)
    try:
        await db.commit()
        return row
    except IntegrityError:
        await db.rollback()
        return (await db.execute(
            select(PaymentCallback).where(
                PaymentCallback.provider == "daraja",
                PaymentCallback.checkout_request_id == checkout_id,
            )
        )).scalar_one()


async def _apply_callback(
    db: AsyncSession, txn: MpesaTransaction, result_code: str,
    amount: Optional[Decimal], receipt: Optional[str], description: str,
) -> str:
    """Apply one callback to one locked payment intent. Returns its outcome."""
    if txn.callback_processed:
        return "duplicate"

    if result_code != "0":
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        logger.warning("[mpesa] payment failed cid=%s code=%s", txn.checkout_request_id, result_code)
        await db.commit()
        return "failed"

    reported = amount if amount is not None else None
    expected = Decimal(str(txn.amount or 0))
    amount_ok = reported is not None and expected > 0 and abs(reported - expected) < Decimal("0.01")
    if not amount_ok:
        reason = (f"M-Pesa callback for transaction {txn.id} reported {reported}, "
                  f"expected {expected} (receipt {receipt}) - not settled")
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = "amount mismatch"
        await record_audit(db, "system", "mpesa_amount_mismatch", "deal", txn.deal_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation(
            "mpesa_amount_mismatch", deal_id=txn.deal_id, reason=reason,
            checkout_request_id=txn.checkout_request_id,
        )
        await db.commit()
        return "amount_mismatch"

    if not receipt:
        reason = (f"M-Pesa callback for transaction {txn.id} succeeded without a receipt - "
                  "not settled; reconcile with Safaricom")
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = "missing receipt"
        await record_audit(db, "system", "mpesa_missing_receipt", "deal", txn.deal_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation(
            "mpesa_missing_receipt", deal_id=txn.deal_id, reason=reason,
            checkout_request_id=txn.checkout_request_id,
        )
        await db.commit()
        return "reconciliation_required"

    duplicate_receipt = (await db.execute(
        select(MpesaTransaction.id).where(
            MpesaTransaction.mpesa_receipt == receipt,
            MpesaTransaction.id != txn.id,
        ).limit(1)
    )).scalar()
    if duplicate_receipt:
        reason = (f"M-Pesa receipt {receipt} already belongs to transaction "
                  f"{duplicate_receipt}; transaction {txn.id} was not settled")
        txn.status = MpesaStatus.failed
        txn.callback_processed = True
        txn.active_intent = None
        txn.last_error = "duplicate receipt"
        await record_audit(db, "system", "mpesa_duplicate_receipt", "deal", txn.deal_id, reason)
        from api.core.reconciliation import report_reconciliation
        report_reconciliation(
            "mpesa_duplicate_receipt", deal_id=txn.deal_id, reason=reason,
            checkout_request_id=txn.checkout_request_id,
        )
        await db.commit()
        return "duplicate_receipt"

    txn.mpesa_receipt = receipt
    await _settle_successful_stk(db, txn)
    await publish(MpesaCallbackReceived(
        checkout_request_id=txn.checkout_request_id or "",
        result_code=0,
        mpesa_receipt=txn.mpesa_receipt or "",
        amount=txn.amount,
    ))
    return "applied"


async def _drain_callback_inbox(db: AsyncSession, checkout_id: str) -> Optional[str]:
    """Apply a previously-unknown callback once its payment row exists.

    Failure here is left for the sweep: the prompt has already been sent,
    so making the initiating HTTP response fail would not undo it.
    """
    row = (await db.execute(
        select(PaymentCallback).where(
            PaymentCallback.provider == "daraja",
            PaymentCallback.checkout_request_id == checkout_id,
            PaymentCallback.status == PaymentCallbackStatus.PENDING,
        ).with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if row is None:
        return None
    txn = (await db.execute(
        select(MpesaTransaction).where(MpesaTransaction.checkout_request_id == checkout_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if txn is None:
        await db.rollback()
        return None
    try:
        outcome = await _apply_callback(
            db, txn, row.result_code or "", row.amount, row.receipt, row.result_description or "",
        )
        row.status = PaymentCallbackStatus.PROCESSED
        row.processed_at = datetime.utcnow()
        row.attempts = (row.attempts or 0) + 1
        row.last_error = None
        await db.commit()
        return outcome
    except Exception as exc:
        await db.rollback()
        logger.exception("[mpesa] inbox callback retry failed cid=%s: %s", checkout_id, type(exc).__name__)
        return None


async def _process_mpesa_callback(request: Request, db: AsyncSession) -> dict:
    """Shared Safaricom STK callback handling for both routes above."""
    try:
        body = await request.json()
    except ValueError:
        raise HTTPException(status_code=400, detail="The callback body must be JSON")

    checkout_id, result_code, amount, receipt, description = _callback_fields(body)
    if not checkout_id or result_code is None:
        # An incomplete body is not evidence of failure. Reject it so it is
        # not recorded as a failed payment and cannot poison a live intent.
        raise HTTPException(status_code=400, detail="CheckoutRequestID and ResultCode are required")

    # Store first: a callback that beats the initiation response is still
    # durable, and a redelivery hits the unique row rather than re-applying.
    row = await _remember_callback(db, checkout_id, result_code, amount, receipt, description)
    if row.status == PaymentCallbackStatus.PROCESSED:
        return {"ResultCode": 0, "ResultDesc": "Accepted"}

    txn = (await db.execute(
        select(MpesaTransaction).where(MpesaTransaction.checkout_request_id == checkout_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if txn is None:
        # Leave the inbox row pending. The initiation path drains it after it
        # stores the CheckoutRequestID; the sweep retries if that process died.
        logger.warning("[mpesa] callback stored for not-yet-visible checkout cid=%s", checkout_id)
        return {"ResultCode": 0, "ResultDesc": "Accepted"}

    try:
        outcome = await _apply_callback(db, txn, result_code, amount, receipt, description)
        row = await db.get(PaymentCallback, row.id, populate_existing=True)
        if row is not None:
            row.status = PaymentCallbackStatus.PROCESSED
            row.processed_at = datetime.utcnow()
            row.attempts = (row.attempts or 0) + 1
            row.last_error = None
            await db.commit()
        logger.info("[mpesa] callback cid=%s outcome=%s", checkout_id, outcome)
    except Exception as exc:
        # A 500 makes Safaricom redeliver. Returning 200 here used to turn a
        # transient database failure into a permanently unrecorded payment.
        await db.rollback()
        logger.exception("[mpesa] callback processing failed cid=%s: %s", checkout_id, type(exc).__name__)
        raise HTTPException(status_code=500, detail="Callback not processed")

    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.get("/status/{deal_id}")
async def get_deal_payment_status(
    deal_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return the latest M-Pesa transaction status for a deal."""
    deal = (await db.execute(
        select(Deal).where(
            Deal.id == deal_id,
            ((Deal.buyer_id == current_user["id"]) | (Deal.seller_id == current_user["id"])),
        )
    )).scalar_one_or_none()
    if deal is None:
        # Same response for "not found" and "not yours" - an id probe must
        # not reveal that somebody else's deal exists.
        raise HTTPException(status_code=404, detail="Deal not found")
    result = await db.execute(
        select(MpesaTransaction)
        .where(MpesaTransaction.deal_id == deal_id)
        .order_by(MpesaTransaction.created_at.desc())
        .limit(1)
    )
    txn = result.scalar_one_or_none()
    if not txn:
        return {"status": "no_transaction", "deal_id": deal_id}

    return {
        "deal_id":             deal_id,
        "status":              txn.status.value,
        "amount":              txn.amount,
        "mpesa_receipt":       txn.mpesa_receipt,
        "checkout_request_id": txn.checkout_request_id,
        "created_at":          txn.created_at.isoformat(),
    }
