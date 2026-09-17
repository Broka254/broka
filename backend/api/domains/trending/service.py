"""Trending Service v1 — time-decayed score computed on read (Design
Journal Volume 6, Ch.7). No stored is_trending flag, no maintained list.

Decay: a view/interest from HALF_LIFE_HOURS ago counts for half as much as
one right now — makes recent momentum outweigh lifetime totals, per the
external spec's own reasoning in Ch.16 of its source document.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, Interest, Category, User
from api.domains.listings.service import ListingService

HALF_LIFE_HOURS = 36.0


class TrendingService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_trending(
        self, limit: int = 20, offset: int = 0, category_id: str | None = None
    ) -> list[dict]:
        cutoff = datetime.utcnow() - timedelta(days=14)
        interest_rows = await self.db.execute(
            select(Interest.listing_id, func.count(Interest.id))
            .where(Interest.created_at >= cutoff)
            .group_by(Interest.listing_id)
        )
        interest_counts = dict(interest_rows.all())

        query = select(Listing).where(Listing.created_at >= cutoff)
        if category_id:
            # Match the Phase 1 category system (Listing.subcategory_id,
            # which may point at this category or one of its children) -
            # not Listing.category, the older free-text column, which the
            # rest of this domain no longer treats as the source of truth
            # once categories exist (see domains/listings/service.py).
            child_ids = (
                await self.db.execute(select(Category.id).where(Category.parent_id == category_id))
            ).scalars().all()
            query = query.where(Listing.subcategory_id.in_([category_id, *child_ids]))
        listings = (await self.db.execute(query)).scalars().all()

        now = datetime.utcnow()
        scored = []
        for l in listings:
            age_hours = max((now - l.created_at).total_seconds() / 3600.0, 0.01)
            decay = 0.5 ** (age_hours / HALF_LIFE_HOURS)
            interest_weight = interest_counts.get(l.id, 0) * 5  # a negotiation-started signal outweighs a view
            scored.append(((l.views + interest_weight) * decay, l))

        scored.sort(key=lambda pair: pair[0], reverse=True)
        page = [l for _, l in scored[offset:offset + limit]]

        # FIX (redesign-guide audit): batch-fetch sellers for this page so
        # trending cards carry the same seller_name/verified/rating/
        # completed_deals every other listing response now does (see
        # listings/service.py's _listing_dict) - one IN(...) query for the
        # whole page, not one per listing.
        seller_ids = {l.seller_id for l in page if l.seller_id}
        sellers_by_id: dict[str, User] = {}
        if seller_ids:
            seller_rows = (await self.db.execute(select(User).where(User.id.in_(seller_ids)))).scalars().all()
            sellers_by_id = {u.id: u for u in seller_rows}

        # Reuses the same serializer every other listing response uses
        # (domains/listings/service.py) so trending results carry the same
        # image/verified/price fields as everywhere else in the API,
        # rather than a second, thinner listing JSON shape.
        return [ListingService._listing_dict(l, seller=sellers_by_id.get(l.seller_id)) for l in page]
