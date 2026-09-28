"""
BROKA v3.0 - Auth & Security
─────────────────────────────
• Access tokens: 15 minutes (was 7 days — issue #7 fixed)
• Refresh tokens: 30 days, opaque jti stored in DB for revocation
• Startup fails if SECRET_KEY == default placeholder (issue #4 fixed)
• decode_token() returns None on failure — safe for WebSocket use
"""
from __future__ import annotations

import asyncio
import functools
import os
import secrets
import logging
import bcrypt
from datetime import datetime, timedelta, timezone
from jose import JWTError, jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer

logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────────────────────

SECRET_KEY = os.getenv("SECRET_KEY", "CHANGE_THIS_TO_A_RANDOM_64_CHAR_STRING_IN_PROD")
ALGORITHM  = "HS256"

ACCESS_TOKEN_EXPIRE_MINUTES = int(os.getenv("ACCESS_TOKEN_EXPIRE_MINUTES", "15"))
REFRESH_TOKEN_EXPIRE_DAYS   = int(os.getenv("REFRESH_TOKEN_EXPIRE_DAYS",   "30"))

_INSECURE_DEFAULTS = {
    "CHANGE_THIS_TO_A_RANDOM_64_CHAR_STRING_IN_PROD",
    "secret", "changeme", "password", "broka",
}

oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/auth/login")


# ── Startup guard (issue #4) ──────────────────────────────────────────────────

def validate_secret_key() -> None:
    """
    Call once at startup (done in main.py lifespan).
    In production: raises RuntimeError — server won't start with insecure key.
    In development: logs a warning.
    Generate a safe key: python -c "import secrets; print(secrets.token_hex(32))"
    """
    env     = os.getenv("ENV", os.getenv("ENVIRONMENT", "development")).lower()
    is_prod = env in ("production", "prod", "staging")
    unsafe  = SECRET_KEY in _INSECURE_DEFAULTS or len(SECRET_KEY) < 32

    if unsafe:
        msg = (
            "FATAL: SECRET_KEY is insecure (using default placeholder or < 32 chars). "
            "Generate a safe key: python -c \"import secrets; print(secrets.token_hex(32))\" "
            "then set it as a SECRET_KEY environment variable."
        )
        if is_prod:
            raise RuntimeError(msg)
        logger.warning("[security] %s", msg)


# ── Password hashing ──────────────────────────────────────────────────────────
#
# bcrypt reads at most 72 BYTES of a password. This used to cut passwords at
# 72 characters, which is more than 72 bytes once a password has anything
# beyond ASCII - and bcrypt 5 raises ValueError rather than truncating, so
# signing up or logging in with such a password was a 500. The cut is now in
# bytes. Every hash already stored was made from these same bytes (ASCII
# passwords are unchanged; bcrypt before 5 truncated to 72 bytes itself), so
# they all still verify.
#
# A hash takes ~250 ms of CPU. Called straight from an async handler, that is
# 250 ms in which the event loop serves nobody - every login stalls every
# other request on the worker. Handlers use the *_async forms, which run in a
# thread; bcrypt releases the GIL, so they run in parallel with the loop.

_BCRYPT_MAX_BYTES = 72


def _bcrypt_input(plain: str) -> bytes:
    # 72 characters are always at least 72 bytes, so encoding only those is
    # the same cut - and a pasted megabyte "password" costs nothing.
    # surrogatepass: a JSON string may carry a lone surrogate.
    return plain[:_BCRYPT_MAX_BYTES].encode("utf-8", "surrogatepass")[:_BCRYPT_MAX_BYTES]


def hash_password(plain: str) -> str:
    return bcrypt.hashpw(_bcrypt_input(plain), bcrypt.gensalt()).decode()


