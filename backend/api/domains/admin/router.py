"""Admin Router v3.0 — now includes fraud management and audit log access."""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, desc

from api.database import (
    get_db, User, Listing, Deal, Dispute, Review,
    MpesaTransaction, MpesaStatus, AuditLog, FraudEvent, DealStatus,
)
from api.models.payment_callback import PaymentCallback, PaymentCallbackStatus
from api.models.store import Store
from api.security import get_current_user
from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.permissions import require_admin
from api.core.fraud import compute_trust_score, trust_band

_log = logging.getLogger(__name__)

router = APIRouter()


class AdminActionIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=500)


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


@router.get("/ops-snapshot")
async def ops_snapshot(
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """One bounded read for the dashboard's operations page.

    The external dashboard previously called this path and received 404.
    Every number here is computed from a live table; none is a placeholder.
    Kept deliberately aggregate-only - the dashboard does not need user
    phone numbers or provider payloads to show operational load.
    """
    async def count(model, *where):
        query = select(func.count()).select_from(model)
        if where:
            query = query.where(*where)
        return int((await db.execute(query)).scalar() or 0)

    deal_rows = (await db.execute(
        select(Deal.status, func.count(Deal.id)).group_by(Deal.status)
    )).all()
    deals_by_status = {
        getattr(status, "value", str(status)): int(count or 0)
        for status, count in deal_rows
    }
    payment_rows = (await db.execute(
        select(MpesaTransaction.status, func.count(MpesaTransaction.id))
        .group_by(MpesaTransaction.status)
    )).all()
    payments_by_status = {
        getattr(status, "value", str(status)): int(count or 0)
        for status, count in payment_rows
    }

    pending_callbacks = await count(
        PaymentCallback,
        PaymentCallback.status == PaymentCallbackStatus.PENDING,
    )
    stale_mpesa = await count(
        MpesaTransaction,
        MpesaTransaction.status == MpesaStatus.pending,
    )

    return {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "users": {
            "total": await count(User),
            "flagged": await count(User, User.is_flagged == True),  # noqa: E712
            "admins": await count(User, User.is_admin == True),     # noqa: E712
        },
        "listings": {"total": await count(Listing)},
        "stores": {
            "total": await count(Store),
            "active": await count(Store, Store.deleted_at.is_(None), Store.is_active == True),  # noqa: E712
            "deleted": await count(Store, Store.deleted_at.is_not(None)),
        },
        "deals": {"total": sum(deals_by_status.values()), "by_status": deals_by_status},
        "payments": {
            "total": sum(payments_by_status.values()),
            "by_status": payments_by_status,
            "pending_callbacks": pending_callbacks,
        },
        "disputes": {"total": await count(Dispute)},
        "jobs": {"stale_pending_stk": stale_mpesa},
    }


@router.get("/health/services")
async def service_health(
    admin: User = Depends(require_admin),
):
    """Configuration and reachability of the services the API depends on.

    Values are booleans/states only. Never return an API key, DSN, token or
    provider response body: this endpoint is authenticated, but credentials
    still do not belong in an HTTP response or the logs it produces.
    """
    from api.core.config import settings
    from api.database import schema_status

    services = {}
    overall_ok = True
    try:
        status = await schema_status()
        services["database"] = {
            "ok": True,
            "schema_ok": bool(status["current"]),
            "schema_version": status["current_version"],
            "schema_required": status["required_version"],
        }
        overall_ok = overall_ok and bool(status["current"])
    except Exception as exc:
        services["database"] = {"ok": False, "error": type(exc).__name__}
        overall_ok = False

    if settings.redis_enabled:
        try:
            import redis.asyncio as aioredis
            client = aioredis.from_url(
                settings.redis_url, socket_connect_timeout=2, socket_timeout=2,
            )
            await client.ping()
            await client.aclose()
            services["redis"] = {"ok": True}
        except Exception as exc:
            services["redis"] = {"ok": False, "error": type(exc).__name__}
            overall_ok = False
    else:
        services["redis"] = {
            "ok": False,
            "configured": False,
            "detail": "not configured; in-process fallbacks are active",
        }

    services["mpesa"] = {
        "ok": bool(settings.mpesa_consumer_key and settings.mpesa_consumer_secret),
        "configured": bool(settings.mpesa_consumer_key and settings.mpesa_consumer_secret),
        "callback_secret_configured": bool(settings.mpesa_callback_secret),
    }
    services["econfirm"] = {
        "ok": bool(settings.econfirm_api_key),
        "configured": bool(settings.econfirm_api_key),
    }
    services["zetupay"] = {
        "ok": bool(settings.zetupay_enabled and settings.zetupay_secret_key),
        "enabled": bool(settings.zetupay_enabled),
        "configured": bool(settings.zetupay_secret_key),
    }
    services["sms"] = {"configured": bool(
        (settings.mobitech_api_key and settings.mobitech_sender_name)
        or (settings.at_api_key and settings.at_username)
    )}
    services["email"] = {"configured": bool(settings.email_enabled)}
    services["object_storage"] = {"configured": bool(settings.r2_configured)}
    services["error_tracking"] = {"configured": bool(settings.sentry_dsn)}

    return {
        "checked_at": datetime.utcnow().isoformat() + "Z",
        "status": "ok" if overall_ok else "degraded",
        "services": services,
    }


@router.get("/stores")
async def admin_stores(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    active: Optional[bool] = None,
    deleted: bool = False,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Bounded store listing for the admin dashboard.

    The external dashboard called `/admin/stores` and got 404. This exposes
    operational fields only; business email and owner phone are not needed
    to moderate a store and are omitted.
    """
    query = select(Store)
    if deleted:
        query = query.where(Store.deleted_at.is_not(None))
    else:
        query = query.where(Store.deleted_at.is_(None))
    if active is not None:
        query = query.where(Store.is_active == active)
    rows = (await db.execute(
        query.order_by(desc(Store.created_at)).limit(limit).offset(offset)
    )).scalars().all()
    return [
        {
            "id": store.id,
            "owner_id": store.owner_id,
            "name": store.name,
            "slug": store.slug,
            "category": store.category,
            "county": store.county,
            "is_active": bool(store.is_active),
            "deleted_at": store.deleted_at.isoformat() if store.deleted_at else None,
            "rating": store.rating,
            "rating_reviews": store.rating_reviews,
            "created_at": store.created_at.isoformat() if store.created_at else None,
        }
        for store in rows
    ]


@router.get("/users")
async def list_users(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
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
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_admin = True
    await record_audit(
        db, admin.id, "admin_promoted", "user", user_id,
        detail=(body.reason if body else None) or "promoted by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id}


@router.post("/users/{user_id}/flag")
async def flag_user(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    # Idempotent: clicking flag twice used to subtract another 30 points.
    if not user.is_flagged:
        user.is_flagged = True
        user.trust_score = max(0, (user.trust_score or 100) - 30)
    await record_audit(
        db, admin.id, "user_flagged", "user", user_id,
        detail=(body.reason if body else None) or "flagged by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": user.trust_score}


@router.post("/users/{user_id}/unflag")
async def unflag_user(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
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
    await record_audit(
        db, admin.id, "user_unflagged", "user", user_id,
        detail=(body.reason if body else None) or "unflagged by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": score}


@router.post("/users/{user_id}/recompute-trust")
async def recompute_trust(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    score = await compute_trust_score(user_id, db)
    await record_audit(
        db, admin.id, "user_trust_recomputed", "user", user_id,
        detail=(body.reason if body else None) or f"trust recomputed to {score}",
        ip_address=client_ip_or_none(request),
    )
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


@router.get("/diagnostics/econfirm")
async def econfirm_diagnostics(
    amount: float = Query(1000, gt=0, le=1_000_000),
    admin: User = Depends(require_admin),
):
    """Is E-Confirm reachable with this deployment's key? Asks for the fee
    on `amount` - a read that moves no money - and returns what came back,
    including E-Confirm's own error, so a failed payment can be told apart
    from a wrong key, a wrong base URL or E-Confirm being down."""
    from api.core.config import settings
    from api.core.econfirm_client import EConfirmAPIError, EConfirmClient, EConfirmError
    out = {
        "configured": bool(settings.econfirm_api_key),
        "base_url": settings.econfirm_base_url,
        "call": f"GET /fee-quote?amount={int(round(amount))}",
    }
    try:
        out["response"] = await EConfirmClient().fee_quote(amount)
        out["ok"] = True
    except EConfirmAPIError as exc:
        out.update(ok=False, error="rejected", status_code=exc.status_code,
                   message=exc.message, provider_detail=exc.provider_detail)
    except EConfirmError as exc:
        out.update(ok=False, error=type(exc).__name__, message=str(exc))
    return out


@router.post("/deals/{deal_id}/econfirm-refunded")
async def econfirm_refunded(
    deal_id: str,
    request: Request,
    admin: User = Depends(require_admin),
    db: AsyncSession = Depends(get_db),
):
    """Close an approved refund that was returned by hand through E-Confirm.

    BROKA has no refund call on E-Confirm's API, so an approved refund on an
    E-Confirm deal freezes it and raises an `econfirm_refund_required`
    reconciliation alert (api/domains/escrow/protection.py). Once the money
    is back with the buyer, this marks the deal refunded and records it in
    the ledger.
    """
    from api.core.client_ip import client_ip_or_none
    from api.domains.escrow.protection import mark_econfirm_refunded
    return await mark_econfirm_refunded(db, deal_id, admin.id, request_ip=client_ip_or_none(request))


@router.get("/audit-logs")
async def get_audit_logs(
    resource_type: Optional[str] = None,
    resource_id: Optional[str] = None,
    actor_id: Optional[str] = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
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
    limit: int = Query(50, ge=1, le=200),
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
    limit: int = Query(50, ge=1, le=200),
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


@router.get("/diagnostics/client-ip")
async def client_ip_diagnostics(
    request: Request,
    admin: User = Depends(require_admin),
):
    """What this deployment believes the caller's address is, and why.

    Every per-IP rate limit depends on it (api/core/client_ip.py). Call it
    from a phone on mobile data: `resolved` should be that phone's public
    address, and `source` should not be "peer" behind a proxy - a peer
    address there is the proxy, shared by every user."""
    from api.core.client_ip import resolve
    from api.core.config import settings

    ip, source = resolve(request)
    return {
        "resolved": ip,
        "source": source,
        "peer": request.client.host if request.client else None,
        "headers": {
            name: request.headers.get(name)
            for name in ("cf-connecting-ip", "true-client-ip", "x-forwarded-for", "x-real-ip")
        },
        "config": {
            "client_ip_header": settings.client_ip_header or None,
            "trusted_proxy_hops": settings.trusted_proxy_hops,
            "storefront_key_set": bool(settings.storefront_api_key),
        },
    }
