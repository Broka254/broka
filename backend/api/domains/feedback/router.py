"""HTTP contracts for user feedback and complaints.

Customer routes are strictly own-rows-only: a user can file, list and read
their own submissions, never another user's. Admin routes triage the
queue (status + reply) under the feedback permissions. Bodies are user
text and are never written to logs or audit detail.
"""
from __future__ import annotations

import json
import logging
from datetime import datetime
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import feedback_submit_limiter
from api.database import get_db, User
from api.models.feedback import (
    FEEDBACK_CATEGORIES, FEEDBACK_KINDS, FEEDBACK_SEVERITIES,
    FEEDBACK_STATUSES, UserFeedback,
)
from api.security import get_current_user

customer_router = APIRouter()
admin_router = APIRouter()
logger = logging.getLogger(__name__)

_MAX_PAGE = 100
_SUBJECT_MAX = 160
_BODY_MAX = 5_000
_RESPONSE_MAX = 5_000


def _iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return value.isoformat() + "Z"


def _clean(value: str, *, allow_newlines: bool = False) -> str:
    value = (value or "").strip().replace("\x00", "")
    allowed = "\n\t" if allow_newlines else ""
    return "".join(ch for ch in value if ch >= " " or ch in allowed).strip()


class FeedbackCreateIn(BaseModel):
    kind: Literal["feedback", "complaint"] = "feedback"
    category: str = "general"
    severity: Literal["low", "normal", "high", "urgent"] = "normal"
    subject: str = Field(min_length=1, max_length=_SUBJECT_MAX)
    body: str = Field(min_length=1, max_length=_BODY_MAX)
    related_listing_id: Optional[str] = Field(default=None, max_length=36)
    related_deal_id: Optional[str] = Field(default=None, max_length=36)
    related_user_id: Optional[str] = Field(default=None, max_length=36)

    @field_validator("category")
    @classmethod
    def _category(cls, value: str) -> str:
        value = (value or "").strip().lower()
        if value not in FEEDBACK_CATEGORIES:
            raise ValueError(
                f"category must be one of {', '.join(FEEDBACK_CATEGORIES)}")
        return value

    @field_validator("subject")
    @classmethod
    def _subject(cls, value: str) -> str:
        value = _clean(value)
        if not value:
            raise ValueError("subject may not be blank")
        return value

    @field_validator("body")
    @classmethod
    def _body(cls, value: str) -> str:
        value = _clean(value, allow_newlines=True)
        if not value:
            raise ValueError("body may not be blank")
        return value


