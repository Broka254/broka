"""Zeno's daily sessions: what an account without a plan may use each day.

A free account asks Zeno about ZENO_FREE_LISTING_SESSIONS_PER_DAY listings
and starts ZENO_FREE_AGENT_SESSIONS_PER_DAY Buying Agent hunts a day (two
each by default). The unit is a session, not a message:

  * a LISTING session is every question about one listing that day - "Is
    this a fair price?", then "and the seller?", then "find me something
    similar" is one use, however many turns it takes;
  * an AGENT session is one hunt - the Buying Agent's questions, its
    searches and every refinement after them. A hunt begins with a turn
    that has no conversation before it (a first message, "New chat", a
    request from Home); a turn that carries one continues the newest hunt
    of the day;
  * a hunt handed over from a listing ("Find me something similar") is
    part of that listing's session: it is recorded with the listing session
    as its parent and is not counted again.

Midnight in Kenya renews them, the same clock as the daily voice requests
(entitlements.day_key). Plan holders are never counted - their sessions are
recorded with no slot. This is counted whatever PREMIUM_ENABLED says: with
it off nobody can buy a plan, so the refusal says when the sessions come
back instead of offering one.

A session is taken before the model is paid for (admit_*), and given back
(release) when the turn that opened it failed - an answer the user never
got is not a use. The day's limit holds under two taps at once because a
counted session takes the lowest free `slot`, and the unique (user, kind,
day, slot) index lets only one request have each.
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.models.zeno_session import ZenoSession

logger = logging.getLogger(__name__)

LISTING = "listing"
AGENT = "agent"

# Kenya is UTC+3 all year: a day's sessions renew at its midnight.
_KENYA = timedelta(hours=3)

# The key a hunt handed over from a listing is filed under, so every turn
# of that hunt finds the same session.
_FROM_LISTING = "listing:"


@dataclass(frozen=True)
class Admission:
    """The session a turn belongs to.

    `opened`: this turn started it, so a failed turn gives it back.
    `counted`: it took one of today's free sessions.
    """
    session_id: Optional[str]
    opened: bool = False
    counted: bool = False


def _now() -> datetime:
    """Naive UTC now - one place, so a test can move the clock."""
    return datetime.utcnow()


def kenya_day(now: datetime) -> str:
    """Today in Kenya, for naive UTC `now`."""
    return f"{(now + _KENYA):%Y-%m-%d}"


def renews_at(now: datetime) -> datetime:
    """The next midnight in Kenya, as naive UTC."""
    local = now + _KENYA
    return datetime(local.year, local.month, local.day) + timedelta(days=1) - _KENYA


def limit_for(kind: str) -> int:
    if kind == LISTING:
        return settings.zeno_free_listing_sessions_per_day
    return settings.zeno_free_agent_sessions_per_day


async def _has_plan(db: AsyncSession, user_id: str, now: datetime) -> bool:
    """A paid plan running now - whether or not plans are on sale."""
    from api.domains.premium.entitlements import active_subscription
    return await active_subscription(db, user_id, now) is not None


async def _find(db: AsyncSession, user_id: str, kind: str, key: str, day: str) -> Optional[ZenoSession]:
    return (await db.execute(
        select(ZenoSession).where(
            ZenoSession.user_id == user_id, ZenoSession.kind == kind,
            ZenoSession.session_key == key, ZenoSession.day == day,
        )
    )).scalar_one_or_none()


async def _touch(db: AsyncSession, row: ZenoSession, now: datetime) -> None:
    """One more turn in a session already open."""
    await db.execute(
        update(ZenoSession)
        .where(ZenoSession.id == row.id)
        .values(turns=ZenoSession.turns + 1, last_turn_at=now)
        .execution_options(synchronize_session=False)
    )
    await db.commit()


async def _open(
    db: AsyncSession, *, user_id: str, kind: str, key: str, day: str, now: datetime,
    counted: bool, parent_id: Optional[str] = None,
) -> tuple[Optional[ZenoSession], bool]:
    """Write the session row: (row, opened by this call). A counted one
    takes the lowest free slot; (None, False) when today's are all taken.

    Two requests racing: one for the same session gets the row the other
    wrote (opened False); one for another session at the same moment loses
    the slot and tries the next one free.
    """
    limit = limit_for(kind)
    for _ in range(limit + 3):
        slot = None
        if counted:
            taken = set((await db.execute(
                select(ZenoSession.slot).where(
                    ZenoSession.user_id == user_id, ZenoSession.kind == kind,
                    ZenoSession.day == day, ZenoSession.slot.is_not(None),
                )
            )).scalars().all())
            free = [n for n in range(1, limit + 1) if n not in taken]
            if not free:
                return None, False
            slot = free[0]
        row = ZenoSession(
            user_id=user_id, kind=kind, session_key=key[:80], day=day, slot=slot,
            parent_id=parent_id, turns=1, created_at=now, last_turn_at=now,
        )
        try:
            # A savepoint, not a rollback of the caller's transaction: only
            # this insert is undone when it loses a race.
            async with db.begin_nested():
                db.add(row)
            await db.commit()
            return row, True
        except IntegrityError:
            existing = await _find(db, user_id, kind, key[:80], day)
            if existing is not None:
                return existing, False
    return None, False


def refusal(kind: str, now: Optional[datetime] = None) -> HTTPException:
    """The 402 for a free account that has used today's sessions of `kind`.

    {"code": "ZENO_SESSIONS_USED", "message", "feature", "plan", "upgrade_to",
    "limit", "renews_at"}: the shape of every premium refusal
    (entitlements._refusal), so older app builds show the message as it is.
    `upgrade_to` is a plan only while plans are on sale.
    """
    from api.domains.pricing.plans import PREMIUM_PLANS

    now = now or _now()
    limit = limit_for(kind)
    up = PREMIUM_PLANS[0] if settings.premium_enabled and PREMIUM_PLANS else None
    if kind == LISTING:
        if limit <= 0:
            used = "Asking Zeno about a listing isn't included on a free account right now."
        else:
            used = (f"You've asked Zeno about {limit} listing{'s' if limit != 1 else ''} today - "
                    f"the free limit. Every question about a listing counts once a day, "
                    f"and they renew at midnight.")
        more = " Ask about as many as you like with BROKA {plan}, from KES {price} a month."
    else:
        if limit <= 0:
            used = "The Buying Agent isn't included on a free account right now."
        else:
            used = (f"You've used today's {limit} free Buying Agent hunt{'s' if limit != 1 else ''}. "
                    f"A hunt counts once however long it runs, and they renew at midnight.")
        more = " With BROKA {plan}, from KES {price} a month, Zeno hunts as often as you like."
    message = used + (more.format(plan=up.name, price=up.monthly_price) if up else "")
    return HTTPException(status_code=402, detail={
        "code": "ZENO_SESSIONS_USED",
        "message": message,
        "feature": f"zeno_{kind}_sessions",
        "plan": None,
        "upgrade_to": up.id if up else None,
        "limit": limit,
        "renews_at": renews_at(now).isoformat(),
    })


async def admit_listing(
    db: AsyncSession, user_id: str, listing_id: str, now: Optional[datetime] = None,
) -> Admission:
    """A turn asking Zeno about someone else's listing: today's session for
    that listing, opened if this is its first question. Raises the 402 when
    a free account has none left."""
    now = now or _now()
    day = kenya_day(now)
    existing = await _find(db, user_id, LISTING, listing_id, day)
    if existing is not None:
        await _touch(db, existing, now)
        return Admission(existing.id, opened=False, counted=existing.slot is not None)
    counted = not await _has_plan(db, user_id, now)
    row, opened = await _open(db, user_id=user_id, kind=LISTING, key=listing_id,
                              day=day, now=now, counted=counted)
    if row is None:
        raise refusal(LISTING, now)
    return Admission(row.id, opened=opened, counted=row.slot is not None)


async def admit_agent(
    db: AsyncSession, user_id: str, *, fresh: bool,
    from_listing_id: Optional[str] = None, now: Optional[datetime] = None,
) -> Admission:
    """A Buying Agent turn: the hunt it belongs to.

    `fresh`: the turn has no conversation before it, so it starts a hunt.
    `from_listing_id`: the hunt was handed over from questions about that
    listing - part of today's session for it, when there is one.
    """
    now = now or _now()
    day = kenya_day(now)
    if from_listing_id:
        parent = await _find(db, user_id, LISTING, from_listing_id, day)
        if parent is not None:
            key = f"{_FROM_LISTING}{from_listing_id}"
            existing = await _find(db, user_id, AGENT, key[:80], day)
            if existing is not None:
                await _touch(db, existing, now)
                return Admission(existing.id, opened=False, counted=False)
            row, opened = await _open(db, user_id=user_id, kind=AGENT, key=key, day=day,
                                      now=now, counted=False, parent_id=parent.id)
            return Admission(row.id if row else None, opened=opened, counted=False)
        # No session for that listing today (it was yesterday's): an
        # ordinary hunt.
    if not fresh:
        latest = (await db.execute(
            select(ZenoSession).where(
                ZenoSession.user_id == user_id, ZenoSession.kind == AGENT, ZenoSession.day == day,
            ).order_by(ZenoSession.last_turn_at.desc()).limit(1)
        )).scalar_one_or_none()
        if latest is not None:
            await _touch(db, latest, now)
            return Admission(latest.id, opened=False, counted=latest.slot is not None)
    counted = not await _has_plan(db, user_id, now)
    row, opened = await _open(db, user_id=user_id, kind=AGENT, key=uuid.uuid4().hex,
                              day=day, now=now, counted=counted)
    if row is None:
        raise refusal(AGENT, now)
    return Admission(row.id, opened=opened, counted=row.slot is not None)


async def release(db: AsyncSession, admission: Optional[Admission]) -> None:
    """Give a session back: the turn that opened it got no answer.

    Only a session nothing else has used since (one turn) - a second
    question that went through meanwhile has made it a real use. Never
    raises: it runs on the way out of a failed turn.
    """
    if admission is None or not admission.opened or not admission.session_id:
        return
    # Twice at most: the first attempt fails only when the failed turn left
    # the transaction unusable, and a rollback is what clears that.
    for attempt in (1, 2):
        try:
            await db.execute(
                delete(ZenoSession).where(ZenoSession.id == admission.session_id,
                                          ZenoSession.turns <= 1)
            )
            await db.commit()
            return
        except Exception as exc:
            try:
                await db.rollback()
            except Exception:
                pass
            if attempt == 2:
                logger.warning("[zeno_sessions] could not give back session %s: %s",
                               admission.session_id, type(exc).__name__)


async def today(db: AsyncSession, user_id: str, now: Optional[datetime] = None) -> dict:
    """GET /zeno/sessions/today: what is used and left of today's sessions.

    {"limited", "day", "renews_at", "listing": {"limit", "used", "left",
    "listing_ids"}, "agent": {"limit", "used", "left"}}. With a plan,
    `limited` is false and limit/left are null: nothing is counted.
    `listing_ids` are the listings already asked about today - asking about
    one of them again costs nothing.
    """
    now = now or _now()
    day = kenya_day(now)
    rows = (await db.execute(
        select(ZenoSession.kind, ZenoSession.session_key, ZenoSession.slot).where(
            ZenoSession.user_id == user_id, ZenoSession.day == day,
        )
    )).all()
    planned = await _has_plan(db, user_id, now)

    def part(kind: str) -> dict:
        used = sum(1 for k, _key, slot in rows if k == kind and slot is not None)
        limit = limit_for(kind)
        return {
            "limit": None if planned else limit,
            "used": used,
            "left": None if planned else max(0, limit - used),
        }

    listing = part(LISTING)
    listing["listing_ids"] = sorted({key for k, key, _slot in rows if k == LISTING})
    return {
        "limited": not planned,
        "day": day,
        "renews_at": renews_at(now).isoformat(),
        "listing": listing,
        "agent": part(AGENT),
    }
