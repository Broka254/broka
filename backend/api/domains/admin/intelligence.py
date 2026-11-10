"""Admin intelligence and founder reports.

Reads (every /intelligence route, the report archive, previews) need
ADMIN_SUMMARY, the dashboard's read permission. Generating a report writes
only an admin_reports row and an audit row, so it needs the same
permission; it changes no marketplace or money state.

The figures and their definitions live in api/core/intelligence.py; the
advice in api/core/insights.py; reports in api/core/admin_reports.py.
"""
from __future__ import annotations

import json
from datetime import datetime, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import admin_reports, intelligence
from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.config import settings
from api.core.insights import build_insights, severity_counts
from api.core.permissions import Permission, require_permission
from api.core.timeutil import parse_iso_to_naive_utc
from api.database import User, get_db
from api.models.admin_report import REPORT_KINDS, AdminReport

router = APIRouter()

def _parse(raw: Optional[str], label: str) -> Optional[datetime]:
    if raw is None or not raw.strip():
        return None
    try:
        return parse_iso_to_naive_utc(raw)
    except ValueError:
        raise HTTPException(status_code=422, detail=f"{label} must be an ISO-8601 date or time")


# ── Intelligence ──────────────────────────────────────────────────────────────

@router.get("/intelligence/pulse")
async def intelligence_pulse(
    window_days: int = Query(7, ge=1, le=90),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """The period's growth, liquidity, responsiveness, trust and money
    against the period before, plus Day-30 targets and break-even."""
    return await intelligence.pulse(db, window_days=window_days)


@router.get("/intelligence/insights")
async def intelligence_insights(
    window_days: int = Query(7, ge=1, le=90),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    start = now - timedelta(days=window_days)
    pulse = await intelligence.pulse_between(db, start, now, now=now)
    categories = await intelligence.categories_between(
        db, now - timedelta(days=max(window_days, 30)), now, now=now)
    sellers = await intelligence.sellers_overview(db, now=now, limit=10)
    insights = build_insights(pulse=pulse, categories=categories, sellers=sellers)
    return {
        "generated_at": intelligence.iso(now),
        "window_days": window_days,
        "insights": insights,
        "counts": severity_counts(insights),
    }


@router.get("/intelligence/categories")
async def intelligence_categories(
    window_days: int = Query(30, ge=7, le=180),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    return await intelligence.categories(db, window_days=window_days)


@router.get("/intelligence/geography")
async def intelligence_geography(
    window_days: int = Query(30, ge=7, le=180),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    return await intelligence.geography(db, window_days=window_days)


@router.get("/intelligence/funnel")
async def intelligence_funnel(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Sign-ups in [from, to) - by default the last 90 days - followed through
    the seller and buyer journeys to today."""
    end = _parse(to, "to") or datetime.utcnow()
    start = _parse(from_, "from") or end - timedelta(days=90)
    if start >= end:
        raise HTTPException(status_code=422, detail="from must be before to")
    if end - start > timedelta(days=366):
        raise HTTPException(status_code=422, detail="the range may be at most 366 days")
    return await intelligence.funnel(db, start=start, end=end)


@router.get("/intelligence/cohorts")
async def intelligence_cohorts(
    weeks: int = Query(8, ge=2, le=12),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    return await intelligence.cohorts(db, weeks=weeks)


@router.get("/intelligence/sellers")
async def intelligence_sellers(
    limit: int = Query(20, ge=1, le=100),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    return await intelligence.sellers_overview(db, limit=limit)


# ── Reports ───────────────────────────────────────────────────────────────────

class ReportGenerateIn(BaseModel):
    kind: Literal["daily", "weekly", "monthly"]
    # A local date (YYYY-MM-DD) inside the period to regenerate. Omitted:
    # the most recent period that has closed.
    period_date: Optional[str] = Field(default=None, max_length=10)


@router.get("/reports")
async def list_reports(
    kind: Optional[str] = Query(None),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    conditions = []
    if kind is not None:
        if kind not in REPORT_KINDS:
            raise HTTPException(status_code=422, detail=f"kind must be one of {', '.join(REPORT_KINDS)}")
        conditions.append(AdminReport.kind == kind)
    total = int((await db.execute(
        select(func.count(AdminReport.id)).where(*conditions))).scalar() or 0)
    rows = (await db.execute(
        select(AdminReport).where(*conditions)
        .order_by(desc(AdminReport.period_start), desc(AdminReport.generated_at), AdminReport.kind)
        .limit(limit).offset(offset)
    )).scalars().all()
    return {
        "items": [admin_reports.report_meta(row) for row in rows],
        "total": total, "limit": limit, "offset": offset,
        "generated_at": intelligence.iso(datetime.utcnow()),
        "schedule": {
            "enabled": settings.admin_reports_enabled,
            "timezone": admin_reports.tz_label(),
            "kinds": list(REPORT_KINDS),
        },
    }


# Registered before /reports/{report_id}: a path parameter would otherwise
# swallow "preview".
@router.get("/reports/preview")
async def preview_report(
    kind: str = Query("weekly"),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """The period in progress, to date. Computed, never stored: a week that
    has not ended must not take the place of its finished report."""
    if kind not in REPORT_KINDS:
        raise HTTPException(status_code=422, detail=f"kind must be one of {', '.join(REPORT_KINDS)}")
    now = datetime.utcnow()
    start, end = admin_reports.period_bounds(kind, now=now, which="current")
    payload = await admin_reports.build_report(db, kind=kind, start=start, end=end, now=now)
    return {
        "id": None,
        "kind": kind,
        "title": payload["title"],
        "headline": payload["headline"],
        "period_start": intelligence.iso(start),
        "period_end": intelligence.iso(end),
        "period_label": payload["period"]["label"],
        "generated_at": payload["generated_at"],
        "generated_by": admin.id,
        "insight_counts": payload["insight_counts"],
        "stored": False,
        "payload": payload,
        "markdown": admin_reports.render_markdown(payload),
    }


@router.post("/reports/generate")
async def generate_report(
    body: ReportGenerateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Build (or rebuild) the report for one closed period and store it."""
    now = datetime.utcnow()
    if body.period_date:
        try:
            local_day = datetime.strptime(body.period_date, "%Y-%m-%d")
        except ValueError:
            raise HTTPException(status_code=422, detail="period_date must be YYYY-MM-DD")
        # Local noon of that day, as UTC, sits safely inside its period.
        anchor = local_day + timedelta(hours=12) - timedelta(hours=settings.report_tz_offset_hours)
        start, end = admin_reports.period_bounds(body.kind, now=now, anchor=anchor)
    else:
        start, end = admin_reports.period_bounds(body.kind, now=now, which="previous")
    if end > now:
        raise HTTPException(
            status_code=422,
            detail="That period has not finished yet; open the live preview instead.")
    row, created = await admin_reports.save_report(
        db, kind=body.kind, start=start, end=end, generated_by=admin.id, now=now, replace=True)
    await record_audit(
        db, admin.id, "admin_report_generated", "admin_report", row.id,
        detail=json.dumps({"kind": row.kind, "period_start": intelligence.iso(row.period_start),
                           "created": created}, separators=(",", ":")),
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return admin_reports.report_detail(row)


@router.get("/reports/{report_id}")
async def get_report(
    report_id: str,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    row = (await db.execute(
        select(AdminReport).where(AdminReport.id == report_id))).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Report not found")
    return admin_reports.report_detail(row)


__all__ = ["router"]
