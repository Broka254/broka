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
import re
import secrets
from datetime import datetime, timedelta
from typing import Optional
from fastapi import HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession

from api.security import (
    hash_password_async, verify_login_password, verify_password_async, create_access_token,
    create_phone_verify_token, decode_phone_verify_token, create_email_verify_token,
    decode_email_verify_token, create_password_reset_token, decode_password_reset_token,
    password_fingerprint,
)
from api.core.events import publish, UserRegistered, UserLoggedIn
from api.core.config import settings
from api.core.geo import haversine_km
from api.core.sms import get_sms_provider
from api.core.email import get_email_provider, build_otp_email
from api.database import AccountType, OtpPurpose, SellerMetrics, SellerTier
from .repository import UserRepository

logger = logging.getLogger(__name__)


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


# Deliberately conservative: lowercase and trim, then one structural check.
# Real deliverability is decided by whether the code actually arrives, not by
# how clever a local regex is, and over-strict patterns are a well-known way
# to reject valid addresses.
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _normalize_email(email: str) -> str:
    """Lowercased and trimmed, or "" when it cannot be an address."""
    e = (email or "").strip().lower()
    return e if _EMAIL_RE.match(e) else ""


def generate_business_display_name(name: str, category: Optional[str], location: Optional[str]) -> str:
    """Builds the structured, non-free-typed display name, e.g.
    'Clanix · Wholesale · Sira'. Structured fields (not a single free-typed
    string) so search/Zeno never see 'Clanix-Ugunja' vs 'Clanix ugunja' vs
    'CLANIX' fragmenting the same business into different-looking entities.
    """
    parts = [p.strip() for p in (name, category, location) if p and p.strip()]
    return " · ".join(parts)


# The signup wizard's rule (flutter_app auth_screen.dart). Only checked on a
# password being changed: registration has always taken whatever the app
# sent, and existing passwords are what they are.
MIN_PASSWORD_LENGTH = 6


