"""HTTP contracts for user feedback and complaints.

Customer routes are strictly own-rows-only: a user can file, list and read
their own submissions, never another user's. Admin routes triage the
queue (status + reply) under the feedback permissions. Bodies are user
text and are never written to logs, audit detail or admin alerts.

A complaint is never a message into the void:
  * an urgent, high or safety complaint raises an Alert Centre alert the
    moment it is filed, and that alert resolves itself with the complaint;
  * the person who filed it gets a push when the team replies, starts on
    it, resolves or closes it - and sees the reply in their history;
  * the admin queue shows who filed it, what it is about, how long it has
    waited against its first-reply deadline (intelligence.COMPLAINT_SLA_HOURS)
    and what the team did, from the audit trail.
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
from datetime import datetime, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import and_, asc, case, desc, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.intelligence import COMPLAINT_SLA_HOURS, OPEN_FEEDBACK_STATUSES, complaints_overview
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import feedback_submit_limiter
from api.database import AuditLog, Deal, Listing, get_db, User
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
# How long a triage waits on the push to the person who filed it. The
# reply is already saved; a slow push provider must not hold the admin up.
_NOTIFY_TIMEOUT_SECONDS = 5.0
_ALERT_KIND = "complaint_filed"
_SEVERITY_RANK = {"urgent": 0, "high": 1, "normal": 2, "low": 3}
_CATEGORY_LABELS = {
    "general": "General", "bug": "Something is broken", "suggestion": "Suggestion",
    "compliment": "Compliment", "account": "Account", "payments": "Payments",
    "listing": "A listing", "seller_conduct": "Seller conduct",
    "buyer_conduct": "Buyer conduct", "delivery": "Delivery", "safety": "Safety",
    "other": "Other",
}


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


class ReporterOut(BaseModel):
    id: str
    name: Optional[str]
    phone: Optional[str]
    account_type: Optional[str]
    trust_score: int
    is_flagged: bool
    created_at: Optional[str]


class FeedbackAdminItemOut(FeedbackOut):
    user_id: str
    responded_by_id: Optional[str]
    reporter: Optional[ReporterOut]
    age_hours: float
    sla_hours: int
    sla_breached: bool
    # Set by a triage that tried to tell the person who filed it: how many
    # of their phones the push provider accepted. None: no push was due.
    notified_devices: Optional[int] = None


class FeedbackAdminPageOut(BaseModel):
    items: list[FeedbackAdminItemOut]
    total: int
    limit: int
    offset: int


class RelatedListingOut(BaseModel):
    id: str
    name: Optional[str]
    status: Optional[str]
    category: Optional[str]
    price: Optional[float]
    seller_id: Optional[str]


class RelatedUserOut(BaseModel):
    id: str
    name: Optional[str]
    phone: Optional[str]
    trust_score: int
    is_flagged: bool
    complaints_against_total: int
    complaints_against_open: int


class RelatedDealOut(BaseModel):
    id: str
    status: Optional[str]
    agreed_price: Optional[float]
    seller_id: Optional[str]
    buyer_id: Optional[str]
    created_at: Optional[str]


class TimelineEntryOut(BaseModel):
    at: Optional[str]
    actor_id: str
    action: str
    status: Optional[str]


class ReporterHistoryOut(BaseModel):
    submissions: int
    complaints: int


class FeedbackAdminDetailOut(FeedbackAdminItemOut):
    related_listing: Optional[RelatedListingOut]
    related_user: Optional[RelatedUserOut]
    related_deal: Optional[RelatedDealOut]
    reporter_history: ReporterHistoryOut
    timeline: list[TimelineEntryOut]


class FeedbackStatsOut(BaseModel):
    total: int
    by_status: dict[str, int]
    by_kind: dict[str, int]
    open_complaints: int
    generated_at: str
    # The queue as a founder reads it (intelligence.complaints_overview).
    by_category: dict[str, int] = {}
    by_severity: dict[str, int] = {}
    open_by_severity: dict[str, int] = {}
    unanswered: int = 0
    sla_breached: int = 0
    sla_breached_urgent: int = 0
    oldest_unanswered_hours: Optional[float] = None
    filed_last_7d: int = 0
    filed_previous_7d: int = 0
    median_response_hours_90d: Optional[float] = None
    repeat_reported_users: list[dict] = []
    sla_hours: dict[str, int] = {}


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


def _trust(score: Optional[int]) -> int:
    return int(score) if score is not None else 100


def _reporter(user: Optional[User]) -> Optional[dict]:
    if user is None:
        return None
    return {
        "id": user.id, "name": user.name, "phone": user.phone,
        "account_type": getattr(user.account_type, "value", user.account_type),
        "trust_score": _trust(user.trust_score), "is_flagged": bool(user.is_flagged),
        "created_at": _iso(user.created_at),
    }


def _admin_item(row: UserFeedback, reporter: Optional[User], now: datetime) -> dict:
    created = row.created_at or now
    age = max(0.0, (now - created).total_seconds() / 3600)
    sla = COMPLAINT_SLA_HOURS.get(row.severity, 72)
    breached = (
        row.kind == "complaint" and row.status in OPEN_FEEDBACK_STATUSES
        and row.responded_at is None and age > sla
    )
    return {
        **_out(row), "user_id": row.user_id, "responded_by_id": row.responded_by_id,
        "reporter": _reporter(reporter), "age_hours": round(age, 1),
        "sla_hours": sla, "sla_breached": breached,
    }


async def _users_by_id(db: AsyncSession, ids: set[str]) -> dict[str, User]:
    ids = {i for i in ids if i}
    if not ids:
        return {}
    rows = (await db.execute(select(User).where(User.id.in_(ids)))).scalars().all()
    return {user.id: user for user in rows}


async def _raise_complaint_alert(row_id: str, severity: str, category: str) -> None:
    """Page the Alert Centre for a complaint that cannot wait for the queue.
    Its own session, after the complaint is committed: a failed alert must
    never lose the complaint. No user text goes into the alert."""
    from api.core.admin_alert_subscribers import _create

    label = _CATEGORY_LABELS.get(category, category.replace("_", " "))
    urgent = severity == "urgent" or category == "safety"
    if severity == "urgent":
        title = f"Urgent complaint: {label}"
    elif severity == "high":
        title = f"High-priority complaint: {label}"
    else:
        title = f"{label} complaint filed"
    await _create(
        _ALERT_KIND, "critical" if urgent else "high", title,
        body=(f"A {severity} {label.lower()} complaint was filed. First reply due within "
              f"{COMPLAINT_SLA_HOURS.get(severity, 72)} hours."),
        href=f"/complaints?id={row_id}",
        meta={"feedback_id": row_id},
    )


async def _resolve_complaint_alert(row_id: str) -> None:
    from api.core.admin_alerts import resolve_by_ref
    from api.database import AsyncSessionLocal

    try:
        async with AsyncSessionLocal() as db:
            await resolve_by_ref(db, kind=_ALERT_KIND, ref={"feedback_id": row_id})
            await db.commit()
    except Exception as exc:
        logger.warning("[feedback] alert auto-resolve failed (non-fatal): %s", type(exc).__name__)


def _notification_for(kind: str, previous_status: str, status: str,
                      reply: Optional[str]) -> Optional[tuple[str, str]]:
    """(title, body) of the push owed to the person who filed it, if any."""
    noun = "complaint" if kind == "complaint" else "feedback"
    if reply:
        text = " ".join(reply.split())
        return (f"BROKA replied to your {noun}", text[:137] + "..." if len(text) > 140 else text)
    if status == previous_status:
        return None
    if status == "resolved":
        return (f"Your {noun} has been resolved",
                "Open Feedback & complaints to see what the team did.")
    if status == "closed":
        return (f"Your {noun} was closed", "Open Feedback & complaints for the details.")
    if status == "in_progress":
        return (f"We're working on your {noun}", "A member of the BROKA team has picked it up.")
    return None


async def _notify_reporter(user_id: str, feedback_id: str, status: str, title: str, body: str) -> int:
    from api.core.push_devices import push_user

    try:
        return await asyncio.wait_for(
            push_user(user_id, title=title, body=body,
                      data={"type": "feedback_update", "feedbackId": feedback_id, "status": status}),
            timeout=_NOTIFY_TIMEOUT_SECONDS,
        )
    except Exception as exc:
        logger.warning("[feedback] reply push failed (non-fatal): %s", type(exc).__name__)
        return 0


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
    if row.kind == "complaint" and (row.severity in ("urgent", "high") or row.category == "safety"):
        await _raise_complaint_alert(row.id, row.severity, row.category)
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

def _overdue_condition(now: datetime):
    """Open complaints with no reply past their severity's deadline."""
    return and_(
        UserFeedback.kind == "complaint",
        UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES),
        UserFeedback.responded_at.is_(None),
        or_(*(
            and_(UserFeedback.severity == severity,
                 UserFeedback.created_at < now - timedelta(hours=hours))
            for severity, hours in COMPLAINT_SLA_HOURS.items()
        )),
    )


