"""
BROKA v3.0 - Auth & Security
─────────────────────────────
• Access tokens: 15 minutes (was 7 days — issue #7 fixed)
• Refresh tokens: 30 days, opaque jti stored in DB for revocation
• Startup fails if SECRET_KEY == default placeholder (issue #4 fixed)
• decode_token() returns None on failure — safe for WebSocket use
"""
from __future__ import annotations

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

def hash_password(plain: str) -> str:
    return bcrypt.hashpw(plain[:72].encode(), bcrypt.gensalt()).decode()


def verify_password(plain: str, hashed: str) -> bool:
    return bcrypt.checkpw(plain[:72].encode(), hashed.encode())


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
    """Safe decode — returns None on any error. Used by WebSocket endpoints."""
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None


def decode_token_strict(token: str) -> dict:
    """Raises HTTP 401 on failure. Used by HTTP route dependencies."""
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
