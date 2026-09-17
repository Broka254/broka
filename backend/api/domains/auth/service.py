"""Auth Service — business logic for OTP / register / login / profile.

v6.1 onboarding rework (see CHANGES.md):
  - Phone is the unique identifier. Email is optional.
  - Registration prefers a verified-phone token (obtained via
    request_otp -> verify_otp), but OTP is optional at signup — a bare
    `phone` is accepted too, and verification can be finished later.
    See `phone_verified` on the user.
  - Every account starts as `buyer`. Becoming a seller is a separate,
    later step (upgrade_to_seller) — never forced at signup.
"""
from __future__ import annotations

import hashlib
import logging
import math
import re
import secrets
from datetime import datetime, timedelta
from typing import Optional
from fastapi import HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from api.security import (
    hash_password, verify_password, create_access_token,
    create_phone_verify_token, decode_phone_verify_token,
    create_refresh_token,
)
from api.core.events import publish, UserRegistered, UserLoggedIn
from api.core.config import settings
from api.core.sms import get_sms_provider
from api.database import AccountType, OtpPurpose, RefreshToken, SellerMetrics
from .repository import UserRepository

logger = logging.getLogger(__name__)


def _haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    R = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def _hash_otp(code: str) -> str:
    # OTPs are short-lived (5 min) and rate-limited, so a fast hash is fine —
    # this isn't a password, it's a one-time throwaway value.
    return hashlib.sha256(code.encode()).hexdigest()


def _normalize_phone(phone: str) -> str:
    """Light normalization only — full E.164 validation happens client-side
    (the phone input is a dedicated phone field, not free text)."""
    p = phone.strip().replace(" ", "")
    if p.startswith("0") and len(p) == 10:
        # Common Kenyan local format (07XXXXXXXX) -> +254XXXXXXXXX
        p = "+254" + p[1:]
    elif p and not p.startswith("+"):
        p = "+" + p
    return p


def generate_business_display_name(name: str, category: Optional[str], location: Optional[str]) -> str:
    """Builds the structured, non-free-typed display name, e.g.
    'Clanix · Wholesale · Sira'. Structured fields (not a single free-typed
    string) so search/Zeno never see 'Clanix-Ugunja' vs 'Clanix ugunja' vs
    'CLANIX' fragmenting the same business into different-looking entities.
    """
    parts = [p.strip() for p in (name, category, location) if p and p.strip()]
    return " · ".join(parts)


def _normalise_gender(value):
    """Map a submitted gender onto the stored allow-list, or None.

    None and "prefer_not_to_say" are both valid stored states and are
    treated identically at every read site - see core/nudge_templates.
    """
    from api.core.nudge_templates import VALID_GENDERS
    if not value:
        return None
    v = str(value).strip().lower().replace(" ", "_").replace("-", "_")
    if v in ("prefer_not_to_say", "prefernottosay", "undisclosed", "none"):
        return "prefer_not_to_say"
    return v if v in VALID_GENDERS else None


# ── OTP SMS body ──────────────────────────────────────────────────────────────

# An Android SMS Retriever app-signature hash is exactly 11 characters drawn
# from the base64 alphabet. This is validated rather than trusted because the
# value arrives from the client and is interpolated straight into an SMS body
# we then send to an arbitrary phone number: without the check, any caller
# could push chosen text (a phishing link, say) through our SMS gateway to any
# handset. A value that fails the check is dropped, not rejected, so a buggy
# or outdated client still receives a usable code instead of no SMS at all.
_APP_SIGNATURE_RE = re.compile(r"^[A-Za-z0-9+/=]{11}$")

# Google's SMS Retriever contract for a message the app can read without any
# user interaction: it must start with "<#>", contain the code, and end with
# the app-signature hash, all within 140 bytes.
# https://developers.google.com/identity/sms-retriever/verify
_OTP_TEXT = "{code} is your BROKA verification code. It expires in 5 minutes. Don't share it with anyone."