def _like_escape(text: str) -> str:
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _search_condition(term: str):
    """Subject text, or the reference the app shows the reporter.

    The app labels each submission "#3F2A9C" - the first six hex digits of
    its id - so a user can quote it to support; pasting that reference (with
    or without the #) finds the submission. % and _ are literal, not
    wildcards.
    """
    condition = UserFeedback.subject.ilike(f"%{_like_escape(term)}%", escape="\\")
    reference = term.lstrip("#").strip().lower()
    if re.fullmatch(r"[0-9a-f]{6,8}", reference):
        condition = or_(condition, UserFeedback.id.like(f"{reference}%"))
    return condition


@admin_router.get("", response_model=FeedbackAdminPageOut)
async def list_feedback(
    kind: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    category: Optional[str] = Query(None),
    severity: Optional[str] = Query(None),
    search: Optional[str] = Query(None, max_length=100),
    user_id: Optional[str] = Query(None, max_length=64),
    related_user_id: Optional[str] = Query(None, max_length=64),
    queue: Optional[Literal["open", "unanswered", "overdue", "closed"]] = Query(None),
    sort: Literal["newest", "oldest", "priority"] = Query("newest"),
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.VIEW_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    """The triage queue. `queue` narrows to what needs a human: open
    (open, acknowledged or in progress), unanswered (open with no reply),
    overdue (unanswered complaints past their deadline) or closed."""
    now = datetime.utcnow()
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
    if search and search.strip():
        conditions.append(_search_condition(search.strip()))
    if user_id:
        conditions.append(UserFeedback.user_id == user_id)
    if related_user_id:
        conditions.append(UserFeedback.related_user_id == related_user_id)
    if queue == "open":
        conditions.append(UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES))
    elif queue == "unanswered":
        conditions.append(UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES))
        conditions.append(UserFeedback.responded_at.is_(None))
    elif queue == "overdue":
        conditions.append(_overdue_condition(now))
    elif queue == "closed":
        conditions.append(UserFeedback.status.in_(("resolved", "closed")))

    if sort == "oldest":
        order = (asc(UserFeedback.created_at), asc(UserFeedback.id))
    elif sort == "priority":
        # Unanswered urgent work first, then by how long it has waited.
        order = (
            case((UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES), 0), else_=1),
            case(_SEVERITY_RANK, value=UserFeedback.severity, else_=len(_SEVERITY_RANK)),
            asc(UserFeedback.created_at), asc(UserFeedback.id),
        )
    else:
        order = (desc(UserFeedback.created_at), desc(UserFeedback.id))

    total = int((await db.execute(
        select(func.count(UserFeedback.id)).where(*conditions))).scalar() or 0)
    rows = (await db.execute(
        select(UserFeedback).where(*conditions)
        .order_by(*order).limit(limit).offset(offset))).scalars().all()
    reporters = await _users_by_id(db, {r.user_id for r in rows})
    return {"items": [_admin_item(r, reporters.get(r.user_id), now) for r in rows],
            "total": total, "limit": limit, "offset": offset}


