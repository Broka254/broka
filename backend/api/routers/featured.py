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

from api.database import get_db, Listing, FeaturedPayment, MpesaStatus
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
    "https://broka-dbjd.onrender.com/featured/callback",
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
                FeaturedPayment.checkout_request_id == checkout_id
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
                plan = BOOST_PLANS.get(payment.plan, {"days": 7})
                now  = datetime.utcnow()
                # Extend existing featured period if already active
                base = listing.featured_until if (listing.featured_until and listing.featured_until > now) else now
                listing.is_featured   = True
                listing.featured_until = base + timedelta(days=plan["days"])
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
