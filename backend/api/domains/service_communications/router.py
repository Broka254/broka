"""HTTP contracts for service communications.

The admin router manages drafts and delivery; the customer router exposes only
the authenticated user's own published announcement rows. No response contains
an ORM object, provider payload, device token or internal exception text.
"""
from __future__ import annotations

import hashlib
import json
import logging
from datetime import datetime
from typing import Literal, Optional
from urllib.parse import urlparse

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field, field_validator, model_validator
from sqlalchemy import desc, exists, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.config import settings
from api.core.idempotency import IdempotencyResult, idempotency_guard
from api.core.observability import request_id_var
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import service_communication_publish_limiter
from api.core.timeutil import to_naive_utc
from api.database import get_db, User
from api.domains.service_communications import service
from api.domains.service_communications.audience import (
    MAX_EXPLICIT_USER_IDS,
    AudienceValidationError,
    audience_json,
    count_audience,
    normalize_audience,
    parse_audience,
    parse_stored_audience,
    validate_explicit_audience,
)
from api.models.service_communication import (
    COMMUNICATION_SEVERITIES,
    COMMUNICATION_STATUSES,
    COMMUNICATION_TYPES,
    ServiceCommunication,
    ServiceCommunicationDeviceDelivery,
    ServiceCommunicationRecipient,
)
from api.security import get_current_user

admin_router = APIRouter()
customer_router = APIRouter()
logger = logging.getLogger(__name__)

_MAX_PAGE = 200
_TITLE_MAX = 160
_BODY_MAX = 10_000
_DEEP_LINK_MAX = 512
_PUSH_PAYLOAD_MAX_BYTES = 3_600
_HOSTS = {"broka.co.ke", "www.broka.co.ke"}
_APP_SCHEMES = {"broka"}


def _iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    if value.tzinfo is not None:
        value = to_naive_utc(value)
    return value.isoformat() + "Z"


def _clean_text(value: str, *, allow_newlines: bool = False) -> str:
    value = (value or "").strip().replace("\x00", "")
    allowed = "\n\t" if allow_newlines else ""
    return "".join(ch for ch in value if ch >= " " or ch in allowed).strip()


def _validate_deep_link(value: Optional[str]) -> Optional[str]:
    if value is None or value == "":
        return None
    if len(value) > _DEEP_LINK_MAX:
        raise ValueError(f"deep_link may be at most {_DEEP_LINK_MAX} characters")
    parsed = urlparse(value)
    if parsed.username or parsed.password:
        raise ValueError("deep_link may not contain credentials")
    if parsed.scheme == "https":
        if parsed.hostname not in _HOSTS:
            raise ValueError("deep_link https URLs must point to broka.co.ke")
    elif parsed.scheme in _APP_SCHEMES:
        if not parsed.netloc or parsed.netloc.lower() not in {
            "app", "store", "listing", "deal", "communications",
        }:
            raise ValueError("deep_link app host is not recognised")
    else:
        raise ValueError("deep_link must be an https://broka.co.ke or broka:// URL")
    return value


def _validate_push_payload(
    channels: list[str], title: str, body: str, deep_link: Optional[str],
) -> None:
    if "push" not in channels:
        return
    # FCM caps the entire message near 4 KB, including notification text and
    # data keys. Leave room for the fixed metadata and reject at draft time
    # rather than committing a campaign that can only fail at send time.
    size = len(title.encode("utf-8")) + len(body.encode("utf-8"))
    if deep_link:
        size += len(deep_link.encode("utf-8"))
    if size > _PUSH_PAYLOAD_MAX_BYTES:
        raise ValueError(
            "push title, body and deep_link must fit within "
            f"{_PUSH_PAYLOAD_MAX_BYTES} UTF-8 bytes; use in_app only for longer text"
        )


def _normalize_datetime(value: Optional[datetime]) -> Optional[datetime]:
    if value is None:
        return None
    return to_naive_utc(value)


class AudienceIn(BaseModel):
    kind: Literal["all", "buyers", "sellers", "store_owners", "user_ids"] = "all"
    user_ids: list[str] = Field(default_factory=list, max_length=MAX_EXPLICIT_USER_IDS)

    @model_validator(mode="after")
    def _valid(self):
        normalize_audience(self.model_dump())
        return self


