# ==========================================================================
# DEAD CODE - NOT MOUNTED, NOT IMPORTED.
#
# Verified 2026-09-14 by reading main.py directly rather than trusting
# comments: this module's name does not appear in main.py's
# `from api.routers import (...)` tuple, and no `app.include_router(...)`
# call references it. Nothing in the backend imports it either. None of
# its routes are reachable at runtime.
#
# Canonical replacement: api/domains/admin/router.py     (mounted at /admin)
#
# QUARANTINED, NOT DELETED (spec section 21). Deleting it is a separate,
# reversible commit that should be made once someone has confirmed no
# out-of-tree consumer (a script, a notebook, an ops runbook) imports it.
# Leaving it importable but clearly marked costs nothing; deleting it
# blind is the failure mode that section warns about.
#
# Do not add routes here. Do not mount this module.
# ==========================================================================
"""
⚠️  NOT MOUNTED — LEGACY / DEAD CODE (verified during Store hardening
pass, 2026-09: never imported in main.py). Canonical implementation is
api/domains/admin/router.py. Left in place rather than deleted; do not
edit this file expecting it to affect the running app. ⚠️

BROKA - Admin Router

Authenticated, admin-only endpoints for fraud monitoring, user management,
dispute oversight, and transaction visibility. Every route requires
require_admin (checks User.is_admin = True).

Bootstrap: set ADMIN_BOOTSTRAP_EMAIL env var before first boot, then call
POST /admin/bootstrap with that email - that user becomes admin. After
bootstrap, admins can promote other users via POST /admin/users/{id}/promote.
"""

import os
import logging
from datetime import datetime, timedelta
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, desc

from api.database import (
    get_db, User, Listing, Deal, Dispute, DisputeStatus,
    MpesaTransaction, MpesaStatus, DealStatus,
)
from api.security import get_current_user, require_admin

logger = logging.getLogger(__name__)
router = APIRouter()


# ── Bootstrap (no auth required, single-use guarded by env) ───────────────────

@router.post("/bootstrap")
async def bootstrap_admin(db: AsyncSession = Depends(get_db)):
    """
    Promote the user whose email matches ADMIN_BOOTSTRAP_EMAIL to admin.
    Idempotent. Fails closed when the env var is not set.
    """
    email = os.getenv("ADMIN_BOOTSTRAP_EMAIL", "").strip().lower()
    if not email:
        raise HTTPException(status_code=503, detail="Admin bootstrap is disabled")
    user = (await db.execute(select(User).where(User.email == email))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="Bootstrap user not found - sign up first")
    user.is_admin = True
    await db.commit()
    return {"user_id": user.id, "email": user.email, "is_admin": True}


# ── Dashboard summary ─────────────────────────────────────────────────────────

