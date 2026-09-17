"""
BROKA - Seller Verification Router
Sellers pay via M-Pesa STK Push to receive a BROKA Verified badge.

Tiers:
  basic  - KES 299 / year  - "BROKA Verified" gold badge
  gold   - KES 599 / year  - "BROKA Gold"      badge + priority listing

ENV VARS (shared with mpesa.py):
  MPESA_CONSUMER_KEY, MPESA_CONSUMER_SECRET, MPESA_SHORTCODE,
  MPESA_PASSKEY, MPESA_ENV

FLOW:
  1. POST /verify/purchase   - STK Push → save VerificationPayment record
  2. POST /verify/callback   - Safaricom callback → mark user.is_verified + tier
  3. GET  /verify/status     - app polls this until payment confirmed/failed
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

from api.database import get_db, User, VerificationPayment, MpesaStatus
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
    "MPESA_VERIFY_CALLBACK_URL",
    "https://broka-dbjd.onrender.com/verify/callback",
)
BASE_URL  = "https://api.safaricom.co.ke" if MPESA_ENV == "production" else "https://sandbox.safaricom.co.ke"
OAUTH_URL = f"{BASE_URL}/oauth/v1/generate?grant_type=client_credentials"
STK_URL   = f"{BASE_URL}/mpesa/stkpush/v1/processrequest"

# ── Tiers ─────────────────────────────────────────────────────────────────────

VERIFY_TIERS = {
    "basic": {
        "price":        299,
        "label":        "BROKA Verified",
        "months":       12,
        "description":  "Gold verified badge on all your listings for 12 months.",
    },
    "gold": {
        "price":        599,
        "label":        "BROKA Gold",
        "months":       24,
        "description":  "Gold badge + priority placement in search results for 24 months.",
    },
}

# ── Schemas ───────────────────────────────────────────────────────────────────

class PurchaseRequest(BaseModel):
    tier:         str    # "basic" | "gold"
    phone_number: str    # buyer's M-Pesa phone  07XX or 2547XX


# ── M-Pesa helpers ────────────────────────────────────────────────────────────

async def _get_token() -> str:
    creds = base64.b64encode(f"{CONSUMER_KEY}:{CONSUMER_SECRET}".encode()).decode()
    async with httpx.AsyncClient(timeout=15) as c:
        r = await c.get(OAUTH_URL, headers={"Authorization": f"Basic {creds}"})
    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"M-Pesa OAuth failed: {r.text}")
    return r.json()["access_token"]


def _password_and_ts() -> tuple[str, str]:
    ts  = (datetime.now(timezone.utc) + timedelta(hours=3)).strftime("%Y%m%d%H%M%S")
    pwd = base64.b64encode(f"{SHORTCODE}{PASSKEY}{ts}".encode()).decode()
    return pwd, ts


def _fmt_phone(phone: str) -> str:
    p = phone.strip().replace(" ", "").replace("-", "")
    if p.startswith("0"):   p = "254" + p[1:]
    elif p.startswith("+"): p = p[1:]
    return p


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/tiers")
async def list_tiers():
    """Return available verification tiers - no auth required."""
    return {"tiers": VERIFY_TIERS}


@router.post("/purchase")
async def purchase_verification(
    payload: PurchaseRequest,
    db:      AsyncSession = Depends(get_db),
    current: User         = Depends(get_current_user),
):
    """
    Initiate M-Pesa STK Push for badge purchase.
    Returns checkout_request_id - poll /verify/status to confirm.
    """
    tier_info = VERIFY_TIERS.get(payload.tier)
    if not tier_info:
        raise HTTPException(
            status_code=400,
            detail=f"Invalid tier. Choose from: {list(VERIFY_TIERS)}"
        )

    # Prevent double-purchase if already active
    user_r = await db.execute(select(User).where(User.id == current["id"]))
    user   = user_r.scalar_one()
    if user.is_verified and user.verify_tier == payload.tier:
        # Check expiry
        if user.verify_expires_at and user.verify_expires_at > datetime.utcnow():
            raise HTTPException(
                status_code=409,
                detail=f"Already {tier_info['label']} until {user.verify_expires_at.strftime('%b %Y')}"
            )

    amount = tier_info["price"]
    phone  = _fmt_phone(payload.phone_number)
    pwd, ts = _password_and_ts()
    token   = await _get_token()

    stk_payload = {
        "BusinessShortCode": SHORTCODE,
        "Password":          pwd,
        "Timestamp":         ts,
        "TransactionType":   "CustomerPayBillOnline",
        "Amount":            amount,
        "PartyA":            phone,
        "PartyB":            SHORTCODE,
        "PhoneNumber":       phone,
        "CallBackURL":       CALLBACK_URL,
        "AccountReference":  f"BROKA-VERIFY-{current['id'][:8].upper()}",
        "TransactionDesc":   f"BROKA {tier_info['label']} badge",
    }

    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(
            STK_URL, json=stk_payload,
            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        )

    if r.status_code != 200:
        raise HTTPException(status_code=502, detail=f"STK Push failed: {r.text}")
    body = r.json()
    if body.get("ResponseCode") != "0":
        raise HTTPException(
            status_code=400,
            detail=body.get("ResponseDescription", "M-Pesa rejected the request"),
        )

    # Save pending payment record
    vpay = VerificationPayment(
        user_id             = current["id"],
        tier                = payload.tier,
        phone               = phone,
        amount              = float(amount),
        checkout_request_id = body["CheckoutRequestID"],
        merchant_request_id = body.get("MerchantRequestID"),
        status              = MpesaStatus.pending,
    )
    db.add(vpay)
    await db.commit()
    await db.refresh(vpay)

    logger.info(
        "[verify] STK Push sent - user=%s tier=%s phone=%s amount=KES%d",
        current["id"], payload.tier, phone, amount,
    )

    return {
        "checkout_request_id": body["CheckoutRequestID"],
        "customer_message":    body.get("CustomerMessage", "Check your phone to complete payment"),
        "amount":              amount,
        "tier":                payload.tier,
        "tier_label":          tier_info["label"],
    }


@router.post("/callback")
async def verification_callback(request_data: dict, db: AsyncSession = Depends(get_db)):
    """
    SECURITY: this route had NO protection at all until this fix - any
    caller could POST a forged {"ResultCode": 0, ...} body with a guessed/
    observed CheckoutRequestID and get user.is_verified granted for free,
    no real M-Pesa payment required. Same vulnerability class as
    mpesa.py's callback, fixed the same way: once MPESA_CALLBACK_SECRET is
    configured, this route rejects outright and only /verify/callback/
    <secret> is accepted. Only still processes callbacks when no secret
    is configured at all (sandbox/local setups) - validate_startup() now
    refuses to start in production without one set.
    """
    if CALLBACK_SECRET:
        logger.warning(
            "Rejected verification callback on the UNPROTECTED /verify/callback "
            "route - MPESA_CALLBACK_SECRET is configured, so only "
            "/verify/callback/<secret> is accepted."
        )
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_verification_callback(request_data, db)


@router.post("/callback/{secret}")
async def verification_callback_secured(secret: str, request_data: dict, db: AsyncSession = Depends(get_db)):
    """Secret-protected variant - this is the one MPESA_VERIFY_CALLBACK_URL should point to."""
    if not CALLBACK_SECRET or secret != CALLBACK_SECRET:
        # Vague 404 rather than 403, matching mpesa.py - a guesser can't
        # distinguish "wrong secret" from "route doesn't exist".
        raise HTTPException(status_code=404, detail="Not found")
    return await _process_verification_callback(request_data, db)


async def _process_verification_callback(request_data: dict, db: AsyncSession) -> dict:
    """Shared Safaricom STK callback handling for both routes above."""
    try:
        body  = request_data.get("Body", {})
        stkCb = body.get("stkCallback", {})
        code  = stkCb.get("ResultCode", -1)
        mid   = stkCb.get("MerchantRequestID", "")
        cid   = stkCb.get("CheckoutRequestID", "")

        vpay_r = await db.execute(
            select(VerificationPayment).where(
                VerificationPayment.checkout_request_id == cid
            )
        )
        vpay = vpay_r.scalar_one_or_none()
        if not vpay:
            logger.warning("[verify] Callback - no VerificationPayment for CID %s", cid)
            return {"ResultCode": 0, "ResultDesc": "Accepted"}

        if code == 0:
            # Payment successful
            metadata  = stkCb.get("CallbackMetadata", {}).get("Item", [])
            receipt   = next((i["Value"] for i in metadata if i["Name"] == "MpesaReceiptNumber"), None)
            vpay.status        = MpesaStatus.success
            vpay.mpesa_receipt = receipt

            # Upgrade the user
            tier_info = VERIFY_TIERS.get(vpay.tier, VERIFY_TIERS["basic"])
            months    = tier_info["months"]

            user_r = await db.execute(select(User).where(User.id == vpay.user_id))
            user   = user_r.scalar_one_or_none()
            if user:
                user.is_verified        = True
                user.verify_tier        = vpay.tier
                user.verify_expires_at  = datetime.utcnow() + timedelta(days=months * 30)
                logger.info(
                    "[verify] ✅ User %s verified - tier=%s expires=%s receipt=%s",
                    user.id, vpay.tier, user.verify_expires_at, receipt,
                )
        else:
            vpay.status = MpesaStatus.failed
            logger.info("[verify] ❌ Payment failed for CID %s - code=%s", cid, code)

        await db.commit()
    except Exception as e:
        logger.error("[verify] Callback error: %s", e)

    return {"ResultCode": 0, "ResultDesc": "Accepted"}


@router.get("/status")
async def check_status(
    db:      AsyncSession = Depends(get_db),
    current: User         = Depends(get_current_user),
):
    """
    Poll this after STK Push.
    Returns the latest verification payment status + current user verification state.
    """
    user_r = await db.execute(select(User).where(User.id == current["id"]))
    user   = user_r.scalar_one()

    vpay_r = await db.execute(
        select(VerificationPayment)
        .where(VerificationPayment.user_id == current["id"])
        .order_by(VerificationPayment.created_at.desc())
    )
    vpay = vpay_r.scalars().first()

    return {
        "is_verified":       user.is_verified,
        "verify_tier":       user.verify_tier,
        "verify_expires_at": user.verify_expires_at.isoformat() if user.verify_expires_at else None,
        "payment_status":    vpay.status.value if vpay else None,
        "mpesa_receipt":     vpay.mpesa_receipt if vpay else None,
    }
