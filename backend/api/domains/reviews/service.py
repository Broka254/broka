"""Reviews Service v3.0

A review is a buyer's word on a seller, left after a deal that completed:
the buyer confirmed delivery and the escrow paid the seller out. That is the
only thing that makes someone a buyer of this seller rather than a person
with an opinion, so it is checked here, on the deal, for every review - the
app only hides the button from everyone else.
"""
from __future__ import annotations

from typing import Optional
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

from api.database import Review, Deal, DealStatus, Listing, User
from api.core.events import publish, ReviewSubmitted
from api.core.audit import record_audit

# The deal statuses a buyer may review after. Released only: a refunded or
# cancelled deal is not a purchase, and a paid one has not been delivered yet.
REVIEWABLE_STATUSES = (DealStatus.released,)


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
            raise HTTPException(status_code=400, detail="Can only review after delivery is confirmed")

        # Prevent duplicate reviews
        er = await self.db.execute(
            select(Review).where(Review.deal_id == deal_id, Review.reviewer_id == reviewer_id)
        )
        if er.scalar_one_or_none():
            raise HTTPException(status_code=409, detail="You have already reviewed this deal")

        review = Review(
            deal_id=deal_id,
            reviewer_id=reviewer_id,
            seller_id=deal.seller_id,
            rating=rating,
            comment=comment[:1000],
        )
        self.db.add(review)

        # Update seller's aggregate rating
        await self._update_seller_rating(deal.seller_id)

        await record_audit(
            self.db, reviewer_id, "review_submitted", "review", "",
            detail=f"deal_id={deal_id} rating={rating}",
        )
        await self.db.commit()
        await self.db.refresh(review)

        await publish(ReviewSubmitted(
            review_id=review.id,
            deal_id=deal_id,
            seller_id=deal.seller_id,
            reviewer_id=reviewer_id,
            rating=rating,
        ))

        return self._review_dict(review)

    async def get_seller_reviews(
        self, seller_id: str, limit: int = 20, offset: int = 0,
    ) -> list[dict]:
        """Newest first, each with the reviewer's public name - the profile
        screen printed "Buyer" on every card without it."""
        r = await self.db.execute(
            select(Review).where(Review.seller_id == seller_id)
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
        r = await self.db.execute(
            select(Review.rating, func.count(Review.id))
            .where(Review.seller_id == seller_id)
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
    ) -> list[dict]:
        """The caller's completed purchases - optionally from one seller -
        each marked with whether it has been reviewed yet. What decides if a
        "Write a review" button is shown at all, and what the review screen
        lets the buyer pick from."""
        q = select(Deal.id, Deal.seller_id, Deal.listing_id, Deal.agreed_price,
                   Deal.created_at, Deal.released_at).where(
            Deal.buyer_id == buyer_id,
            Deal.seller_id != buyer_id,
            Deal.status.in_(REVIEWABLE_STATUSES),
        )
        if seller_id:
            q = q.where(Deal.seller_id == seller_id)
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
        lr = await self.db.execute(
            select(Listing.id, Listing.name)
            .where(Listing.id.in_({d.listing_id for d in deals if d.listing_id})))
        listings = dict(lr.all())

        return [{
            "deal_id": d.id,
            "seller_id": d.seller_id,
            "seller_name": sellers.get(d.seller_id) or "Seller",
            "listing_name": listings.get(d.listing_id) or "Listing",
            "agreed_price": d.agreed_price,
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
