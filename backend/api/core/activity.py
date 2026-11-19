"""User activity: sessions, presence and the engagement metrics the dashboard shows.

One rule decides every number here: a measurement is either computed from
`user_sessions`/`users` rows or reported as unavailable. Nothing is inferred
from a missing table, back-filled, or modelled from a heartbeat that never
happened.

Terminology, because the dashboard must not blur these:

* **Live / presence** - an open session whose last heartbeat is within
  `ONLINE_THRESHOLD_SECS` (300s, the same window the app's "online" badge
  uses). It answers "who is here now".
* **Active in a window** - a distinct user with a session activity stamp
  (`last_activity_at`) inside the window. DAU/WAU/MAU use this. It is not
  presence: a user active this morning is a daily active user and offline.
* **Foreground time** - seconds between consecutive heartbeats while the app
  reported itself foreground, capped at the presence window so a gap that
  ends in a new session never becomes usage.

Sessions are closed by an explicit sign-out, by `close_stale_sessions` (run
from the 5-minute worker sweep), or by a suspension. There is no client event
that can be trusted to always arrive.
"""
from __future__ import annotations

import statistics
from datetime import datetime, timedelta
from typing import Iterable, Optional

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

# Same threshold as api/core/presence.py: one definition of "online".
ONLINE_THRESHOLD_SECS = 300
# Two heartbeats closer than this do not need a second row update. The app
# beats every ~60s, so in practice each beat advances the session; the floor
# exists for a client that retries in a tight loop.
HEARTBEAT_WRITE_INTERVAL_SECS = 15
# Detailed rows are kept this long. Longer than the 30-day engagement windows
# the dashboard offers, so a month-over-month comparison never silently loses
# the earlier month. Aggregates older than this are simply not claimed.
SESSION_RETENTION_DAYS = 180
# A single foreground stretch longer than this is treated as a suspicious gap
# (a phone left open) rather than six hours of use.
MAX_FOREGROUND_GAP_SECS = ONLINE_THRESHOLD_SECS
# Per-session durations are capped when averaging: a session left open by a
# crash is closed by the sweep, but a cap keeps one bad row from dominating.
MAX_SESSION_SECONDS = 6 * 3600
# Bounds for the peak-concurrency scan; a wider window is answered from the
# rows that exist rather than by scanning without limit.
PEAK_SCAN_LIMIT = 20_000


def _now() -> datetime:
    # Naive UTC, like every DateTime column in this codebase.
    return datetime.utcnow()


async def touch_session(
    db: AsyncSession,
    user_id: str,
    *,
    device_id: Optional[str] = None,
    platform: Optional[str] = None,
    foreground: bool = True,
    session_id: Optional[str] = None,
    now: Optional[datetime] = None,
) -> dict:
    """Record one heartbeat and return the session it belongs to.

    Reuses the caller's open session for this device; starts a new one when
    the previous beat is older than the presence window, because the gap
    between them is not usage. Does not commit - the caller does.
    """
    from api.database import User
    from api.models.activity import UserSession

    now = now or _now()
    stmt = select(UserSession).where(
        UserSession.user_id == user_id,
        UserSession.ended_at.is_(None),
    )
    if session_id:
        stmt = stmt.where(UserSession.id == session_id)
    elif device_id:
        stmt = stmt.where(UserSession.device_id == device_id)
    stmt = stmt.order_by(UserSession.last_activity_at.desc()).limit(1)
    session = (await db.execute(stmt)).scalar_one_or_none()

    if session is not None and now - session.last_activity_at > timedelta(
        seconds=ONLINE_THRESHOLD_SECS
    ):
        # The app was away longer than the presence window. Close the old
        # session where it last reported and open a new one, so the two
        # durations describe when the person was actually present.
        session.ended_at = session.last_activity_at
        session.end_reason = "inactivity"
        session = None

    created = False
    if session is None:
        session = UserSession(
            user_id=user_id,
            device_id=device_id,
            platform=platform,
            started_at=now,
            last_activity_at=now,
            is_foreground=bool(foreground),
            heartbeat_count=1,
        )
        db.add(session)
        await db.flush()
        created = True
    else:
        gap = max(0.0, (now - session.last_activity_at).total_seconds())
        if gap < HEARTBEAT_WRITE_INTERVAL_SECS:
            # A duplicate/retried beat inside the throttle window: answer with
            # the session as it stands rather than writing the same row again.
            return _session_payload(session, created=False)
        if foreground and session.is_foreground:
            session.foreground_seconds = int(session.foreground_seconds or 0) + int(
                min(gap, MAX_FOREGROUND_GAP_SECS)
            )
        session.is_foreground = bool(foreground)
        session.heartbeat_count = int(session.heartbeat_count or 0) + 1
        session.last_activity_at = now
        if platform and not session.platform:
            session.platform = platform

    # `users.last_seen` still feeds the app's chat presence. Advance it only
    # when it would visibly change, so a heartbeat does not rewrite a row
    # that already says the same thing.
    await db.execute(
        update(User)
        .where(
            User.id == user_id,
            or_(
                User.last_seen.is_(None),
                User.last_seen < now - timedelta(seconds=30),
            ),
        )
        .values(last_seen=now)
    )
    return _session_payload(session, created=created)


