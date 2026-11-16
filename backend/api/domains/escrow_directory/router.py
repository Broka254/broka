"""HTTP contracts for the escrow provider directory.

PUBLIC (no sign-in; a buyer reads this before deciding to deal), mounted at
/escrow-providers:

  GET /escrow-providers              the listed providers, how current each is,
                                     the notices about providers BROKA does not
                                     list, and the disclosures
  GET /escrow-providers/compare      the same, filtered, with a fee estimate per
                                     provider for an amount and whether BROKA
                                     is willing to rank them
  GET /escrow-providers/{id}         one provider, in full (or its notice, when
                                     it is not listed and has one)

ADMIN (MANAGE_ESCROW_PROVIDERS), mounted at /admin/escrow-providers:

  GET   /                      every provider, whatever its status, with what
                               blocks approval and what is out of date
  GET   /{id}                  one, with its record and its change history
  POST  /                      add a provider (always as a draft)
  PATCH /{id}                  edit details; a fee change needs its source
  POST  /{id}/review           record that an area was checked, and when
  POST  /{id}/status           approve, suspend, reinstate or reject

NOTHING HERE MOVES MONEY. There is no payment, payout, release or refund
route in this module and none may be added: BROKA does not hold, receive or
release anyone's money, and an endpoint that looked as if it did would be a
promise it cannot keep. Every response that shows a provider carries the
disclosure text (disclosures.py).
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip, client_ip_or_none
from api.core.config import settings
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import escrow_directory_limiter
from api.database import User, get_db

from . import catalogue, fees, projection, repository, schema

logger = logging.getLogger(__name__)
public_router = APIRouter()
admin_router = APIRouter()

_CACHE = "public, max-age=60"


def _today():
    """Today's date, UTC (the repo stores naive UTC). A function so a test
    can fix the day."""
    return datetime.utcnow().date()


def _ages() -> dict:
    return {"pricing_max_age_days": settings.escrow_pricing_max_age_days,
            "record_max_age_days": settings.escrow_record_max_age_days}


async def _records(db: AsyncSession) -> list[dict]:
    """The records, refreshed into this process's snapshot as well, so what
    this request shows and what Zeno says in the next second agree."""
    return await catalogue.refresh(lambda: repository.load_stored(db))


# ── Public ───────────────────────────────────────────────────────────────

@public_router.get("")
async def list_providers(request: Request, response: Response, db: AsyncSession = Depends(get_db)):
    await escrow_directory_limiter.check_and_record(f"ip:{client_ip(request)}")
    response.headers["Cache-Control"] = _CACHE
    return catalogue.public_catalogue(await _records(db), _today(), **_ages())


@public_router.get("/compare")
async def compare_providers(
    request: Request,
    response: Response,
    amount: Optional[int] = Query(None, ge=1, le=fees.MAX_AMOUNT_KES,
                                  description="Whole KSh the seller should receive"),
    payout: Optional[Literal["phone", "till", "paybill", "bank"]] = Query(
        None, description="Where the seller will be paid, for providers whose payout charge depends on it"),
    sort: Literal["name", "lowest_fee", "highest_limit"] = Query("name"),
    no_account: bool = Query(False, description="Only providers documented as needing no account"),
    kyc: Optional[Literal["required", "not_required"]] = Query(None),
    payment_method: Optional[Literal["mpesa", "mpesa_stk_push", "mpesa_paybill", "mpesa_till",
                                     "bank_transfer", "card"]] = Query(None),
    category: Optional[Literal["goods", "services", "vehicles", "property", "digital", "freelance"]] = Query(None),
    documented_disputes: bool = Query(False, description="Only providers with a documented dispute process"),
    documented_refunds: bool = Query(False, description="Only providers with documented refund conditions"),
    db: AsyncSession = Depends(get_db),
):
    await escrow_directory_limiter.check_and_record(f"ip:{client_ip(request)}")
    response.headers["Cache-Control"] = _CACHE
    criteria = catalogue.build_criteria(
        no_account=no_account, kyc=kyc, payment_method=payment_method, category=category,
        documented_disputes=documented_disputes, documented_refunds=documented_refunds)
    return catalogue.compare_providers(await _records(db), _today(), amount=amount, payout=payout,
                                       sort=sort, criteria=criteria, **_ages())


@public_router.get("/{provider_id}")
async def get_provider(provider_id: str, request: Request, response: Response,
                       db: AsyncSession = Depends(get_db)):
    await escrow_directory_limiter.check_and_record(f"ip:{client_ip(request)}")
    response.headers["Cache-Control"] = _CACHE
    record = next((r for r in await _records(db) if r["id"] == provider_id), None)
    if record is None:
        raise HTTPException(status_code=404, detail="No such provider")
    if record["status"] in schema.LISTED_STATUSES:
        return {"provider": projection.public_view(record, _today(), **_ages()),
                "disclosures": projection.disclosures_view()}
    # Not listed: say only what BROKA chose to say publicly, if anything. A
    # draft or rejected provider with no notice does not exist as far as the
    # public is concerned.
    if record.get("public_notice"):
        return {"notice": projection.notice_view(record), "disclosures": projection.disclosures_view()}
    raise HTTPException(status_code=404, detail="No such provider")


# ── Admin ────────────────────────────────────────────────────────────────

class CreateIn(BaseModel):
    record: dict
    reason: str = Field(min_length=5, max_length=500)


class EditIn(BaseModel):
    patch: dict
    reason: str = Field(min_length=5, max_length=500)
    expected_version: Optional[int] = Field(None, ge=0)
    # A fee change needs these: the provider's own page, and what it showed.
    source_url: Optional[str] = Field(None, max_length=300)
    source_note: Optional[str] = Field(None, max_length=1000)


class ReviewIn(BaseModel):
    area: Literal["identity", "terms", "pricing", "operational"]
    outcome: Literal["verified", "passed", "failed", "pending"]
    reason: str = Field(min_length=5, max_length=500)
    verified_on: Optional[str] = Field(None, max_length=10)
    next_review: Optional[str] = Field(None, max_length=10)
    source_url: Optional[str] = Field(None, max_length=300)
    source_note: Optional[str] = Field(None, max_length=1000)
    expected_version: Optional[int] = Field(None, ge=0)


class StatusIn(BaseModel):
    status: Literal["under_review", "approved", "suspended", "rejected"]
    reason: str = Field(min_length=5, max_length=500)
    # What the public is told about a provider that is not listed. Optional;
    # neutral by convention - it states what BROKA lists, not an accusation.
    public_notice: Optional[str] = Field(None, max_length=400)
    expected_version: Optional[int] = Field(None, ge=0)


def problem_detail(problems: list[str], code: str) -> dict:
    """An error body the app can show. The app (ApiClient) reads `message`
    and `code` from a structured detail; a bare list of strings comes out as
    "Request failed", which tells a person nothing about what to fix. The
    individual problems stay in `problems` for a screen that wants them."""
    return {"code": code, "message": " ".join(p.rstrip(".") + "." for p in problems), "problems": problems}


def _fail(error: repository.DirectoryError):
    raise HTTPException(status_code=error.status_code,
                        detail=problem_detail(error.problems, "ESCROW_PROVIDER_REFUSED"))


def _admin(record: dict, version: int) -> dict:
    return {**projection.admin_view(record, _today(), **_ages()), "version": version}


@admin_router.get("")
async def admin_list(
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    records = await repository.all_records(db)
    items = []
    for record in records:
        view = projection.admin_view(record, _today(), **_ages())
        version = await repository.stored_version(db, record["id"])
        items.append({"id": record["id"], "name": record["display_name"], "status": record["status"],
                      "freshness": view["freshness"]["state"], "needs_review": view["freshness"]["needs_review"],
                      "can_be_approved": view["can_be_approved"],
                      "version": version, "stored": version > 0})
    return {"items": items, "allowed_domains": list(repository.allowlist())}


@admin_router.get("/{provider_id}")
async def admin_get(
    provider_id: str,
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    record = await repository.get_record(db, provider_id)
    if record is None:
        raise HTTPException(status_code=404, detail="No such provider")
    return {**_admin(record, await repository.stored_version(db, provider_id)),
            "revisions": await repository.revisions(db, provider_id)}


@admin_router.post("", status_code=201)
async def admin_create(
    body: CreateIn, request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await repository.create_provider(db, body.record, actor_id=admin.id, reason=body.reason)
    except repository.DirectoryError as error:
        _fail(error)
    await record_audit(db, admin.id, "escrow_provider_created", "escrow_provider", result["record"]["id"],
                       detail=body.reason, ip_address=client_ip_or_none(request))
    await db.commit()
    return _admin(result["record"], result["version"])


@admin_router.patch("/{provider_id}")
async def admin_edit(
    provider_id: str, body: EditIn, request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await repository.edit_provider(
            db, provider_id, body.patch, actor_id=admin.id, reason=body.reason,
            source_url=body.source_url, source_note=body.source_note,
            expected_version=body.expected_version)
    except repository.DirectoryError as error:
        _fail(error)
    await record_audit(
        db, admin.id, "escrow_provider_edited", "escrow_provider", provider_id,
        detail=("cleared: " + ", ".join(result["cleared"]) + " | " if result["cleared"] else "") + body.reason,
        ip_address=client_ip_or_none(request))
    await db.commit()
    return {**_admin(result["record"], result["version"]), "cleared": result["cleared"]}


@admin_router.post("/{provider_id}/review")
async def admin_review(
    provider_id: str, body: ReviewIn, request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await repository.record_review(
            db, provider_id, actor_id=admin.id, reason=body.reason, area=body.area,
            outcome=body.outcome, verified_on=body.verified_on, next_review=body.next_review,
            source_url=body.source_url, source_note=body.source_note,
            expected_version=body.expected_version)
    except repository.DirectoryError as error:
        _fail(error)
    await record_audit(db, admin.id, "escrow_provider_reviewed", "escrow_provider", provider_id,
                       detail=f"{body.area}={body.outcome} | {body.reason}", ip_address=client_ip_or_none(request))
    await db.commit()
    return _admin(result["record"], result["version"])


@admin_router.post("/{provider_id}/status")
async def admin_status(
    provider_id: str, body: StatusIn, request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_ESCROW_PROVIDERS)),
    db: AsyncSession = Depends(get_db),
):
    try:
        result = await repository.change_status(
            db, provider_id, body.status, actor_id=admin.id, reason=body.reason,
            public_notice=body.public_notice, expected_version=body.expected_version)
    except repository.DirectoryError as error:
        _fail(error)
    await record_audit(db, admin.id, f"escrow_provider_{body.status}", "escrow_provider", provider_id,
                       detail=body.reason, ip_address=client_ip_or_none(request))
    await db.commit()
    return _admin(result["record"], result["version"])