def _check_new_password(password: str) -> None:
    if len(password or "") < MIN_PASSWORD_LENGTH:
        raise HTTPException(
            status_code=422,
            detail=f"Use at least {MIN_PASSWORD_LENGTH} characters for your password",
        )


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
        await self._consume_phone_otp(phone, code, purpose)
        token = create_phone_verify_token(phone)
        return {"ok": True, "phone_verify_token": token}

    async def _consume_phone_otp(self, phone: str, code: str, purpose: OtpPurpose) -> None:
        """Checks `code` against the latest pending code of `purpose` sent to
        the (normalised) `phone`, and spends it. Raises on anything else."""
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

    # ── Forgotten password: SMS code → new password ─────────────────────────
    # The phone number is the account, so a code sent to it is what proves
    # the person resetting is its owner. Codes for this are their own
    # purpose (login_recovery): a registration code can't reset a password,
    # and a reset code can't register a second account.

    async def request_password_reset(
        self, phone: str, app_signature: Optional[str] = None,
    ) -> dict:
        phone = _normalize_phone(phone)
        # Says plainly when there's no account. Registration's code request
        # already answers "is this number on BROKA?" (409), so a vague reply
        # here would protect nothing - and would leave someone who mistyped
        # their number waiting for a code that is never sent.
        if not await self.repo.get_by_phone(phone):
            raise HTTPException(
                status_code=404,
                detail="No BROKA account uses this number. Check it, or create an account.",
            )
        return await self.request_otp(
            phone, purpose=OtpPurpose.login_recovery, app_signature=app_signature,
        )

    async def verify_password_reset(self, phone: str, code: str) -> dict:
        phone = _normalize_phone(phone)
        await self._consume_phone_otp(phone, code, OtpPurpose.login_recovery)
        user = await self.repo.get_by_phone(phone)
        if not user:
            raise HTTPException(status_code=404, detail="No BROKA account uses this number.")
        return {"ok": True, "reset_token": create_password_reset_token(phone, user.password_hash)}

    async def reset_password(self, reset_token: str, new_password: str) -> dict:
        claims = decode_password_reset_token(reset_token)
        if not claims:
            raise HTTPException(
                status_code=400,
                detail="This reset has expired. Request a new code and try again.",
            )
        user = await self.repo.get_by_phone(claims["phone"])
        # A different fingerprint means the password changed after the token
        # was issued - most likely by this very token, replayed.
        if not user or password_fingerprint(user.password_hash) != claims.get("pwf"):
            raise HTTPException(
                status_code=400,
                detail="This reset was already used. Request a new code if you need to.",
            )
        _check_new_password(new_password)
        user.password_hash = await hash_password_async(new_password)
        # The SMS code just proved the number, for an account that may have
        # skipped verifying it at signup.
        user.phone_verified = True
        user.last_seen = datetime.utcnow()
        return await self._fresh_session_after_password_change(user)

    async def change_password(
        self, user_id: str, current_password: str, new_password: str,
    ) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        # 400, not 401: the app renews its session on a 401 and sends the
        # request again, which would spend a second guess for nothing.
        if not await verify_password_async(current_password, user.password_hash):
            raise HTTPException(status_code=400, detail="Your current password is wrong")
        _check_new_password(new_password)
        if await verify_password_async(new_password, user.password_hash):
            raise HTTPException(
                status_code=400, detail="Choose a password different from your current one",
            )
        user.password_hash = await hash_password_async(new_password)
        return await self._fresh_session_after_password_change(user)

    async def _fresh_session_after_password_change(self, user) -> dict:
        """Signs every other phone out - a password is changed because
        someone else might know the old one, and their refresh token would
        otherwise outlive it by a month - then signs this one in again."""
        from api.domains.auth.refresh_router import revoke_all_refresh_tokens
        await revoke_all_refresh_tokens(self.db, user.id)
        await self.db.commit()
        token = create_access_token({"sub": user.id})
        refresh_token = await self._issue_refresh_token(user.id)
        return {
            "ok": True,
            "access_token": token,
            "refresh_token": refresh_token,
            "token_type": "bearer",
            "user_id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "phone": user.phone,
            "account_type": user.account_type.value if user.account_type else "buyer",
            "profile_photo": user.profile_photo,
            "lat": user.lat,
            "lng": user.lng,
        }

    # ── Registration (buyer-only; seller is a later upgrade) ────────────────

    # ── Email OTP ────────────────────────────────────────────────────────
    # Email stays optional at signup. These endpoints exist so that when
    # someone does give an address, it can be proven rather than merely
    # typed - which is what makes it safe to later use for password
    # recovery or receipts.

    async def request_email_otp(
        self, email: str, purpose: OtpPurpose = OtpPurpose.registration,
        allow_registered: bool = False,
    ) -> dict:
        """Email a verification code. `allow_registered` is for proving an
        address for something other than a new account - a store's business
        email may well be an address that already has a BROKA account."""
        email = _normalize_email(email)
        if not email:
            raise HTTPException(status_code=400, detail="Enter a valid email address")

        if purpose == OtpPurpose.registration and not allow_registered:
            existing = await self.repo.get_by_email(email)
            if existing:
                raise HTTPException(status_code=409, detail="That email is already in use")

        code = "".join(secrets.choice("0123456789") for _ in range(settings.otp_length))
        expires_at = datetime.utcnow() + timedelta(seconds=settings.otp_expiry_seconds)
        await self.repo.create_email_otp(email, _hash_otp(code), expires_at, purpose=purpose)

        minutes = max(1, settings.otp_expiry_seconds // 60)
        subject, html, text = build_otp_email(code, minutes)
        sent = await get_email_provider().send(email, subject, html, text)
        if not sent:
            raise HTTPException(
                status_code=503,
                detail="Couldn't send the verification email. Please try again.",
            )

        result = {"ok": True, "email": email, "expires_in_seconds": settings.otp_expiry_seconds}
        if not settings.is_production:
            # Dev/CI only, exactly as the phone flow does it.
            result["debug_code"] = code
        return result

    async def verify_email_otp(
        self, email: str, code: str, purpose: OtpPurpose = OtpPurpose.registration,
    ) -> dict:
        email = _normalize_email(email)
        otp = await self.repo.get_latest_email_otp(email, purpose)
        if not otp:
            raise HTTPException(
                status_code=400,
                detail="No pending verification for this email. Request a new code.",
            )
        if otp.expires_at < datetime.utcnow():
            raise HTTPException(status_code=400, detail="That code has expired. Request a new one.")
        if otp.attempts >= settings.otp_max_attempts:
            raise HTTPException(status_code=429, detail="Too many attempts. Request a new code.")
        if _hash_otp(code.strip()) != otp.code_hash:
            await self.repo.increment_otp_attempts(otp)
            raise HTTPException(status_code=400, detail="Incorrect code")

        await self.repo.consume_otp(otp)
        return {"ok": True, "email": email, "email_verify_token": create_email_verify_token(email)}

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
        email_verify_token: Optional[str] = None,
        profile_photo: Optional[str] = None,
        # Signup-time seller categorisation. account_type "buyer_seller"
        # creates a selling account outright rather than making the user come
        # back through Menu -> Start selling. Business fields are only
        # meaningful for a long_term seller; the wizard does not ask a
        # short_term one for them.
        account_type: Optional[str] = None,
        seller_tier: Optional[str] = None,
        business_name: Optional[str] = None,
        business_category: Optional[str] = None,
        business_location: Optional[str] = None,
        business_description: Optional[str] = None,
    ) -> dict:
        # The profile photo arrives as base64 (converted to an image asset
        # by the media backfill). A link to an image elsewhere is refused:
        # every buyer who opened the seller's listings would load it.
        from api.domains.media.service import check_legacy_images
        from api.models.media import MediaPurpose
        await check_legacy_images(self.db, None, [profile_photo], MediaPurpose.AVATAR)

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

        # Same precedence rule as the phone above: a proven address always
        # wins over a typed one, so a verified email can never be swapped for
        # someone else's in the same request.
        email_verified = False
        if email_verify_token:
            decoded_email = decode_email_verify_token(email_verify_token)
            if not decoded_email:
                raise HTTPException(
                    status_code=400,
                    detail="Email verification expired or invalid. Please verify your email again.",
                )
            email = decoded_email
            email_verified = True
        else:
            email = _normalize_email(email) if email else None

        if email:
            existing_email = await self.repo.get_by_email(email)
            if existing_email:
                raise HTTPException(status_code=409, detail="That email is already in use")

        # Unrecognised values fall back to a buyer account rather than
        # failing the registration: losing a signup over a malformed optional
        # field is a far worse outcome than starting as a buyer, which the
        # user can upgrade from Profile at any time.
        resolved_account_type = (
            AccountType.buyer_seller
            if (account_type or "").strip() == AccountType.buyer_seller.value
            else AccountType.buyer
        )
        resolved_seller_tier = None
        if resolved_account_type == AccountType.buyer_seller:
            raw_tier = (seller_tier or "").strip()
            resolved_seller_tier = (
                SellerTier.long_term
                if raw_tier == SellerTier.long_term.value
                else SellerTier.short_term
            )

        # Business identity is only stored for a long-term seller, and only
        # when the required parts are all present. A half-filled business
        # would produce a display name like "· Electronics ·", which would
        # then show up in search and be awkward to correct.
        biz = {}
        if resolved_seller_tier == SellerTier.long_term:
            b_name = (business_name or "").strip()
            b_cat = (business_category or "").strip()
            b_loc = (business_location or "").strip()
            if b_name and b_cat and b_loc:
                biz = {
                    "business_name": b_name,
                    "business_category": b_cat,
                    "business_location": b_loc,
                    "business_description": (business_description or "").strip() or None,
                    "business_display_name": generate_business_display_name(b_name, b_cat, b_loc),
                }

        pw_hash = await hash_password_async(password)

        # Only a PROVEN address may claim the bootstrap admin seat. Matching a
        # typed email was enough before email verification existed, which
        # meant anyone who knew or guessed ADMIN_BOOTSTRAP_EMAIL - usually a
        # founder's public address - and registered first became admin. The
        # real admin now verifies their email during signup to claim it.
        is_admin = (
            email_verified
            and bool(settings.admin_bootstrap_email)
            and email == settings.admin_bootstrap_email
        )

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
            email_verified=email_verified,
            password_hash=pw_hash,
            lat=lat,
            lng=lng,
            profile_photo=profile_photo,
            is_admin=is_admin,
            trust_score=100,
            account_type=resolved_account_type,
            seller_tier=resolved_seller_tier,
            **biz,
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
            "seller_tier": user.seller_tier.value if user.seller_tier else None,
            "profile_photo": user.profile_photo,
        }

    # ── Login: phone + password/biometric ────────────────────────────────────

    async def login(self, phone: str, password: str) -> dict:
        phone = _normalize_phone(phone)
        user = await self.repo.get_by_phone(phone)
        # Checked even when there is no such account - see verify_login_password.
        password_ok = await verify_login_password(password, user.password_hash if user else None)
        if not user or not password_ok:
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
        from api.domains.auth.refresh_router import issue_refresh_token_row
        rt_token = issue_refresh_token_row(self.db, user_id)
        await self.db.commit()
        return rt_token

    # ── Seller upgrade (separate, later step — never forced at signup) ──────

    async def upgrade_to_seller(
        self,
        user_id: str,
        business_name: Optional[str] = None,
        business_category: Optional[str] = None,
        business_location: Optional[str] = None,
        business_description: Optional[str] = None,
        seller_tier: str = SellerTier.long_term.value,
    ) -> dict:
        """Lets a buyer start selling - the seller questions signup asks,
        asked later: a short-term seller (a few items) needs nothing more; a
        long-term one sets up the business identity."""
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")

        if seller_tier == SellerTier.short_term.value:
            # Never a downgrade: an account already set up as a business keeps
            # its business name and store. Answering "just a few items" again
            # must not take those away.
            if user.seller_tier == SellerTier.long_term and user.business_display_name:
                return self._user_dict(user)
            user = await self.repo.update(
                user,
                account_type=AccountType.buyer_seller,
                seller_tier=SellerTier.short_term,
            )
            return self._user_dict(user)

        b_name = (business_name or "").strip()
        b_cat = (business_category or "").strip()
        b_loc = (business_location or "").strip()
        # All three or nothing, as at signup: a half-filled business becomes a
        # display name like "· Electronics ·" in search, and the old endpoint
        # stored exactly that for empty strings.
        if not (b_name and b_cat and b_loc):
            raise HTTPException(
                status_code=422,
                detail="A business needs a name, what it sells and a location",
            )
        user = await self.repo.update(
            user,
            account_type=AccountType.buyer_seller,
            # Filling in a full business identity is what long_term means, so
            # this lands there regardless of what was chosen at signup.
            seller_tier=SellerTier.long_term,
            business_name=b_name,
            business_category=b_cat,
            business_location=b_loc,
            business_description=(business_description or "").strip() or None,
            business_display_name=generate_business_display_name(b_name, b_cat, b_loc),
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
            from api.domains.media.service import check_legacy_images
            from api.models.media import MediaPurpose
            await check_legacy_images(self.db, user_id, [profile_photo], MediaPurpose.AVATAR)
            updates["profile_photo"] = profile_photo
            # Converted to an image asset again by the media backfill.
            updates["profile_photo_id"] = None
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
        viewer_id: Optional[str] = None,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
    ) -> list[dict]:
        # Other people, so the public view (_public_user_dict). This returned
        # _user_dict - email, phone, trust score, fraud flag, admin bit - for
        # up to 20 matches of any text, to any signed-in account.
        users = await self.repo.search(q, exclude_id=viewer_id)
        results = []
        for u in users:
            d = self._public_user_dict(u)
            distance = self._public_distance_km(u, viewer_lat, viewer_lng)
            if distance is not None:
                d["distance_km"] = distance
            results.append(d)
        return results

    async def get_user_profile(
        self,
        user_id: str,
        viewer_id: Optional[str] = None,
        viewer_lat: Optional[float] = None,
        viewer_lng: Optional[float] = None,
    ) -> dict:
        user = await self.repo.get_by_id(user_id)
        if not user:
            raise HTTPException(status_code=404, detail="User not found")
        # The account itself gets everything (the seller dashboard reads its
        # own trust and DCR here); anyone else gets the public view - the chat
        # header, the product page's seller block and the profile screen need
        # nothing more.
        own = viewer_id is not None and viewer_id == user.id
        if own:
            d = self._user_dict(user)
            if viewer_lat is not None and viewer_lng is not None and user.lat and user.lng:
                d["distance_km"] = round(haversine_km(viewer_lat, viewer_lng, user.lat, user.lng), 1)
        else:
            d = self._public_user_dict(user)
            distance = self._public_distance_km(user, viewer_lat, viewer_lng)
            if distance is not None:
                d["distance_km"] = distance
        # Social proof at the point of decision (Volume 2 §2.4). Only queried
        # for accounts that have actually sold something - avoids a pointless
        # extra query on every pure-buyer profile view. Kept out of
        # _user_dict/the bulk-listing path above (search results etc. call
        # that in a loop; this stays a single-profile-fetch-only cost).
        #
        # The deal completion time rides the same gate: every release path
        # bumps completed_deals as it stamps released_at, so an account with
        # no completed deal has nothing to time.
        if (user.completed_deals or 0) > 0:
            from api.core.fraud import seller_deal_stats
            from api.domains.trust.deal_time import deal_completion_time
            d.update(await seller_deal_stats(user_id, self.db))
            d.update(await deal_completion_time(self.db, user_id))
        # Volume 2 §3.6: DCR for the seller dashboard. Deliberately NOT
        # gated to completed_deals>0 like the block above - a SellerMetrics
        # row exists for any seller with >=1 listing (see
        # domains/trust/completion_rate.recompute_all_dcr), including
        # brand-new sellers with zero deals yet, and §3.5's cold-start
        # fairness point is exactly that they should see their neutral 80%
        # starting score, not have it hidden until their first sale.
        # The owner's own - the raw ranking inputs, rank score included, are
        # not a public figure.
        metrics = await self.db.get(SellerMetrics, user_id) if own else None
        if metrics:
            d["dcr_score"]  = metrics.dcr_score
            d["rank_score"] = metrics.rank_score
        # What a buyer is shown of the same numbers on a listing's screen:
        # rating, completion rate and response time, from last night's
        # snapshot - never rank or backlog (trust/public_standing.py).
        from api.domains.trust.public_standing import public_seller_standing
        standing = await public_seller_standing(self.db, user_id)
        if standing:
            d["seller_standing"] = standing
        return d

    # Where another user is, to two decimal places: about a kilometre. The
    # "Show my location" setting promises an approximate location, and the
    # stored value is the phone's GPS fix.
    _PUBLIC_COORD_DECIMALS = 2

    @classmethod
    def _approx_point(cls, user) -> tuple[float, float] | None:
        if not user.location_visible or user.lat is None or user.lng is None:
            return None
        return (round(user.lat, cls._PUBLIC_COORD_DECIMALS),
                round(user.lng, cls._PUBLIC_COORD_DECIMALS))

    @classmethod
    def _public_distance_km(
        cls, user, viewer_lat: Optional[float], viewer_lng: Optional[float],
    ) -> float | None:
        """Distance to [user]'s approximate point, not their exact one. The
        viewer's coordinates are whatever the caller sends, so a distance from
        the exact fix, asked for from three made-up places, would pinpoint the
        user to within about 100 m."""
        point = cls._approx_point(user)
        if point is None or viewer_lat is None or viewer_lng is None:
            return None
        return round(haversine_km(viewer_lat, viewer_lng, point[0], point[1]), 1)

    @classmethod
    def _public_user_dict(cls, user) -> dict:
        """What one user may see of another.

        Everything a public surface shows - the chat header, a product's
        seller block, a profile - and nothing else: no email or phone, no
        trust score or fraud flag, no admin bit, no language or security
        settings. [_user_dict] is for the account itself (/auth/me, and
        /auth/user/{id} on your own id).
        """
        from api.core.presence import online_status
        is_online, last_seen_label = online_status(user.last_seen)
        point = cls._approx_point(user)
        return {
            "id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "account_type": user.account_type.value if user.account_type else "buyer",
            "business_name": user.business_name,
            "business_display_name": user.business_display_name,
            "business_category": user.business_category,
            "business_description": user.business_description,
            # A place, like the coordinates: shown only with the user's leave.
            "business_location": user.business_location if user.location_visible else None,
            "lat": point[0] if point else None,
            "lng": point[1] if point else None,
            "rating": user.rating,
            "completed_deals": user.completed_deals,
            "is_verified": user.is_verified,
            "profile_photo": user.profile_photo,
            "last_seen": user.last_seen.isoformat() if user.last_seen else None,
            "is_online": is_online,
            "last_seen_label": last_seen_label,
            "created_at": user.created_at.isoformat() if user.created_at else None,
        }

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
            # Lets the app tell a proven address from a merely typed one, so
            # Profile can offer to finish verification later.
            "email_verified": user.email_verified,
            "seller_tier": user.seller_tier.value if user.seller_tier else None,
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
