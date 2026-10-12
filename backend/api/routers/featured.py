"""
BROKA - Featured Listing Boost Router
Sellers paid via M-Pesa STK Push to pin a listing at the top of the home feed
with a glowing "FEATURED" badge. No longer sold (2026-10-12): a listing pays
only its listing fee. POST /featured/boost refuses; what is left settles and
reports boosts bought before, until they run out.

Pricing:
  1 week  - KES 99
  4 weeks - KES 350  (best value)

ENV VARS (shared with mpesa.py / verify.py): MPESA_CALLBACK_SECRET

FLOW:
  1. POST /featured/boost         - STK Push → save FeaturedPayment
  2. POST /featured/callback      - Safaricom callback → mark listing.is_featured + featured_until
  3. GET  /featured/status/{id}   - app polls until confirmed/failed
  4. GET  /featured/my-listings   - returns seller's own listings (id + name + is_featured + featured_until)

With ZETUPAY_ENABLED, step 1 asks ZetuPay for the prompt instead and step 2
is ZetuPay's webhook (POST /payments/zetupay/webhook), which settles the
FeaturedPayment through zetupay_settled() below.
"""

import os
import logging
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, Listing, FeaturedPayment, MpesaStatus
from api.domains.payments import service as zetupay_charges
from api.domains.pricing.service import FEATURED_NOT_SOLD
from api.models.zetupay import Purpose
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

# ── Config ────────────────────────────────────────────────────────────────────

# Same secret and same vulnerability class as mpesa.py's callback - see its
# CALLBACK_SECRET comment. Reused (not a second env var) so Xavier sets one
# secret and updates three Safaricom-registered callback URLs with it.
CALLBACK_SECRET = os.getenv("MPESA_CALLBACK_SECRET", "")

# ── Plans ─────────────────────────────────────────────────────────────────────

BOOST_PLANS = {
    "week":  {"price": 99,  "days": 7,  "label": "1 Week Boost",  "best_value": False},
    "month": {"price": 350, "days": 28, "label": "4 Week Boost",  "best_value": True},
}

# ── Schemas ───────────────────────────────────────────────────────────────────

class BoostRequest(BaseModel):
    listing_id:   str
    plan:         str    # "week" | "month"
    phone_number: str    # 07XX or 2547XX


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/plans")
async def get_plans():
    """No plans: featured placement is no longer sold (boost_listing)."""
    return {"plans": {}}


