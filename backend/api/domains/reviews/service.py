"""Reviews Service v4.0

A review is a buyer's word on a seller - and, when the product was sold
through a store, on that store too. It is a record of a deal that happened,
not an opinion anyone may post.

WHO MAY REVIEW: only the buyer of a deal with the seller, one review per
deal. A Deal row exists only when the two sides reached one in the app, so
it is the proof that they actually dealt. A conversation alone is not: any
account can open a chat and post a comment, which is exactly the random
review this rule exists to stop (until 2026-10-22 a chat was enough).

WHY NOT "COMPLETED": BROKA holds no money while buyers pay sellers
directly, so a deal never reaches released here and requiring it meant
nobody could ever review. Every deal status counts except cancelled and
refunded - a deal still agreeing, paid, delivered or in a dispute is one
the buyer was part of, and is often the only public record of what went
wrong (ESCROW_AUDIT.md, STORES_RATING_PLAN.md §2).

Its review row also carries the deal's store (reviews.store_id) so a shop
is rated from its own sales, never from its owner's other shop.
"""
from __future__ import annotations

import logging
from typing import Optional
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Review, Deal, DealStatus, Listing, User
from api.models.store import Store
from api.core.events import publish, ReviewSubmitted
from api.core.audit import record_audit

logger = logging.getLogger(__name__)

# A deal that was cancelled or refunded is not one the buyer went through
# with: there is nothing to review. Every other status is a deal they were
# part of - including the ones still running, because BROKA never learns
# that a deal completed (buyers pay sellers outside it).
NOT_A_PURCHASE = (DealStatus.cancelled, DealStatus.refunded)
REVIEWABLE_STATUSES = tuple(s for s in DealStatus if s not in NOT_A_PURCHASE)

# Prefix older app builds used for a chat-only "deal". Reads nothing any
# more, but a request still carrying one gets a plain answer instead of a
# 404 that looks like a broken screen.
CHAT_REVIEW_PREFIX = "chat:"


