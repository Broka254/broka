"""Reviews Service v3.0

A review is a buyer's word on a seller. With REVIEWS_REQUIRE_COMPLETED_DEAL
on, only after a deal that completed: the buyer confirmed delivery and the
escrow paid the seller out. Off (the default while buyers pay sellers outside
BROKA, so no deal ever completes here), a buyer may review a seller they
agreed a deal with (anything but cancelled or refunded) or talked with about
one of their listings - once per deal, and once per seller without one. That
is what makes someone a buyer of this seller rather than a person with an
opinion, so it is checked here for every review - the app only hides the
button from everyone else.

A conversation without a deal is offered to the app as a reviewable "deal"
whose id is CHAT_REVIEW_PREFIX + the seller's id, so builds already installed
review it through the screen they have; its review row has no deal.
"""
from __future__ import annotations

from typing import Optional
from fastapi import HTTPException
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func

from api.database import Review, Deal, DealStatus, Listing, NegotiationMessage, User
from api.core.config import settings
from api.core.events import publish, ReviewSubmitted
from api.core.audit import record_audit

# The deal statuses a buyer may review after, when reviews require a
# completed deal. Released only: a refunded or cancelled deal is not a
# purchase, and a paid one has not been delivered yet.
REVIEWABLE_STATUSES = (DealStatus.released,)
# Not a purchase whatever the setting.
_NOT_A_PURCHASE = (DealStatus.cancelled, DealStatus.refunded)

CHAT_REVIEW_PREFIX = "chat:"


def reviewable_statuses() -> tuple:
    if settings.reviews_require_completed_deal:
        return REVIEWABLE_STATUSES
    return tuple(s for s in DealStatus if s not in _NOT_A_PURCHASE)


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
            return await self._submit_chat_review(
                deal_id[len(CHAT_REVIEW_PREFIX):], reviewer_id, rating, comment)

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
        if deal.status not in reviewable_statuses():
            raise HTTPException(status_code=400, detail="Can only review after delivery is confirmed")

        if await self._already_reviewed(deal_id, reviewer_id):
            raise HTTPException(status_code=409, detail="You have already reviewed this deal")

        return await self._save(Review(
            deal_id=deal_id,
            reviewer_id=reviewer_id,
            seller_id=deal.seller_id,
            rating=rating,
            comment=comment[:1000],
        ))

    async def _submit_chat_review(
        self, seller_id: str, reviewer_id: str, rating: int, comment: str,
    ) -> dict:
        """A review of a seller the reviewer talked with but has no deal with."""
        if settings.reviews_require_completed_deal:
            raise HTTPException(status_code=400, detail="Can only review after delivery is confirmed")
        if not seller_id or seller_id == reviewer_id:
            raise HTTPException(status_code=403, detail="You can't review yourself")
        if not await self._talked_with(reviewer_id, seller_id):
            raise HTTPException(
                status_code=403,
                detail="You can review a seller once you've talked with them about a listing")
        dup = await self.db.execute(select(Review.id).where(
            Review.seller_id == seller_id, Review.reviewer_id == reviewer_id,
            Review.deal_id.is_(None)))
        if dup.first() is not None:
            raise HTTPException(status_code=409, detail="You have already reviewed this seller")
        return await self._save(Review(
            deal_id=None,
            reviewer_id=reviewer_id,
            seller_id=seller_id,
            rating=rating,
            comment=comment[:1000],
        ))

    async def _talked_with(self, buyer_id: str, seller_id: str) -> bool:
        """The buyer wrote in a thread of theirs on one of the seller's
        listings - a stranger with no conversation has no review to give."""
        # visibility-ok: selects one id to test the buyer wrote here, no content
        r = await self.db.execute(
            select(NegotiationMessage.id)
            .join(Listing, Listing.id == NegotiationMessage.listing_id)
            .where(
                NegotiationMessage.buyer_id == buyer_id,
                NegotiationMessage.sender_id == buyer_id,
                Listing.seller_id == seller_id,
            ).limit(1))
        return r.first() is not None

    async def _save(self, review: Review) -> dict:
        seller_id, reviewer_id, deal_id = review.seller_id, review.reviewer_id, review.deal_id
        rating = review.rating
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
            Deal.status.in_(reviewable_statuses()),
        )
        if seller_id:
            q = q.where(Deal.seller_id == seller_id)
        deals = (await self.db.execute(q.order_by(Deal.created_at.desc()).limit(100))).all()
        chats = [] if settings.reviews_require_completed_deal else \
            await self._reviewable_chats(buyer_id, seller_id, {d.seller_id for d in deals})
        if not deals:
            return chats

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
        } for d in deals] + chats

    async def _reviewable_chats(
        self, buyer_id: str, seller_id: Optional[str], dealt_with: set,
    ) -> list[dict]:
        """One entry per seller the buyer talked with and has no deal with,
        newest conversation first, in my_reviewable_deals' shape."""
        # visibility-ok: selects listing ids and times of the buyer's own messages, no content
        q = (select(Listing.seller_id, Listing.name, NegotiationMessage.created_at)
             .join(Listing, Listing.id == NegotiationMessage.listing_id)
             .where(NegotiationMessage.buyer_id == buyer_id,
                    NegotiationMessage.sender_id == buyer_id,
                    Listing.seller_id != buyer_id))
        if seller_id:
            q = q.where(Listing.seller_id == seller_id)
        rows = (await self.db.execute(
            q.order_by(NegotiationMessage.created_at.desc()).limit(500))).all()
        latest: dict[str, tuple] = {}
        for sid, name, at in rows:
            if sid and sid not in dealt_with and sid not in latest:
                latest[sid] = (name, at)
        if not latest:
            return []
        reviewed = {row[0] for row in (await self.db.execute(
            select(Review.seller_id).where(
                Review.reviewer_id == buyer_id, Review.deal_id.is_(None),
                Review.seller_id.in_(latest)))).all()}
        sellers = {uid: nickname or name for uid, name, nickname in (await self.db.execute(
            select(User.id, User.name, User.nickname).where(User.id.in_(latest)))).all()}
        return [{
            "deal_id": f"{CHAT_REVIEW_PREFIX}{sid}",
            "seller_id": sid,
            "seller_name": sellers.get(sid) or "Seller",
            "listing_name": name or "Listing",
            "agreed_price": None,
            "created_at": at.isoformat() if at else None,
            "completed_at": None,
            "already_reviewed": sid in reviewed,
        } for sid, (name, at) in latest.items()]

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
