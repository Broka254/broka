"""Administrative production-cost API for the BROKA dashboard.

Mounted at /admin/revenue/costs. Every route is backend-mediated - the
dashboard never talks to a provider, a database service account or an
internal table directly. Reads require ADMIN_SUMMARY; every write requires
MANAGE_COSTS, which only an administrator holds.

Reporting periods are half-open [from, to) everywhere, in naive UTC, and
every response names the period it describes. Amounts are integer minor
currency units; a cost that is not known is `null`, never 0.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.permissions import Permission, require_permission
from api.database import User, get_db
from api.domains.service_costs import service as costs
from api.models.service_cost import CostConfidence

router = APIRouter()


# ── Request contracts ───────────────────────────────────────────────────────

class CostEntryIn(BaseModel):
    service_key: str = Field(min_length=1, max_length=64)
    period_start: datetime
    period_end: datetime
    currency: str = Field(default="KES", min_length=3, max_length=8)
    actual_cost_minor: Optional[int] = Field(default=None, ge=0)
    estimated_cost_minor: Optional[int] = Field(default=None, ge=0)
    manually_entered_cost_minor: Optional[int] = Field(default=None, ge=0)
    notes: Optional[str] = Field(default=None, max_length=2000)
    invoice_reference: Optional[str] = Field(default=None, max_length=160)


class CostEntryPatch(BaseModel):
    actual_cost_minor: Optional[int] = Field(default=None, ge=0)
    estimated_cost_minor: Optional[int] = Field(default=None, ge=0)
    manually_entered_cost_minor: Optional[int] = Field(default=None, ge=0)
    currency: Optional[str] = Field(default=None, min_length=3, max_length=8)
    notes: Optional[str] = Field(default=None, max_length=2000)
    invoice_reference: Optional[str] = Field(default=None, max_length=160)
    reason: Optional[str] = Field(default=None, max_length=1000)
    clear_manual: bool = False


class PricingIn(BaseModel):
    service_key: str = Field(min_length=1, max_length=64)
    pricing_unit: str = Field(min_length=1, max_length=40)
    unit_price_minor: int = Field(ge=0)
    currency: str = Field(default="KES", min_length=3, max_length=8)
    effective_from: datetime
    effective_until: Optional[datetime] = None
    pricing_source: str = Field(min_length=1, max_length=160)
    confidence: str = CostConfidence.ESTIMATED


class PricingPatch(BaseModel):
    unit_price_minor: Optional[int] = Field(default=None, ge=0)
    effective_until: Optional[datetime] = None
    pricing_source: Optional[str] = Field(default=None, max_length=160)
    confidence: Optional[str] = None
    reason: Optional[str] = Field(default=None, max_length=1000)


# ── Helpers ─────────────────────────────────────────────────────────────────

def _range(from_raw: Optional[str], to_raw: Optional[str]) -> tuple[datetime, datetime]:
    try:
        return costs.report_range(from_raw, to_raw)
    except costs.ValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


def _fail(exc: Exception) -> None:
    """Translate domain errors into the API's status codes, once."""
    if isinstance(exc, costs.ValidationError):
        raise HTTPException(status_code=422, detail=str(exc))
    if isinstance(exc, costs.ConflictError):
        raise HTTPException(status_code=409, detail=str(exc))
    if isinstance(exc, LookupError):
        raise HTTPException(status_code=404, detail=str(exc))
    raise exc


# ── Reads ───────────────────────────────────────────────────────────────────

