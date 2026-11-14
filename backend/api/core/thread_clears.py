"""Reading and writing "deleted for me" (models/thread_clear.py).

Every surface that shows one person a conversation asks `cleared_at` for
their side and leaves out what was sent up to it: the inbox, the history
routes, the chat sockets' replay, the unread counts. The offline sync needs
no filter: deleting a chat settles what was still waiting for that person
(negotiate.clear_conversation), so nothing deleted is handed out again.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.thread_clear import ThreadClear


def _thread(listing_id: Optional[str], store_id: Optional[str]):
    if store_id and not listing_id:
        return ThreadClear.store_id == store_id
    return ThreadClear.listing_id == listing_id


async def cleared_at(
    db: AsyncSession, user_id: str, *, buyer_id: Optional[str],
    listing_id: Optional[str] = None, store_id: Optional[str] = None,
) -> Optional[datetime]:
    """When `user_id` last deleted this conversation, or None."""
    if not user_id or not buyer_id or not (listing_id or store_id):
        return None
    return (await db.execute(
        select(ThreadClear.cleared_at).where(
            ThreadClear.user_id == user_id,
            ThreadClear.buyer_id == buyer_id,
            _thread(listing_id, store_id),
        )
    )).scalar_one_or_none()


async def clears_for(db: AsyncSession, user_id: str) -> dict:
    """Every conversation `user_id` has deleted, for the inbox's one pass:
    {("listing", listing_id, buyer_id) | ("store", store_id, buyer_id): at}."""
    rows = (await db.execute(
        select(ThreadClear.listing_id, ThreadClear.store_id,
               ThreadClear.buyer_id, ThreadClear.cleared_at)
        .where(ThreadClear.user_id == user_id)
    )).all()
    out: dict = {}
    for listing_id, store_id, buyer_id, at in rows:
        if listing_id:
            out[("listing", listing_id, buyer_id)] = at
        elif store_id:
            out[("store", store_id, buyer_id)] = at
    return out


def later(a: Optional[datetime], b: Optional[datetime]) -> Optional[datetime]:
    """The later of two optional moments: a replay or count floor and a
    deletion, whichever cuts more."""
    if a is None:
        return b
    if b is None:
        return a
    return max(a, b)


async def record(
    db: AsyncSession, user_id: str, *, buyer_id: str, role: str,
    listing_id: Optional[str] = None, store_id: Optional[str] = None,
    at: Optional[datetime] = None,
) -> datetime:
    """Delete the conversation for `user_id` up to `at` (now). Only ever
    moves forward, and commits. Returns the watermark left in place."""
    at = at or datetime.utcnow()
    for attempt in range(2):
        row = (await db.execute(
            select(ThreadClear).where(
                ThreadClear.user_id == user_id,
                ThreadClear.buyer_id == buyer_id,
                _thread(listing_id, store_id),
            ).execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if row is None:
            db.add(ThreadClear(
                user_id=user_id, buyer_id=buyer_id, role=role,
                listing_id=None if (store_id and not listing_id) else listing_id,
                store_id=store_id if (store_id and not listing_id) else None,
                cleared_at=at,
            ))
            left = at
        else:
            if at > row.cleared_at:
                row.cleared_at = at
            left = row.cleared_at
        try:
            await db.commit()
            return left
        except IntegrityError:
            # Two devices deleting the same chat at once: the other insert
            # won; move its row instead.
            await db.rollback()
            if attempt:
                raise
    return at
