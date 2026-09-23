"""Auth Router v6.1 — phone-first onboarding: OTP request/verify, register,
login (phone + password/biometric), and seller upgrade.

Wraps AuthService, adds rate limiting."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db, OtpPurpose
from api.security import get_current_user
from api.core.rate_limit import (
    login_limiter, register_limiter, otp_request_limiter, otp_verify_limiter,
)
from .service import AuthService, _normalize_phone, _normalize_email

router = APIRouter()


# Rate-limit keys are built from the SAME normalisation the service applies,
# not from the raw request field. Otherwise "0712345678", "+254712345678" and
# "254712345678" - one handset to the service - are three separate budgets to
# the limiter, and the per-number limit multiplies by however many spellings
# an attacker cares to try.
def _phone_key(phone: str) -> str:
    return f"phone:{_normalize_phone(phone or '')}"


def _email_key(email: str) -> str:
    # _normalize_email returns "" for anything that isn't an address; fall
    # back to the trimmed input so malformed values still share one bucket
    # per spelling rather than all sharing the empty key.
    return f"email:{_normalize_email(email) or (email or '').strip().lower()}"


# ── Schemas ───────────────────────────────────────────────────────────────────

class OtpRequestIn(BaseModel):
    phone: str
    # Android SMS Retriever app-signature hash (11 chars), sent by the
    # Flutter client so the OTP SMS can be matched and auto-filled by the
    # app with NO user prompt at all. Computed on-device from the package
    # name + signing certificate, so it differs between debug, release and
    # Play-signed builds - which is exactly why the client supplies it
    # rather than the server holding a build-time constant that would be
    # wrong for two of those three cases.
    #
    # Optional: iOS supplies nothing here (it uses the keyboard's own
    # one-time-code suggestion), and an older client that doesn't send it
    # still gets a working, human-readable SMS.
    app_signature: Optional[str] = None


class OtpVerifyIn(BaseModel):
    phone: str
    code: str


class EmailOtpRequestIn(BaseModel):
    email: str


class EmailOtpVerifyIn(BaseModel):
    email: str
    code: str


class RegisterIn(BaseModel):
    # OTP is optional at signup (can be skipped and verified later from
    # Profile). Provide EITHER phone_verify_token (from otp/verify — the
    # phone is taken from the token, proven owned) OR phone (typed, not
    # proven) — at least one is required. If both are present, the
    # verified token always wins.
    phone_verify_token: Optional[str] = None
    phone: Optional[str] = None
    name: str                       # official name
    password: str
    lat: float
    lng: float
    nickname: Optional[str] = None  # what Zeno should call them — optional
    # Optional at signup. Used so Zeno never mis-genders someone when it
    # refers to them in a message to the other party (see
    # core/nudge_templates). Accepted values: "male", "female",
    # "prefer_not_to_say". Anything else - including omitting it entirely -
    # is stored as NULL and treated identically to "prefer_not_to_say".
    gender: Optional[str] = None
    email: Optional[str] = None     # optional, not required
    # From /auth/email/otp/verify. Present means the address was proven, and
    # it then wins over any raw `email` above, exactly as the phone token
    # wins over a raw phone.
    email_verify_token: Optional[str] = None
    # Seller categorisation, chosen in the first two wizard steps.
    # account_type: "buyer" (default) or "buyer_seller".
    # seller_tier:  "short_term" or "long_term" — ignored for a buyer.
    # The business_* fields are only read for a long_term seller.
    account_type: Optional[str] = None
    seller_tier: Optional[str] = None
    business_name: Optional[str] = None
    business_category: Optional[str] = None
    business_location: Optional[str] = None
    business_description: Optional[str] = None
    profile_photo: Optional[str] = None  # selfie, base64


class LoginIn(BaseModel):
    phone: str
    password: str


class ProfilePatch(BaseModel):
    nickname: Optional[str] = None
    profile_photo: Optional[str] = None


class SellerUpgradeIn(BaseModel):
    business_name: str
    business_category: str
    business_location: str
    business_description: Optional[str] = None


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/otp/request")
async def request_otp(
    body: OtpRequestIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    ip = request.client.host if request.client else "unknown"
    await otp_request_limiter.check_and_record(_phone_key(body.phone))
    await otp_request_limiter.check_and_record(f"ip:{ip}")
    svc = AuthService(db)
    return await svc.request_otp(
        body.phone,
        purpose=OtpPurpose.registration,
        app_signature=body.app_signature,
    )


@router.post("/otp/verify")
async def verify_otp(
    body: OtpVerifyIn,
    db: AsyncSession = Depends(get_db),
):
    await otp_verify_limiter.check_and_record(_phone_key(body.phone))
    svc = AuthService(db)
    return await svc.verify_otp(body.phone, body.code, purpose=OtpPurpose.registration)


@router.post("/email/otp/request")
async def request_email_otp(
    body: EmailOtpRequestIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    ip = request.client.host if request.client else "unknown"
    # Limited per address AND per IP, like the SMS route. Email costs less
    # than an SMS, but an unthrottled endpoint that emails an arbitrary
    # address on demand is a spam relay wearing our sending domain's
    # reputation.
    await otp_request_limiter.check_and_record(_email_key(body.email))
    await otp_request_limiter.check_and_record(f"ip:{ip}")
    svc = AuthService(db)
    return await svc.request_email_otp(body.email, purpose=OtpPurpose.registration)


@router.post("/email/otp/verify")
async def verify_email_otp(
    body: EmailOtpVerifyIn,
    db: AsyncSession = Depends(get_db),
):
    await otp_verify_limiter.check_and_record(_email_key(body.email))
    svc = AuthService(db)
    return await svc.verify_email_otp(body.email, body.code, purpose=OtpPurpose.registration)


@router.post("/register", status_code=201)
async def register(
    body: RegisterIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    ip = request.client.host if request.client else "unknown"
    await register_limiter.check_and_record(ip)
    svc = AuthService(db)
    return await svc.register(
        phone_verify_token=body.phone_verify_token,
        phone=body.phone,
        name=body.name,
        password=body.password,
        lat=body.lat,
        lng=body.lng,
        nickname=body.nickname,
        gender=body.gender,
        email=body.email,
        email_verify_token=body.email_verify_token,
        profile_photo=body.profile_photo,
        account_type=body.account_type,
        seller_tier=body.seller_tier,
        business_name=body.business_name,
        business_category=body.business_category,
        business_location=body.business_location,
        business_description=body.business_description,
    )


@router.post("/login")
async def login(
    body: LoginIn,
    request: Request,
    db: AsyncSession = Depends(get_db),
):
    ip = request.client.host if request.client else "unknown"
    await login_limiter.check_and_record(ip)
    await login_limiter.check_and_record(_phone_key(body.phone))
    svc = AuthService(db)
    return await svc.login(phone=body.phone, password=body.password)


@router.post("/upgrade-to-seller")
async def upgrade_to_seller(
    body: SellerUpgradeIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    return await svc.upgrade_to_seller(
        user_id=current_user["id"],
        business_name=body.business_name,
        business_category=body.business_category,
        business_location=body.business_location,
        business_description=body.business_description,
    )


@router.get("/me")
async def me(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    return await svc.get_me(current_user["id"])


@router.patch("/profile")
async def update_profile(
    body: ProfilePatch,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    return await svc.update_profile(
        user_id=current_user["id"],
        nickname=body.nickname,
        profile_photo=body.profile_photo,
    )


@router.patch("/location")
async def update_location(
    lat: float,
    lng: float,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    await svc.update_location(current_user["id"], lat, lng)
    return {"ok": True}


@router.patch("/language")
async def set_language(
    language: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from api.database import User
    from sqlalchemy import select
    r = await db.execute(select(User).where(User.id == current_user["id"]))
    user = r.scalar_one_or_none()
    if user:
        user.preferred_language = language
        await db.commit()
    return {"ok": True}


@router.patch("/biometric-enroll")
async def biometric_enroll(
    biometric_type: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from api.database import User
    from sqlalchemy import select
    r = await db.execute(select(User).where(User.id == current_user["id"]))
    user = r.scalar_one_or_none()
    if user:
        user.biometric_enrolled = biometric_type
        await db.commit()
    return {"ok": True}


@router.patch("/location-visibility")
async def location_visibility(
    visible: bool,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from api.database import User
    from sqlalchemy import select
    r = await db.execute(select(User).where(User.id == current_user["id"]))
    user = r.scalar_one_or_none()
    if user:
        user.location_visible = visible
        await db.commit()
    return {"ok": True}


@router.patch("/heartbeat")
async def heartbeat(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from api.database import User
    from sqlalchemy import select
    from datetime import datetime
    r = await db.execute(select(User).where(User.id == current_user["id"]))
    user = r.scalar_one_or_none()
    if user:
        user.last_seen = datetime.utcnow()
        await db.commit()
    return {"ok": True}


@router.patch("/fcm-token")
async def update_fcm_token(
    fcm_token: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    from api.database import User
    from sqlalchemy import select
    r = await db.execute(select(User).where(User.id == current_user["id"]))
    user = r.scalar_one_or_none()
    if user:
        user.fcm_token = fcm_token
        await db.commit()
    return {"ok": True}


@router.get("/search")
async def search_users(
    q: str,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    return await svc.search_users(q, viewer_lat=lat, viewer_lng=lng)


@router.get("/user/{user_id}")
async def get_user_profile(
    user_id: str,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = AuthService(db)
    return await svc.get_user_profile(user_id, viewer_lat=lat, viewer_lng=lng)