class FeedbackUpdateIn(BaseModel):
    status: Optional[Literal["open", "acknowledged", "in_progress", "resolved", "closed"]] = None
    admin_response: Optional[str] = Field(default=None, max_length=_RESPONSE_MAX)

    @field_validator("admin_response")
    @classmethod
    def _response(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        value = _clean(value, allow_newlines=True)
        if not value:
            raise ValueError("admin_response may not be blank")
        return value


class FeedbackOut(BaseModel):
    id: str
    kind: str
    category: str
    severity: str
    subject: str
    body: str
    related_listing_id: Optional[str]
    related_deal_id: Optional[str]
    related_user_id: Optional[str]
    status: str
    admin_response: Optional[str]
    responded_at: Optional[str]
    resolved_at: Optional[str]
    created_at: str
    updated_at: str


class FeedbackPageOut(BaseModel):
    items: list[FeedbackOut]
    total: int
    limit: int
    offset: int


class FeedbackStatsOut(BaseModel):
    total: int
    by_status: dict[str, int]
    by_kind: dict[str, int]
    open_complaints: int
    generated_at: str


def _out(row: UserFeedback) -> dict:
    return {
        "id": row.id, "kind": row.kind, "category": row.category,
        "severity": row.severity, "subject": row.subject, "body": row.body,
        "related_listing_id": row.related_listing_id,
        "related_deal_id": row.related_deal_id,
        "related_user_id": row.related_user_id,
        "status": row.status, "admin_response": row.admin_response,
        "responded_at": _iso(row.responded_at),
        "resolved_at": _iso(row.resolved_at),
        "created_at": _iso(row.created_at), "updated_at": _iso(row.updated_at),
    }


# ── Customer ────────────────────────────────────────────────────────────────

@customer_router.post("", response_model=FeedbackOut, status_code=201)
async def submit_feedback(
    body: FeedbackCreateIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await feedback_submit_limiter.check_and_record(current_user["id"])
    # A complaint about yourself is a data-entry slip, not a case.
    if body.related_user_id and body.related_user_id == current_user["id"]:
        raise HTTPException(
            status_code=422, detail="related_user_id may not be yourself")
    now = datetime.utcnow()
    row = UserFeedback(
        user_id=current_user["id"], kind=body.kind, category=body.category,
        severity=body.severity, subject=body.subject, body=body.body,
        related_listing_id=body.related_listing_id or None,
        related_deal_id=body.related_deal_id or None,
        related_user_id=body.related_user_id or None,
        status="open", created_at=now, updated_at=now,
    )
    db.add(row)
    await db.commit()
    await db.refresh(row)
    logger.info(
        "[feedback] event=submitted id=%s kind=%s category=%s severity=%s",
        row.id, row.kind, row.category, row.severity)
    return _out(row)


@customer_router.get("", response_model=FeedbackPageOut)
async def list_my_feedback(
    kind: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    conditions = [UserFeedback.user_id == current_user["id"]]
    if kind is not None:
        if kind not in FEEDBACK_KINDS:
            raise HTTPException(status_code=422, detail="invalid kind")
        conditions.append(UserFeedback.kind == kind)
    if status is not None:
        if status not in FEEDBACK_STATUSES:
            raise HTTPException(status_code=422, detail="invalid status")
        conditions.append(UserFeedback.status == status)
    total = int((await db.execute(
        select(func.count(UserFeedback.id)).where(*conditions))).scalar() or 0)
    rows = (await db.execute(
        select(UserFeedback).where(*conditions)
        .order_by(desc(UserFeedback.created_at), desc(UserFeedback.id))
        .limit(limit).offset(offset))).scalars().all()
    return {"items": [_out(r) for r in rows],
            "total": total, "limit": limit, "offset": offset}


@customer_router.get("/{feedback_id}", response_model=FeedbackOut)
async def get_my_feedback(
    feedback_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    row = (await db.execute(select(UserFeedback).where(
        UserFeedback.id == feedback_id,
        UserFeedback.user_id == current_user["id"],
    ))).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Submission not found")
    return _out(row)


# ── Admin triage ────────────────────────────────────────────────────────────

@admin_router.get("", response_model=FeedbackPageOut)
async def list_feedback(
    kind: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    category: Optional[str] = Query(None),
    severity: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.VIEW_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    conditions = []
    if kind is not None:
        if kind not in FEEDBACK_KINDS:
            raise HTTPException(status_code=422, detail="invalid kind")
        conditions.append(UserFeedback.kind == kind)
    if status is not None:
        if status not in FEEDBACK_STATUSES:
            raise HTTPException(status_code=422, detail="invalid status")
        conditions.append(UserFeedback.status == status)
    if category is not None:
        if category not in FEEDBACK_CATEGORIES:
            raise HTTPException(status_code=422, detail="invalid category")
        conditions.append(UserFeedback.category == category)
    if severity is not None:
        if severity not in FEEDBACK_SEVERITIES:
            raise HTTPException(status_code=422, detail="invalid severity")
        conditions.append(UserFeedback.severity == severity)
    total = int((await db.execute(
        select(func.count(UserFeedback.id)).where(*conditions))).scalar() or 0)
    rows = (await db.execute(
        select(UserFeedback).where(*conditions)
        .order_by(desc(UserFeedback.created_at), desc(UserFeedback.id))
        .limit(limit).offset(offset))).scalars().all()
    return {"items": [_out(r) for r in rows],
            "total": total, "limit": limit, "offset": offset}


@admin_router.get("/stats", response_model=FeedbackStatsOut)
async def feedback_stats(
    admin: User = Depends(require_permission(Permission.VIEW_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    by_status = {str(s): int(c) for s, c in (await db.execute(
        select(UserFeedback.status, func.count()).group_by(UserFeedback.status)
    )).all()}
    by_kind = {str(k): int(c) for k, c in (await db.execute(
        select(UserFeedback.kind, func.count()).group_by(UserFeedback.kind)
    )).all()}
    open_complaints = int((await db.execute(
        select(func.count(UserFeedback.id)).where(
            UserFeedback.kind == "complaint",
            UserFeedback.status.in_(("open", "acknowledged", "in_progress")),
        ))).scalar() or 0)
    return {
        "total": sum(by_status.values()), "by_status": by_status,
        "by_kind": by_kind, "open_complaints": open_complaints,
        "generated_at": datetime.utcnow().isoformat() + "Z",
    }


@admin_router.patch("/{feedback_id}", response_model=FeedbackOut)
async def triage_feedback(
    feedback_id: str,
    body: FeedbackUpdateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    if body.status is None and body.admin_response is None:
        raise HTTPException(
            status_code=422, detail="status or admin_response is required")
    row = (await db.execute(select(UserFeedback).where(
        UserFeedback.id == feedback_id).with_for_update())).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Submission not found")
    now = datetime.utcnow()
    if body.status is not None:
        row.status = body.status
        if body.status in ("resolved", "closed"):
            row.resolved_at = row.resolved_at or now
        else:
            row.resolved_at = None
    if body.admin_response is not None:
        row.admin_response = body.admin_response
        row.responded_by_id = admin.id
        row.responded_at = now
        # A reply the user has not seen yet implies a human looked: an
        # untouched `open` case moves to acknowledged on its own.
        if row.status == "open":
            row.status = "acknowledged"
    row.updated_at = now
    await record_audit(
        db, admin.id, "user_feedback_triaged", "user_feedback", row.id,
        detail=json.dumps({"status": row.status}, separators=(",", ":")),
        ip_address=client_ip_or_none(request))
    await db.commit()
    await db.refresh(row)
    return _out(row)


__all__ = ["customer_router", "admin_router"]
