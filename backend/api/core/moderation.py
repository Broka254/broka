"""Account moderation: the enforcement side of flagging.

`is_flagged` marks risk. It must never be confused with suspension: a flagged
seller is still a signed-in seller. This module owns the account state that
actually decides whether a request is served.

States (`users.account_status`):

* ``active``      - normal account.
* ``restricted``  - signed in, transactional permissions removed while an
                   investigation runs (api/core/permissions.py). Not blocked.
* ``suspended``   - cannot sign in and cannot use an existing access token.
                   ``suspended_until`` NULL means permanent; a timestamp means
                   it lapses back to ``active`` on its own.
* ``banned``      - recognised as blocked for compatibility; suspension writes
                   ``suspended``.

Every transition appends a `user_moderation_actions` row and an audit row, and
revokes refresh tokens plus every open session. `api/core/account_guard.py`
enforces the state on ordinary requests, so blocking login is not the only
line of defence.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

ACTIVE = "active"
RESTRICTED = "restricted"
SUSPENDED = "suspended"
BANNED = "banned"

BLOCKED_STATUSES = (SUSPENDED, BANNED)
STATUSES = (ACTIVE, RESTRICTED, SUSPENDED, BANNED)

# How long a process trusts its cached answer to "is this account blocked".
# Short enough that a suspension made by another replica lands quickly, long
# enough that an ordinary request does not cost a database query.
VERDICT_TTL_SECONDS = 15.0

_verdicts: dict[str, tuple[float, dict]] = {}


def _naive(value: Optional[datetime]) -> Optional[datetime]:
    if value is None or value.tzinfo is None:
        return value
    return value.astimezone(timezone.utc).replace(tzinfo=None)


def _effective(status_value: Optional[str], until: Optional[datetime], now: datetime) -> str:
    value = (status_value or ACTIVE).lower()
    until = _naive(until)
    if value in BLOCKED_STATUSES and until is not None and until <= now:
        return ACTIVE
    return value


def effective_status(user, now: Optional[datetime] = None) -> str:
    """The status that applies right now.

    A temporary suspension lapses without a worker: reading it after its
    expiry answers ``active`` even before any sweep has tidied the row.
    """
    now = now or datetime.utcnow()
    return _effective(
        getattr(user, "account_status", None),
        getattr(user, "suspended_until", None),
        now,
    )


def is_blocked(user, now: Optional[datetime] = None) -> bool:
    return effective_status(user, now) in BLOCKED_STATUSES


def account_state(user, now: Optional[datetime] = None) -> dict:
    """Serialisable moderation state, for the admin API and the dashboard."""
    now = now or datetime.utcnow()
    state = effective_status(user, now)
    until = _naive(getattr(user, "suspended_until", None))
    return {
        "status": state,
        "blocked": state in BLOCKED_STATUSES,
        "permanent": state in BLOCKED_STATUSES and until is None,
        "reason": getattr(user, "suspension_reason", None),
        "suspended_at": _naive(getattr(user, "suspended_at", None)),
        "suspended_until": until,
        "suspended_by": getattr(user, "suspended_by", None),
        "reinstated_at": _naive(getattr(user, "reinstated_at", None)),
        "reinstated_by": getattr(user, "reinstated_by", None),
        "flagged": bool(getattr(user, "is_flagged", False)),
        "trust_score": getattr(user, "trust_score", None),
    }


def assert_can_sign_in(user) -> None:
    """Raise 403 for a blocked account. Called from every sign-in path."""
    if user is None:
        return
    state = effective_status(user)
    if state in BLOCKED_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "This account is suspended. Contact BROKA support if you "
                "believe this is a mistake."
            ),
        )


async def enforce_account_row(db: AsyncSession, user_id: str) -> None:
    """Raise for a blocked account, reading the row rather than an object.

    Used by paths that issue credentials (refresh) and so must not accept a
    stale user instance.
    """
    from api.database import User

    row = (
        await db.execute(
            select(User.account_status, User.suspended_until).where(User.id == user_id)
        )
    ).first()
    if row is None:
        return
    if _effective(row[0], row[1], datetime.utcnow()) in BLOCKED_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This account is suspended.",
        )


# ── Cached verdict for the request guard ─────────────────────────────────────

async def blocked_verdict(user_id: str) -> Optional[dict]:
    """{"blocked", "status", "revoked_before"} for `user_id`, cached briefly.

    Returns None when the account does not exist, which leaves the route's own
    401/404 in charge - this guard must not become the place an unknown id is
    rejected.
    """
    now_mono = time.monotonic()
    hit = _verdicts.get(user_id)
    if hit is not None and hit[0] > now_mono:
        return hit[1]

    from api.database import AsyncSessionLocal, User

    async with AsyncSessionLocal() as db:
        row = (
            await db.execute(
                select(
                    User.account_status,
                    User.suspended_until,
                    User.sessions_revoked_at,
                ).where(User.id == user_id)
            )
        ).first()

    if row is None:
        verdict = None
    else:
        account_status, suspended_until, revoked_at = row
        verdict = {
            "blocked": _effective(account_status, suspended_until, datetime.utcnow())
            in BLOCKED_STATUSES,
            "status": account_status or ACTIVE,
            "revoked_before": _naive(revoked_at),
        }
    _verdicts[user_id] = (now_mono + VERDICT_TTL_SECONDS, verdict)
    return verdict


def invalidate_verdict(user_id: str) -> None:
    """Forget a cached verdict after this process changed the account."""
    _verdicts.pop(user_id, None)


# ── Transitions ──────────────────────────────────────────────────────────────

def _suspension_window(
    mode: str, duration_hours: Optional[int], now: datetime
) -> Optional[datetime]:
    if mode == "permanent":
        return None
    if mode != "temporary":
        raise HTTPException(status_code=422, detail="mode must be temporary or permanent")
    if duration_hours is None or duration_hours < 1 or duration_hours > 24 * 365:
        raise HTTPException(
            status_code=422,
            detail="duration_hours must be between 1 and 8760 for a temporary suspension",
        )
    return now + timedelta(hours=duration_hours)


async def suspend_user(
    db: AsyncSession,
    *,
    user,
    actor_id: str,
    mode: str,
    duration_hours: Optional[int],
    reason: str,
    notes: Optional[str] = None,
    ip_address: Optional[str] = None,
    now: Optional[datetime] = None,
) -> dict:
    """Suspend `user`, revoke its sessions and record why.

    The caller commits. Nothing here deletes data or touches money - a
    suspension is access control, and it is reversible.
    """
    from api.core.audit import record_audit
    from api.core.activity import close_session
    from api.models.activity import UserModerationAction

    now = now or datetime.utcnow()
    if user.id == actor_id:
        # Self-suspension locks the administrator out of the workflow that
        # would undo it, without any other administrator present.
        raise HTTPException(
            status_code=409, detail="You cannot suspend your own account"
        )
    if bool(getattr(user, "is_admin", False)):
        raise HTTPException(
            status_code=409,
            detail="Administrator accounts cannot be suspended through the moderation workflow",
        )

    until = _suspension_window(mode, duration_hours, now)
    previous = effective_status(user, now)
    if previous in BLOCKED_STATUSES:
        raise HTTPException(
            status_code=409, detail="This account is already suspended"
        )

    user.account_status = SUSPENDED
    user.suspended_until = until
    user.suspension_reason = reason
    user.suspended_at = now
    user.suspended_by = actor_id
    user.sessions_revoked_at = now

    closed = await close_session(db, user.id, reason="suspended", now=now)

    try:
        from api.domains.auth.refresh_router import revoke_all_refresh_tokens

        await revoke_all_refresh_tokens(db, user.id)
    except Exception:  # pragma: no cover - a token table that predates this
        logger.exception("[moderation] could not revoke refresh tokens for %s", user.id)

    db.add(
        UserModerationAction(
            user_id=user.id,
            action="suspend",
            new_status=SUSPENDED,
            previous_status=previous,
            actor_id=actor_id,
            reason=reason,
            notes=notes,
            duration_hours=duration_hours if until is not None else None,
            expires_at=until,
            created_at=now,
        )
    )
    await record_audit(
        db,
        actor_id,
        "user_suspended",
        "user",
        user.id,
        detail=f"{mode} suspension: {reason}"
        + (f" (until {until.isoformat()}Z)" if until else " (permanent)")
        + (f". Notes: {notes}" if notes else ""),
        ip_address=ip_address,
    )
    invalidate_verdict(user.id)
    logger.info(
        "[moderation] user=%s suspended mode=%s until=%s sessions_closed=%s actor=%s",
        user.id, mode, until, closed, actor_id,
    )
    return {**account_state(user, now), "sessions_closed": closed}


async def reinstate_user(
    db: AsyncSession,
    *,
    user,
    actor_id: str,
    reason: str,
    notes: Optional[str] = None,
    ip_address: Optional[str] = None,
    now: Optional[datetime] = None,
) -> dict:
    """Return a suspended account to active. The caller commits."""
    from api.core.audit import record_audit
    from api.models.activity import UserModerationAction

    now = now or datetime.utcnow()
    previous = effective_status(user, now)

    user.account_status = ACTIVE
    user.suspended_until = None
    user.reinstated_at = now
    user.reinstated_by = actor_id
    # The reason stays on the row: reinstatement does not erase why the
    # account was suspended, and the history below is the full record anyway.

    db.add(
        UserModerationAction(
            user_id=user.id,
            action="reinstate",
            new_status=ACTIVE,
            previous_status=previous,
            actor_id=actor_id,
            reason=reason,
            notes=notes,
            created_at=now,
        )
    )
    await record_audit(
        db,
        actor_id,
        "user_reinstated",
        "user",
        user.id,
        detail=reason + (f". Notes: {notes}" if notes else ""),
        ip_address=ip_address,
    )
    invalidate_verdict(user.id)
    logger.info("[moderation] user=%s reinstated actor=%s", user.id, actor_id)
    return account_state(user, now)


async def moderation_history(db: AsyncSession, user_id: str, limit: int = 50) -> list[dict]:
    from api.models.activity import UserModerationAction

    rows = (
        await db.execute(
            select(UserModerationAction)
            .where(UserModerationAction.user_id == user_id)
            .order_by(UserModerationAction.created_at.desc())
            .limit(limit)
        )
    ).scalars().all()
    return [
        {
            "id": row.id,
            "action": row.action,
            "previous_status": row.previous_status,
            "new_status": row.new_status,
            "actor_id": row.actor_id,
            "reason": row.reason,
            "notes": row.notes,
            "duration_hours": row.duration_hours,
            "expires_at": row.expires_at,
            "created_at": row.created_at,
        }
        for row in rows
    ]
