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
import hashlib
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


def token_fingerprint(token: str) -> str:
    """A short, stable label for a device token in logs.

    An FCM token is a credential - anyone holding it can push to that phone -
    so it must never reach a log line. A truncated hash still lets two lines
    about the same phone be tied together while diagnosing a delivery
    problem. Ten hex characters distinguish far more tokens than this
    deployment will ever hold and reveal nothing usable.
    """
    return hashlib.sha256((token or "").encode("utf-8")).hexdigest()[:10]


async def _remove_own_token(db: AsyncSession, user_id: str, token: str) -> int:
    """Delete `token` only while this user owns it, and unhook the legacy
    column it fills. Returns how many device rows went."""
    result = await db.execute(delete(PushDevice).where(
        PushDevice.token == token, PushDevice.user_id == user_id))
    for kind in KINDS:
        column = _legacy_column(kind)
        await db.execute(
            update(User).where(User.id == user_id, column == token).values({column: None})
        )
    return result.rowcount or 0


async def register(
    db: AsyncSession, user_id: str, token: str,
    kind: str = "fcm", platform: Optional[str] = None,
    previous_token: Optional[str] = None,
) -> bool:
    """This phone (`token`) is now signed in as `user_id`. The caller commits.

    Any other account holding the same token loses it - in this table and in
    the legacy column - which is what stops a shared phone ringing for the
    person who signed out of it.

    `previous_token` is the token this same phone had before a refresh. It is
    only ever removed while `user_id` owns it, so one account cannot delete
    another's registration by naming a token in the request.

    Returns False when there is nothing registrable (empty token or unknown
    kind) rather than pretending a registration happened.
    """
    token = (token or "").strip()
    if not token or kind not in KINDS:
        logger.warning(
            "[push] TOKEN_REGISTER_REJECTED user=%s kind=%s reason=%s",
            user_id, kind, "empty_token" if not token else "unknown_kind",
        )
        return False
    previous_token = (previous_token or "").strip()
    now = datetime.utcnow()
    row = await db.get(PushDevice, token)
    if row is None:
        db.add(PushDevice(token=token, user_id=user_id, kind=kind,
                          platform=platform, created_at=now, updated_at=now))
        outcome = "registered"
        transfer_from = None
    else:
        # A token belongs to exactly one account. Seeing it move is the
        # difference between a shared phone changing hands and one account
        # mysteriously losing calls.
        transfer_from = row.user_id if row.user_id != user_id else None
        outcome = "transferred" if transfer_from else "refreshed"
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

    if previous_token and previous_token != token:
        rotated = await _remove_own_token(db, user_id, previous_token)
        logger.info(
            "[push] TOKEN_ROTATED user=%s kind=%s old=%s new=%s removed=%s",
            user_id, kind, token_fingerprint(previous_token),
            token_fingerprint(token), rotated,
        )

    stale = (await db.execute(
        select(PushDevice.token)
        .where(PushDevice.user_id == user_id, PushDevice.kind == kind)
        .order_by(PushDevice.updated_at.desc())
        .offset(MAX_DEVICES_PER_KIND)
    )).scalars().all()
    if stale:
        await db.execute(delete(PushDevice).where(PushDevice.token.in_(stale)))

    logger.info(
        "[push] TOKEN_%s user=%s kind=%s token=%s%s",
        outcome.upper(), user_id, kind, token_fingerprint(token),
        f" previous_user={transfer_from}" if transfer_from else "",
    )
    return True


async def unregister(db: AsyncSession, user_id: str, token: str) -> None:
    """Sign-out on one phone: its token stops receiving this user's pushes.
    Only the user's own token - a signed-in user cannot unhook someone
    else's phone by naming its token. The caller commits."""
    token = (token or "").strip()
    if not token:
        logger.warning("[push] TOKEN_UNREGISTER_REJECTED user=%s reason=empty_token",
                       user_id)
        return
    removed = await _remove_own_token(db, user_id, token)
    logger.info("[push] TOKEN_UNREGISTERED user=%s token=%s removed=%s",
                user_id, token_fingerprint(token), removed)


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
    # Fingerprints, never tokens: this line exists to answer "did the
    # recipient have a route at the moment of the send?" from production logs.
    if tokens:
        logger.info(
            "[push] TOKENS_FOUND user=%s kind=%s count=%d tokens=%s",
            user_id, kind, len(tokens),
            ",".join(token_fingerprint(t) for t in tokens),
        )
    else:
        logger.info("[push] NO_TOKENS user=%s kind=%s", user_id, kind)
    return tokens


async def forget(token: str, reason: str = "unregistered") -> None:
    """FCM says this token is permanently dead (app uninstalled, data
    cleared, token rotated): stop pushing to it, everywhere."""
    try:
        async with AsyncSessionLocal() as db:
            await db.execute(delete(PushDevice).where(PushDevice.token == token))
            for kind in KINDS:
                column = _legacy_column(kind)
                await db.execute(update(User).where(column == token).values({column: None}))
            await db.commit()
        logger.info("[push] dead device token forgotten token=%s reason=%s",
                    token_fingerprint(token), reason)
    except Exception as exc:
        logger.warning("[push] could not forget a dead token token=%s: %s",
                       token_fingerprint(token), type(exc).__name__)


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
        # The exception string from a push path can quote a token or the
        # notification body; the type is enough to tell a lookup bug from an
        # outage.
        logger.warning("[push] could not load devices for user=%s: %s",
                       user_id, type(exc).__name__)
        return 0
    if not tokens:
        logger.info("[push] PUSH_NO_DEVICES user=%s route=%s",
                    user_id, data.get("type") or "generic")
        return 0

    sender = send or _default_sender()
    results = await asyncio.gather(
        *(sender(token=t, title=title, body=body, data=data, **send_kwargs) for t in tokens),
        return_exceptions=True,
    )
    sent = 0
    for token, result in zip(tokens, results):
        if isinstance(result, BaseException):
            logger.warning("[push] send raised for user=%s token=%s type=%s",
                           user_id, token_fingerprint(token), type(result).__name__)
            continue
        if result:
            sent += 1
        elif getattr(result, "unregistered", False):
            # Only a dead registration reaches here: a sender/project
            # mismatch or a transient provider failure must leave the token
            # alone, or a misconfigured deployment would quietly delete
            # every phone it cannot push to.
            await forget(token, reason="fcm_unregistered")
    route = str(data.get("type") or "generic")
    log = logger.info if route in ("incoming_call", "missed_call") else logger.debug
    log("[push] PUSH_RESULT user=%s route=%s tokens=%d accepted=%d",
        user_id, route, len(tokens), sent)
    return sent