def _build_otp_message(code: str, app_signature: Optional[str]) -> str:
    """Compose the OTP SMS, in SMS-Retriever form when we have a valid hash.

    Without a hash (iOS, or a client predating this) the message is exactly
    what it has always been, so nothing regresses for those callers.
    """
    body = _OTP_TEXT.format(code=code)
    if not app_signature:
        return body
    sig = app_signature.strip()
    if not _APP_SIGNATURE_RE.match(sig):
        logger.warning(
            "[otp] ignoring malformed app_signature (len=%d) - sending a plain OTP SMS",
            len(sig),
        )
        return body
    retriever = f"<#> {body}\n{sig}"
    if len(retriever.encode("utf-8")) > 140:
        # Over the limit the Retriever API silently never matches, which
        # would look exactly like "autofill randomly doesn't work". Better
        # to send a message the user can still read and type by hand.
        logger.warning("[otp] SMS-Retriever body exceeds 140 bytes - sending a plain OTP SMS")
        return body
    return retriever


class AuthService:
    def __init__(self, db: AsyncSession):
        self.repo = UserRepository(db)
        self.db = db

    # ── Phone OTP ────────────────────────────────────────────────────────────

    async def request_otp(
        self,
        phone: str,
        purpose: OtpPurpose = OtpPurpose.registration,
        app_signature: Optional[str] = None,
    ) -> dict:
        phone = _normalize_phone(phone)
        if purpose == OtpPurpose.registration:
            existing = await self.repo.get_by_phone(phone)
            if existing:
                raise HTTPException(status_code=409, detail="This phone number is already registered")

        code = "".join(secrets.choice("0123456789") for _ in range(settings.otp_length))
        expires_at = datetime.utcnow() + timedelta(seconds=settings.otp_expiry_seconds)
        await self.repo.create_otp(phone, _hash_otp(code), expires_at, purpose=purpose)

        provider = get_sms_provider()
        message = _build_otp_message(code, app_signature)
        sent = await provider.send(phone, message)
        if not sent:
            raise HTTPException(status_code=503, detail="Couldn't send the verification code. Please try again.")
        result = {"ok": True, "phone": phone, "expires_in_seconds": settings.otp_expiry_seconds}
        if not settings.is_production:
            # Dev/CI convenience only — never included when settings.is_production
            # is True. Lets tests and local development verify a phone number
            # without a live Africa's Talking account.
            result["debug_code"] = code
        return result

    async def verify_otp(self, phone: str, code: str, purpose: OtpPurpose = OtpPurpose.registration) -> dict:
        phone = _normalize_phone(phone)
        otp = await self.repo.get_latest_otp(phone, purpose)
        if not otp:
            raise HTTPException(status_code=400, detail="No pending verification for this phone. Request a new code.")
        if otp.expires_at < datetime.utcnow():
            raise HTTPException(status_code=400, detail="That code has expired. Request a new one.")
        if otp.attempts >= settings.otp_max_attempts:
            raise HTTPException(status_code=429, detail="Too many attempts. Request a new code.")
        if _hash_otp(code.strip()) != otp.code_hash:
            await self.repo.increment_otp_attempts(otp)
            raise HTTPException(status_code=400, detail="Incorrect code")

        await self.repo.consume_otp(otp)
        token = create_phone_verify_token(phone)
        return {"ok": True, "phone_verify_token": token}

    # ── Registration (buyer-only; seller is a later upgrade) ────────────────

    async def register(
        self,
        name: str,
        password: str,
        lat: float,
        lng: float,
        phone_verify_token: Optional[str] = None,
        phone: Optional[str] = None,
        nickname: Optional[str] = None,
        gender: Optional[str] = None,
        email: Optional[str] = None,
        profile_photo: Optional[str] = None,
    ) -> dict:
        # OTP is optional (Design request: skippable at signup, verify
        # later). A verified token always wins when present — even if a raw
        # `phone` was also sent, so a proven number can never be swapped
        # for an unproven one in the same request. Only fall back to the
        # raw, unverified `phone` when no token was provided at all.
        phone_verified = False
        if phone_verify_token:
            decoded_phone = decode_phone_verify_token(phone_verify_token)
            if not decoded_phone:
                raise HTTPException(
                    status_code=400,
                    detail="Phone verification expired or invalid. Please verify your number again.",
                )
            phone = decoded_phone
            phone_verified = True
        else:
            if not phone or not phone.strip():
                raise HTTPException(
                    status_code=400,
                    detail="Enter a phone number, or verify it with an SMS code.",
                )
            phone = _normalize_phone(phone)

        existing = await self.repo.get_by_phone(phone)
        if existing:
            raise HTTPException(status_code=409, detail="This phone number is already registered")

        email = email.strip().lower() if email and email.strip() else None
        if email:
            existing_email = await self.repo.get_by_email(email)
            if existing_email:
                raise HTTPException(status_code=409, detail="That email is already in use")

        pw_hash = hash_password(password)

        is_admin = bool(settings.admin_bootstrap_email) and email == settings.admin_bootstrap_email

        user = await self.repo.create(
            name=name.strip(),
            # Normalised through the same allow-list the rest of the app
            # reads. An unrecognised value is stored as NULL rather than
            # rejected: gender is optional, and failing a registration over
            # a malformed optional field would be a worse outcome than
            # treating it as undisclosed.
            gender=_normalise_gender(gender),
            nickname=nickname.strip() if nickname else None,
            phone=phone,
            phone_verified=phone_verified,
            email=email,
            password_hash=pw_hash,
            lat=lat,
            lng=lng,
            profile_photo=profile_photo,
            is_admin=is_admin,
            trust_score=100,
            account_type=AccountType.buyer,
        )

        token = create_access_token({"sub": user.id})
        refresh_token = await self._issue_refresh_token(user.id)
        await publish(UserRegistered(user_id=user.id, email=user.email or "", name=user.name))
        return {
            "access_token": token,
            "refresh_token": refresh_token,
            "token_type": "bearer",
            "user_id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "phone": user.phone,
            "phone_verified": user.phone_verified,
            "account_type": user.account_type.value,
            "profile_photo": user.profile_photo,
        }

    # ── Login: phone + password/biometric ────────────────────────────────────

    async def login(self, phone: str, password: str) -> dict:
        phone = _normalize_phone(phone)
        user = await self.repo.get_by_phone(phone)
        if not user or not verify_password(password, user.password_hash):
            raise HTTPException(
                status_code=status.HTTP_401_UNAUTHORIZED,
                detail="Invalid phone number or password",
            )

        user.last_seen = datetime.utcnow()
        await self.db.commit()

        token = create_access_token({"sub": user.id})
        refresh_token = await self._issue_refresh_token(user.id)
        await publish(UserLoggedIn(user_id=user.id))
        return {
            "access_token": token,
            "refresh_token": refresh_token,
            "token_type": "bearer",
            "user_id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "phone": user.phone,
            "account_type": user.account_type.value,
            "profile_photo": user.profile_photo,
            "lat": user.lat,
            "lng": user.lng,
        }

    async def _issue_refresh_token(self, user_id: str) -> str:
        """FIX (2026-08-13, reported as 'calls silently stopped notifying the
        callee'): register()/login() previously only ever issued a 15-minute
        access token (ACCESS_TOKEN_EXPIRE_MINUTES) and never a refresh token -
        POST /auth/token/refresh (refresh_router.py) has existed and worked
        correctly this whole time, but had nothing to ever exchange, since no
        client could ever obtain a refresh token in the first place. In
        practice this meant every background/polling feature (incoming-call
        detection chief among them - GlobalPollerService/ApiService.
        checkIncomingCall has no 401 handling at all) went silently dead
        exactly ACCESS_TOKEN_EXPIRE_MINUTES after login, with no error
        surfaced anywhere. See CHANGES.md for the full chain (this fix, the
        matching Flutter typo fix, and the new 401-retry on the call-polling
        path) - this alone does not fix the reported symptom without those.
        """
        rt_token, expiry, jti = create_refresh_token(user_id)
        self.db.add(RefreshToken(user_id=user_id, jti=jti, expires_at=expiry))
        await self.db.commit()
        return rt_token

    # ── Seller upgrade (separate, later step — never forced at signup) ──────

    async def upgrade_to_seller(
        self,
        user_id: str,
        business_name: str,
        business_category: str,
        business_location: str,
        business_description: Optional[str] = None,
    ) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")

        display_name = generate_business_display_name(business_name, business_category, business_location)
        user = await self.repo.update(
            user,
            account_type=AccountType.buyer_seller,
            business_name=business_name.strip(),
            business_category=business_category.strip(),
            business_location=business_location.strip(),
            business_description=(business_description or "").strip() or None,
            business_display_name=display_name,
        )
        return self._user_dict(user)

    async def get_me(self, user_id: str) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        return self._user_dict(user)

    async def update_profile(
        self,
        user_id: str,
        nickname: Optional[str],
        profile_photo: Optional[str],
    ) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        updates = {}
        if nickname is not None:
            updates["nickname"] = nickname
        if profile_photo is not None:
            updates["profile_photo"] = profile_photo
        if updates:
            user = await self.repo.update(user, **updates)
        return self._user_dict(user)

    async def update_location(self, user_id: str, lat: float, lng: float) -> None:
        user = await self.repo.get_by_id(user_id)
        if user:
            await self.repo.update(user, lat=lat, lng=lng)

    async def search_users(
        self,
        q: str,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
    ) -> list[dict]:
        users = await self.repo.search(q)
        results = []
        for u in users:
            d = self._user_dict(u)
            if viewer_lat is not None and viewer_lng is not None and u.lat and u.lng and u.location_visible:
                d["distance_km"] = round(_haversine_km(viewer_lat, viewer_lng, u.lat, u.lng), 1)
            results.append(d)
        return results

    async def get_user_profile(
        self,
        user_id: str,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
    ) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        d = self._user_dict(user)
        if viewer_lat is not None and viewer_lng is not None and user.lat and user.lng and user.location_visible:
            d["distance_km"] = round(_haversine_km(viewer_lat, viewer_lng, user.lat, user.lng), 1)
        # Social proof at the point of decision (Volume 2 §2.4). Only queried
        # for accounts that have actually sold something - avoids a pointless
        # extra query on every pure-buyer profile view. Kept out of
        # _user_dict/the bulk-listing path above (search results etc. call
        # that in a loop; this stays a single-profile-fetch-only cost).
        if (user.completed_deals or 0) > 0:
            from api.core.fraud import seller_deal_stats
            d.update(await seller_deal_stats(user_id, self.db))
        # Volume 2 §3.6: DCR for the seller dashboard. Deliberately NOT
        # gated to completed_deals>0 like the block above - a SellerMetrics
        # row exists for any seller with >=1 listing (see
        # domains/trust/completion_rate.recompute_all_dcr), including
        # brand-new sellers with zero deals yet, and §3.5's cold-start
        # fairness point is exactly that they should see their neutral 80%
        # starting score, not have it hidden until their first sale.
        metrics = await self.db.get(SellerMetrics, user_id)
        if metrics:
            d["dcr_score"]  = metrics.dcr_score
            d["rank_score"] = metrics.rank_score
        return d

    @staticmethod
    def _user_dict(user) -> dict:
        from api.core.fraud import trust_band
        from api.core.presence import online_status
        is_online, last_seen_label = online_status(user.last_seen)
        return {
            "id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "email": user.email,
            "phone": user.phone,
            "phone_verified": user.phone_verified,
            "account_type": user.account_type.value if user.account_type else "buyer",
            "business_name": user.business_name,
            "business_category": user.business_category,
            "business_location": user.business_location,
            "business_description": user.business_description,
            "business_display_name": user.business_display_name,
            "lat": user.lat if user.location_visible else None,
            "lng": user.lng if user.location_visible else None,
            "rating": user.rating,
            "completed_deals": user.completed_deals,
            "is_verified": user.is_verified,
            "verify_tier": user.verify_tier,
            "verify_expires_at": user.verify_expires_at.isoformat() if user.verify_expires_at else None,
            "preferred_language": user.preferred_language,
            "location_visible": user.location_visible,
            "biometric_enrolled": user.biometric_enrolled,
            "profile_photo": user.profile_photo,
            "is_admin": user.is_admin,
            # Raw timestamp kept as-is for backward compatibility with any
            # existing consumer. New, additive fields below are what chat
            # headers should actually render - see api.core.presence.
            "last_seen": user.last_seen.isoformat() if user.last_seen else None,
            "is_online": is_online,
            "last_seen_label": last_seen_label,
            "trust_score": user.trust_score or 100,
            "trust_band": trust_band(user.trust_score or 100),
            "is_flagged": bool(user.is_flagged),
            "created_at": user.created_at.isoformat() if user.created_at else None,
        }