def _session_payload(session, *, created: bool) -> dict:
    return {
        "session_id": session.id,
        "started_at": session.started_at,
        "last_activity_at": session.last_activity_at,
        "foreground_seconds": int(session.foreground_seconds or 0),
        "is_foreground": bool(session.is_foreground),
        "created": created,
    }


async def close_session(
    db: AsyncSession,
    user_id: str,
    *,
    session_id: Optional[str] = None,
    device_id: Optional[str] = None,
    reason: str = "logout",
    now: Optional[datetime] = None,
) -> int:
    """Close this user's open session(s). Returns how many rows were closed.

    Per row rather than one bulk UPDATE, because the final foreground stretch
    (the gap since the last beat) belongs to the usage total and a bulk
    statement cannot add it without reading each row anyway.
    """
    from api.models.activity import UserSession

    now = now or _now()
    stmt = select(UserSession).where(
        UserSession.user_id == user_id,
        UserSession.ended_at.is_(None),
    )
    if session_id:
        stmt = stmt.where(UserSession.id == session_id)
    elif device_id:
        stmt = stmt.where(UserSession.device_id == device_id)
    sessions = (await db.execute(stmt)).scalars().all()

    for session in sessions:
        if session.is_foreground:
            gap = max(0.0, (now - session.last_activity_at).total_seconds())
            session.foreground_seconds = int(session.foreground_seconds or 0) + int(
                min(gap, MAX_FOREGROUND_GAP_SECS)
            )
        session.ended_at = now
        session.end_reason = reason
    return len(sessions)


async def close_stale_sessions(db: AsyncSession, *, now: Optional[datetime] = None) -> int:
    """Close sessions whose last beat is older than the presence window.

    Run from the worker sweep. A closed session ends where it was last seen,
    not at the moment the sweep noticed it: the difference is the time it was
    silently gone.
    """
    from api.models.activity import UserSession

    now = now or _now()
    cutoff = now - timedelta(seconds=ONLINE_THRESHOLD_SECS)
    result = await db.execute(
        update(UserSession)
        .where(
            UserSession.ended_at.is_(None),
            UserSession.last_activity_at < cutoff,
        )
        .values(ended_at=UserSession.last_activity_at, end_reason="inactivity")
    )
    return int(result.rowcount or 0)


async def purge_old_sessions(db: AsyncSession, *, now: Optional[datetime] = None) -> int:
    """Delete closed sessions past the retention window."""
    from api.models.activity import UserSession

    now = now or _now()
    cutoff = now - timedelta(days=SESSION_RETENTION_DAYS)
    result = await db.execute(
        UserSession.__table__.delete().where(
            UserSession.ended_at.isnot(None),
            UserSession.ended_at < cutoff,
        )
    )
    return int(result.rowcount or 0)


async def _distinct_users(db: AsyncSession, since: datetime) -> int:
    from api.models.activity import UserSession

    value = (
        await db.execute(
            select(func.count(func.distinct(UserSession.user_id))).where(
                UserSession.last_activity_at >= since
            )
        )
    ).scalar()
    return int(value or 0)


