"""Payments router - money users pay BROKA, through ZetuPay.

  POST /payments/zetupay/webhook                ZetuPay's payment webhook
  POST /payments/zetupay/test-charge            admin: KES 10 to your own phone
  GET  /payments/zetupay/payments/{reference}   admin: where a ZetuPay payment stands

Register https://api.broka.co.ke/payments/zetupay/webhook as a Transaction
Callback Endpoint on ZetuPay's Developers page. Charges start where they
always have - POST /pricing/listing-fee/pay, /premium/subscribe,
/featured/boost and /verify/purchase - and the app polls their own status
routes.
"""
import json
import logging
from typing import Optional

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import mpesa_stk, zetupay
from api.core.client_ip import client_ip
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.rate_limit import stk_limiter
from api.database import get_db
from api.domains.payments import service, test_charge
from api.models.zetupay import Purpose
from api.security import require_admin

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/zetupay/webhook")
async def zetupay_webhook(
    request: Request,
    x_zetupay_signature: Optional[str] = Header(None, alias="x-zetupay-signature"),
    db: AsyncSession = Depends(get_db),
):
    """The signature covers the exact bytes ZetuPay sent, so it is checked on
    the raw body before anything is parsed: without it, anyone who finds
    this URL could claim any payment succeeded."""
    raw = await request.body()
    if not zetupay.signature_ok(raw, x_zetupay_signature):
        logger.warning("[zetupay] webhook refused: bad, stale or missing signature, from %s",
                       client_ip(request))
        raise HTTPException(status_code=401, detail="Invalid signature")
    try:
        payload = json.loads(raw)
    except ValueError:
        raise HTTPException(status_code=400, detail="The body must be JSON.")
    if not isinstance(payload, dict):
        raise HTTPException(status_code=400, detail="The body must be a JSON object.")
    if zetupay.is_subscription_event(payload):
        # BROKA bills its own plans (PRICING.md) and creates no ZetuPay
        # subscriptions, so none of these should arrive. Acknowledged, so
        # ZetuPay stops retrying, and never read as a payment.
        logger.warning("[zetupay] subscription event %r ignored", payload.get("event"))
        return {"received": True, "outcome": "ignored_event"}

    try:
        outcome = await service.apply_event(db, zetupay.parse_event(payload), source="webhook")
    except Exception:
        # A 500, so ZetuPay redelivers (up to 6 tries): either none of this
        # event was committed and the redelivery applies it, or it was and
        # the transaction ledger turns the redelivery away.
        logger.exception("[zetupay] webhook not processed")
        raise HTTPException(status_code=500, detail="Not processed")
    return {"received": True, "outcome": outcome}


class TestChargeIn(BaseModel):
    phone_number: str = Field(..., max_length=20)


@router.post("/zetupay/test-charge")
async def zetupay_test_charge(
    body: TestChargeIn,
    current_user: dict = Depends(require_admin),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    """KES 10 to the number given, buying nothing: ZetuPay has no sandbox,
    and its going-live check is a small real payment (test_charge.py)."""
    if idempotency.cached:
        return idempotency.response
    if not service.enabled():
        raise HTTPException(status_code=409, detail="ZetuPay is off (ZETUPAY_ENABLED).")
    phone = mpesa_stk.normalize_phone(body.phone_number)
    if phone is None:
        raise HTTPException(status_code=400, detail="Enter a Safaricom number, e.g. 0712 345 678.")
    await stk_limiter.check_and_record(current_user["id"])
    reference = service.new_reference(Purpose.TEST)
    try:
        payment = await service.start(
            db, user_id=current_user["id"], purpose=Purpose.TEST, amount=test_charge.AMOUNT,
            phone=phone, target_id=reference, related_id=None, reference=reference,
            description="BROKA ZetuPay test",
        )
    except zetupay.ZetuPayUnavailable as exc:
        raise HTTPException(status_code=502, detail=service.unavailable_detail(exc))
    result = service.payment_dict(payment)
    await idempotency.store(result)
    return result


@router.get("/zetupay/payments/{reference}")
async def zetupay_payment_status(
    reference: str,
    current_user: dict = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Any ZetuPay payment by its BROKA reference, asking ZetuPay first when
    it is still unfinished."""
    payment = await service.status_by_reference(db, reference)
    if payment is None:
        raise HTTPException(status_code=404, detail="Payment not found")
    return service.payment_dict(payment)
