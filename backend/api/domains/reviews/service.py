"""Reviews Service v3.0"""
from __future__ import annotations

from typing import Optional
from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

from api.database import Review, Deal, DealStatus, User
from api.core.events import publish, ReviewSubmitted
from api.core.audit import record_audit


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
        if deal.status != DealStatus.released:
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

    async def get_seller_reviews(self, seller_id: str) -> list[dict]:
        r = await self.db.execute(
            select(Review).where(Review.seller_id == seller_id)
            .order_by(Review.created_at.desc())
        )
        return [self._review_dict(rev) for rev in r.scalars().all()]

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