async def live_counts(db: AsyncSession, *, now: Optional[datetime] = None) -> dict:
    """Open sessions whose last beat is inside the presence window."""
    from api.models.activity import UserSession

    now = now or _now()
    cutoff = now - timedelta(seconds=ONLINE_THRESHOLD_SECS)
    row = (
        await db.execute(
            select(
                func.count(UserSession.id),
                func.count(func.distinct(UserSession.user_id)),
            ).where(
                UserSession.ended_at.is_(None),
                UserSession.last_activity_at >= cutoff,
            )
        )
    ).one()
    return {
        "active_sessions": int(row[0] or 0),
        "active_users": int(row[1] or 0),
        "window_seconds": ONLINE_THRESHOLD_SECS,
    }


async def peak_concurrent(
    db: AsyncSession, *, since: datetime, now: Optional[datetime] = None
) -> Optional[int]:
    """Highest number of sessions open at the same instant since `since`.

    A sweep line over session intervals. Bounded: if the window holds more
    rows than PEAK_SCAN_LIMIT the answer is None ("unavailable") rather than
    a guess from a partial scan.
    """
    from api.models.activity import UserSession

    now = now or _now()
    rows = (
        await db.execute(
            select(
                UserSession.started_at,
                UserSession.last_activity_at,
                UserSession.ended_at,
            )
            .where(UserSession.last_activity_at >= since)
            .limit(PEAK_SCAN_LIMIT + 1)
        )
    ).all()
    if len(rows) > PEAK_SCAN_LIMIT:
        return None

    events: list[tuple[datetime, int]] = []
    for started, last_seen, ended in rows:
        if started is None or last_seen is None:
            continue
        end = ended or last_seen
        if end < started:
            end = started
        events.append((started, 1))
        events.append((end, -1))
    # Ends sort before starts at the same instant, so a session that ends at
    # 10:00 does not make the one starting at 10:00 overlap it.
    events.sort(key=lambda pair: (pair[0], pair[1]))
    current = peak = 0
    for _, delta in events:
        current += delta
        peak = max(peak, current)
    _ = now  # the window is bounded by the caller; kept for signature symmetry
    return peak


async def _durations(db: AsyncSession, *, since: datetime) -> list[float]:
    from api.models.activity import UserSession

    rows = (
        await db.execute(
            select(UserSession.started_at, UserSession.ended_at).where(
                UserSession.ended_at.isnot(None),
                UserSession.ended_at >= since,
            )
        )
    ).all()
    out: list[float] = []
    for started, ended in rows:
        if started is None or ended is None:
            continue
        seconds = (ended - started).total_seconds()
        if seconds <= 0:
            continue
        out.append(min(seconds, MAX_SESSION_SECONDS))
    return out


def _round(value: Optional[float]) -> Optional[float]:
    return None if value is None else round(float(value), 2)


