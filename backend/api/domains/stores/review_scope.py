"""Which reviews belong to a store.

WHY THIS IS A MODULE
====================
Two places need the same rule: the store's reviews screen and the store's
rating. If they answered it differently, a shop would show five reviews and
be rated from three - the exact drift the rating's own docstring warns
against.

THE RULE
========
1. A review of a deal is attributed at write time to the store whose
   listing was sold (`reviews.store_id`). Unambiguous, and the only case
   where a store is genuinely named by the data.

2. A chat-only review has no deal and therefore no listing. Since
   2026-10-22 no new one can be written (reviews/service.py: a deal is
   what proves the buyer dealt with the seller), but the rows posted
   before that are real and stay readable. Such a row belongs to the
   seller's shop when the seller has exactly one live store: one owner,
   one shop, no ambiguity. A seller with two shops gets no such
   attribution, because picking one would be a guess, and the review
   stays on the person's profile where it already lives.

   A review of a personal listing (a deal with no store) also has no
   `store_id`, but it is not a chat review and must NOT join the owner's
   shop: the shop did not sell that item. Only `deal_id IS NULL` earns the
   sole-store fallback.

The "sole store" test is about the OWNER, not the store: it is the same
answer for both of that owner's rows, so the rule cannot flip per shop.
"""
from __future__ import annotations

from typing import Iterable

from sqlalchemy import and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Review
from api.models.store import Store


async def sole_store_ids(db: AsyncSession, store_ids: Iterable[str]) -> set[str]:
    """The subset of `store_ids` whose owner has exactly one live store."""
    ids = [i for i in store_ids if i]
    if not ids:
        return set()
    rows = (await db.execute(
        select(Store.id, Store.owner_id).where(
            Store.id.in_(ids), Store.deleted_at.is_(None))
    )).all()
    if not rows:
        return set()
    owners = {owner_id for _, owner_id in rows}
    counts = dict((await db.execute(
        select(Store.owner_id, func.count(Store.id))
        .where(Store.owner_id.in_(owners), Store.deleted_at.is_(None))
        .group_by(Store.owner_id)
    )).all())
    return {store_id for store_id, owner_id in rows if int(counts.get(owner_id, 0)) == 1}


def store_review_condition(store_id: str, owner_id: str, sole: bool):
    """SQLAlchemy condition for "reviews of this store"."""
    condition = Review.store_id == store_id
    if sole:
        condition = or_(
            condition,
            and_(
                Review.store_id.is_(None),
                Review.deal_id.is_(None),
                Review.seller_id == owner_id,
            ),
        )
    return condition
