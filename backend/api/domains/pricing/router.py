"""Pricing router.

  GET  /pricing/listing-fee/quote                    price a listing before it exists
  GET  /pricing/listing-fee/listings/{id}/quote      price one of your listings (pay or renew)
  POST /pricing/listing-fee/pay                      send the M-Pesa prompt
  GET  /pricing/listing-fee/payments/{id}            how that payment stands
  GET  /pricing/listing-fee/mine                     your listings waiting for payment
  POST /pricing/listing-fee/callback/{secret}        Safaricom's result
  GET  /pricing/plans, /pricing/categories           the public price lists

PRICING.md explains the prices; pricing/payments.py the payment.
"""
import logging
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.rate_limit import stk_limiter
from api.database import get_db
from api.domains.pricing import engine, payments, plans, service
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

# Matches escrow's MAX_AGREED_PRICE_KES order of magnitude: anything above is
# a typo, and the quote would only echo it back as the category's maximum.
_MAX_PRICE = 1_000_000_000


@router.get("/listing-fee/quote")
async def listing_fee_quote(
    category: str = Query(..., min_length=1, max_length=60),
    price: float = Query(..., gt=0, le=_MAX_PRICE, description="Price of one unit, KES"),
    quantity: int = Query(1, ge=1, le=100_000, description="Units offered in the listing"),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The monthly listing fee for the signed-in seller, and 1-6 month options.

    Priced on the caller's own completion record, so it needs sign-in; the
    category table (GET /pricing/categories) shows everyone the new-seller
    price.
    """
    return await service.listing_fee_quote(db, current_user["id"], category, price, quantity)


@router.get("/listing-fee/listings/{listing_id}/quote")
async def listing_quote(
    listing_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The fee for one of the caller's listings, the months that can still
    be added (six ahead at most) and where its paid time stands."""
    return await payments.listing_quote(db, current_user["id"], listing_id)


class PayIn(BaseModel):
    listing_id: str = Field(..., max_length=64)
    months: int = Field(..., ge=1, le=engine.MAX_MONTHS)
    phone_number: str = Field(..., max_length=20)
    # Featured placement with the listing, short-term sellers only.
    featured_plan: Optional[Literal["week", "month"]] = None


@router.post("/listing-fee/pay")
async def pay_listing_fee(
    body: PayIn,
    current_user: dict = Depends(get_current_user),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    """Send the M-Pesa prompt for `months` of the listing. The amount comes
    from the server's quote, never from the request."""
    if idempotency.cached:
        return idempotency.response
    # Per user: every call prompts a phone for money, and the number is the
    # caller's to type - unlimited, it is a way to harass someone else's.
    await stk_limiter.check_and_record(current_user["id"])
    result = await payments.start_payment(
        db, current_user["id"], body.listing_id, body.months, body.phone_number,
        body.featured_plan,
    )
    await idempotency.store(result)
    return result


@router.get("/listing-fee/payments/{payment_id}")
async def listing_fee_payment_status(
    payment_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await payments.payment_status(db, current_user["id"], payment_id)


@router.get("/listing-fee/mine")
async def my_listings_needing_payment(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Listings buyers can't see until paid, or won't within a week."""
    return {"listings": await payments.listings_needing_payment(db, current_user["id"])}


async def _callback(request: Request, db: AsyncSession) -> dict:
    try:
        await payments.process_callback(db, await request.json())
    except Exception as exc:
        # Logged, and still a 200: a non-200 makes Safaricom redeliver
        # forever, and the status poll's own query settles the payment.
        logger.error("[listing_fee] callback error: %s", exc, exc_info=True)
    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.post("/listing-fee/callback")
async def listing_fee_callback(request: Request, db: AsyncSession = Depends(get_db)):
    """Only while MPESA_CALLBACK_SECRET is unset (local and sandbox): anyone
    who can reach an unprotected callback can claim a payment succeeded.
    validate_startup() refuses production without the secret."""
    if settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _callback(request, db)


@router.post("/listing-fee/callback/{secret}")
async def listing_fee_callback_secured(secret: str, request: Request, db: AsyncSession = Depends(get_db)):
    if not settings.mpesa_callback_secret or secret != settings.mpesa_callback_secret:
        raise HTTPException(status_code=404, detail="Not found")
    return await _callback(request, db)


@router.get("/plans")
async def pricing_plans():
    """Premium plans, store plans and the commission."""
    return plans.catalog()


@router.get("/categories")
async def pricing_categories():
    """Every category's risk coefficient, fee ceiling and typical price."""
    return {"currency": "KES", "categories": service.category_table()}