async def overview(
    db: AsyncSession, *, now: Optional[datetime] = None, window_days: int = 30
) -> dict:
    """Everything the User Intelligence workspace needs, in one read."""
    from api.database import User

    now = now or _now()
    presence = await live_counts(db, now=now)

    active_5m = await _distinct_users(db, now - timedelta(minutes=5))
    active_15m = await _distinct_users(db, now - timedelta(minutes=15))
    active_60m = await _distinct_users(db, now - timedelta(minutes=60))

    dau = await _distinct_users(db, now - timedelta(days=1))
    wau = await _distinct_users(db, now - timedelta(days=7))
    mau = await _distinct_users(db, now - timedelta(days=30))

    window_start = now - timedelta(days=window_days)
    active_window = await _distinct_users(db, window_start)

    from api.models.activity import UserSession

    # "New" means the account itself was created inside the window and had
    # activity in it; "returning" is the rest of the active window. Neither
    # is inferred from a heartbeat that predates registration.
    active_user_ids = select(UserSession.user_id).where(
        UserSession.last_activity_at >= window_start
    )
    new_users = int(
        (
            await db.execute(
                select(func.count(func.distinct(User.id))).where(
                    User.created_at >= window_start,
                    User.id.in_(active_user_ids),
                )
            )
        ).scalar()
        or 0
    )

    total_users = int((await db.execute(select(func.count(User.id)))).scalar() or 0)
    blocked_users = int(
        (
            await db.execute(
                select(func.count(User.id)).where(
                    User.account_status.in_(("suspended", "banned"))
                )
            )
        ).scalar()
        or 0
    )
    eligible_users = max(0, total_users - blocked_users)

    durations = await _durations(db, since=window_start)
    avg_session = _round(statistics.fmean(durations)) if durations else None
    median_session = _round(statistics.median(durations)) if durations else None

    foreground_total = int(
        (
            await db.execute(
                select(func.coalesce(func.sum(UserSession.foreground_seconds), 0)).where(
                    UserSession.last_activity_at >= now - timedelta(days=7)
                )
            )
        ).scalar()
        or 0
    )
    active_7d = await _distinct_users(db, now - timedelta(days=7))
    avg_daily_seconds = (
        _round(foreground_total / active_7d / 7) if active_7d else None
    )

    peak = await peak_concurrent(db, since=now - timedelta(hours=24), now=now)

    unavailable: list[dict] = []
    if avg_session is None:
        unavailable.append(
            {
                "metric": "session_duration",
                "reason": "No session has ended inside this window yet, so no duration exists to average.",
            }
        )
    if peak is None:
        unavailable.append(
            {
                "metric": "peak_concurrent_users",
                "reason": "More sessions in the last 24h than the bounded scan allows; the figure is not estimated.",
            }
        )

    return {
        "generated_at": now.isoformat() + "Z",
        "presence": presence,
        "windows": {
            "5m": {"active_users": active_5m},
            "15m": {"active_users": active_15m},
            "60m": {"active_users": active_60m},
        },
        "engagement": {
            "dau": dau,
            "wau": wau,
            "mau": mau,
            "dau_mau": _round(dau / mau) if mau else None,
            "avg_session_seconds": avg_session,
            "median_session_seconds": median_session,
            "avg_daily_foreground_seconds": avg_daily_seconds,
            "new_users": new_users,
            "returning_users": max(0, active_window - new_users),
        },
        "population": {
            "registered_users": total_users,
            "blocked_users": blocked_users,
            "eligible_users": eligible_users,
            "active_user_pct": _round(active_window / eligible_users * 100)
            if eligible_users
            else None,
            "window_days": window_days,
        },
        "peak": {
            "users": peak,
            "window_hours": 24,
        },
        "definitions": {
            "active_users": "Distinct accounts with a session heartbeat inside the presence window (300s).",
            "active_sessions": "Open sessions whose last heartbeat is inside the presence window.",
            "dau": "Distinct accounts with a session heartbeat in the last 24 hours.",
            "wau": "Distinct accounts with a session heartbeat in the last 7 days.",
            "mau": "Distinct accounts with a session heartbeat in the last 30 days.",
            "dau_mau": "DAU divided by MAU, a ratio between 0 and 1.",
            "avg_session_seconds": "Mean of (started_at to ended_at) for sessions that ended in the window, capped at 6h.",
            "median_session_seconds": "Median of the same set; less distorted by one long session.",
            "avg_daily_foreground_seconds": "Foreground seconds in the last 7 days divided by distinct active users and by 7.",
            "active_user_pct": "Distinct active users in the population window divided by eligible registered accounts (all accounts minus suspended/banned), times 100.",
            "new_users": "Accounts created inside the population window that also had activity in it.",
            "returning_users": "Active accounts in the window minus the new ones.",
            "peak_concurrent_users": "Highest number of sessions open at one instant in the last 24h.",
        },
        "unavailable": unavailable,
    }


async def series(
    db: AsyncSession, buckets: Iterable[tuple[datetime, datetime]]
) -> list[dict]:
    """Distinct active users per bucket, for GET /admin/analytics/timeseries.

    A user counts in the bucket their session's last heartbeat falls in. The
    series is returned even when every bucket is zero - an empty period is a
    real answer, not a missing one.
    """
    from api.models.activity import UserSession

    buckets = list(buckets)
    if not buckets:
        return []
    start, end = buckets[0][0], buckets[-1][1]
    rows = (
        await db.execute(
            select(UserSession.user_id, UserSession.last_activity_at).where(
                UserSession.last_activity_at >= start,
                UserSession.last_activity_at < end,
            )
        )
    ).all()

    per_bucket: list[set[str]] = [set() for _ in buckets]
    bounds = [b_start for b_start, _ in buckets]
    for user_id, stamp in rows:
        if stamp is None:
            continue
        # bisect over bucket starts: the last bucket whose start <= stamp.
        import bisect

        index = bisect.bisect_right(bounds, stamp) - 1
        if 0 <= index < len(per_bucket):
            per_bucket[index].add(user_id)

    return [
        {"t": b_start.isoformat() + "Z", "v": len(per_bucket[index])}
        for index, (b_start, _) in enumerate(buckets)
    ]