class CommunicationCreateIn(BaseModel):
    title: str = Field(min_length=1, max_length=_TITLE_MAX)
    body: str = Field(min_length=1, max_length=_BODY_MAX)
    communication_type: Literal["announcement", "maintenance", "incident", "product_update"]
    severity: Literal["low", "normal", "high", "critical"] = "normal"
    audience: AudienceIn
    channels: list[str] = Field(default_factory=lambda: ["in_app"], max_length=2)
    deep_link: Optional[str] = Field(default=None, max_length=_DEEP_LINK_MAX)
    expires_at: Optional[datetime] = None

    @field_validator("title")
    @classmethod
    def _title(cls, value: str) -> str:
        value = _clean_text(value)
        if not value:
            raise ValueError("title may not be blank")
        return value

    @field_validator("body")
    @classmethod
    def _body(cls, value: str) -> str:
        value = _clean_text(value, allow_newlines=True)
        if not value:
            raise ValueError("body may not be blank")
        return value

    @field_validator("channels")
    @classmethod
    def _channels(cls, value: list[str]) -> list[str]:
        cleaned: list[str] = []
        for channel in value:
            channel = (channel or "").strip().lower()
            if channel not in ("in_app", "push"):
                raise ValueError(
                    f"unsupported channel {channel!r}; available channels are in_app and push"
                )
            if channel not in cleaned:
                cleaned.append(channel)
        if "in_app" not in cleaned:
            raise ValueError("in_app is required; push is optional")
        return cleaned

    @field_validator("deep_link")
    @classmethod
    def _deep_link(cls, value: Optional[str]) -> Optional[str]:
        return _validate_deep_link(value)

    @model_validator(mode="after")
    def _expiry(self):
        self.expires_at = _normalize_datetime(self.expires_at)
        if self.expires_at is not None and self.expires_at <= datetime.utcnow():
            raise ValueError("expires_at must be in the future")
        return self


class CommunicationUpdateIn(BaseModel):
    expected_version: Optional[int] = Field(default=None, ge=1)
    title: Optional[str] = Field(default=None, min_length=1, max_length=_TITLE_MAX)
    body: Optional[str] = Field(default=None, min_length=1, max_length=_BODY_MAX)
    communication_type: Optional[
        Literal["announcement", "maintenance", "incident", "product_update"]
    ] = None
    severity: Optional[Literal["low", "normal", "high", "critical"]] = None
    audience: Optional[AudienceIn] = None
    channels: Optional[list[str]] = Field(default=None, max_length=2)
    deep_link: Optional[str] = Field(default=None, max_length=_DEEP_LINK_MAX)
    expires_at: Optional[datetime] = None

    @field_validator("title")
    @classmethod
    def _title(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        value = _clean_text(value)
        if not value:
            raise ValueError("title may not be blank")
        return value

    @field_validator("body")
    @classmethod
    def _body(cls, value: Optional[str]) -> Optional[str]:
        if value is None:
            return None
        value = _clean_text(value, allow_newlines=True)
        if not value:
            raise ValueError("body may not be blank")
        return value

    @field_validator("channels")
    @classmethod
    def _channels(cls, value: Optional[list[str]]) -> Optional[list[str]]:
        if value is None:
            return None
        return CommunicationCreateIn._channels(value)

    @field_validator("deep_link")
    @classmethod
    def _deep_link(cls, value: Optional[str]) -> Optional[str]:
        return _validate_deep_link(value)

    @model_validator(mode="after")
    def _at_least_one(self):
        self.expires_at = _normalize_datetime(self.expires_at)
        non_nullable = {
            "title", "body", "communication_type", "severity", "audience",
            "channels",
        }
        for name in self.model_fields_set & non_nullable:
            if getattr(self, name) is None:
                raise ValueError(f"{name} may not be null")
        editable = {
            "title", "body", "communication_type", "severity", "audience",
            "channels", "deep_link", "expires_at",
        }
        if not (self.model_fields_set & editable):
            raise ValueError("at least one editable field is required")
        if self.expires_at is not None and self.expires_at <= datetime.utcnow():
            raise ValueError("expires_at must be in the future")
        return self


class ScheduleIn(BaseModel):
    scheduled_at: datetime

    @model_validator(mode="after")
    def _future(self):
        self.scheduled_at = to_naive_utc(self.scheduled_at)
        if self.scheduled_at <= datetime.utcnow():
            raise ValueError("scheduled_at must be in the future")
        return self


class ReasonIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=500)


