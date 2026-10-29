"""Admin additions: alerts, revenue, timeseries, detail reads.

Permissions (all pre-existing enums — no new permission was introduced):
  - reads (alerts list/stream, revenue, timeseries, detail reads):
    ADMIN_SUMMARY, the dashboard's existing read permission.
  - alert ack/resolve/manual-create: MANAGE_USERS, the existing
    operator-action permission (same as flag/unflag).

Error shapes follow the file they extend (detail strings, 404 "not found",
422 for bad query values).
"""
from __future__ import annotations

import asyncio
import json
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.permissions import Permission, require_permission
from api.database import Deal, Dispute, DisputeStatus, Listing, User, get_db
from api.domains.admin.router import (
    _deal_item,
    _iso,
    _money,
    _now_iso,
    _status,
    _user_item,
)
from api.models.dispute import DisputeCase
from api.models.store import Store

router = APIRouter()


class AdminActionIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=500)


class AlertCreateIn(BaseModel):
    kind: str = Field(max_length=64)
    severity: str = Field(max_length=16)
    title: str = Field(max_length=255)
    body: Optional[str] = None
    href: Optional[str] = Field(default=None, max_length=255)
    meta: Optional[dict] = None


# ── Alerts ────────────────────────────────────────────────────────────────────

@router.get("/alerts")
async def list_alerts(
    status: str = Query("open"),
    severity: Optional[str] = Query(None),
    kind: Optional[str] = Query(None, max_length=64),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    from api.core.admin_alerts import list_alerts as _list
    from api.models.admin_alert import AlertSeverity, AlertStatus

    if status not in ("open", "acknowledged", "resolved", "all"):
        raise HTTPException(
            status_code=422,
            detail="status must be one of open, acknowledged, resolved, all",
        )
    if severity is not None and severity not in AlertSeverity.ALL:
        raise HTTPException(status_code=422, detail="unknown severity")
    rows, total, unread = await _list(
        db, status=status, severity=severity, kind=kind,
        limit=limit, offset=offset,
    )
    from api.core.admin_alerts import alert_to_dict

    return {
        "items": [alert_to_dict(row) for row in rows],
        "total": total,
        "unread": unread,
    }


@router.post("/alerts", status_code=201)
async def create_alert(
    body: AlertCreateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    from api.core.admin_alerts import alert_to_dict, create_alert as _create
    from api.models.admin_alert import AlertSeverity

    if not body.kind.strip():
        raise HTTPException(status_code=422, detail="kind is required")
    if body.severity not in AlertSeverity.ALL:
        raise HTTPException(status_code=422, detail="unknown severity")
    if not body.title.strip():
        raise HTTPException(status_code=422, detail="title is required")
    try:
        row = await _create(
            db,
            kind=body.kind.strip(),
            severity=body.severity,
            title=body.title.strip(),
            body=body.body,
            href=body.href,
            meta=body.meta or {},
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    await record_audit(
        db, admin.id, "admin_alert_created", "admin_alert", str(row.id),
        detail=f"kind={row.kind} severity={row.severity} title={row.title}",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    await db.refresh(row)
    return alert_to_dict(row)


async def _transition(
    alert_id: int,
    body: Optional[AdminActionIn],
    request: Request,
    admin: User,
    db: AsyncSession,
    action: str,
) -> dict:
    from api.core.admin_alerts import acknowledge, alert_to_dict, resolve

    fn = acknowledge if action == "acknowledge" else resolve
    row = await fn(db, alert_id, admin.id, (body.reason if body else None))
    if row is None:
        raise HTTPException(status_code=404, detail="Alert not found")
    await record_audit(
        db, admin.id, f"admin_alert_{action}d", "admin_alert", str(row.id),
        detail=(body.reason if body else None) or f"{action}d by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    await db.refresh(row)
    return alert_to_dict(row)


@router.post("/alerts/{alert_id}/acknowledge")
async def acknowledge_alert(
    alert_id: int,
    body: Optional[AdminActionIn] = None,
    request: Request = None,  # type: ignore[assignment]
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    return await _transition(
        alert_id, body, request, admin, db, "acknowledge"
    )


@router.post("/alerts/{alert_id}/resolve")
async def resolve_alert(
    alert_id: int,
    body: Optional[AdminActionIn] = None,
    request: Request = None,  # type: ignore[assignment]
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    return await _transition(alert_id, body, request, admin, db, "resolve")


@router.get("/alerts/stream")
async def alerts_stream(
    request: Request,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """Server-Sent Events: new alerts, unread stats, and heartbeats.

    Resumes from the Last-Event-ID header (polls for rows with id greater
    than it every 5s); emits `event: stats` with the open count every 15s
    and a `: ping` comment heartbeat every 15s so idle proxies do not cut
    the stream. Stops promptly when the client disconnects.
    """
    from api.database import AsyncSessionLocal
    from api.models.admin_alert import AdminAlert, AlertStatus

    try:
        last_id = int(request.headers.get("Last-Event-ID", "0") or 0)
    except ValueError:
        last_id = 0

    async def _unread(db: AsyncSession) -> int:
        from sqlalchemy import func

        return int(
            (await db.execute(
                select(func.count(AdminAlert.id)).where(
                    AdminAlert.status == AlertStatus.OPEN
                )
            )).scalar() or 0
        )

    async def _new_since(db: AsyncSession, since: int):
        from api.core.admin_alerts import alert_to_dict

        rows = (
            await db.execute(
                select(AdminAlert)
                .where(AdminAlert.id > since)
                .order_by(AdminAlert.id)
                .limit(100)
            )
        ).scalars().all()
        return rows

    async def _gen():
        cursor = last_id
        stats_at = 0.0
        import time

        while True:
            if await request.is_disconnected():
                break
            async with AsyncSessionLocal() as db:
                rows = await _new_since(db, cursor)
                from api.core.admin_alerts import alert_to_dict

                for row in rows:
                    cursor = max(cursor, int(row.id))
                    yield f"event: alert\ndata: {json.dumps(alert_to_dict(row))}\n\n"
                now = time.monotonic()
                if now - stats_at >= 15:
                    stats_at = now
                    yield f"event: stats\ndata: {json.dumps({'unread': await _unread(db)})}\n\n"
                    yield ": ping\n\n"
            for _ in range(50):  # 5s in 100ms slices, abortable on disconnect
                await asyncio.sleep(0.1)
                if await request.is_disconnected():
                    break

    return StreamingResponse(
        _gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )


# ── Revenue ───────────────────────────────────────────────────────────────────

@router.get("/revenue")
async def admin_revenue(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    bucket: str = Query("day"),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """BROKA income vs platform costs. Reads finance permission; never
    touches deal/escrow rows (E-Confirm money is not BROKA income)."""
    from api.core.revenue import revenue_report

    try:
        return await revenue_report(db, from_raw=from_, to_raw=to, bucket=bucket)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


# ── Analytics timeseries ──────────────────────────────────────────────────────

@router.get("/analytics/timeseries")
async def admin_timeseries(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    bucket: str = Query("day"),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    from api.core.analytics import timeseries_report

    try:
        return await timeseries_report(
            db, from_raw=from_, to_raw=to, bucket=bucket
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


# ── Detail reads ──────────────────────────────────────────────────────────────

def _listing_item(listing: Listing) -> dict:
    return {
        "id": listing.id,
        "name": listing.name,
        "seller_id": listing.seller_id,
        "store_id": listing.store_id,
        "category": listing.category,
        "price": _money(listing.price),
        "status": _status(listing.status),
        "listing_type": _status(listing.listing_type),
        "location_name": listing.location_name,
        "views": int(listing.views or 0),
        "is_featured": bool(listing.is_featured),
        "created_at": _iso(listing.created_at),
        # Extras beyond the list shape: the fields an operator opens the
        # record for (description, expiry, featuring, payment standing).
        "description": listing.description,
        "featured_until": _iso(listing.featured_until),
        "paid_until": _iso(getattr(listing, "paid_until", None)),
        "updated_at": _iso(getattr(listing, "updated_at", None)),
    }


@router.get("/listings/{listing_id}")
async def admin_listing_detail(
    listing_id: str,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    listing = (
        await db.execute(select(Listing).where(Listing.id == listing_id))
    ).scalar_one_or_none()
    if listing is None:
        raise HTTPException(status_code=404, detail="Listing not found")
    return {**_listing_item(listing), "generated_at": _now_iso()}


@router.get("/disputes/{dispute_id}")
async def admin_dispute_detail(
    dispute_id: str,
    admin: User = Depends(require_permission(Permission.VIEW_ALL_DISPUTES)),
    db: AsyncSession = Depends(get_db),
):
    dispute = (
        await db.execute(select(DisputeCase).where(DisputeCase.id == dispute_id))
    ).scalar_one_or_none()
    if dispute is None:
        raise HTTPException(status_code=404, detail="Dispute not found")
    deal = None
    if dispute.deal_id:
        deal = (
            await db.execute(select(Deal).where(Deal.id == dispute.deal_id))
        ).scalar_one_or_none()
    now = datetime.utcnow()
    age = None
    if dispute.created_at is not None:
        age = round(
            max(0.0, (now - dispute.created_at).total_seconds() / 3600), 2
        )
    return {
        "id": dispute.id,
        "deal_id": dispute.deal_id,
        "opener_id": dispute.opener_id,
        "dispute_type": dispute.dispute_type,
        "branch": _status(dispute.branch),
        "state": _status(dispute.state),
        "ai_recommendation": dispute.ai_recommendation,
        "rule_decision": dispute.rule_decision,
        "rule_decision_reason": dispute.rule_decision_reason,
        "fund_action": dispute.fund_action,
        "fund_amount": _money(dispute.fund_amount),
        "resolved_by": dispute.resolved_by,
        "created_at": _iso(dispute.created_at),
        "updated_at": _iso(dispute.updated_at),
        "closed_at": _iso(dispute.closed_at),
        "age_hours": age,
        # Extras: the deal context an operator needs without a second call.
        "deal": _deal_item(deal) if deal is not None else None,
        "generated_at": _now_iso(),
    }


@router.get("/stores/{store_id}")
async def admin_store_detail(
    store_id: str,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    store = (
        await db.execute(select(Store).where(Store.id == store_id))
    ).scalar_one_or_none()
    if store is None:
        raise HTTPException(status_code=404, detail="Store not found")
    return {
        "id": store.id,
        "name": store.name,
        "slug": store.slug,
        "owner_id": store.owner_id,
        "category": store.category,
        "county": store.county,
        "is_active": bool(store.is_active),
        "rating": store.rating,
        "rating_reviews": int(store.rating_reviews or 0),
        "deleted_at": _iso(store.deleted_at),
        "created_at": _iso(store.created_at),
        # Extras: contact + presentation fields for ops review.
        "description": store.description,
        "official_phone": store.official_phone,
        "official_email": store.official_email,
        "updated_at": _iso(store.updated_at),
        "generated_at": _now_iso(),
    }
