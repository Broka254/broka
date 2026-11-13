"""Deleting a chat from one's own inbox (models/thread_clear.py).

The messages stay - they are the other person's copy and the evidence a
dispute is decided on. What goes is this person's view of everything up to
the moment they deleted it: the inbox row, the history and the chat socket's
replay all skip it. A newer message brings the chat back from there.

A chat with money in it cannot be deleted: while a deal is paid, disputed or
waiting on its resolution, the chat is where that deal is handled, and a
person who deleted it would lose the thread they need.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus
from api.models.thread_clear import ThreadClear

# Deal states with the buyer's money held in escrow: the chat stays until it
# is settled. Not "agreed": with payments outside BROKA an agreed deal is
# where a finished sale stops, and that chat is exactly the one people want
# to delete once the deal is done.
DEAL_IN_PROGRESS = (
    DealStatus.paid,
    DealStatus.disputed,
    DealStatus.awaiting_condition_check,
    DealStatus.awaiting_resolution,
    DealStatus.awaiting_replacement,
    DealStatus.goods_not_arrived,
)


def _thread_cond(listing_id: Optional[str], store_id: Optional[str]):
    if store_id:
        return ThreadClear.store_id == store_id
    return ThreadClear.listing_id == listing_id


async def cleared_at(
    db: AsyncSession, user_id: str, *, buyer_id: Optional[str],
    listing_id: Optional[str] = None, store_id: Optional[str] = None,
) -> Optional[datetime]:
    """When this person last deleted this chat, or None."""
    if not buyer_id or not (listing_id or store_id):
        return None
    return (await db.execute(
        select(ThreadClear.cleared_at).where(
            ThreadClear.user_id == user_id,
            _thread_cond(listing_id, store_id),
            ThreadClear.buyer_id == buyer_id,
        )
    )).scalar_one_or_none()


async def cleared_threads(db: AsyncSession, user_id: str) -> dict:
    """Every chat this person deleted, for the inbox in one query:
    {("listing", listing_id, buyer_id) | ("store", store_id, buyer_id): cleared_at}."""
    rows = (await db.execute(
        select(ThreadClear.listing_id, ThreadClear.store_id,
               ThreadClear.buyer_id, ThreadClear.cleared_at)
        .where(ThreadClear.user_id == user_id)
    )).all()
    out: dict = {}
    for listing_id, store_id, buyer_id, at in rows:
        if store_id:
            out[("store", store_id, buyer_id)] = at
        elif listing_id:
            out[("listing", listing_id, buyer_id)] = at
    return out


def hidden_by_clear(at: Optional[datetime], message_created_at: Optional[datetime]) -> bool:
    """A message this person deleted with the chat: written at or before
    the moment they deleted it."""
    return at is not None and message_created_at is not None and message_created_at <= at


async def deal_in_progress(db: AsyncSession, listing_id: Optional[str], buyer_id: str) -> bool:
    """A deal on this thread with money held or on its way (DEAL_IN_PROGRESS).
    Store-general threads carry no deal."""
    if not listing_id:
        return False
    return (await db.execute(
        select(Deal.id).where(
            Deal.listing_id == listing_id,
            Deal.buyer_id == buyer_id,
            Deal.status.in_(DEAL_IN_PROGRESS),
        ).limit(1)
    )).first() is not None


async def clear_thread(
    db: AsyncSession, user_id: str, role: str, *, buyer_id: str,
    listing_id: Optional[str] = None, store_id: Optional[str] = None,
    now: Optional[datetime] = None,
) -> datetime:
    """Record that this person deleted the chat now. Commits."""
    now = now or datetime.utcnow()
    for attempt in range(2):
        row = (await db.execute(
            select(ThreadClear).where(
                ThreadClear.user_id == user_id,
                _thread_cond(listing_id, store_id),
                ThreadClear.buyer_id == buyer_id,
            ).execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if row is None:
            db.add(ThreadClear(
                user_id=user_id, listing_id=None if store_id else listing_id,
                store_id=store_id, buyer_id=buyer_id, role=role, cleared_at=now,
            ))
        else:
            row.cleared_at = now
        try:
            await db.commit()
            return now
        except IntegrityError:
            # Deleted twice at once (a double tap on two requests): the
            # other insert won; move its row instead.
            await db.rollback()
            if attempt:
                raise
    return now