class RetryIn(BaseModel):
    recipient_ids: Optional[list[str]] = Field(
        default=None, min_length=1, max_length=500,
    )


class AudiencePreviewIn(BaseModel):
    audience: AudienceIn


class AudiencePreviewOut(BaseModel):
    kind: str
    count: int
    max_audience: int
    allowed: bool


class DeliverySummaryOut(BaseModel):
    total_recipients: int
    read_count: int
    by_status: dict[str, int]
    devices_by_status: dict[str, int]
    provider_accepted: int
    confirmed_delivered: int
    failed: int
    retry_scheduled: int
    pending: int


class CommunicationOut(BaseModel):
    id: str
    title: str
    body: str
    communication_type: str
    severity: str
    status: str
    audience: dict
    channels: list[str]
    audience_count: Optional[int]
    deep_link: Optional[str]
    created_by_id: str
    updated_by_id: Optional[str]
    version: int
    created_at: str
    updated_at: str
    scheduled_at: Optional[str]
    published_at: Optional[str]
    completed_at: Optional[str]
    cancelled_at: Optional[str]
    expires_at: Optional[str]
    push_available: bool
    warnings: list[str] = Field(default_factory=list)


class CommunicationDetailOut(BaseModel):
    communication: CommunicationOut
    delivery: DeliverySummaryOut


class CommunicationListOut(BaseModel):
    items: list[CommunicationOut]
    total: int
    limit: int
    offset: int


class RecipientOut(BaseModel):
    id: str
    user_id: str
    status: str
    attempt_count: int
    last_attempt_at: Optional[str]
    provider_message_id: Optional[str]
    delivered_at: Optional[str]
    read_at: Optional[str]
    failure_category: Optional[str]
    retry_eligible: bool
    next_attempt_at: Optional[str]


class RecipientPageOut(BaseModel):
    items: list[RecipientOut]
    total: int
    limit: int
    offset: int


class CommunicationStatsOut(BaseModel):
    communication_id: str
    status: str
    audience_count: Optional[int]
    delivery: DeliverySummaryOut
    generated_at: str


class PublishOut(BaseModel):
    communication: CommunicationOut
    accepted: bool = True


class RetryOut(BaseModel):
    retried: int
    message: str


class WorkerDiagnosticsOut(BaseModel):
    generated_at: str
    worker: dict
    backlog: dict


class CustomerAnnouncementOut(BaseModel):
    id: str
    title: str
    body: str
    communication_type: str
    severity: str
    deep_link: Optional[str]
    published_at: Optional[str]
    expires_at: Optional[str]
    read_at: Optional[str]
    is_read: bool


class CustomerAnnouncementPageOut(BaseModel):
    items: list[CustomerAnnouncementOut]
    total: int
    limit: int
    offset: int


class ReadOut(BaseModel):
    id: str
    is_read: bool
    read_at: Optional[str]


def _push_available() -> bool:
    from api.routers import calls
    return calls._get_fcm() is not None


def _communication_dict(communication: ServiceCommunication) -> dict:
    channels = service._channels(communication.channels_json)
    warnings: list[str] = []
    push_available = _push_available()
    if "push" in channels and not push_available:
        warnings.append(
            "Firebase/FCM is not configured; the in-app announcement is still published, "
            "but push delivery is unavailable."
        )
    return {
        "id": communication.id,
        "title": communication.title,
        "body": communication.body,
        "communication_type": communication.communication_type,
        "severity": communication.severity,
        "status": communication.status,
        "audience": parse_audience(communication.audience_json),
        "channels": channels,
        "audience_count": communication.audience_count,
        "deep_link": communication.deep_link,
        "created_by_id": communication.created_by_id,
        "updated_by_id": communication.updated_by_id,
        "version": communication.version,
        "created_at": _iso(communication.created_at),
        "updated_at": _iso(communication.updated_at),
        "scheduled_at": _iso(communication.scheduled_at),
        "published_at": _iso(communication.published_at),
        "completed_at": _iso(communication.completed_at),
        "cancelled_at": _iso(communication.cancelled_at),
        "expires_at": _iso(communication.expires_at),
        "push_available": push_available,
        "warnings": warnings,
    }


