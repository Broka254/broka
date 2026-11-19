"""Admin activity intelligence and account moderation.

Reads (overview, the user table, one account's activity profile) need
ADMIN_SUMMARY, the dashboard's ordinary read permission. Suspending and
reinstating need SUSPEND_USER, which only administrators hold today.

Nothing here computes a metric the database cannot answer: an empty window is
zero, an unavailable figure is reported as unavailable by
api/core/activity.py, and a suspension is a state change plus an audit row -
no marketplace or money data is touched.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, Field
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import activity, moderation
from api.core.client_ip import client_ip_or_none
from api.core.permissions import Permission, require_permission
from api.core.presence import online_status
from api.database import Listing, User, get_db
from api.models.activity import UserSession

router = APIRouter()


def _iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return value.isoformat() + "Z"


class SuspendIn(BaseModel):
    mode: Literal["temporary", "permanent"] = "temporary"
    # Ignored for a permanent suspension; required for a temporary one.
    duration_hours: Optional[int] = Field(default=None, ge=1, le=24 * 365)
    reason: str = Field(min_length=3, max_length=500)
    notes: Optional[str] = Field(default=None, max_length=2000)


class ReinstateIn(BaseModel):
    reason: str = Field(min_length=3, max_length=500)
    notes: Optional[str] = Field(default=None, max_length=2000)


# ── Reads ─────────────────────────────────────────────────────────────────────

@router.get("/activity/overview")
async def activity_overview(
    window_days: int = Query(30, ge=1, le=90),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Live presence, DAU/WAU/MAU, durations, retention and the denominator
    behind the active-user percentage. One read, one server timestamp."""
    return await activity.overview(db, window_days=window_days)


