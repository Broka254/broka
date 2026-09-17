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

from datetime import datetime, timezone
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

    now = datetime.now(timezone.utc)
    if stored.expires_at.replace(tzinfo=timezone.utc) < now:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token expired")

    # Issue new access token
    access_token = create_access_token({"sub": user_id})
    return {
        "access_token":  access_token,
        "token_type":    "bearer",
        "expires_in":    15 * 60,  # 15 minutes in seconds
    }


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