async def _delivery_summary(db: AsyncSession, communication_id: str) -> dict:
    rows = (await db.execute(
        select(ServiceCommunicationRecipient.status, func.count())
        .where(ServiceCommunicationRecipient.communication_id == communication_id)
        .group_by(ServiceCommunicationRecipient.status)
    )).all()
    by_status = {str(status): int(count) for status, count in rows}
    device_rows = (await db.execute(
        select(ServiceCommunicationDeviceDelivery.status, func.count())
        .where(ServiceCommunicationDeviceDelivery.communication_id == communication_id)
        .group_by(ServiceCommunicationDeviceDelivery.status)
    )).all()
    devices = {str(status): int(count) for status, count in device_rows}
    read_count = int((await db.execute(
        select(func.count(ServiceCommunicationRecipient.id)).where(
            ServiceCommunicationRecipient.communication_id == communication_id,
            ServiceCommunicationRecipient.read_at.is_not(None),
        )
    )).scalar() or 0)
    pending = sum(by_status.get(name, 0) for name in ("queued", "sending", "retry_scheduled"))
    return {
        "total_recipients": sum(by_status.values()),
        "read_count": read_count,
        "by_status": by_status,
        "devices_by_status": devices,
        "provider_accepted": by_status.get("provider_accepted", 0),
        "confirmed_delivered": by_status.get("delivered", 0),
        "failed": by_status.get("failed", 0),
        "retry_scheduled": by_status.get("retry_scheduled", 0),
        "pending": pending,
    }


async def _get_communication(
    db: AsyncSession, communication_id: str, *, lock: bool = False,
) -> ServiceCommunication:
    query = select(ServiceCommunication).where(ServiceCommunication.id == communication_id)
    if lock:
        query = query.with_for_update()
    communication = (await db.execute(query)).scalar_one_or_none()
    if communication is None:
        raise HTTPException(status_code=404, detail="Communication not found")
    return communication


def _request_id() -> str:
    return request_id_var.get("-")


async def _audit(
    db: AsyncSession, request: Request, admin: User, action: str,
    communication_id: str, **detail,
) -> None:
    await record_audit(
        db, admin.id, action, "service_communication", communication_id,
        detail=json.dumps(
            {"request_id": _request_id(), **detail},
            separators=(",", ":"), sort_keys=True,
        ),
        ip_address=client_ip_or_none(request),
    )


def _publish_key(admin_id: str, communication_id: str, client_key: Optional[str]) -> Optional[str]:
    if not client_key:
        return None
    if len(client_key) > 200:
        raise HTTPException(status_code=400, detail="X-Idempotency-Key is too long")
    raw = (
        f"admin:{admin_id}\nPOST\n/admin/communications/{communication_id}/publish\n"
        f"{client_key}"
    )
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


async def _validate_audience_and_limit(db: AsyncSession, audience: dict) -> int:
    if (
        audience["kind"] == "user_ids"
        and len(audience["user_ids"]) > settings.service_communication_max_explicit_recipients
    ):
        raise HTTPException(
            status_code=422,
            detail=(
                "audience.user_ids exceeds the configured maximum of "
                f"{settings.service_communication_max_explicit_recipients}"
            ),
        )
    try:
        await validate_explicit_audience(db, audience)
        count = await count_audience(db, audience)
    except AudienceValidationError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    if count > settings.service_communication_max_audience:
        raise HTTPException(
            status_code=422,
            detail=(
                f"audience resolves to {count} users, above the configured maximum of "
                f"{settings.service_communication_max_audience}"
            ),
        )
    return count


# ── Admin: audience preview ──────────────────────────────────────────────────