class ReviewService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def submit_review(
        self,
        deal_id: str,
        reviewer_id: str,
        rating: int,
        comment: str = "",
    ) -> dict:
        if not (1 <= rating <= 5):
            raise HTTPException(status_code=400, detail="Rating must be between 1 and 5")
        if deal_id.startswith(CHAT_REVIEW_PREFIX):
            raise HTTPException(
                status_code=403,
                detail="A review needs a deal. Open the deal you had with this seller to rate it.")

        # Validate deal access
        r = await self.db.execute(select(Deal).where(Deal.id == deal_id))
        deal = r.scalar_one_or_none()
        if not deal:
            raise HTTPException(status_code=404, detail="Deal not found")
        if deal.buyer_id != reviewer_id:
            raise HTTPException(status_code=403, detail="Only the buyer can review this deal")
        # A deal an account opened with itself buys nothing; a review from it
        # would be the seller rating themselves.
        if deal.seller_id == reviewer_id:
            raise HTTPException(status_code=403, detail="You can't review yourself")
        if deal.status not in REVIEWABLE_STATUSES:
            raise HTTPException(
                status_code=400,
                detail="That deal was cancelled or refunded, so there is nothing to review")

        if await self._already_reviewed(deal_id, reviewer_id):
            raise HTTPException(status_code=409, detail="You have already reviewed this deal")

        # Attribute the review to the store whose product was sold. This is
        # what lets a store's own rating count only its own deals: a seller
        # with two shops would otherwise have one record lift both. Looked up
        # once, here, from the deal's listing - the review never carries a
        # store chosen by the caller.
        listing_store = (await self.db.execute(
            select(Listing.store_id).where(Listing.id == deal.listing_id)
        )).scalar_one_or_none() if deal.listing_id else None

        return await self._save(Review(
            deal_id=deal_id,
            reviewer_id=reviewer_id,
            seller_id=deal.seller_id,
            store_id=listing_store,
            rating=rating,
            comment=comment[:1000],
        ))

    async def _save(self, review: Review) -> dict:
        seller_id, reviewer_id, deal_id = review.seller_id, review.reviewer_id, review.deal_id
        rating = review.rating
        store_id = review.store_id
        # The check above is a courtesy; uq_reviews_deal_reviewer is the
        # guard. Two submissions sent together (a double tap, two phones)
        # both pass the check, and the second insert fails here - at the
        # flush the rating average triggers, or at commit.
        try:
            self.db.add(review)
            await self._update_seller_rating(seller_id)
            await record_audit(
                self.db, reviewer_id, "review_submitted", "review", "",
                detail=f"deal_id={deal_id} seller_id={seller_id} rating={rating}",
            )
            await self.db.commit()
        except IntegrityError:
            await self.db.rollback()
            raise HTTPException(status_code=409, detail="You have already reviewed this deal")
        await self.db.refresh(review)

        # The store's number moves the moment a review lands, not the next
        # time the nightly pass happens to run - a seller who just earned a
        # bad review should see it before their next customer does. Failure
        # here must not fail the review: the rating is recomputed nightly
        # regardless, and the buyer's words are already committed.
        if store_id:
            try:
                from api.domains.stores.rating import refresh_store_rating
                await refresh_store_rating(self.db, store_id)
            except Exception as exc:  # noqa: BLE001 - never lose the review
                logger.warning("[reviews] store rating refresh failed: %s", exc)

        await publish(ReviewSubmitted(
            review_id=review.id,
            deal_id=deal_id or "",
            seller_id=seller_id,
            reviewer_id=reviewer_id,
            rating=rating,
        ))

        return self._review_dict(review)

    async def _already_reviewed(self, deal_id: str, reviewer_id: str) -> bool:
        r = await self.db.execute(
            select(Review.id).where(Review.deal_id == deal_id, Review.reviewer_id == reviewer_id))
        return r.first() is not None

    async def get_seller_reviews(
        self, seller_id: str, limit: int = 20, offset: int = 0,
    ) -> list[dict]:
        """Newest first, each with the reviewer's public name - the profile
        screen printed "Buyer" on every card without it."""
        return await self._reviews(Review.seller_id == seller_id, limit, offset)

    async def _reviews(self, condition, limit: int, offset: int) -> list[dict]:
        r = await self.db.execute(
            select(Review).where(condition)
            .order_by(Review.created_at.desc())
            .offset(offset).limit(limit)
        )
        reviews = r.scalars().all()
        names: dict[str, str] = {}
        reviewer_ids = {rev.reviewer_id for rev in reviews}
        if reviewer_ids:
            ur = await self.db.execute(
                select(User.id, User.name, User.nickname).where(User.id.in_(reviewer_ids)))
            names = {uid: self._public_name(nickname or name) for uid, name, nickname in ur.all()}
        return [
            {**self._review_dict(rev), "reviewer_name": names.get(rev.reviewer_id, "BROKA buyer")}
            for rev in reviews
        ]

    async def get_summary(self, seller_id: str) -> dict:
        """{avg, count, distribution} over every review of the seller.

        avg is None, not 0 and not the 5.0 User.rating starts at, when there
        are no reviews: a seller nobody has reviewed has no average.
        distribution is keyed "1".."5", the keys JSON can carry."""
        return await self._summary(Review.seller_id == seller_id)

    async def get_store_reviews(
        self, store_id: str, limit: int = 20, offset: int = 0,
        *, owner_id: Optional[str] = None, include_seller_chat: bool = False,
    ) -> list[dict]:
        """The reviews a store's page shows.

        `include_seller_chat` is the sole-store rule (stores/review_scope.py):
        a chat-only review has no listing, so it belongs to the owner's shop
        only when that owner has exactly one. The caller decides, because it
        is the caller that knows how many shops the owner runs. The condition
        itself lives in review_scope, shared with the rating - if the two
        answered "which reviews are this shop's" differently, a shop would
        show five reviews and be rated from three.
        """
        from api.domains.stores.review_scope import store_review_condition
        condition = store_review_condition(
            store_id, owner_id or "", include_seller_chat and bool(owner_id))
        return await self._reviews(condition, limit, offset)

    async def get_store_summary(
        self, store_id: str, *,
        owner_id: Optional[str] = None, include_seller_chat: bool = False,
    ) -> dict:
        """{avg, count, distribution} for one store's reviews."""
        from api.domains.stores.review_scope import store_review_condition
        condition = store_review_condition(
            store_id, owner_id or "", include_seller_chat and bool(owner_id))
        return await self._summary(condition)

    async def _summary(self, condition) -> dict:
        r = await self.db.execute(
            select(Review.rating, func.count(Review.id))
            .where(condition)
            .group_by(Review.rating)
        )
        dist = {str(star): 0 for star in range(1, 6)}
        for star, n in r.all():
            if str(star) in dist:
                dist[str(star)] = int(n)
        count = sum(dist.values())
        total = sum(int(star) * n for star, n in dist.items())
        return {
            "avg": round(total / count, 1) if count else None,
            "count": count,
            "distribution": dist,
        }

    async def my_reviewable_deals(
        self, buyer_id: str, seller_id: Optional[str] = None,
        store_id: Optional[str] = None,
    ) -> list[dict]:
        """The caller's deals - optionally with one seller, or on one
        shop's products - each saying whether it has been reviewed yet.

        This is what decides whether a "Write a review" button is shown at
        all, and what the review screen offers to pick from. `store_id` is
        how a store page asks the same question about its own sales: a
        review of that shop has to name a product the shop sold, never
        another shop of the same owner.
        """
        q = select(Deal.id, Deal.seller_id, Deal.listing_id, Deal.agreed_price,
                   Deal.status, Deal.created_at, Deal.released_at).where(
            Deal.buyer_id == buyer_id,
            Deal.seller_id != buyer_id,
            Deal.status.in_(REVIEWABLE_STATUSES),
        )
        if seller_id:
            q = q.where(Deal.seller_id == seller_id)
        if store_id:
            q = q.where(Deal.listing_id.in_(
                select(Listing.id).where(Listing.store_id == store_id)))
        deals = (await self.db.execute(q.order_by(Deal.created_at.desc()).limit(100))).all()
        if not deals:
            return []

        deal_ids = [d.id for d in deals]
        rv = await self.db.execute(
            select(Review.deal_id).where(
                Review.reviewer_id == buyer_id, Review.deal_id.in_(deal_ids)))
        reviewed = {row[0] for row in rv.all()}

        sr = await self.db.execute(
            select(User.id, User.name, User.nickname)
            .where(User.id.in_({d.seller_id for d in deals})))
        sellers = {uid: nickname or name for uid, name, nickname in sr.all()}
        # The product and the shop behind it, in one query: a store page's
        # "Rate this store" needs to know both, and the card shows the
        # product's name.
        lr = await self.db.execute(
            select(Listing.id, Listing.name, Listing.store_id)
            .where(Listing.id.in_({d.listing_id for d in deals if d.listing_id})))
        listings = {lid: (name, store) for lid, name, store in lr.all()}
        shop_names = {}
        shop_ids = {store for _, store in listings.values() if store}
        if shop_ids:
            shop_names = dict((await self.db.execute(
                select(Store.id, Store.name).where(Store.id.in_(shop_ids)))).all())

        return [{
            "deal_id": d.id,
            "seller_id": d.seller_id,
            "seller_name": sellers.get(d.seller_id) or "Seller",
            "listing_name": (listings.get(d.listing_id) or (None, None))[0] or "Listing",
            "store_id": (listings.get(d.listing_id) or (None, None))[1],
            "store_name": shop_names.get(
                (listings.get(d.listing_id) or (None, None))[1]),
            "agreed_price": d.agreed_price,
            "status": d.status.value if hasattr(d.status, "value") else d.status,
            "created_at": d.created_at.isoformat() if d.created_at else None,
            "completed_at": d.released_at.isoformat() if d.released_at else None,
            "already_reviewed": d.id in reviewed,
        } for d in deals]

    async def _update_seller_rating(self, seller_id: str) -> None:
        r = await self.db.execute(
            select(func.avg(Review.rating)).where(Review.seller_id == seller_id)
        )
        avg = r.scalar() or 5.0
        ur = await self.db.execute(select(User).where(User.id == seller_id))
        seller = ur.scalar_one_or_none()
        if seller:
            seller.rating = round(float(avg), 2)

    @staticmethod
    def _public_name(name: Optional[str]) -> str:
        """First name and an initial - "Amina W." - the way the review cards
        name a buyer. Reviews are public; a buyer's full name is not."""
        parts = (name or "").split()
        if not parts:
            return "BROKA buyer"
        return f"{parts[0]} {parts[1][0]}." if len(parts) > 1 else parts[0]

    @staticmethod
    def _review_dict(r: Review) -> dict:
        return {
            "id": r.id,
            "deal_id": r.deal_id,
            "reviewer_id": r.reviewer_id,
            "seller_id": r.seller_id,
            "rating": r.rating,
            "comment": r.comment,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
