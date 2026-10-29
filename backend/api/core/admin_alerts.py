"""Admin alert service — create / acknowledge / resolve / list.

Dedup rule (the reason this is a service, not inline queries): an event that
re-fires for the same entity — a dispute timer re-emitting DISPUTE.OPENED, a
webhook redelivery surfacing PAYMENT.FAILED twice — must not page the ops
screen twice. create_alert skips the insert when an open alert with the same
kind and the same meta reference already exists and returns the existing row.
"""
from __future__ import annotations

import logging
from datetime import datetime
from typing import Any, Optional

from sqlalchemy import desc, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.admin_alert import AdminAlert, AlertSeverity, AlertStatus

_log = logging.getLogger(__name__)


def alert_to_dict(row: AdminAlert) -> dict:
    from api.core.timeutil import to_naive_utc

    def _iso(value: Optional[datetime]) -> Optional[str]:
        if value is None:
            return None
        if value.tzinfo is not None:
            value = to_naive_utc(value)
        return value.isoformat() + "Z"

    return {
        "id": row.id,
        "kind": row.kind,
        "severity": row.severity,
        "title": row.title,
        "body": row.body,
        "href": row.href,
        "status": row.status,
        "created_at": _iso(row.created_at),
        "acknowledged_at": _iso(row.acknowledged_at),
        "acknowledged_by": row.acknowledged_by,
        "resolved_at": _iso(row.resolved_at),
        "meta": row.meta or {},
    }


def _meta_matches(stored: Any, wanted: dict) -> bool:
    """True when every key of the wanted ref is present with the same value.

    Compared in Python, not SQL: JSON operators differ between SQLite and
    Postgres, and the candidate set (open alerts of one kind) is small.
    """
    if not isinstance(stored, dict):
        return False
    return all(stored.get(key) == value for key, value in wanted.items())


async def create_alert(
    db: AsyncSession,
    *,
    kind: str,
    severity: str,
    title: str,
    body: Optional[str] = None,
    href: Optional[str] = None,
    meta: Optional[dict] = None,
) -> AdminAlert:
    """Insert an alert, or return the still-open duplicate when one exists.

    Dedup only applies when a meta ref is given: a hand-written operational
    note with no ref is always a new row, because there is nothing stable to
    match it against. Does not commit; the caller owns the transaction.
    """
    if severity not in AlertSeverity.ALL:
        raise ValueError(f"unknown severity {severity!r}")
    if meta:
        existing = (
            await db.execute(
                select(AdminAlert)
                .where(
                    AdminAlert.kind == kind,
                    AdminAlert.status == AlertStatus.OPEN,
                )
                .order_by(desc(AdminAlert.created_at), desc(AdminAlert.id))
            )
        ).scalars().all()
        for row in existing:
            if _meta_matches(row.meta, meta):
                return row
    row = AdminAlert(
        kind=kind,
        severity=severity,
        title=title,
        body=body,
        href=href,
        status=AlertStatus.OPEN,
        meta=meta or {},
        created_at=datetime.utcnow(),
    )
    db.add(row)
    await db.flush()
    return row


async def acknowledge(
    db: AsyncSession,
    alert_id: int,
    admin_id: str,
    reason: Optional[str] = None,  # noqa: ARG001 - kept for a symmetric ack/resolve API; recorded in the audit row by the router
) -> Optional[AdminAlert]:
    """Mark open → acknowledged. Idempotent: re-acking or acking a resolved
    alert returns the row unchanged instead of erroring or reopening it."""
    row = (
        await db.execute(select(AdminAlert).where(AdminAlert.id == alert_id))
    ).scalar_one_or_none()
    if row is None:
        return None
    if row.status == AlertStatus.OPEN:
        row.status = AlertStatus.ACKNOWLEDGED
        row.acknowledged_at = datetime.utcnow()
        row.acknowledged_by = admin_id
        await db.flush()
    return row


async def resolve(
    db: AsyncSession,
    alert_id: int,
    admin_id: str,  # noqa: ARG001 - symmetric with acknowledge; the audit row carries the actor
    reason: Optional[str] = None,  # noqa: ARG001 - same as above
) -> Optional[AdminAlert]:
    """Mark open/acknowledged → resolved. Idempotent like acknowledge."""
    row = (
        await db.execute(select(AdminAlert).where(AdminAlert.id == alert_id))
    ).scalar_one_or_none()
    if row is None:
        return None
    if row.status != AlertStatus.RESOLVED:
        row.status = AlertStatus.RESOLVED
        row.resolved_at = datetime.utcnow()
        await db.flush()
    return row


async def resolve_by_ref(
    db: AsyncSession, *, kind: str, ref: dict
) -> int:
    """Auto-resolve every open alert of `kind` whose meta contains `ref`.

    Used when the underlying fact clears itself, e.g. DISPUTE.RESOLVED
    closing the alert DISPUTE.OPENED raised. Returns the count resolved.
    """
    rows = (
        await db.execute(
            select(AdminAlert).where(
                AdminAlert.kind == kind,
                AdminAlert.status != AlertStatus.RESOLVED,
            )
        )
    ).scalars().all()
    now = datetime.utcnow()
    count = 0
    for row in rows:
        if _meta_matches(row.meta, ref):
            row.status = AlertStatus.RESOLVED
            row.resolved_at = now
            count += 1
    if count:
        await db.flush()
    return count


async def list_alerts(
    db: AsyncSession,
    *,
    status: str = AlertStatus.OPEN,
    severity: Optional[str] = None,
    kind: Optional[str] = None,
    limit: int = 50,
    offset: int = 0,
) -> tuple[list[AdminAlert], int, int]:
    """Newest-first page plus the filtered total and the unread (open) count.

    `unread` honours the severity/kind filters but never the status filter:
    it answers "how many need attention under this filter", which is what
    the dashboard badge shows.
    """
    conditions = []
    if status != "all":
        conditions.append(AdminAlert.status == status)
    if severity:
        conditions.append(AdminAlert.severity == severity)
    if kind:
        conditions.append(AdminAlert.kind == kind)

    total = int(
        (
            await db.execute(
                select(func.count(AdminAlert.id)).where(*conditions)
            )
        ).scalar()
        or 0
    )
    rows = (
        await db.execute(
            select(AdminAlert)
            .where(*conditions)
            .order_by(desc(AdminAlert.created_at), desc(AdminAlert.id))
            .limit(limit)
            .offset(offset)
        )
    ).scalars().all()

    unread_conditions = []
    if severity:
        unread_conditions.append(AdminAlert.severity == severity)
    if kind:
        unread_conditions.append(AdminAlert.kind == kind)
    unread = int(
        (
            await db.execute(
                select(func.count(AdminAlert.id)).where(
                    AdminAlert.status == AlertStatus.OPEN, *unread_conditions
                )
            )
        ).scalar()
        or 0
    )
    return list(rows), total, unread
