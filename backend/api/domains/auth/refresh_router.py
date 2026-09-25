"""
BROKA v3.0 - Refresh Token Endpoints (issue #8 fixed)
───────────────────────────────────────────────────────
POST /auth/token/refresh — exchange a refresh token for a new access token
POST /auth/token/revoke  — revoke a refresh token (logout from one device)
POST /auth/token/revoke-all — revoke all refresh tokens for a user (logout all devices)

Refresh tokens are stored in the `refresh_tokens` table:
  - jti (unique token ID) for exact revocation
  - user_id + expires_at for expiry checks
  - revoked_at for immediate invalidation
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, update

from api.database import get_db, RefreshToken
from api.security import (
    create_access_token,
    create_refresh_token,
    decode_refresh_token,
    get_current_user,
)

router = APIRouter()

# Sliding sign-in. A refresh token lasts REFRESH_TOKEN_EXPIRE_DAYS from when
# it was issued; one used after ROTATE_AFTER is exchanged for a fresh one,
# so someone who opens the app at least that often stays signed in, and
# only a phone left unused for the whole lifetime has to sign in again.
# (The app used to hide a fixed 30-day expiry by logging in again with the
# user's stored password - which it no longer keeps.)
#
# The token being replaced keeps working for ROTATION_GRACE: if the
# response carrying the new one is lost on a bad connection, the app's
# retry with the old one still succeeds instead of signing the user out.
ROTATE_AFTER = timedelta(days=7)
ROTATION_GRACE = timedelta(minutes=10)


def issue_refresh_token_row(db: AsyncSession, user_id: str) -> str:
    """A new refresh token for `user_id`, its row added to `db` (the
    caller commits).

    expires_at is stored as naive UTC, like every DateTime column here.
    It used to be passed timezone-aware, which SQLite accepts and Postgres
    (asyncpg) refuses outright - so on Postgres every signup and login
    failed with a 500 when this row was written."""
    token, expiry, jti = create_refresh_token(user_id)
    db.add(RefreshToken(
        user_id=user_id, jti=jti, expires_at=expiry.astimezone(timezone.utc).replace(tzinfo=None),
    ))
    return token


def _naive_utc(value: Optional[datetime]) -> Optional[datetime]:
    if value is None or value.tzinfo is None:
        return value
    return value.astimezone(timezone.utc).replace(tzinfo=None)


class RefreshRequest(BaseModel):
    refresh_token: str


class RevokeRequest(BaseModel):
    refresh_token: str


# ── POST /auth/token/refresh ──────────────────────────────────────────────────

@router.post("/token/refresh")
async def refresh_access_token(body: RefreshRequest, db: AsyncSession = Depends(get_db)):
    """
    Exchange a valid refresh token for a new short-lived access token.
    The existing refresh token remains valid until its expiry.
    If you want rotation (single-use refresh tokens), revoke the old one here.
    """
    payload = decode_refresh_token(body.refresh_token)
    if not payload:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")

    jti     = payload.get("jti")
    user_id = payload.get("sub")

    # Verify token exists in DB and is not revoked
    r = await db.execute(
        select(RefreshToken).where(
            RefreshToken.jti == jti,
            RefreshToken.user_id == user_id,
        )
    )
    stored = r.scalar_one_or_none()

    if not stored:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token not found")

    if stored.revoked_at is not None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token has been revoked")

    now = datetime.now(timezone.utc).replace(tzinfo=None)
    if _naive_utc(stored.expires_at) < now:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")

    response = {
        "access_token":  create_access_token({"sub": user_id}),
        "token_type":    "bearer",
        "expires_in":    15 * 60,  # 15 minutes in seconds
    }
    issued = _naive_utc(stored.created_at)
    if issued is None or now - issued >= ROTATE_AFTER:
        response["refresh_token"] = issue_refresh_token_row(db, user_id)
        grace_until = now + ROTATION_GRACE
        if _naive_utc(stored.expires_at) > grace_until:
            stored.expires_at = grace_until
        await db.commit()
    return response


# ── POST /auth/token/revoke ───────────────────────────────────────────────────

@router.post("/token/revoke", status_code=204)
async def revoke_token(body: RevokeRequest, db: AsyncSession = Depends(get_db)):
    """Revoke a specific refresh token (logout from one device)."""
    payload = decode_refresh_token(body.refresh_token)
    if not payload:
        return  # Invalid token — nothing to revoke, return 204 silently

    jti = payload.get("jti")
    await db.execute(
        update(RefreshToken)
        .where(RefreshToken.jti == jti)
        .values(revoked_at=datetime.utcnow())
    )
    await db.commit()


# ── POST /auth/token/revoke-all ───────────────────────────────────────────────

@router.post("/token/revoke-all", status_code=204)
async def revoke_all_tokens(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Revoke ALL refresh tokens for the current user (logout all devices)."""
    await db.execute(
        update(RefreshToken)
        .where(
            RefreshToken.user_id == current_user["id"],
            RefreshToken.revoked_at.is_(None),
        )
        .values(revoked_at=datetime.utcnow())
    )
    await db.commit()
