"""Traders Service v1 — a filtered, re-presented view of existing sellers.
Not a new identity model (Design Journal Volume 6, Ch.5): Trader == User.
"""
from __future__ import annotations

import math
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import User, UserSpecialization, Listing, Category


def _haversine_km(lat1, lng1, lat2, lng2) -> float:
    R = 6371
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))


class TradersService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_traders(
        self,
        category_id: str | None = None,
        limit: int = 20,
        viewer_lat: float | None = None,
        viewer_lng: float | None = None,
    ) -> list[dict]:
        query = select(User).where(User.completed_deals > 0)
        if category_id:
            query = query.join(UserSpecialization, UserSpecialization.user_id == User.id).where(
                UserSpecialization.category_id == category_id
            )
        query = query.order_by(User.rating.desc()).limit(limit)
        users = (await self.db.execute(query)).scalars().all()
        if not users:
            return []

        user_ids = [u.id for u in users]

        # FIX (redesign-guide audit): previously ran one COUNT(*) query PER
        # trader in the list (N+1) - batched into a single grouped query.
        count_rows = (await self.db.execute(
            select(Listing.seller_id, func.count(Listing.id))
            .where(Listing.seller_id.in_(user_ids))
            .group_by(Listing.seller_id)
        )).all()
        listing_counts = {row[0]: row[1] for row in count_rows}

        # Each trader's single top specialization (by listing_count), for
        # the list card's compact "specializes in X" (Design v2 §30) - the
        # full breakdown stays profile-only (get_trader below). ORDER BY
        # user_id, listing_count DESC means the first row seen per user_id
        # while looping is that user's highest-count specialization.
        spec_rows = (await self.db.execute(
            select(UserSpecialization).where(UserSpecialization.user_id.in_(user_ids))
            .order_by(UserSpecialization.user_id, UserSpecialization.listing_count.desc())
        )).scalars().all()
        top_spec_by_user: dict[str, UserSpecialization] = {}
        for s in spec_rows:
            top_spec_by_user.setdefault(s.user_id, s)
        cat_ids = {s.category_id for s in top_spec_by_user.values()}
        cat_names: dict[str, str] = {}
        if cat_ids:
            cat_rows = (await self.db.execute(select(Category).where(Category.id.in_(cat_ids)))).scalars().all()
            cat_names = {c.id: c.name for c in cat_rows}

        result = []
        for u in users:
            top_spec = top_spec_by_user.get(u.id)
            specializations = (
                [{"id": top_spec.category_id, "name": cat_names.get(top_spec.category_id, "Unknown")}]
                if top_spec else []
            )
            result.append(self._trader_dict(
                u, listing_count=listing_counts.get(u.id, 0),
                specializations=specializations,
                viewer_lat=viewer_lat, viewer_lng=viewer_lng,
            ))
        return result

    async def get_trader(
        self, user_id: str,
        viewer_lat: float | None = None, viewer_lng: float | None = None,
    ) -> dict | None:
        user = await self.db.get(User, user_id)
        if not user:
            return None
        listing_count = (await self.db.execute(
            select(func.count(Listing.id)).where(Listing.seller_id == user.id)
        )).scalar_one()

        specs = (await self.db.execute(
            select(UserSpecialization).where(UserSpecialization.user_id == user.id)
            .order_by(UserSpecialization.listing_count.desc())
        )).scalars().all()
        cat_ids = [s.category_id for s in specs]
        categories = {}
        if cat_ids:
            rows = (await self.db.execute(select(Category).where(Category.id.in_(cat_ids)))).scalars().all()
            categories = {c.id: c.name for c in rows}
        # {id, name} pairs, not bare ids - the profile screen's
        # top-categories section has no other way to show something
        # more meaningful than a raw category UUID.
        specializations = [
            {"id": s.category_id, "name": categories.get(s.category_id, "Unknown")} for s in specs
        ]

        return self._trader_dict(
            user, listing_count=listing_count, specializations=specializations,
            viewer_lat=viewer_lat, viewer_lng=viewer_lng,
        )

    def _trader_dict(
        self, u: User, listing_count: int, specializations: list[dict],
        viewer_lat: float | None = None, viewer_lng: float | None = None,
    ) -> dict:
        out = {
            "id": u.id, "business_name": u.business_name or u.name,
            "is_verified": u.is_verified, "rating": u.rating,
            "completed_deals": u.completed_deals, "listing_count": listing_count,
            "specializations": specializations,
            # Deliberately not including a Deal Completion Rate field: the
            # design doc points to "an existing per-seller DCR function
            # (Volume 2, Ch.3)" and says not to reimplement it, but no such
            # function exists anywhere in this codebase under any name
            # (searched), and Volume 2 was not provided alongside Volume 6.
            # Leaving this out rather than fabricating a computation the
            # doc explicitly said should be reused, not reinvented.
            "profile_photo": u.profile_photo,
            # location_name/distance_km only when the trader has left their
            # location visible - the same privacy switch search_screen.dart's
            # user search already respects (User.location_visible), applied
            # here for consistency rather than exposing it unconditionally
            # just because Design v2 §30 lists "location"/"distance" as card
            # elements.
            "location_name": (u.business_location or None) if u.location_visible else None,
        }
        if (
            viewer_lat is not None and viewer_lng is not None
            and u.lat is not None and u.lng is not None and u.location_visible
        ):
            out["distance_km"] = round(_haversine_km(viewer_lat, viewer_lng, u.lat, u.lng), 1)
        return out
