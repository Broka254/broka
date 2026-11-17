"""Order updates: the in-app feed, and the pushes sent from it.

PERSIST FIRST, THEN TELL
========================
An order event and its store_order_notifications rows are written in the
same transaction as the change they announce (service.py). Only after that
commit does anything try to reach a phone, so a push that fails - no
Firebase, a dead token, FCM down - can never undo an order, and an order
that did not commit is never announced.

AT MOST ONE PUSH PER CLAIM
==========================
Every send first claims its row with a conditional UPDATE (push_state still
'pending', no live claim), so the request that made the row and a sweep on
another replica cannot both send it. A transient failure leaves the row
pending for the sweep (task_store_order_sweep, every five minutes) until
MAX_ATTEMPTS; a person with no phone signed in is 'no_device' and not
retried - they see the update in the feed when they next look. The rows are
unique per (event, recipient), so a retried request cannot create a second.

No database transaction is open while FCM is called: each step uses its own
short session and ends it before the network call (AGENTS.md).
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Iterable, Optional

from sqlalchemy import func, or_, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.store_order import StoreOrder, StoreOrderNotification

logger = logging.getLogger(__name__)

PUSH_TYPE = "store_order"
MAX_ATTEMPTS = 5
CLAIM_SECONDS = 120
RETRY_WINDOW = timedelta(hours=24)
_PAGE_MAX = 100


async def deliver(notification_ids: Iterable[str]) -> None:
    """Push each of these notifications that is still due. Never raises."""
    for nid in list(dict.fromkeys(notification_ids)):
        try:
            await _deliver_one(nid)
        except Exception as exc:  # noqa: BLE001 - one bad row must not stop the rest
            logger.warning("[store_orders] push for %s failed: %s", nid, type(exc).__name__)


async def _deliver_one(nid: str) -> None:
    from api.database import AsyncSessionLocal

    now = datetime.utcnow()
    stale = now - timedelta(seconds=CLAIM_SECONDS)
    async with AsyncSessionLocal() as db:
        claimed = await db.execute(
            update(StoreOrderNotification)
            .where(
                StoreOrderNotification.id == nid,
                StoreOrderNotification.push_state == "pending",
                or_(StoreOrderNotification.push_claimed_at.is_(None),
                    StoreOrderNotification.push_claimed_at < stale),
            )
            .values(push_claimed_at=now, push_attempts=StoreOrderNotification.push_attempts + 1)
            .execution_options(synchronize_session=False)
        )
        await db.commit()
        if claimed.rowcount != 1:
            return
        row = (await db.execute(
            select(
                StoreOrderNotification.recipient_id, StoreOrderNotification.recipient_role,
                StoreOrderNotification.title, StoreOrderNotification.body,
                StoreOrderNotification.order_id, StoreOrderNotification.kind,
                StoreOrderNotification.push_attempts, StoreOrder.status,
            )
            .join(StoreOrder, StoreOrder.id == StoreOrderNotification.order_id)
            .where(StoreOrderNotification.id == nid)
        )).one()
        await db.commit()  # ends the read: nothing is held through the push

    recipient_id, role, title, body, order_id, kind, attempts, status = row
    from api.core import push_devices

    outcome = push_devices.PushOutcome()
    sent = 0
    raised = False
    try:
        sent = await push_devices.push_user(
            recipient_id, title=title, body=body,
            data={
                "type": PUSH_TYPE,
                "order_id": order_id,
                "status": status,
                "event": kind,
                "role": role,
                "screen": "store_order",
                "title": title,
                "body": body,
            },
            outcome=outcome,
            android_channel_id="broka_updates",
            # One notification per order on the phone: the latest update
            # replaces the one before it instead of stacking.
            android_tag=f"store_order:{order_id}",
        )
    except Exception as exc:  # noqa: BLE001 - push_user should not raise; if it does, retry later
        raised = True
        logger.warning("[store_orders] push raised for %s: %s", nid, type(exc).__name__)

    if sent:
        state = "sent"
    elif (raised or outcome.retryable) and attempts < MAX_ATTEMPTS:
        state = "pending"
    elif outcome.error == "NO_DEVICES":
        state = "no_device"
    else:
        state = "failed"
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(StoreOrderNotification)
            .where(StoreOrderNotification.id == nid)
            .values(
                push_state=state,
                pushed_at=datetime.utcnow() if sent else None,
                # A retry is due at the next sweep, not after the claim ages out.
                push_claimed_at=None if state == "pending" else now,
            )
            .execution_options(synchronize_session=False)
        )
        await db.commit()


async def retry_pending(limit: int = 100) -> int:
    """The sweep: send what is still pending, and give up on what has
    waited past RETRY_WINDOW - an order update a day late is noise."""
    from api.database import AsyncSessionLocal

    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        await db.execute(
            update(StoreOrderNotification)
            .where(StoreOrderNotification.push_state == "pending",
                   StoreOrderNotification.created_at < now - RETRY_WINDOW)
            .values(push_state="failed")
            .execution_options(synchronize_session=False)
        )
        ids = (await db.execute(
            select(StoreOrderNotification.id)
            .where(
                StoreOrderNotification.push_state == "pending",
                StoreOrderNotification.created_at >= now - RETRY_WINDOW,
                or_(StoreOrderNotification.push_claimed_at.is_(None),
                    StoreOrderNotification.push_claimed_at < now - timedelta(seconds=CLAIM_SECONDS)),
            )
            .order_by(StoreOrderNotification.created_at)
            .limit(limit)
        )).scalars().all()
        await db.commit()
    await deliver(ids)
    return len(ids)


# ── The feed ────────────────────────────────────────────────────────────────

def _view(n: StoreOrderNotification) -> dict:
    return {
        "id": n.id,
        "order_id": n.order_id,
        "kind": n.kind,
        "role": n.recipient_role,
        "title": n.title,
        "body": n.body,
        "created_at": n.created_at.isoformat() + "Z" if n.created_at else None,
        "read": n.read_at is not None,
    }


async def unread_count(db: AsyncSession, user_id: str) -> int:
    return int((await db.execute(
        select(func.count()).select_from(StoreOrderNotification).where(
            StoreOrderNotification.recipient_id == user_id,
            StoreOrderNotification.read_at.is_(None),
        )
    )).scalar_one() or 0)


async def feed(db: AsyncSession, user_id: str, *, unread_only: bool = False,
               order_id: Optional[str] = None, limit: int = 30, offset: int = 0) -> dict:
    q = select(StoreOrderNotification).where(StoreOrderNotification.recipient_id == user_id)
    if unread_only:
        q = q.where(StoreOrderNotification.read_at.is_(None))
    if order_id:
        q = q.where(StoreOrderNotification.order_id == order_id)
    rows = (await db.execute(
        q.order_by(StoreOrderNotification.created_at.desc())
        .offset(offset).limit(max(1, min(limit, _PAGE_MAX)))
    )).scalars().all()
    return {"items": [_view(n) for n in rows], "unread": await unread_count(db, user_id)}


async def mark_read(db: AsyncSession, user_id: str, *, ids: Optional[list[str]] = None,
                    order_id: Optional[str] = None, everything: bool = False) -> int:
    """Mark the caller's own notifications read - by id, by order or all.
    Someone else's ids match nothing: the recipient is part of the WHERE."""
    if not ids and not order_id and not everything:
        return 0
    q = update(StoreOrderNotification).where(
        StoreOrderNotification.recipient_id == user_id,
        StoreOrderNotification.read_at.is_(None),
    )
    if ids:
        q = q.where(StoreOrderNotification.id.in_(ids[:_PAGE_MAX]))
    if order_id:
        q = q.where(StoreOrderNotification.order_id == order_id)
    result = await db.execute(q.values(read_at=datetime.utcnow()).execution_options(synchronize_session=False))
    await db.commit()
    return int(result.rowcount or 0)
