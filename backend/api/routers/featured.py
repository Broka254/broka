"""
BROKA - Featured Listing Boost Router
Sellers pay via M-Pesa STK Push to pin a listing at the top of the home feed
with a glowing "FEATURED" badge.

Pricing:
  1 week  - KES 99
  4 weeks - KES 350  (best value)

ENV VARS (shared with mpesa.py / verify.py):
  MPESA_CONSUMER_KEY, MPESA_CONSUMER_SECRET, MPESA_SHORTCODE,
  MPESA_PASSKEY, MPESA_ENV

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
import base64
import logging
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.core import mpesa_stk
from api.core.rate_limit import stk_limiter
from api.core.zetupay import ZetuPayUnavailable
from api.database import get_db, Listing, FeaturedPayment, MpesaStatus, SellerTier, User
from api.domains.listings.paid import is_live
from api.domains.payments import service as zetupay_charges
from api.domains.pricing.service import FEATURED_NOT_FOR_LONG_TERM
from api.models.zetupay import Purpose
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

# ── Config ────────────────────────────────────────────────────────────────────

MPESA_ENV       = os.getenv("MPESA_ENV", "sandbox")
CONSUMER_KEY    = os.getenv("MPESA_CONSUMER_KEY", "")
CONSUMER_SECRET = os.getenv("MPESA_CONSUMER_SECRET", "")
SHORTCODE       = os.getenv("MPESA_SHORTCODE", "174379")
PASSKEY         = os.getenv("MPESA_PASSKEY", "")
# Same secret and same vulnerability class as mpesa.py's callback - see its
# CALLBACK_SECRET comment. Reused (not a second env var) so Xavier sets one
# secret and updates three Safaricom-registered callback URLs with it.
CALLBACK_SECRET = os.getenv("MPESA_CALLBACK_SECRET", "")
CALLBACK_URL    = os.getenv(
    "MPESA_FEATURED_CALLBACK_URL",
    "https://api.broka.co.ke/featured/callback",
)
BASE_URL  = "https://api.safaricom.co.ke" if MPESA_ENV == "production" else "https://sandbox.safaricom.co.ke"
OAUTH_URL = f"{BASE_URL}/oauth/v1/generate?grant_type=client_credentials"
STK_URL   = f"{BASE_URL}/mpesa/stkpush/v1/processrequest"

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


# ── M-Pesa helpers ────────────────────────────────────────────────────────────

async def _get_token() -> str:
    creds = base64.b64encode(f"{CONSUMER_KEY}:{CONSUMER_SECRET}".encode()).decode()
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(OAUTH_URL, headers={"Authorization": f"Basic {creds}"})
    r.raise_for_status()
    return r.json()["access_token"]


def _normalize_phone(phone: str) -> str:
    p = phone.strip().replace(" ", "").replace("-", "")
    if p.startswith("0"):
        p = "254" + p[1:]
    if p.startswith("+"):
        p = p[1:]
    return p


def _stk_password() -> tuple[str, str]:
    ts = (datetime.now(timezone.utc) + timedelta(hours=3)).strftime("%Y%m%d%H%M%S")
    raw = f"{SHORTCODE}{PASSKEY}{ts}"
    return base64.b64encode(raw.encode()).decode(), ts


async def _send_stk(token: str, phone: str, amount: int, listing_name: str) -> dict:
    password, ts = _stk_password()
    payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          password,
        "Timestamp":         ts,
        "TransactionType":   "CustomerPayBillOnline",
        "Amount":            amount,
        "PartyA":            phone,
        "PartyB":            SHORTCODE,
        "PhoneNumber":       phone,
        "CallBackURL":       CALLBACK_URL,
        "AccountReference":  "BROKABoost",
        "TransactionDesc":   f"Feature: {listing_name[:20]}",
    }
    async with httpx.AsyncClient(timeout=20) as c:
        r = await c.post(STK_URL, json=payload,
                         headers={"Authorization": f"Bearer {token}",
                                  "Content-Type": "application/json"})
    r.raise_for_status()
    return r.json()


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/plans")
async def get_plans():
    """Return available boost plans - no auth needed."""
    return {"plans": BOOST_PLANS}


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
    db: AsyncSession = Depends(get_db),
):
    """Initiate M-Pesa STK Push to boost a listing."""
    # Validate plan
    plan = BOOST_PLANS.get(req.plan)
    if not plan:
        raise HTTPException(status_code=400, detail="Invalid plan. Choose 'week' or 'month'.")

    # Confirm listing belongs to this seller
    result = await db.execute(
        select(Listing).where(
            Listing.id == req.listing_id,
            Listing.seller_id == current_user["id"],
        )
    )
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found or not yours.")

    # Placement is sold to short-term sellers only (PRICING.md, "Featured
    # listings"): a long-term seller's listings rank on their completion
    # record, and selling them placement as well would let money outrank the
    # record the listing fee rewards. Checked before the STK push, so a
    # refused seller is never prompted for money.
    tier = (await db.execute(
        select(User.seller_tier).where(User.id == current_user["id"])
    )).scalar()
    if tier == SellerTier.long_term:
        raise HTTPException(status_code=403, detail=FEATURED_NOT_FOR_LONG_TERM)
    # Featuring a listing buyers can't see - its fee unpaid, or its paid
    # time over - would take the money and show nothing.
    if not is_live(listing):
        raise HTTPException(
            status_code=409,
            detail="Pay this listing's fee first - buyers can't see it yet.",
        )

    if zetupay_charges.enabled():
        return await _boost_with_zetupay(db, current_user["id"], listing, req.plan, req.phone_number)

    phone = _normalize_phone(req.phone_number)
    amount = plan["price"]

    try:
        token = await _get_token()
        stk   = await _send_stk(token, phone, amount, listing.name)
    except Exception as e:
        logger.error("STK Push failed for boost: %s", e)
        raise HTTPException(status_code=502, detail="Could not reach M-Pesa. Try again.")

    checkout_id  = stk.get("CheckoutRequestID", "")
    merchant_id  = stk.get("MerchantRequestID", "")
    resp_code    = stk.get("ResponseCode", "-1")

    if resp_code != "0":
        raise HTTPException(status_code=400, detail=stk.get("ResponseDescription", "STK Push rejected."))

    # Save payment record
    payment = FeaturedPayment(
        user_id             = current_user["id"],
        listing_id          = req.listing_id,
        plan                = req.plan,
        phone               = phone,
        amount              = amount,
        checkout_request_id = checkout_id,
        merchant_request_id = merchant_id,
        status              = MpesaStatus.pending,
    )
    db.add(payment)
    await db.commit()

    return {
        "message":            "Payment prompt sent. Enter your M-Pesa PIN.",
        "checkout_request_id": checkout_id,
        "plan_label":         plan["label"],
        "amount":             amount,
        "days":               plan["days"],
    }


async def _boost_with_zetupay(
    db: AsyncSession, user_id: str, listing: Listing, plan_key: str, phone_number: str,
) -> dict:
    """The boost's prompt through ZetuPay. Same answer as the Daraja path,
    with checkout_request_id holding the ZetuPay reference."""
    plan = BOOST_PLANS[plan_key]
    # The strict check, before any prompt: a mistyped number prompts a
    # stranger for money.
    phone = mpesa_stk.normalize_phone(phone_number)
    if phone is None:
        raise HTTPException(status_code=400, detail="Enter a Safaricom number, e.g. 0712 345 678.")
    # Per user: every call prompts a phone for money.
    await stk_limiter.check_and_record(user_id)
    if await zetupay_charges.prompt_pending(db, user_id, Purpose.BOOST, listing.id):
        raise HTTPException(status_code=409, detail=(
            "An M-Pesa prompt for this boost is already on your phone. "
            "Finish it, or try again in two minutes."
        ))

    reference = zetupay_charges.new_reference(Purpose.BOOST)
    payment = FeaturedPayment(
        user_id=user_id, listing_id=listing.id, plan=plan_key, phone=phone,
        amount=plan["price"], checkout_request_id=reference,
        status=MpesaStatus.pending, provider=zetupay_charges.PROVIDER,
    )
    db.add(payment)
    await db.flush()
    try:
        await zetupay_charges.start(
            db, user_id=user_id, purpose=Purpose.BOOST, amount=plan["price"], phone=phone,
            target_id=payment.id, related_id=listing.id, reference=reference,
            description=f"BROKA boost {plan['days']}d",
        )
    except ZetuPayUnavailable as exc:
        raise HTTPException(status_code=502, detail=zetupay_charges.unavailable_detail(exc))
    return {
        "message":            "Payment prompt sent. Enter your M-Pesa PIN.",
        "checkout_request_id": reference,
        "plan_label":         plan["label"],
        "amount":             plan["price"],
        "days":               plan["days"],
    }


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