@router.get("/activity/users")
async def activity_users(
    q: Optional[str] = Query(None, max_length=100),
    status_filter: Literal["all", "active", "suspended", "flagged"] = Query(
        "all", alias="status"
    ),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """The searchable activity table: who is present, who is suspended, and
    how much foreground time each account accumulated in the last 30 days."""
    now = datetime.utcnow()

    # Open sessions and their last beat, per account.
    open_sessions = (
        select(
            UserSession.user_id.label("user_id"),
            func.count(UserSession.id).label("open_sessions"),
            func.max(UserSession.last_activity_at).label("last_activity"),
        )
        .where(UserSession.ended_at.is_(None))
        .group_by(UserSession.user_id)
        .subquery()
    )
    # Foreground seconds in the window, per account.
    recent_usage = (
        select(
            UserSession.user_id.label("user_id"),
            func.coalesce(func.sum(UserSession.foreground_seconds), 0).label("foreground"),
            func.count(UserSession.id).label("sessions"),
        )
        .where(UserSession.last_activity_at >= now - timedelta(days=30))
        .group_by(UserSession.user_id)
        .subquery()
    )
    listing_counts = (
        select(
            Listing.seller_id.label("seller_id"),
            func.count(Listing.id).label("listings"),
        )
        .group_by(Listing.seller_id)
        .subquery()
    )

    query = (
        select(
            User,
            open_sessions.c.open_sessions,
            open_sessions.c.last_activity,
            recent_usage.c.foreground,
            recent_usage.c.sessions,
            listing_counts.c.listings,
        )
        .outerjoin(open_sessions, open_sessions.c.user_id == User.id)
        .outerjoin(recent_usage, recent_usage.c.user_id == User.id)
        .outerjoin(listing_counts, listing_counts.c.seller_id == User.id)
    )

    filters = []
    if q:
        like = f"%{q.strip()}%"
        filters.append(
            or_(User.name.ilike(like), User.phone.ilike(like), User.email.ilike(like))
        )
    if status_filter == "active":
        filters.append(User.account_status == moderation.ACTIVE)
    elif status_filter == "suspended":
        filters.append(User.account_status.in_(moderation.BLOCKED_STATUSES))
    elif status_filter == "flagged":
        filters.append(User.is_flagged.is_(True))  # noqa: E712
    if filters:
        query = query.where(*filters)

    total = int(
        (
            await db.execute(
                select(func.count(User.id)).where(*filters) if filters else select(func.count(User.id))
            )
        ).scalar()
        or 0
    )

    rows = (
        await db.execute(
            query.order_by(User.created_at.desc()).limit(limit).offset(offset)
        )
    ).all()

    users = []
    for user, open_count, last_activity, foreground, sessions, listings in rows:
        is_online, label = online_status(
            last_activity or getattr(user, "last_seen", None)
        )
        state = moderation.account_state(user, now)
        users.append(
            {
                "id": user.id,
                "name": user.name,
                "phone": user.phone,
                "email": user.email,
                "account_type": getattr(user.account_type, "value", user.account_type),
                "is_admin": bool(user.is_admin),
                "is_flagged": bool(user.is_flagged),
                "trust_score": user.trust_score,
                "created_at": _iso(user.created_at),
                "last_seen": _iso(getattr(user, "last_seen", None)),
                "is_online": is_online,
                "presence_label": label,
                "open_sessions": int(open_count or 0),
                "sessions_30d": int(sessions or 0),
                "foreground_seconds_30d": int(foreground or 0),
                "listings": int(listings or 0),
                "moderation": state,
            }
        )

    return {
        "generated_at": _iso(now),
        "window_days": 30,
        "total": total,
        "limit": limit,
        "offset": offset,
        "users": users,
    }


@router.get("/users/{user_id}/activity")
async def user_activity_profile(
    user_id: str,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """One account's activity profile: state, sessions and moderation history.

    Deliberately does not expose message contents, call audio or precise
    location - none of that belongs in an operations dashboard.
    """
    now = datetime.utcnow()
    user = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    sessions = (
        await db.execute(
            select(UserSession)
            .where(UserSession.user_id == user_id)
            .order_by(UserSession.last_activity_at.desc())
            .limit(50)
        )
    ).scalars().all()

    since = now - timedelta(days=30)
    totals = (
        await db.execute(
            select(
                func.count(UserSession.id),
                func.coalesce(func.sum(UserSession.foreground_seconds), 0),
            ).where(
                UserSession.user_id == user_id,
                UserSession.last_activity_at >= since,
            )
        )
    ).one()

    is_online, label = online_status(
        sessions[0].last_activity_at if sessions and sessions[0].ended_at is None else user.last_seen
    )

    return {
        "generated_at": _iso(now),
        "window_days": 30,
        "user": {
            "id": user.id,
            "name": user.name,
            "phone": user.phone,
            "email": user.email,
            "account_type": getattr(user.account_type, "value", user.account_type),
            "is_admin": bool(user.is_admin),
            "is_flagged": bool(user.is_flagged),
            "trust_score": user.trust_score,
            "created_at": _iso(user.created_at),
            "last_seen": _iso(user.last_seen),
            "is_online": is_online,
            "presence_label": label,
        },
        "moderation": moderation.account_state(user, now),
        "totals_30d": {
            "sessions": int(totals[0] or 0),
            "foreground_seconds": int(totals[1] or 0),
        },
        "sessions": [
            {
                "id": row.id,
                "device_id": row.device_id,
                "platform": row.platform,
                "started_at": _iso(row.started_at),
                "last_activity_at": _iso(row.last_activity_at),
                "ended_at": _iso(row.ended_at),
                "end_reason": row.end_reason,
                "foreground_seconds": int(row.foreground_seconds or 0),
                "is_foreground": bool(row.is_foreground),
            }
            for row in sessions
        ],
        "moderation_history": await moderation.moderation_history(db, user_id),
    }


@router.get("/users/{user_id}/moderation")
async def user_moderation_history(
    user_id: str,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    user = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return {
        "user_id": user_id,
        "moderation": moderation.account_state(user),
        "history": await moderation.moderation_history(db, user_id),
    }


# ── Decisions ─────────────────────────────────────────────────────────────────

@router.post("/users/{user_id}/suspend")
async def suspend_user(
    user_id: str,
    body: SuspendIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.SUSPEND_USER)),
    db: AsyncSession = Depends(get_db),
):
    """Suspend an account and revoke everything it is holding open.

    The state change, the session closure, the refresh-token revocation, the
    moderation row and the audit row commit together, so a suspension can
    never be half applied.
    """
    user = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    state = await moderation.suspend_user(
        db,
        user=user,
        actor_id=admin.id,
        mode=body.mode,
        duration_hours=body.duration_hours,
        reason=body.reason,
        notes=body.notes,
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "moderation": state}


@router.post("/users/{user_id}/reinstate")
async def reinstate_user(
    user_id: str,
    body: ReinstateIn,
    request: Request,
    admin: User = Depends(require_permission(Permission.SUSPEND_USER)),
    db: AsyncSession = Depends(get_db),
):
    user = (
        await db.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    state = await moderation.reinstate_user(
        db,
        user=user,
        actor_id=admin.id,
        reason=body.reason,
        notes=body.notes,
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "moderation": state}