@admin_router.post("/preview", response_model=AudiencePreviewOut)
async def preview_audience(
    body: AudiencePreviewIn,
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    audience = normalize_audience(body.audience.model_dump())
    count = await _validate_audience_and_limit(db, audience)
    return {
        "kind": audience["kind"],
        "count": count,
        "max_audience": settings.service_communication_max_audience,
        "allowed": count <= settings.service_communication_max_audience,
    }


# ── Admin: communication CRUD and lifecycle ─────────────────────────────────

@admin_router.get("", response_model=CommunicationListOut)
async def list_communications(
    response: Response,
    status: Optional[str] = Query(None),
    communication_type: Optional[str] = Query(None),
    severity: Optional[str] = Query(None),
    search: Optional[str] = Query(None, max_length=100),
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    conditions = []
    if status is not None:
        if status not in COMMUNICATION_STATUSES:
            raise HTTPException(status_code=422, detail="invalid communication status")
        conditions.append(ServiceCommunication.status == status)
    if communication_type is not None:
        if communication_type not in COMMUNICATION_TYPES:
            raise HTTPException(status_code=422, detail="invalid communication type")
        conditions.append(ServiceCommunication.communication_type == communication_type)
    if severity is not None:
        if severity not in COMMUNICATION_SEVERITIES:
            raise HTTPException(status_code=422, detail="invalid severity")
        conditions.append(ServiceCommunication.severity == severity)
    if search and search.strip():
        term = f"%{search.strip()}%"
        conditions.append(ServiceCommunication.title.ilike(term))
    total = int((await db.execute(
        select(func.count(ServiceCommunication.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(ServiceCommunication).where(*conditions)
        .order_by(desc(ServiceCommunication.created_at), desc(ServiceCommunication.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    response.headers["X-Total-Count"] = str(total)
    return {
        "items": [_communication_dict(row) for row in rows],
        "total": total, "limit": limit, "offset": offset,
    }


@admin_router.post("", response_model=CommunicationOut, status_code=201)
async def create_communication(
    body: CommunicationCreateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    audience = normalize_audience(body.audience.model_dump())
    try:
        _validate_push_payload(body.channels, body.title, body.body, body.deep_link)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    await _validate_audience_and_limit(db, audience)
    now = datetime.utcnow()
    communication = ServiceCommunication(
        title=body.title,
        body=body.body,
        communication_type=body.communication_type,
        severity=body.severity,
        status="draft",
        audience_json=audience_json(audience),
        channels_json=json.dumps(body.channels, separators=(",", ":")),
        deep_link=body.deep_link,
        expires_at=body.expires_at,
        created_by_id=admin.id,
        updated_by_id=admin.id,
        created_at=now,
        updated_at=now,
        version=1,
    )
    db.add(communication)
    await db.flush()
    await service.create_version(db, communication, admin.id)
    await _audit(db, request, admin, "service_communication_created", communication.id,
                 status="draft", version=1)
    await db.commit()
    logger.info(
        "[service_communications] event=created id=%s type=%s audience_kind=%s channels=%s",
        communication.id, communication.communication_type, audience["kind"],
        body.channels,
    )
    return _communication_dict(communication)


@admin_router.get("/{communication_id}", response_model=CommunicationDetailOut)
async def get_communication(
    communication_id: str,
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id)
    return {
        "communication": _communication_dict(communication),
        "delivery": await _delivery_summary(db, communication_id),
    }


@admin_router.patch("/{communication_id}", response_model=CommunicationOut)
async def update_communication(
    communication_id: str,
    body: CommunicationUpdateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id, lock=True)
    if communication.status != "draft":
        raise HTTPException(
            status_code=409,
            detail="Only drafts can be edited; this communication has already entered publication.",
        )
    if body.expected_version is not None and body.expected_version != communication.version:
        raise HTTPException(status_code=409, detail="Communication version has changed")

    changes = body.model_fields_set - {"expected_version"}
    candidate_title = body.title if "title" in changes else communication.title
    candidate_body = body.body if "body" in changes else communication.body
    candidate_channels = (
        body.channels if "channels" in changes and body.channels is not None
        else service._channels(communication.channels_json)
    )
    candidate_deep_link = (
        body.deep_link if "deep_link" in changes else communication.deep_link
    )
    try:
        _validate_push_payload(
            candidate_channels, candidate_title, candidate_body, candidate_deep_link,
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    if "audience" in changes and body.audience is not None:
        audience = normalize_audience(body.audience.model_dump())
        await _validate_audience_and_limit(db, audience)
        communication.audience_json = audience_json(audience)
    if "channels" in changes and body.channels is not None:
        communication.channels_json = json.dumps(body.channels, separators=(",", ":"))
    for field in ("title", "body", "communication_type", "severity", "deep_link", "expires_at"):
        if field in changes:
            setattr(communication, field, getattr(body, field))
    if communication.expires_at is not None and communication.expires_at <= datetime.utcnow():
        raise HTTPException(status_code=422, detail="expires_at must be in the future")
    communication.version += 1
    communication.updated_by_id = admin.id
    communication.updated_at = datetime.utcnow()
    await service.create_version(db, communication, admin.id)
    await _audit(db, request, admin, "service_communication_updated", communication.id,
                 status=communication.status, version=communication.version,
                 fields=sorted(changes))
    await db.commit()
    return _communication_dict(communication)


@admin_router.post("/{communication_id}/schedule", response_model=CommunicationOut)
async def schedule_communication(
    communication_id: str,
    body: ScheduleIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id, lock=True)
    if communication.status != "draft":
        raise HTTPException(status_code=409, detail="Only a draft can be scheduled")
    if communication.expires_at is not None and communication.expires_at <= body.scheduled_at:
        raise HTTPException(status_code=422, detail="expires_at must be after scheduled_at")
    communication.status = "scheduled"
    communication.scheduled_at = body.scheduled_at
    communication.updated_by_id = admin.id
    communication.updated_at = datetime.utcnow()
    await _audit(db, request, admin, "service_communication_scheduled", communication.id,
                 status="scheduled", scheduled_at=_iso(body.scheduled_at))
    await db.commit()
    return _communication_dict(communication)


@admin_router.post("/{communication_id}/publish", response_model=PublishOut, status_code=202)
async def publish_communication(
    communication_id: str,
    request: Request,
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    idempotency: IdempotencyResult = Depends(idempotency_guard),
    db: AsyncSession = Depends(get_db),
):
    if idempotency.cached:
        return idempotency.response
    await service_communication_publish_limiter.check_and_record(admin.id)
    publish_key = _publish_key(admin.id, communication_id, x_idempotency_key)
    communication = await _get_communication(db, communication_id, lock=True)
    now = datetime.utcnow()
    if publish_key and communication.publish_idempotency_key == publish_key:
        return {"communication": _communication_dict(communication), "accepted": True}
    if communication.status in ("publishing", "published", "completed"):
        raise HTTPException(status_code=409, detail="Communication has already been published")
    if communication.status not in ("draft", "scheduled"):
        raise HTTPException(status_code=409, detail=f"Cannot publish a {communication.status} communication")
    if communication.expires_at is not None and communication.expires_at <= now:
        raise HTTPException(status_code=409, detail="Communication has expired")

    try:
        audience = parse_stored_audience(communication.audience_json)
    except AudienceValidationError as exc:
        raise HTTPException(
            status_code=409,
            detail=f"Stored audience is invalid: {exc}",
        )
    await _validate_audience_and_limit(db, audience)
    if publish_key:
        collision = (await db.execute(
            select(ServiceCommunication.id).where(
                ServiceCommunication.publish_idempotency_key == publish_key,
                ServiceCommunication.id != communication.id,
            )
        )).scalar_one_or_none()
        if collision:
            raise HTTPException(status_code=409, detail="Idempotency key belongs to another communication")

    # Compare-and-swap rather than an ORM assignment: SQLite ignores
    # SELECT ... FOR UPDATE, so two simultaneous publish requests could both
    # pass the draft check above. The status/version predicate lets exactly
    # one request move the row into publishing on both databases.
    claimed = await db.execute(
        update(ServiceCommunication)
        .where(
            ServiceCommunication.id == communication_id,
            ServiceCommunication.status.in_(("draft", "scheduled")),
            ServiceCommunication.version == communication.version,
        )
        .values(
            status="publishing",
            scheduled_at=now,
            publish_idempotency_key=publish_key,
            publish_claim_token=None,
            publish_claim_expires_at=None,
            updated_by_id=admin.id,
            updated_at=now,
        )
    )
    if int(claimed.rowcount or 0) != 1:
        await db.rollback()
        current = (await db.execute(
            select(ServiceCommunication)
            .where(ServiceCommunication.id == communication_id)
            .execution_options(populate_existing=True)
        )).scalar_one()
        if publish_key and current.publish_idempotency_key == publish_key:
            return {"communication": _communication_dict(current), "accepted": True}
        raise HTTPException(
            status_code=409,
            detail="Communication was published or edited by another request",
        )
    await _audit(db, request, admin, "service_communication_publish_requested", communication.id,
                 status="publishing", channels=service._channels(communication.channels_json))
    await db.commit()
    communication = (await db.execute(
        select(ServiceCommunication)
        .where(ServiceCommunication.id == communication_id)
        .execution_options(populate_existing=True)
    )).scalar_one()
    result = {"communication": _communication_dict(communication), "accepted": True}
    await idempotency.store(result)

    # Accelerate the first pass when ARQ/Redis is available. The durable DB
    # loop is still the mechanism that guarantees this row is eventually run.
    try:
        from api.core.workers import enqueue, task_process_service_communications
        await enqueue("notifications", task_process_service_communications)
    except Exception as exc:
        # Do not let a best-effort wake-up make the publication itself fail.
        logger.warning(
            "[service_communications] wake-up enqueue failed request_id=%s type=%s",
            _request_id(), type(exc).__name__,
        )
    return result


@admin_router.post("/{communication_id}/cancel", response_model=CommunicationOut)
async def cancel_communication(
    communication_id: str,
    body: ReasonIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id, lock=True)
    if communication.status not in ("draft", "scheduled"):
        raise HTTPException(
            status_code=409,
            detail="Only a draft or scheduled communication can be cancelled before delivery starts",
        )
    communication.status = "cancelled"
    communication.cancelled_at = datetime.utcnow()
    communication.updated_by_id = admin.id
    communication.updated_at = communication.cancelled_at
    await _audit(db, request, admin, "service_communication_cancelled", communication.id,
                 status="cancelled")
    await db.commit()
    return _communication_dict(communication)


@admin_router.post("/{communication_id}/complete", response_model=CommunicationOut)
async def complete_communication(
    communication_id: str,
    body: ReasonIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id, lock=True)
    if communication.status == "completed":
        return _communication_dict(communication)
    if communication.status != "published":
        raise HTTPException(status_code=409, detail="Only a published communication can be completed")
    now = datetime.utcnow()
    pending = exists().where(
        ServiceCommunicationRecipient.communication_id == communication.id,
        ServiceCommunicationRecipient.status.in_(("queued", "sending", "retry_scheduled")),
    )
    completed = await db.execute(
        update(ServiceCommunication)
        .where(
            ServiceCommunication.id == communication.id,
            ServiceCommunication.status == "published",
            ~pending,
        )
        .values(
            status="completed",
            completed_at=now,
            updated_by_id=admin.id,
            updated_at=now,
        )
    )
    if int(completed.rowcount or 0) != 1:
        await db.rollback()
        raise HTTPException(
            status_code=409,
            detail="Delivery is still in progress; retry or wait for providers before resolving",
        )
    await _audit(db, request, admin, "service_communication_completed", communication.id,
                 status="completed")
    await db.commit()
    communication = (await db.execute(
        select(ServiceCommunication)
        .where(ServiceCommunication.id == communication.id)
        .execution_options(populate_existing=True)
    )).scalar_one()
    return _communication_dict(communication)


@admin_router.post("/{communication_id}/recipients/retry", response_model=RetryOut)
async def retry_recipients(
    communication_id: str,
    body: RetryIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.MANAGE_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    await service_communication_publish_limiter.check_and_record(admin.id)
    communication = await _get_communication(db, communication_id)
    if communication.status not in ("published", "completed"):
        raise HTTPException(status_code=409, detail="Retry is available only after publication")
    retried = await service.retry_eligible_recipients(
        db, communication_id, recipient_ids=body.recipient_ids, commit=False,
    )
    await _audit(db, request, admin, "service_communication_retry_requested", communication.id,
                 retried=retried)
    # The retry and its audit row commit together. Otherwise a process death
    # between them (or a failed audit insert) would leave an unrecorded
    # administrative mutation.
    await db.commit()
    if retried:
        try:
            from api.core.workers import enqueue, task_process_service_communications
            await enqueue("notifications", task_process_service_communications)
        except Exception as exc:
            logger.warning(
                "[service_communications] retry wake-up failed request_id=%s type=%s",
                _request_id(), type(exc).__name__,
            )
    return {"retried": retried, "message": "Eligible recipients were queued for retry"}


@admin_router.get("/{communication_id}/recipients", response_model=RecipientPageOut)
async def list_recipients(
    communication_id: str,
    status: Optional[str] = Query(None),
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    await _get_communication(db, communication_id)
    conditions = [ServiceCommunicationRecipient.communication_id == communication_id]
    if status is not None:
        if status not in ("queued", "sending", "provider_accepted", "delivered", "failed", "retry_scheduled"):
            raise HTTPException(status_code=422, detail="invalid recipient status")
        conditions.append(ServiceCommunicationRecipient.status == status)
    total = int((await db.execute(
        select(func.count(ServiceCommunicationRecipient.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(ServiceCommunicationRecipient).where(*conditions)
        .order_by(ServiceCommunicationRecipient.user_id)
        .limit(limit).offset(offset)
    )).scalars().all()
    return {
        "items": [{
            "id": row.id,
            "user_id": row.user_id,
            "status": row.status,
            "attempt_count": row.attempt_count,
            "last_attempt_at": _iso(row.last_attempt_at),
            "provider_message_id": row.provider_message_id,
            "delivered_at": _iso(row.delivered_at),
            "read_at": _iso(row.read_at),
            "failure_category": row.failure_category,
            "retry_eligible": bool(row.retry_eligible),
            "next_attempt_at": _iso(row.next_attempt_at),
        } for row in rows],
        "total": total, "limit": limit, "offset": offset,
    }


@admin_router.get("/{communication_id}/stats", response_model=CommunicationStatsOut)
async def communication_stats(
    communication_id: str,
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    communication = await _get_communication(db, communication_id)
    return {
        "communication_id": communication.id,
        "status": communication.status,
        "audience_count": communication.audience_count,
        "delivery": await _delivery_summary(db, communication.id),
        "generated_at": datetime.utcnow().isoformat() + "Z",
    }


@admin_router.get("/diagnostics/worker", response_model=WorkerDiagnosticsOut)
async def worker_diagnostics(
    admin: User = Depends(require_permission(Permission.VIEW_COMMUNICATIONS)),
    db: AsyncSession = Depends(get_db),
):
    return await service.runtime_diagnostics(db)


# ── Customer: published in-app announcements ────────────────────────────────

def _visible_conditions(now: datetime) -> list:
    return [
        ServiceCommunication.published_at.is_not(None),
        ServiceCommunication.published_at <= now,
        ServiceCommunication.status.in_(("published", "completed")),
        (ServiceCommunication.expires_at.is_(None) | (ServiceCommunication.expires_at > now)),
    ]


@customer_router.get("", response_model=CustomerAnnouncementPageOut)
async def list_my_announcements(
    limit: int = Query(50, ge=1, le=_MAX_PAGE),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    conditions = [ServiceCommunicationRecipient.user_id == current_user["id"], *_visible_conditions(now)]
    joined = (
        select(ServiceCommunicationRecipient, ServiceCommunication)
        .join(ServiceCommunication, ServiceCommunication.id == ServiceCommunicationRecipient.communication_id)
        .where(*conditions)
    )
    total = int((await db.execute(
        select(func.count()).select_from(joined.subquery())
    )).scalar() or 0)
    rows = (await db.execute(
        joined.order_by(desc(ServiceCommunication.published_at), desc(ServiceCommunication.id))
        .limit(limit).offset(offset)
    )).all()
    return {
        "items": [{
            "id": communication.id,
            "title": communication.title,
            "body": communication.body,
            "communication_type": communication.communication_type,
            "severity": communication.severity,
            "deep_link": communication.deep_link,
            "published_at": _iso(communication.published_at),
            "expires_at": _iso(communication.expires_at),
            "read_at": _iso(recipient.read_at),
            "is_read": recipient.read_at is not None,
        } for recipient, communication in rows],
        "total": total, "limit": limit, "offset": offset,
    }


@customer_router.post("/{communication_id}/read", response_model=ReadOut)
async def mark_announcement_read(
    communication_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    recipient = (await db.execute(
        select(ServiceCommunicationRecipient)
        .join(ServiceCommunication, ServiceCommunication.id == ServiceCommunicationRecipient.communication_id)
        .where(
            ServiceCommunicationRecipient.communication_id == communication_id,
            ServiceCommunicationRecipient.user_id == current_user["id"],
            *_visible_conditions(now),
        )
        .with_for_update()
    )).scalar_one_or_none()
    if recipient is None:
        raise HTTPException(status_code=404, detail="Announcement not found")
    if recipient.read_at is None:
        recipient.read_at = now
        recipient.updated_at = now
        await db.commit()
    return {
        "id": communication_id,
        "is_read": True,
        "read_at": _iso(recipient.read_at),
    }


__all__ = ["admin_router", "customer_router"]