@router.get("/services")
async def list_service_costs(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    service_key: Optional[str] = Query(None, max_length=64),
    category: Optional[str] = Query(None, max_length=40),
    active_only: bool = Query(False),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Every catalogued service with its usage and effective cost.

    Per service: usage quantity, successful quantity, failed quantity, the
    usage unit, actual / estimated / manually adjusted cost, the effective
    reporting cost, currency, cost source, confidence and the period.
    """
    start, end = _range(from_, to)
    try:
        return await costs.services_report(
            db,
            start=start,
            end=end,
            service_key=service_key,
            category=category,
            active_only=active_only,
        )
    except Exception as exc:  # noqa: BLE001 - mapped deliberately by _fail
        _fail(exc)


@router.get("/summary")
async def cost_summary(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Platform-wide production cost, separated by currency and source."""
    start, end = _range(from_, to)
    try:
        return await costs.costs_summary(db, start=start, end=end)
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.get("/usage")
async def list_usage(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    service_key: Optional[str] = Query(None, max_length=64),
    status: Optional[str] = Query(None, max_length=16),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Provider operations recorded in the period (most recent first)."""
    start, end = _range(from_, to)
    try:
        return await costs.list_usage_events(
            db,
            start=start,
            end=end,
            service_key=service_key,
            status=status,
            limit=limit,
            offset=offset,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.get("/entries")
async def list_cost_entries(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    service_key: Optional[str] = Query(None, max_length=64),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Invoice totals, manual amounts and billing-period estimates."""
    start, end = _range(from_, to)
    try:
        return await costs.list_entries(
            db, start=start, end=end, service_key=service_key,
            limit=limit, offset=offset,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.get("/adjustments")
async def list_cost_adjustments(
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    service_key: Optional[str] = Query(None, max_length=64),
    limit: int = Query(200, ge=1, le=500),
    offset: int = Query(0, ge=0),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """The audit history of manual cost overrides, newest first."""
    start, end = _range(from_, to)
    try:
        return await costs.list_adjustments(
            db, start=start, end=end, service_key=service_key,
            limit=limit, offset=offset,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.get("/pricing")
async def list_service_pricing(
    service_key: Optional[str] = Query(None, max_length=64),
    active_at: Optional[str] = Query(None),
    limit: int = Query(500, ge=1, le=500),
    offset: int = Query(0, ge=0),
    _admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Effective-dated unit prices. Historical rows are never rewritten."""
    at = None
    if active_at:
        try:
            from api.core.timeutil import parse_iso_to_naive_utc

            at = parse_iso_to_naive_utc(active_at)
        except ValueError:
            raise HTTPException(status_code=422, detail="invalid active_at")
    try:
        return await costs.list_pricing(
            db, service_key=service_key, active_at=at,
            limit=limit, offset=offset,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


# ── Writes ──────────────────────────────────────────────────────────────────

@router.post("/entries", status_code=201)
async def create_cost_entry(
    body: CostEntryIn,
    admin: User = Depends(require_permission(Permission.MANAGE_COSTS)),
    db: AsyncSession = Depends(get_db),
):
    """Record a provider invoice total, a manual amount, or an estimate.

    A cost entry never deletes or changes usage rows. Updating a manual
    figure later appends a `service_cost_adjustments` row retaining the
    original estimate, and writes an audit-log entry.
    """
    try:
        result = await costs.create_cost_entry(
            db,
            admin_id=admin.id,
            service_key=body.service_key,
            period_start=body.period_start,
            period_end=body.period_end,
            currency=body.currency,
            actual_cost_minor=body.actual_cost_minor,
            estimated_cost_minor=body.estimated_cost_minor,
            manually_entered_cost_minor=body.manually_entered_cost_minor,
            notes=body.notes,
            invoice_reference=body.invoice_reference,
        )
        return result
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.patch("/entries/{entry_id}")
async def update_cost_entry(
    entry_id: int,
    body: CostEntryPatch,
    admin: User = Depends(require_permission(Permission.MANAGE_COSTS)),
    db: AsyncSession = Depends(get_db),
):
    try:
        return await costs.update_cost_entry(
            db,
            admin_id=admin.id,
            entry_id=entry_id,
            actual_cost_minor=body.actual_cost_minor,
            estimated_cost_minor=body.estimated_cost_minor,
            manually_entered_cost_minor=body.manually_entered_cost_minor,
            currency=body.currency,
            notes=body.notes,
            invoice_reference=body.invoice_reference,
            reason=body.reason,
            clear_manual=body.clear_manual,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.post("/pricing", status_code=201)
async def create_service_pricing(
    body: PricingIn,
    admin: User = Depends(require_permission(Permission.MANAGE_COSTS)),
    db: AsyncSession = Depends(get_db),
):
    """Set a per-unit price from a stated effective date.

    The previous open price is closed at the new effective date, so events
    already recorded keep the price that applied to them.
    """
    try:
        return await costs.create_pricing(
            db,
            admin_id=admin.id,
            service_key=body.service_key,
            pricing_unit=body.pricing_unit,
            unit_price_minor=body.unit_price_minor,
            currency=body.currency,
            effective_from=body.effective_from,
            effective_until=body.effective_until,
            pricing_source=body.pricing_source,
            confidence=body.confidence,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)


@router.patch("/pricing/{pricing_id}")
async def update_service_pricing(
    pricing_id: int,
    body: PricingPatch,
    admin: User = Depends(require_permission(Permission.MANAGE_COSTS)),
    db: AsyncSession = Depends(get_db),
):
    """Correct a future price or close a price's validity window.

    A price already in force cannot be rewritten - that would change reports
    that have already been produced. Record a new price instead.
    """
    try:
        return await costs.update_pricing(
            db,
            admin_id=admin.id,
            pricing_id=pricing_id,
            unit_price_minor=body.unit_price_minor,
            effective_until=body.effective_until,
            pricing_source=body.pricing_source,
            confidence=body.confidence,
            reason=body.reason,
        )
    except Exception as exc:  # noqa: BLE001
        _fail(exc)
