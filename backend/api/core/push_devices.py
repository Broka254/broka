"""Pushing to every phone a user is signed in on.

  register()     a phone's push token now belongs to this user (and to no
                 one else - see api/models/push_device.py for why)
  unregister()   sign-out: this phone stops getting this user's pushes
                 (unregister_all: signed out everywhere)
  tokens_for()   a user's tokens of one kind, newest first
  push_user()    one notification to each of them at once; a token FCM
                 reports dead is forgotten

The FCM send itself is api.routers.calls._send_fcm, looked up when a push is
sent (not imported once) so there is one sender for the whole backend and a
test that stands in for it stands in for every caller.

The legacy `users.fcm_token` / `users.apns_voip_token` columns are kept in
step: they hold the user's newest phone, because older code (deal reminders
in core/workers.py, escrow protection) still reads them directly. And they
are where a user who has not opened an updated app since this table existed
still has their token, so tokens_for() falls back to them.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime
from typing import Awaitable, Callable, Optional

from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AsyncSessionLocal, User
from api.models.push_device import PushDevice

logger = logging.getLogger(__name__)

KINDS = ("fcm", "apns_voip")

# Phones kept per user and kind. A token that is never reported dead (the
# app was uninstalled on a phone that never came back online) would
# otherwise be pushed to forever; the oldest goes once a user has this many.
MAX_DEVICES_PER_KIND = 5


def _legacy_column(kind: str):
    return User.apns_voip_token if kind == "apns_voip" else User.fcm_token


async def register(
    db: AsyncSession, user_id: str, token: str,
    kind: str = "fcm", platform: Optional[str] = None,
) -> None:
    """This phone (`token`) is now signed in as `user_id`. The caller commits.

    Any other account holding the same token loses it - in this table and in
    the legacy column - which is what stops a shared phone ringing for the
    person who signed out of it.
    """
    token = (token or "").strip()
    if not token or kind not in KINDS:
        return
    now = datetime.utcnow()
    row = await db.get(PushDevice, token)
    if row is None:
        db.add(PushDevice(token=token, user_id=user_id, kind=kind,
                          platform=platform, created_at=now, updated_at=now))
    else:
        row.user_id = user_id
        row.kind = kind
        row.platform = platform or row.platform
        row.updated_at = now

    column = _legacy_column(kind)
    await db.execute(
        update(User).where(column == token, User.id != user_id).values({column: None})
    )
    await db.execute(update(User).where(User.id == user_id).values({column: token}))
    await db.flush()

    stale = (await db.execute(
        select(PushDevice.token)
        .where(PushDevice.user_id == user_id, PushDevice.kind == kind)
        .order_by(PushDevice.updated_at.desc())
        .offset(MAX_DEVICES_PER_KIND)
    )).scalars().all()
    if stale:
        await db.execute(delete(PushDevice).where(PushDevice.token.in_(stale)))


async def unregister(db: AsyncSession, user_id: str, token: str) -> None:
    """Sign-out on one phone: its token stops receiving this user's pushes.
    Only the user's own token - a signed-in user cannot unhook someone
    else's phone by naming its token. The caller commits."""
    token = (token or "").strip()
    if not token:
        return
    await db.execute(delete(PushDevice).where(
        PushDevice.token == token, PushDevice.user_id == user_id))
    for kind in KINDS:
        column = _legacy_column(kind)
        await db.execute(
            update(User).where(User.id == user_id, column == token).values({column: None})
        )


async def unregister_all(db: AsyncSession, user_id: str) -> None:
    """Signed out everywhere: no phone gets this user's pushes any more.
    The caller commits."""
    await db.execute(delete(PushDevice).where(PushDevice.user_id == user_id))
    await db.execute(update(User).where(User.id == user_id).values(
        {User.fcm_token: None, User.apns_voip_token: None}))


async def tokens_for(db: AsyncSession, user_id: str, kind: str = "fcm") -> list[str]:
    """The user's tokens of this kind, newest first. Falls back to the legacy
    column for a user whose app has not registered since this table
    existed."""
    tokens = list((await db.execute(
        select(PushDevice.token)
        .where(PushDevice.user_id == user_id, PushDevice.kind == kind)
        .order_by(PushDevice.updated_at.desc())
        .limit(MAX_DEVICES_PER_KIND)
    )).scalars().all())
    legacy = (await db.execute(
        select(_legacy_column(kind)).where(User.id == user_id)
    )).scalar_one_or_none()
    if legacy and legacy not in tokens:
        # Only while it belongs to nobody in the table: a token that has
        # moved to another account must not be reached through this one.
        owner = (await db.execute(
            select(PushDevice.user_id).where(PushDevice.token == legacy)
        )).scalar_one_or_none()
        if owner is None:
            tokens.append(legacy)
    return tokens


async def forget(token: str) -> None:
    """FCM says this token is permanently dead (app uninstalled, data
    cleared, token rotated): stop pushing to it, everywhere."""
    try:
        async with AsyncSessionLocal() as db:
            await db.execute(delete(PushDevice).where(PushDevice.token == token))
            for kind in KINDS:
                column = _legacy_column(kind)
                await db.execute(update(User).where(column == token).values({column: None}))
            await db.commit()
        logger.info("[push] PUSH_TOKEN_FORGOTTEN token=...%s", token[-6:])
    except Exception as exc:
        logger.warning("[push] could not forget a dead token: %s", exc)


def _default_sender() -> Callable[..., Awaitable]:
    from api.routers import calls
    return calls._send_fcm


async def push_user(
    user_id: str, *, title: str, body: str, data: dict,
    send: Optional[Callable[..., Awaitable]] = None,
    db: Optional[AsyncSession] = None,
    **send_kwargs,
) -> int:
    """Send one FCM notification to every phone `user_id` is signed in on.
    Returns how many accepted it. Never raises.

    The phones are pushed concurrently: a call rings on all of them at
    once, and one slow FCM round trip doesn't hold up the next phone.
    """
    if not user_id:
        return 0
    try:
        if db is not None:
            tokens = await tokens_for(db, user_id)
        else:
            async with AsyncSessionLocal() as own:
                tokens = await tokens_for(own, user_id)
    except Exception as exc:
        logger.warning("[push] could not load devices for user=%s: %s", user_id, exc)
        return 0
    if not tokens:
        logger.debug("[push] user=%s has no push device", user_id)
        return 0

    sender = send or _default_sender()
    results = await asyncio.gather(
        *(sender(token=t, title=title, body=body, data=data, **send_kwargs) for t in tokens),
        return_exceptions=True,
    )
    sent = 0
    for token, result in zip(tokens, results):
        if isinstance(result, BaseException):
            logger.warning("[push] send raised for user=%s: %s", user_id, result)
            continue
        if result:
            sent += 1
        elif getattr(result, "unregistered", False):
            await forget(token)
    return sent