@admin_router.get("/stats", response_model=FeedbackStatsOut)
async def feedback_stats(
    admin: User = Depends(require_permission(Permission.VIEW_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    by_status = {str(s): int(c) for s, c in (await db.execute(
        select(UserFeedback.status, func.count()).group_by(UserFeedback.status)
    )).all()}
    by_kind = {str(k): int(c) for k, c in (await db.execute(
        select(UserFeedback.kind, func.count()).group_by(UserFeedback.kind)
    )).all()}
    by_category = {str(k): int(c) for k, c in (await db.execute(
        select(UserFeedback.category, func.count()).group_by(UserFeedback.category)
    )).all()}
    by_severity = {str(k): int(c) for k, c in (await db.execute(
        select(UserFeedback.severity, func.count()).group_by(UserFeedback.severity)
    )).all()}
    open_complaints = int((await db.execute(
        select(func.count(UserFeedback.id)).where(
            UserFeedback.kind == "complaint",
            UserFeedback.status.in_(OPEN_FEEDBACK_STATUSES),
        ))).scalar() or 0)
    overview = await complaints_overview(db, now - timedelta(days=7), now, now=now)
    return {
        "total": sum(by_status.values()), "by_status": by_status,
        "by_kind": by_kind, "open_complaints": open_complaints,
        "generated_at": _iso(now),
        "by_category": by_category,
        "by_severity": by_severity,
        "open_by_severity": overview["open_by_severity"],
        "unanswered": overview["unanswered"],
        "sla_breached": overview["sla_breached"],
        "sla_breached_urgent": overview["sla_breached_urgent"],
        "oldest_unanswered_hours": overview["oldest_unanswered_hours"],
        "filed_last_7d": overview["filed"]["current"],
        "filed_previous_7d": overview["filed"]["previous"],
        "median_response_hours_90d": overview["median_response_hours_90d"],
        "repeat_reported_users": overview["repeat_reported_users"],
        "sla_hours": overview["sla_hours"],
    }


async def _detail(db: AsyncSession, row: UserFeedback, now: datetime) -> dict:
    users = await _users_by_id(db, {row.user_id, row.related_user_id or ""})
    item = _admin_item(row, users.get(row.user_id), now)

    related_listing = None
    if row.related_listing_id:
        listing = (await db.execute(
            select(Listing).where(Listing.id == row.related_listing_id))).scalar_one_or_none()
        if listing is not None:
            related_listing = {
                "id": listing.id, "name": listing.name,
                "status": getattr(listing.status, "value", listing.status),
                "category": listing.category,
                "price": float(listing.price) if listing.price is not None else None,
                "seller_id": listing.seller_id,
            }
    related_user = None
    target = users.get(row.related_user_id) if row.related_user_id else None
    if target is not None:
        against = (await db.execute(
            select(UserFeedback.status, func.count(UserFeedback.id))
            .where(UserFeedback.related_user_id == target.id, UserFeedback.kind == "complaint")
            .group_by(UserFeedback.status)
        )).all()
        related_user = {
            "id": target.id, "name": target.name, "phone": target.phone,
            "trust_score": _trust(target.trust_score), "is_flagged": bool(target.is_flagged),
            "complaints_against_total": sum(int(c) for _, c in against),
            "complaints_against_open": sum(int(c) for s, c in against if s in OPEN_FEEDBACK_STATUSES),
        }
    related_deal = None
    if row.related_deal_id:
        deal = (await db.execute(select(Deal).where(Deal.id == row.related_deal_id))).scalar_one_or_none()
        if deal is not None:
            related_deal = {
                "id": deal.id, "status": getattr(deal.status, "value", deal.status),
                "agreed_price": float(deal.agreed_price) if deal.agreed_price is not None else None,
                "seller_id": deal.seller_id, "buyer_id": deal.buyer_id,
                "created_at": _iso(deal.created_at),
            }
    history = (await db.execute(
        select(UserFeedback.kind, func.count(UserFeedback.id))
        .where(UserFeedback.user_id == row.user_id).group_by(UserFeedback.kind)
    )).all()
    audits = (await db.execute(
        select(AuditLog.created_at, AuditLog.actor_id, AuditLog.action, AuditLog.detail)
        .where(AuditLog.resource_type == "user_feedback", AuditLog.resource_id == row.id)
        .order_by(asc(AuditLog.created_at)).limit(50)
    )).all()
    timeline = []
    for at, actor_id, action, detail in audits:
        status = None
        try:
            status = (json.loads(detail) if detail else {}).get("status")
        except (ValueError, AttributeError):
            status = None
        timeline.append({"at": _iso(at), "actor_id": str(actor_id), "action": action,
                         "status": status if isinstance(status, str) else None})
    return {
        **item,
        "related_listing": related_listing,
        "related_user": related_user,
        "related_deal": related_deal,
        "reporter_history": {
            "submissions": sum(int(c) for _, c in history),
            "complaints": sum(int(c) for k, c in history if k == "complaint"),
        },
        "timeline": timeline,
    }


@admin_router.get("/{feedback_id}", response_model=FeedbackAdminDetailOut)
async def get_feedback(
    feedback_id: str,
    admin: User = Depends(require_permission(Permission.VIEW_FEEDBACK)),
    db: AsyncSession = Depends(get_db),
):
    """One submission with who filed it, what it is about (listing, user,
    deal), how often that user has been complained about, and every triage
    step from the audit trail."""
    row = (await db.execute(
        select(UserFeedback).where(UserFeedback.id == feedback_id))).scalar_one_or_none()
    if row is None:
        raise HTTPException(status_code=404, detail="Submission not found")
    return await _detail(db, row, datetime.utcnow())


@admin_router.patch("/{feedback_id}", response_model=FeedbackAdminItemOut)
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
    previous_status = row.status
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
        # untouched `open` case moves to acknowledged on its own - unless
        # the administrator chose its status in the same request, which
        # used to be overridden (sending status=open with a reply came
        # back acknowledged).
        if body.status is None and row.status == "open":
            row.status = "acknowledged"
    row.updated_at = now
    await record_audit(
        db, admin.id, "user_feedback_triaged", "user_feedback", row.id,
        detail=json.dumps({"status": row.status, "replied": body.admin_response is not None},
                          separators=(",", ":")),
        ip_address=client_ip_or_none(request))
    await db.commit()
    await db.refresh(row)

    if row.status in ("resolved", "closed"):
        await _resolve_complaint_alert(row.id)
    notified = None
    message = _notification_for(row.kind, previous_status, row.status, body.admin_response)
    if message is not None:
        notified = await _notify_reporter(row.user_id, row.id, row.status, *message)
    reporter = (await _users_by_id(db, {row.user_id})).get(row.user_id)
    return {**_admin_item(row, reporter, now), "notified_devices": notified}


__all__ = ["customer_router", "admin_router"]
