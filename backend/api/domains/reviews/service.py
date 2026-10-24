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

AFTER SUBMISSION: a review is the buyer's account of a deal that happened,
so it is not removed or recomputed because that deal is later cancelled,
refunded or disputed. Deleting it would let one side erase the other's
record by changing the deal's status. Status only decides whether a review
may be WRITTEN (NOT_A_PURCHASE below); moderation, not a status change, is
the only way a review leaves the record.
"""
from __future__ import annotations

import logging
from typing import Optional
from fastapi import HTTPException
from sqlalchemy import exists, func, or_, select
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

# One limit for every surface that writes or displays a review comment.
# The API schema enforces it before the body reaches here; this check is
# what a direct service call gets. A comment over the limit is refused,
# never cut: the buyer wrote those words, and saving half of them would
# publish a sentence they did not write.
MAX_REVIEW_COMMENT = 500


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
        text = (comment or "").strip()
        if len(text) > MAX_REVIEW_COMMENT:
            raise HTTPException(
                status_code=400,
                detail=f"A review comment can be at most {MAX_REVIEW_COMMENT} characters",
            )
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
        listing = (await self.db.execute(
            select(Listing.id, Listing.store_id, Listing.seller_id, Store.owner_id)
            .outerjoin(Store, Store.id == Listing.store_id)
            .where(Listing.id == deal.listing_id)
        )).first() if deal.listing_id else None
        listing_store = None
        if listing is not None:
            # Both relationships must agree with the deal: the listing has to
            # belong to the seller, and any shop on it has to belong to that
            # seller too. A listing can carry a stale or tampered store_id;
            # trusting it would put the review on a stranger's shop even
            # though the listing itself names the right seller.
            if (listing.seller_id == deal.seller_id
                    and (listing.store_id is None or listing.owner_id == deal.seller_id)):
                listing_store = listing.store_id
            else:
                # A deal naming another seller's listing, or a listing naming
                # another owner's shop, is corrupt or tampered data. Keep the
                # buyer's review of the person they dealt with, but do not let
                # it land on a shop neither side traded through. This is a
                # data-integrity alarm, not a normal path; repair the row
                # rather than guessing a shop.
                logger.warning(
                    "[reviews] deal %s listing %s seller/store owner mismatch "
                    "(listing seller %s, store owner %s, deal seller %s)",
                    deal.id, listing.id, listing.seller_id,
                    listing.owner_id, deal.seller_id,
                )

        return await self._save(Review(
            deal_id=deal_id,
            reviewer_id=reviewer_id,
            seller_id=deal.seller_id,
            store_id=listing_store,
            rating=rating,
            comment=text,
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
            await record_audit(
                self.db, reviewer_id, "review_submitted", "review", "",
                detail=f"deal_id={deal_id} seller_id={seller_id} rating={rating}",
            )
            await self.db.commit()
        except IntegrityError:
            await self.db.rollback()
            raise HTTPException(status_code=409, detail="You have already reviewed this deal")
        await self.db.refresh(review)
        public = self._review_dict(review)
        review_id = review.id

        # User.rating is a legacy cache. Refresh it only after the review is
        # committed, under the user's row lock: two reviews can land at once,
        # and computing the average from inside each writer's transaction
        # made the slower writer store a one-review average over both rows.
        # Public surfaces read reviews/stats.py, so a failure here must not
        # fail the buyer's already-committed review.
        try:
            await self._update_seller_rating(seller_id)
        except Exception as exc:  # noqa: BLE001 - never lose the review
            await self.db.rollback()
            logger.warning("[reviews] seller rating cache refresh failed: %s", exc)

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
                await self.db.rollback()
                logger.warning("[reviews] store rating refresh failed: %s", exc)

        await publish(ReviewSubmitted(
            review_id=review_id,
            deal_id=deal_id or "",
            seller_id=seller_id,
            reviewer_id=reviewer_id,
            rating=rating,
        ))

        return public

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

        A deal that has already been reviewed stays in the answer even if
        it is later cancelled or refunded. Status decides whether a review
        may be written; it does not erase the review that exists. Dropping
        the row here made a buyer who had reviewed a now-refunded deal look
        like a stranger to the seller and shop, and the UI offered them an
        ineligible state instead of "already reviewed".
        """
        reviewed_deal = exists(select(Review.id).where(
            Review.deal_id == Deal.id,
            Review.reviewer_id == buyer_id,
        ))
        q = select(Deal.id, Deal.seller_id, Deal.listing_id, Deal.agreed_price,
                   Deal.status, Deal.created_at, Deal.released_at).where(
            Deal.buyer_id == buyer_id,
            Deal.seller_id != buyer_id,
            or_(Deal.status.in_(REVIEWABLE_STATUSES), reviewed_deal),
        )
        if seller_id:
            q = q.where(Deal.seller_id == seller_id)
        if store_id:
            # A shop page may offer only a sale genuinely made through it:
            # the listing, the store and the deal must all name the same
            # seller. Filtering on Listing.store_id alone offered a review of
            # a person's sale on another owner's shop when the data was bad.
            q = q.where(exists(
                select(Listing.id)
                .join(Store, Store.id == Listing.store_id)
                .where(
                    Listing.id == Deal.listing_id,
                    Listing.store_id == store_id,
                    Listing.seller_id == Deal.seller_id,
                    Store.owner_id == Deal.seller_id,
                )
            ))
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
            select(Listing.id, Listing.name, Listing.store_id, Listing.seller_id)
            .where(Listing.id.in_({d.listing_id for d in deals if d.listing_id})))
        listings = {lid: (name, store, seller) for lid, name, store, seller in lr.all()}
        shops = {}
        shop_ids = {store for _, store, _ in listings.values() if store}
        if shop_ids:
            shops = {sid: (name, owner) for sid, name, owner in (await self.db.execute(
                select(Store.id, Store.name, Store.owner_id)
                .where(Store.id.in_(shop_ids)))).all()}

        # Only include a shop when every link in deal -> listing -> store says
        # the same seller. A corrupt row still appears as a reviewable sale of
        # the person the buyer actually dealt with; it just cannot name an
        # unrelated shop or offer itself on that shop's page.
        metadata = {}
        for deal in deals:
            row = listings.get(deal.listing_id)
            listing_name = row[0] if row else None
            shop_id = shop_name = None
            if row and row[2] == deal.seller_id:
                shop = shops.get(row[1])
                if shop and shop[1] == deal.seller_id:
                    shop_id, shop_name = row[1], shop[0]
            metadata[deal.id] = (listing_name, shop_id, shop_name)

        return [{
            "deal_id": d.id,
            "seller_id": d.seller_id,
            "seller_name": sellers.get(d.seller_id) or "Seller",
            "listing_name": metadata[d.id][0] or "Listing",
            "store_id": metadata[d.id][1],
            "store_name": metadata[d.id][2],
            "agreed_price": d.agreed_price,
            "status": d.status.value if hasattr(d.status, "value") else d.status,
            "created_at": d.created_at.isoformat() if d.created_at else None,
            "completed_at": d.released_at.isoformat() if d.released_at else None,
            "already_reviewed": d.id in reviewed,
        } for d in deals]

    async def _update_seller_rating(self, seller_id: str) -> None:
        # with_for_update serialises concurrent cache refreshes on PostgreSQL;
        # SQLite ignores the hint and serialises the writer itself. The review
        # has already committed, so each refresh sees every committed row.
        seller = (await self.db.execute(
            select(User).where(User.id == seller_id).with_for_update()
            .execution_options(populate_existing=True)
        )).scalar_one_or_none()
        if seller is None:
            return
        r = await self.db.execute(
            select(func.avg(Review.rating)).where(Review.seller_id == seller_id)
        )
        avg = r.scalar()
        # No reviews is no average. This column is only a cache now - every
        # public surface reads reviews/stats.py - but writing 5.0 into it
        # would recreate the "unreviewed seller looks perfect" bug for any
        # legacy reader.
        # Also clear a stale cache when no reviews remain. There is no
        # delete-review route today, but moderation can remove a row;
        # leaving the old average behind would publish a score with no
        # records under it.
        seller.rating = round(float(avg), 2) if avg is not None else None
        await self.db.commit()

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
        """A review as the public reads it: the words, the stars and when -
        never the deal, reviewer or seller id. Those are for the audit row
        and the event, both of which stay inside BROKA."""
        return {
            "id": r.id,
            "rating": r.rating,
            "comment": r.comment,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