def verify_password(plain: str, hashed: str) -> bool:
    """False for a wrong password, and for a stored hash bcrypt can't read -
    a damaged row is a failed login, not a 500."""
    try:
        return bcrypt.checkpw(_bcrypt_input(plain), hashed.encode())
    except (ValueError, TypeError, AttributeError):
        logger.warning("[security] unreadable password hash; treated as a mismatch")
        return False


async def hash_password_async(plain: str) -> str:
    return await asyncio.to_thread(hash_password, plain)


async def verify_password_async(plain: str, hashed: str) -> bool:
    return await asyncio.to_thread(verify_password, plain, hashed)


@functools.cache
def _no_account_hash() -> str:
    # Made with the same gensalt() as real hashes, so checking against it
    # costs exactly what checking a real account costs.
    return hash_password(secrets.token_urlsafe(16))


async def verify_login_password(plain: str, hashed: str | None) -> bool:
    """`verify_password_async`, for a login where the account may not exist
    (`hashed` is None). Without an account there is still a bcrypt check,
    against a throwaway hash: answering "wrong phone" in 1 ms and "wrong
    password" in 250 ms told anyone with a list of numbers which of them
    have BROKA accounts."""
    if hashed is None:
        # _no_account_hash() inside the thread: its first call hashes too.
        await asyncio.to_thread(lambda: verify_password(plain, _no_account_hash()))
        return False
    return await verify_password_async(plain, hashed)


# ── Access token (15 min) ─────────────────────────────────────────────────────

def create_access_token(data: dict) -> str:
    payload          = data.copy()
    payload["exp"]   = datetime.now(timezone.utc) + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    payload["type"]  = "access"
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


# ── Phone-verify token (short-lived, OTP → /auth/register handoff) ──────────
# Issued by /auth/otp/verify once the OTP is correct. /auth/register requires
# this token instead of re-deriving verification state, so a completed OTP
# check can't silently expire mid-form-fill without the user knowing.