@router.get("/my-listings")
async def get_my_listings(
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return seller's own listings with featured status."""
    result = await db.execute(
        select(Listing).where(Listing.seller_id == current_user["id"])
        .order_by(Listing.created_at.desc())
    )
    listings = result.scalars().all()
    now = datetime.utcnow()
    return {
        "listings": [
            {
                "id":             l.id,
                "name":           l.name,
                "category":       l.category,
                "price":          l.price,
                "status":         l.status.value if hasattr(l.status, "value") else str(l.status),
                "is_featured":    bool(l.is_featured and l.featured_until and l.featured_until > now),
                "featured_until": l.featured_until.isoformat() if l.featured_until else None,
            }
            for l in listings
        ]
    }


@router.post("/boost")
async def boost_listing(
    req: BoostRequest,
    current_user=Depends(get_current_user),
):
    """No longer sold (2026-10-12): a listing pays its listing fee and
    nothing else. Refused before any payment prompt, so an older app build
    that still offers a boost never takes money for it. The callbacks and
    the status poll below stay, for boosts paid before and running out."""
    raise HTTPException(status_code=410, detail=FEATURED_NOT_SOLD)


def _extend_featured(listing: Listing, plan_key: str) -> None:
    """Feature the listing for the plan's days, from the end of any boost
    still running - boosting early loses nothing."""
    plan = BOOST_PLANS.get(plan_key, {"days": 7})
    now = datetime.utcnow()
    base = listing.featured_until if (listing.featured_until and listing.featured_until > now) else now
    listing.is_featured = True
    listing.featured_until = base + timedelta(days=plan["days"])


async def zetupay_settled(db: AsyncSession, payment_id: str, receipt: str | None) -> None:
    """ZetuPay confirmed this boost (domains/payments holds the ZetuPay
    payment's lock, so this runs once per payment)."""
    payment = (await db.execute(
        select(FeaturedPayment).where(FeaturedPayment.id == payment_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if payment is None or payment.status == MpesaStatus.success:
        return
    payment.status = MpesaStatus.success
    payment.mpesa_receipt = receipt
    listing = (await db.execute(
        select(Listing).where(Listing.id == payment.listing_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if listing is not None:
        _extend_featured(listing, payment.plan)
    await db.commit()


async def zetupay_failed(db: AsyncSession, payment_id: str, reason: str) -> None:
    payment = (await db.execute(
        select(FeaturedPayment).where(FeaturedPayment.id == payment_id)
        .with_for_update().execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if payment is None or payment.status != MpesaStatus.pending:
        return
    payment.status = MpesaStatus.failed
    logger.info("Boost payment failed for listing %s: %s", payment.listing_id, reason)
    await db.commit()


@router.post("/callback")
async def boost_callback(payload: dict, db: AsyncSession = Depends(get_db)):
    """
    SECURITY: this route had NO protection at all until this fix - any
    caller could POST a forged {"ResultCode": 0, ...} body with a guessed/
    observed CheckoutRequestID and get a listing boosted for free, no real
    M-Pesa payment required. Same vulnerability class as mpesa.py's and
    verify.py's callbacks, fixed the same way: once MPESA_CALLBACK_SECRET
    is configured, this route rejects outright and only /featured/callback/
    <secret> is accepted.
    """
    if CALLBACK_SECRET:
        logger.warning(
            "Rejected boost callback on the UNPROTECTED /featured/callback "
            "route - MPESA_CALLBACK_SECRET is configured, so only "
            "/featured/callback/<secret> is accepted."
        )
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_boost_callback(payload, db)


@router.post("/callback/{secret}")
async def boost_callback_secured(secret: str, payload: dict, db: AsyncSession = Depends(get_db)):
    """Secret-protected variant - this is the one MPESA_FEATURED_CALLBACK_URL should point to."""
    if not CALLBACK_SECRET or secret != CALLBACK_SECRET:
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_boost_callback(payload, db)


async def _process_boost_callback(payload: dict, db: AsyncSession) -> dict:
    """Shared Safaricom STK callback handling for both routes above."""
    try:
        body      = payload.get("Body", {})
        stk_cb    = body.get("stkCallback", {})
        result_code = stk_cb.get("ResultCode", -1)
        checkout_id = stk_cb.get("CheckoutRequestID", "")

        result = await db.execute(
            select(FeaturedPayment).where(
                FeaturedPayment.checkout_request_id == checkout_id,
                # A ZetuPay row's checkout_request_id is its ZetuPay
                # reference: only ZetuPay's webhook may settle it.
                FeaturedPayment.provider != zetupay_charges.PROVIDER,
            )
        )
        payment = result.scalar_one_or_none()
        if not payment:
            logger.warning("Boost callback: payment not found for %s", checkout_id)
            return {"ResultCode": 0, "ResultDesc": "Accepted"}

        if result_code == 0:
            # Extract M-Pesa receipt
            items = stk_cb.get("CallbackMetadata", {}).get("Item", [])
            receipt = next(
                (i["Value"] for i in items if i.get("Name") == "MpesaReceiptNumber"), None
            )
            payment.status       = MpesaStatus.success
            payment.mpesa_receipt = receipt

            # Mark listing as featured
            lresult = await db.execute(
                select(Listing).where(Listing.id == payment.listing_id)
            )
            listing = lresult.scalar_one_or_none()
            if listing:
                _extend_featured(listing, payment.plan)
        else:
            payment.status = MpesaStatus.failed
            logger.info("Boost payment failed for listing %s: %s",
                        payment.listing_id, stk_cb.get("ResultDesc"))

        await db.commit()
    except Exception as e:
        logger.error("Boost callback error: %s", e)

    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.get("/status/{listing_id}")
async def boost_status(
    listing_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Poll boost payment status for a given listing."""
    # Latest payment for this listing by this user
    result = await db.execute(
        select(FeaturedPayment)
        .where(
            FeaturedPayment.listing_id == listing_id,
            FeaturedPayment.user_id    == current_user["id"],
        )
        .order_by(FeaturedPayment.created_at.desc())
        .limit(1)
    )
    payment = result.scalar_one_or_none()
    if (payment is not None and payment.provider == zetupay_charges.PROVIDER
            and payment.status == MpesaStatus.pending):
        # The webhook is late: ask ZetuPay. The id is read first - a
        # refresh can roll back, expiring every object loaded before it.
        payment_id = payment.id
        await zetupay_charges.refresh(db, Purpose.BOOST, payment_id)
        payment = await db.get(FeaturedPayment, payment_id, populate_existing=True)

    # Check listing featured state
    lresult = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = lresult.scalar_one_or_none()
    now = datetime.utcnow()
    is_featured = bool(
        listing and listing.is_featured
        and listing.featured_until
        and listing.featured_until > now
    )

    return {
        "payment_status":  payment.status.value if payment else "none",
        "mpesa_receipt":   payment.mpesa_receipt if payment else None,
        "is_featured":     is_featured,
        "featured_until":  listing.featured_until.isoformat() if (listing and listing.featured_until) else None,
    }
