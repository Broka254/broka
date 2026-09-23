"""Admin Router v3.0 — now includes fraud management and audit log access."""
from __future__ import annotations

import logging
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, desc

from api.database import (
    get_db, User, Listing, Deal, Dispute, Review,
    MpesaTransaction, AuditLog, FraudEvent, DealStatus,
)
from api.security import get_current_user
from api.core.permissions import require_admin
from api.core.fraud import compute_trust_score, trust_band

_log = logging.getLogger(__name__)

router = APIRouter()


@router.get("/summary")
async def admin_summary(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    users_r = await db.execute(select(func.count(User.id)))
    listings_r = await db.execute(select(func.count(Listing.id)))
    deals_r = await db.execute(select(func.count(Deal.id)))
    revenue_r = await db.execute(
        select(func.sum(Deal.commission)).where(Deal.status == DealStatus.released)
    )
    disputes_r = await db.execute(select(func.count(Dispute.id)))
    flagged_r = await db.execute(select(func.count(User.id)).where(User.is_flagged == True))

    return {
        "users": users_r.scalar() or 0,
        "listings": listings_r.scalar() or 0,
        "deals": deals_r.scalar() or 0,
        "commission_earned_kes": float(revenue_r.scalar() or 0),
        "disputes": disputes_r.scalar() or 0,
        "flagged_users": flagged_r.scalar() or 0,
    }


@router.get("/users")
async def list_users(
    limit: int = 50,
    offset: int = 0,
    flagged_only: bool = False,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    q = select(User).order_by(desc(User.created_at)).limit(limit).offset(offset)
    if flagged_only:
        q = q.where(User.is_flagged == True)
    r = await db.execute(q)
    users = r.scalars().all()
    return [
        {
            "id": u.id, "name": u.name, "email": u.email, "phone": u.phone,
            "is_admin": u.is_admin, "is_verified": u.is_verified,
            "trust_score": u.trust_score or 100,
            "trust_band": trust_band(u.trust_score or 100),
            "is_flagged": bool(u.is_flagged),
            "completed_deals": u.completed_deals,
            "rating": u.rating,
            "created_at": u.created_at.isoformat() if u.created_at else None,
        }
        for u in users
    ]


@router.post("/users/{user_id}/promote-admin")
async def promote_to_admin(
    user_id: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_admin = True
    await db.commit()
    return {"ok": True, "user_id": user_id}


@router.post("/users/{user_id}/flag")
async def flag_user(
    user_id: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_flagged = True
    user.trust_score = max(0, (user.trust_score or 100) - 30)
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": user.trust_score}


@router.post("/users/{user_id}/unflag")
async def unflag_user(
    user_id: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_flagged = False
    # Recompute trust score
    score = await compute_trust_score(user_id, db)
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": score}


@router.post("/users/{user_id}/recompute-trust")
async def recompute_trust(
    user_id: str,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    score = await compute_trust_score(user_id, db)
    await db.commit()
    return {"user_id": user_id, "trust_score": score, "trust_band": trust_band(score)}


@router.get("/ai-savings")
async def ai_savings(admin: User = Depends(require_admin)):
    """How many relay-classification calls are being avoided.

    Process-local counters, so they reset on deploy and are per-worker -
    an observability aid for tuning the pre-filter word list, not billing.
    Compare `avoided_fraction` against your provider dashboard.
    """
    from api.core.ai_cost import AISavings
    return AISavings.snapshot()


@router.get("/ledger-integrity")
async def ledger_integrity(
    db: AsyncSession = Depends(get_db),
    admin: User = Depends(require_admin),
):
    """Escrow ledger health.

    Added in the escrow audit (2026-09-14): EscrowLedger.trial_balance()
    already existed but NOTHING ever called it - the double-entry ledger's
    only integrity check was unreachable dead code, which is how a bug that
    left escrow_holding short by 97% of the goods price on every legacy
    deal went unnoticed.

    Read `escrow_integrity_ok`, not `balanced`. `balanced` compares total
    debits to total credits across the whole table, and every ledger helper
    writes matched pairs, so it is true by construction however wrong the
    amounts are. `negative_escrow_deals` is the real assertion: a deal
    whose escrow account has had more money leave it than ever entered it.
    """
    from api.core.ledger import ledger as _ledger
    report = await _ledger.trial_balance(db)
    if not report["escrow_integrity_ok"]:
        _log.error(
            "[ledger] INTEGRITY_FAILURE %d deal(s) with negative escrow balance",
            len(report["negative_escrow_deals"]),
        )
    return report


@router.get("/audit-logs")
async def get_audit_logs(
    resource_type: Optional[str] = None,
    resource_id: Optional[str] = None,
    actor_id: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    q = select(AuditLog).order_by(desc(AuditLog.created_at)).limit(limit).offset(offset)
    if resource_type:
        q = q.where(AuditLog.resource_type == resource_type)
    if resource_id:
        q = q.where(AuditLog.resource_id == resource_id)
    if actor_id:
        q = q.where(AuditLog.actor_id == actor_id)
    r = await db.execute(q)
    logs = r.scalars().all()
    return [
        {
            "id": l.id, "actor_id": l.actor_id, "action": l.action,
            "resource_type": l.resource_type, "resource_id": l.resource_id,
            "detail": l.detail, "ip_address": l.ip_address,
            "created_at": l.created_at.isoformat() if l.created_at else None,
        }
        for l in logs
    ]


@router.get("/fraud-events")
async def get_fraud_events(
    resolved: Optional[bool] = None,
    limit: int = 50,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    q = select(FraudEvent).order_by(desc(FraudEvent.created_at)).limit(limit)
    if resolved is not None:
        q = q.where(FraudEvent.resolved == resolved)
    r = await db.execute(q)
    events = r.scalars().all()
    return [
        {
            "id": e.id, "user_id": e.user_id, "reason": e.reason,
            "triggered_by": e.triggered_by, "trust_score_at_flag": e.trust_score_at_flag,
            "reviewed_by_admin": e.reviewed_by_admin, "resolved": e.resolved,
            "created_at": e.created_at.isoformat() if e.created_at else None,
        }
        for e in events
    ]


@router.get("/transactions")
async def get_transactions(
    limit: int = 50,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(
        select(MpesaTransaction).order_by(desc(MpesaTransaction.created_at)).limit(limit)
    )
    txns = r.scalars().all()
    return [
        {
            "id": t.id, "deal_id": t.deal_id, "buyer_id": t.buyer_id,
            "phone": t.phone, "amount": t.amount,
            "mpesa_receipt": t.mpesa_receipt,
            "status": t.status.value,
            "created_at": t.created_at.isoformat() if t.created_at else None,
        }
        for t in txns
    ]


# ── Platform Architecture Endpoints (v6.0) ────────────────────────────────────

@router.get("/workflow-versions")
async def get_workflow_versions(
    admin: User = Depends(require_admin),
):
    """
    Return all registered workflow versions and their rule sets.
    Useful for understanding which rules apply to in-flight deals.
    """
    from api.core.workflow import spec_summary, CURRENT_VERSION
    return {
        "current_version": CURRENT_VERSION,
        "versions": spec_summary(),
    }


@router.get("/event-metrics")
async def get_event_metrics(
    admin: User = Depends(require_admin),
):
    """
    Return in-process event counts since last restart.
    For persistent metrics, configure Prometheus + Grafana.
    """
    from api.core.observability import get_event_metrics
    from api.core.event_catalog import handler_count
    counts = get_event_metrics()
    total  = sum(counts.values())
    return {
        "total_events":      total,
        "by_type":           counts,
        "registered_handlers": handler_count(),
    }


@router.get("/event-catalog")
async def get_event_catalog(
    admin: User = Depends(require_admin),
):
    """
    Return the full Broka Event Catalog — every event type and its domain.
    Useful for documentation, consumer discovery, and schema governance.
    """
    from api.core.event_catalog import EventType
    catalog = {}
    for et in EventType:
        domain = et.value.split(".")[0]
        catalog.setdefault(domain, []).append(et.value)
    return {
        "total_event_types": len(EventType),
        "by_domain": catalog,
    }


@router.post("/media/backfill")
async def run_media_backfill(
    rows_per_kind: int = Query(50, ge=1, le=500),
    admin: User = Depends(require_admin),
):
    """Run one media backfill pass now (the 5-minute sweep runs smaller
    ones on its own) and report what is left."""
    from api.domains.media.backfill import pending_counts, run_backfill_pass
    done = await run_backfill_pass(rows_per_kind=rows_per_kind, time_budget=60.0)
    return {"converted": done, "remaining": await pending_counts()}