def create_phone_verify_token(phone: str) -> str:
    from api.core.config import settings as _settings
    payload = {
        "phone": phone,
        "type": "phone_verify",
        "exp": datetime.now(timezone.utc) + timedelta(
            minutes=_settings.phone_verify_token_expire_minutes
        ),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def decode_phone_verify_token(token: str) -> str | None:
    """Returns the verified phone number, or None if invalid/expired/wrong type."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    if payload.get("type") != "phone_verify":
        return None
    return payload.get("phone")


# ── Email-verify token (short-lived, email OTP → /auth/register handoff) ────
# Exact counterpart of the phone-verify token above, for the optional email
# step. Kept as its own type so an email token can never stand in for a
# proven phone number, or the reverse.

def create_email_verify_token(email: str) -> str:
    from api.core.config import settings as _settings
    payload = {
        "email": email,
        "type": "email_verify",
        "exp": datetime.now(timezone.utc) + timedelta(
            minutes=_settings.phone_verify_token_expire_minutes
        ),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def decode_email_verify_token(token: str) -> str | None:
    """Returns the verified email address, or None if invalid/expired/wrong type."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    if payload.get("type") != "email_verify":
        return None
    return payload.get("email")


# ── Call token (short-lived, WebSocket signaling auth) ───────────────────────
# Issued by POST /calls/initiate (to the caller) and GET /calls/pending/{id}
# (to the callee) once each is confirmed to be a legitimate participant on a
# specific room_id. GET /calls/ws/{room_id} requires this instead of the
# normal long-lived access token, so a call's signaling connection no longer
# needs that token sitting in a WebSocket URL (which can end up in proxy/
# server access logs) - and scoping it to one room_id means a leaked call
# token only exposes that one call, not the holder's whole account, for a
# few minutes at most.

def create_call_token(user_id: str, room_id: str) -> str:
    from api.core.config import settings as _settings
    payload = {
        "sub":     user_id,
        "room_id": room_id,
        "type":    "call",
        "exp": datetime.now(timezone.utc) + timedelta(
            minutes=_settings.call_token_expire_minutes
        ),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)


def decode_call_token(token: str) -> dict | None:
    """Returns {"sub": user_id, "room_id": room_id, ...} if valid, else None.
    Caller must still confirm payload["room_id"] matches the room being
    joined - this only proves the token itself is genuine and unexpired."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
    if payload.get("type") != "call":
        return None
    return payload


# ── Refresh token (30 day, DB-backed) ────────────────────────────────────────

def create_refresh_token(user_id: str) -> tuple[str, datetime, str]:
    """
    Returns (token_string, expiry_utc, jti).
    Caller must INSERT a RefreshToken row with this jti for revocation to work.
    """
    jti    = secrets.token_urlsafe(16)
    expiry = datetime.now(timezone.utc) + timedelta(days=REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub":  user_id,
        "type": "refresh",
        "jti":  jti,
        "exp":  expiry,
    }
    token = jwt.encode(payload, SECRET_KEY, algorithm=ALGORITHM)
    return token, expiry, jti


def decode_refresh_token(token: str) -> dict | None:
    """Decode without raising. Caller must verify jti exists in DB."""
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload if payload.get("type") == "refresh" else None
    except JWTError:
        return None


# ── Generic decode ────────────────────────────────────────────────────────────

def decode_token(token: str) -> dict | None:
    """Signature and expiry only - says nothing about what the token is FOR.

    Every token this module issues is signed with the same key, so a valid
    signature alone would let a refresh, call, phone-verify or email-verify
    token stand in for an access token. Anything that turns a token into an
    identity must go through decode_access_token() instead.
    """
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None


def decode_access_token(token: str) -> dict | None:
    """The payload of a genuine access token, or None.

    The one gate between "a validly signed token" and "this request is
    user X". Only `type == "access"` passes: a call token is scoped to one
    room for a few minutes, a refresh token is meant only for /auth/refresh,
    and the verify tokens prove a phone or email, not an account. Each of
    those has its own decoder, and none of them may authenticate a route -
    otherwise a call token leaked from a WebSocket URL would be a full
    account token for its lifetime.

    Used by the HTTP dependencies below and by every WebSocket that takes
    the ordinary access token (deal, auction, media chat). The call
    signalling socket uses decode_call_token() instead.
    """
    payload = decode_token(token)
    if payload is None:
        return None
    if payload.get("type") != "access" or not payload.get("sub"):
        return None
    return payload


def decode_token_strict(token: str) -> dict:
    """Raises HTTP 401 unless `token` is a valid access token."""
    payload = decode_token(token)
    if payload is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if payload.get("type") == "refresh":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Provide an access token, not a refresh token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if payload.get("type") != "access":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="This token can't be used to sign in",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return payload


# ── FastAPI dependencies ──────────────────────────────────────────────────────

def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    payload = decode_token_strict(token)
    user_id: str | None = payload.get("sub")
    if not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Bad token payload")
    return {"id": user_id}


# v6.1: browse-before-signup — auto_error=False means a missing/absent
# Authorization header returns None instead of raising, so a listings feed
# (etc.) can serve guests and logged-in users from the same endpoint. An
# invalid/expired token still raises 401 rather than silently downgrading to
# a guest, since that's much more likely to be a bug on the client than an
# intentional guest request.
_oauth2_scheme_optional = OAuth2PasswordBearer(tokenUrl="/auth/login", auto_error=False)


def get_current_user_optional(
    token: str | None = Depends(_oauth2_scheme_optional),
) -> dict | None:
    if not token:
        return None
    return get_current_user(token)


async def require_admin(current_user: dict = Depends(get_current_user)):
    from sqlalchemy import select
    from api.database import AsyncSessionLocal, User
    async with AsyncSessionLocal() as db:
        result = await db.execute(select(User).where(User.id == current_user["id"]))
        user = result.scalar_one_or_none()
    if not user or not user.is_admin:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Admin access required")
    return current_user
