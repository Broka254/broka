"""Traders Service v1 — a filtered, re-presented view of existing sellers.
Not a new identity model (Design Journal Volume 6, Ch.5): Trader == User.
"""
from __future__ import annotations

from sqlalchemy import exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from fastapi import HTTPException

from api.core.geo import format_distance_km, haversine_km, round_distance_km
from api.core.text_search import matches_all_terms, search_terms
from api.database import ListingStatus, Review, User, UserSpecialization, Listing, Category
from api.domains.listings.paid import live_clause
from api.domains.media.service import asset_urls, load_assets, require_owned_assets
from api.models.media import MediaPurpose
from api.models.store import Store

# A trader seen within this long is shown as active now.
ONLINE_WINDOW_SECONDS = 5 * 60


class TradersService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_traders(
        self,
        category_id: str | None = None,
        limit: int = 20,
        viewer_lat: float | None = None,
        viewer_lng: float | None = None,
        search: str | None = None,
    ) -> list[dict]:
        terms = search_terms(search)
        # The browse list is proven traders; a search is for a business by
        # name, and a new business has no completed deal yet - requiring one
        # made "search Clanix Electronics" find nothing until its first sale.
        # Anyone selling counts: a deal done, a listing, a business name or
        # a store.
        has_listing = exists(select(Listing.id).where(Listing.seller_id == User.id))
        has_store = exists(select(Store.id).where(Store.owner_id == User.id))
        has_business = func.length(func.coalesce(User.business_name, "")) > 0
        query = select(User).where(
            or_(User.completed_deals > 0, has_listing, has_store, has_business) if terms
            else User.completed_deals > 0)
        if category_id:
            query = query.join(UserSpecialization, UserSpecialization.user_id == User.id).where(
                UserSpecialization.category_id == category_id
            )
        if terms:
            # Every word in the business name the card shows (the person's
            # name only for a trader without one), or in one of their
            # stores' names - the same word-by-word, wildcard-escaped match
            # listing search uses.
            shown_name = func.coalesce(func.nullif(User.business_name, ""), User.name)
            store_named = exists(select(Store.id).where(
                Store.owner_id == User.id, matches_all_terms(terms, (Store.name,))))
            query = query.where(or_(matches_all_terms(terms, (shown_name,)), store_named))
        # Rank on reviews buyers actually left, not `User.rating` - that
        # column starts every account at 5.0, so ordering by it put
        # never-reviewed sellers above ones with a real 4.8 average. The
        # coalesce sends sellers with no reviews behind those with any,
        # then completed deals separate them.
        review_avg = (
            select(func.avg(Review.rating))
            .where(Review.seller_id == User.id)
            .correlate(User)
            .scalar_subquery()
        )
        query = query.order_by(
            func.coalesce(review_avg, -1).desc(), User.completed_deals.desc()
        ).limit(limit)
        users = (await self.db.execute(query)).scalars().all()
        if not users:
            return []

        user_ids = [u.id for u in users]
        # Real buyer-review figures, one grouped query for the page. The
        # User.rating column starts at 5.0 for every account and is not a
        # score anyone gave; `rating` below is the review average or null.
        from api.domains.reviews.stats import seller_review_figures
        review_figures = await seller_review_figures(self.db, user_ids)

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

        covers = await self._covers(users)
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
                cover=covers.get(u.id),
                review=review_figures.get(u.id, (0, None)),
            ))
        return result

    async def _covers(self, users) -> dict[str, dict]:
        """Each trader's card background, {user_id: asset urls}, in one query."""
        ids = {u.trader_cover_id for u in users if getattr(u, "trader_cover_id", None)}
        assets = await load_assets(self.db, ids)
        out = {}
        for u in users:
            urls = asset_urls(assets.get(u.trader_cover_id)) if u.trader_cover_id else None
            if urls:
                out[u.id] = urls
        return out

    async def set_cover(self, user_id: str, asset_id: str | None) -> dict:
        """The trader's card background: an image they uploaded (as a
        trader cover, or one of their store's covers or photos), or None to
        go back to the card's own gradient."""
        user = await self.db.get(User, user_id)
        if user is None:
            raise HTTPException(status_code=404, detail="User not found")
        if asset_id:
            await require_owned_assets(
                self.db, user_id, [asset_id],
                {MediaPurpose.TRADER_COVER, MediaPurpose.STORE_COVER, MediaPurpose.STORE_PHOTO})
        user.trader_cover_id = asset_id or None
        await self.db.commit()
        covers = await self._covers([user])
        return {"cover": covers.get(user.id)}

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

        from api.domains.reviews.stats import seller_review_figures
        review = (await seller_review_figures(self.db, [user.id])).get(
            user.id, (0, None))
        out = self._trader_dict(
            user, listing_count=listing_count, specializations=specializations,
            viewer_lat=viewer_lat, viewer_lng=viewer_lng,
            cover=(await self._covers([user])).get(user.id),
            review=review,
        )
        out.update(await self._profile_details(user, review))
        return out

    async def _profile_details(
        self, user: User, review: tuple[int, float | None] = (0, None),
    ) -> dict:
        """What the trader's own page adds to the card: who they are, how
        long they've sold here, what buyers say, how fast they answer, their
        stores, and what is on sale now."""
        from datetime import datetime
        from api.domains.trust.public_standing import public_seller_standing

        active = (await self.db.execute(
            select(func.count(Listing.id)).where(
                Listing.seller_id == user.id,
                Listing.status == ListingStatus.active,
                live_clause())
        )).scalar_one()
        review_count, review_avg = review
        stores = (await self.db.execute(
            select(Store.id, Store.name, Store.slug).where(Store.owner_id == user.id)
        )).all()
        standing = await public_seller_standing(self.db, user.id) or {}
        seen = user.last_seen
        return {
            "about": (user.business_description or "").strip() or None,
            "member_since": user.created_at.isoformat() if user.created_at else None,
            "active_listings": int(active or 0),
            "review_count": int(review_count),
            # None, not 0, with no reviews: no average is not a bad one.
            "review_avg": round(review_avg, 1) if review_avg is not None else None,
            "median_response_minutes": standing.get("median_response_minutes"),
            "is_online": bool(seen and (datetime.utcnow() - seen).total_seconds() < ONLINE_WINDOW_SECONDS),
            "last_seen": seen.isoformat() if seen else None,
            "stores": [{"id": sid, "name": name, "slug": slug} for sid, name, slug in stores],
        }

    def _trader_dict(
        self, u: User, listing_count: int, specializations: list[dict],
        viewer_lat: float | None = None, viewer_lng: float | None = None,
        cover: dict | None = None,
        review: tuple[int, float | None] = (0, None),
    ) -> dict:
        review_count, review_avg = review
        out = {
            "id": u.id, "business_name": u.business_name or u.name,
            "is_verified": u.is_verified,
            # Buyer-review average, or null when nobody has reviewed them.
            "rating": review_avg,
            "review_count": review_count,
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
            # The card's optional background image (POST /traders/me/cover):
            # {id, thumb, medium, large}, or None for the card's gradient.
            "cover": cover,
        }
        if (
            viewer_lat is not None and viewer_lng is not None
            and u.lat is not None and u.lng is not None and u.location_visible
        ):
            dist = round_distance_km(haversine_km(viewer_lat, viewer_lng, u.lat, u.lng))
            if dist is not None:
                out["distance_km"] = dist
                out["distance_label"] = format_distance_km(dist)
        return out