@router.get("/summary")
async def admin_summary(
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    last_24h = now - timedelta(hours=24)

    users_total      = (await db.execute(select(func.count(User.id)))).scalar() or 0
    users_verified   = (await db.execute(select(func.count(User.id)).where(User.is_verified == True))).scalar() or 0
    listings_total   = (await db.execute(select(func.count(Listing.id)))).scalar() or 0
    deals_total      = (await db.execute(select(func.count(Deal.id)))).scalar() or 0
    deals_paid       = (await db.execute(select(func.count(Deal.id)).where(Deal.status == DealStatus.paid))).scalar() or 0
    deals_released   = (await db.execute(select(func.count(Deal.id)).where(Deal.status == DealStatus.released))).scalar() or 0
    deals_refunded   = (await db.execute(select(func.count(Deal.id)).where(Deal.status == DealStatus.refunded))).scalar() or 0
    disputes_open    = (await db.execute(select(func.count(Dispute.id)).where(Dispute.status == DisputeStatus.open))).scalar() or 0
    mpesa_success_24h = (await db.execute(
        select(func.coalesce(func.sum(MpesaTransaction.amount), 0))
        .where(MpesaTransaction.status == MpesaStatus.success)
        .where(MpesaTransaction.created_at >= last_24h)
    )).scalar() or 0.0

    return {
        "users": {"total": users_total, "verified": users_verified},
        "listings": {"total": listings_total},
        "deals": {
            "total":    deals_total,
            "paid":     deals_paid,
            "released": deals_released,
            "refunded": deals_refunded,
        },
        "disputes": {"open": disputes_open},
        "mpesa": {"commission_collected_24h_kes": float(mpesa_success_24h)},
        "generated_at": now.isoformat(),
    }


# ── User management ───────────────────────────────────────────────────────────

@router.get("/users")
async def list_users(
    limit: int = 50,
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    limit = max(1, min(limit, 200))
    rows = (await db.execute(
        select(User).order_by(desc(User.created_at)).limit(limit)
    )).scalars().all()
    return [{
        "id":              u.id,
        "name":            u.name,
        "email":           u.email,
        "phone":           u.phone,
        "rating":          u.rating,
        "completed_deals": u.completed_deals,
        "is_verified":     u.is_verified,
        "is_admin":        u.is_admin,
        "created_at":      u.created_at.isoformat() if u.created_at else None,
    } for u in rows]


@router.post("/users/{user_id}/promote")
async def promote_user(
    user_id: str,
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_admin = True
    await db.commit()
    return {"user_id": user.id, "is_admin": True}


@router.post("/users/{user_id}/demote")
async def demote_user(
    user_id: str,
    admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    if user_id == admin["id"]:
        raise HTTPException(status_code=400, detail="Cannot demote yourself")
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_admin = False
    await db.commit()
    return {"user_id": user.id, "is_admin": False}


@router.post("/users/{user_id}/verify")
async def force_verify(
    user_id: str,
    tier: str = "basic",
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Admin-grant verification (e.g. KYC approved manually)."""
    if tier not in ("basic", "gold"):
        raise HTTPException(status_code=400, detail="tier must be basic or gold")
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_verified = True
    user.verify_tier = tier
    user.verify_expires_at = datetime.utcnow() + timedelta(days=365)
    await db.commit()
    return {"user_id": user.id, "is_verified": True, "tier": tier}


# ── Dispute oversight ─────────────────────────────────────────────────────────

@router.get("/disputes")
async def list_disputes(
    status: str | None = None,
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    stmt = select(Dispute).order_by(desc(Dispute.created_at)).limit(200)
    if status:
        try:
            stmt = stmt.where(Dispute.status == DisputeStatus(status))
        except ValueError:
            raise HTTPException(status_code=400, detail="Invalid status filter")
    rows = (await db.execute(stmt)).scalars().all()
    return [{
        "id":              d.id,
        "deal_id":         d.deal_id,
        "opener_id":       d.opener_id,
        "issue_type":      d.issue_type,
        "status":          d.status.value,
        "resolution_type": d.resolution_type,
        "zac_code":        d.zac_code,
        "created_at":      d.created_at.isoformat() if d.created_at else None,
        "resolved_at":     d.resolved_at.isoformat() if d.resolved_at else None,
    } for d in rows]


# ── Transaction monitoring ────────────────────────────────────────────────────

@router.get("/transactions")
async def list_transactions(
    limit: int = 100,
    _admin=Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    limit = max(1, min(limit, 500))
    rows = (await db.execute(
        select(MpesaTransaction).order_by(desc(MpesaTransaction.created_at)).limit(limit)
    )).scalars().all()
    return [{
        "id":             t.id,
        "deal_id":        t.deal_id,
        "buyer_id":       t.buyer_id,
        "phone":          t.phone,
        "amount":         t.amount,
        "status":         t.status.value,
        "mpesa_receipt":  t.mpesa_receipt,
        "created_at":     t.created_at.isoformat() if t.created_at else None,
    } for t in rows]
