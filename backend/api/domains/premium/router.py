"""Premium router.

  GET  /premium/me                     your plan, until when, and what is left this month
  POST /premium/subscribe              send the M-Pesa prompt for a plan
  GET  /premium/payments/{id}          how that payment stands
  POST /premium/callback/{secret}      Safaricom's result

The plans and their prices are GET /pricing/plans.
"""
import logging
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.rate_limit import stk_limiter
from api.database import get_db
from api.domains.premium import entitlements, payments
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/me")
async def my_premium(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await entitlements.summary(db, current_user["id"])


class SubscribeIn(BaseModel):
    plan_id: Literal["plus", "pro", "elite"]
    months: int = Field(..., ge=1, le=12)
    phone_number: str = Field(..., max_length=20)


@router.post("/subscribe")
async def subscribe(
    body: SubscribeIn,
    current_user: dict = Depends(get_current_user),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    """The amount is the plan's price for those months, never the request's."""
    if idempotency.cached:
        return idempotency.response
    # Per user: every call prompts a phone for money, and the number is the
    # caller's to type.
    await stk_limiter.check_and_record(current_user["id"])
    result = await payments.start(db, current_user["id"], body.plan_id, body.months, body.phone_number)
    await idempotency.store(result)
    return result


@router.get("/payments/{payment_id}")
async def premium_payment_status(
    payment_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await payments.payment_status(db, current_user["id"], payment_id)


async def _callback(request: Request, db: AsyncSession) -> dict:
    try:
        await payments.process_callback(db, await request.json())
    except Exception as exc:
        # Still a 200: a non-200 makes Safaricom redeliver forever, and the
        # status poll's own query settles the payment.
        logger.error("[premium] callback error: %s", exc, exc_info=True)
    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.post("/callback")
async def premium_callback(request: Request, db: AsyncSession = Depends(get_db)):
    """Only while MPESA_CALLBACK_SECRET is unset (local and sandbox)."""
    if settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _callback(request, db)


@router.post("/callback/{secret}")
async def premium_callback_secured(secret: str, request: Request, db: AsyncSession = Depends(get_db)):
    if not settings.mpesa_callback_secret or secret != settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _callback(request, db)
