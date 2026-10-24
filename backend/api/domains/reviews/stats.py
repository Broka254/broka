"""A seller's buyer-review figures, read from the reviews themselves.

`User.rating` starts every account at 5.0 and is a denormalised cache, not
a fact: a seller nobody has reviewed has no average, and showing the
column's starting value makes them look perfect. Every public surface that
shows a seller's star rating therefore reads `reviews` - one grouped query
over the indexed `reviews.seller_id`, never a row per seller.
"""
from __future__ import annotations

from typing import Dict, Iterable, Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Review


async def seller_review_figures(
    db: AsyncSession, seller_ids: Iterable[str],
) -> Dict[str, tuple[int, Optional[float]]]:
    """Seller id -> (review count, average or None).

    Every requested id gets an entry, so a missing key can never be
    mistaken for "no data": no reviews is `(0, None)`, not `(0, 5.0)`.
    """
    ids = {i for i in seller_ids if i}
    if not ids:
        return {}
    rows = (await db.execute(
        select(Review.seller_id, func.count(Review.id),
               func.coalesce(func.sum(Review.rating), 0))
        .where(Review.seller_id.in_(ids))
        .group_by(Review.seller_id)
    )).all()
    out: Dict[str, tuple[int, Optional[float]]] = {i: (0, None) for i in ids}
    for seller_id, count, total in rows:
        count = int(count or 0)
        out[seller_id] = (
            count,
            round(float(total or 0) / count, 2) if count else None,
        )
    return out


def figures(
    value: Optional[tuple[int, Optional[float]]],
) -> tuple[int, Optional[float]]:
    """Normalise a lookup result: no entry means no reviews."""
    return value if value is not None else (0, None)
