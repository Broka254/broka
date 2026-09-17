# ==========================================================================
# DEAD CODE - NOT MOUNTED, NOT IMPORTED.
#
# Verified 2026-09-14 by reading main.py directly rather than trusting
# comments: this module's name does not appear in main.py's
# `from api.routers import (...)` tuple, and no `app.include_router(...)`
# call references it. Nothing in the backend imports it either. None of
# its routes are reachable at runtime.
#
# Canonical replacement: api/domains/reviews/router.py   (mounted at /reviews)
#
# QUARANTINED, NOT DELETED (spec section 21). Deleting it is a separate,
# reversible commit that should be made once someone has confirmed no
# out-of-tree consumer (a script, a notebook, an ops runbook) imports it.
# Leaving it importable but clearly marked costs nothing; deleting it
# blind is the failure mode that section warns about.
#
# Do not add routes here. Do not mount this module.
# ==========================================================================
"""
⚠️  NOT MOUNTED — LEGACY / DEAD CODE (verified during Store hardening
pass, 2026-09: never imported in main.py). Canonical implementation is
api/domains/reviews/router.py. Left in place rather than deleted; do not
edit this file expecting it to affect the running app. ⚠️

BROKA - Seller Reviews Router
Buyers who have completed a deal with a seller can leave a star rating (1-5) and comment.
The seller's overall rating is recalculated as a rolling average on each new review.

Endpoints:
  POST /reviews/           - submit a review (buyer auth required)
  GET  /reviews/{seller_id} - list all reviews for a seller (public)
  GET  /reviews/summary/{seller_id} - avg + distribution (public)
  GET  /reviews/my-deals   - return deals current user can still review (buyer view)
  GET  /reviews/check/{deal_id} - has the current user already reviewed this deal?
"""

import logging
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func, and_

from api.database import get_db, Deal, Review, User, DealStatus
from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()


# ── Schemas ───────────────────────────────────────────────────────────────────

class ReviewIn(BaseModel):
    deal_id:  str
    rating:   int   = Field(..., ge=1, le=5)
    comment:  str   = Field("", max_length=500)


class ReviewOut(BaseModel):
    id:            str
    reviewer_name: str
    reviewer_photo: str | None = None
    rating:        int
    comment:       str
    created_at:    str


# ── Helpers ───────────────────────────────────────────────────────────────────

async def _recalc_seller_rating(seller_id: str, db: AsyncSession):
    """Recompute seller.rating as average of all their reviews (1-5 scale)."""
    result = await db.execute(
        select(func.avg(Review.rating)).where(Review.seller_id == seller_id)
    )
    avg = result.scalar()
    if avg is not None:
        sr = await db.execute(select(User).where(User.id == seller_id))
        seller = sr.scalar_one_or_none()
        if seller:
            seller.rating = round(float(avg), 2)


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.post("/")
async def submit_review(
    data:         ReviewIn,
    current_user = Depends(get_current_user),
    db:           AsyncSession = Depends(get_db),
):
    """Submit a rating + comment for a completed deal."""
    reviewer_id = current_user["id"]

    # Fetch the deal
    dr = await db.execute(select(Deal).where(Deal.id == data.deal_id))
    deal = dr.scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found.")

    # Only the buyer of this deal can review the seller
    if deal.buyer_id != reviewer_id:
        raise HTTPException(status_code=403,
                            detail="Only the buyer of this deal can leave a review.")

    # Deal must be in agreed / released state (not cancelled)
    # DealStatus.completed doesn't exist on this enum - was DealStatus.
    # released here, but the typo meant this line raised AttributeError
    # the instant it ran, for every deal regardless of status. This
    # endpoint has never successfully completed a review as a result.
    if deal.status not in (DealStatus.agreed, DealStatus.released):
        raise HTTPException(status_code=400,
                            detail="Cannot review a deal that was not completed.")

    # One review per deal
    existing = await db.execute(
        select(Review).where(
            and_(Review.deal_id == data.deal_id, Review.reviewer_id == reviewer_id)
        )
    )
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=409,
                            detail="You have already reviewed this deal.")

    review = Review(
        deal_id     = data.deal_id,
        reviewer_id = reviewer_id,
        seller_id   = deal.seller_id,
        rating      = data.rating,
        comment     = data.comment.strip(),
    )
    db.add(review)

    # No deal.status mutation and no completed_deals bump here, on purpose.
    # Both already happen correctly in the actual escrow-release flow
    # (routers/escrow.py confirm_delivery, core/workers.py's auto-release) -
    # this endpoint used to also set deal.status = DealStatus.completed
    # (the same nonexistent value fixed above) and bump
    # seller.completed_deals as a side effect of reviewing. Once the crash
    # was fixed, that would have double-counted completed_deals for every
    # deal that's both released and reviewed - which is the normal case,
    # not an edge case. A review should record an opinion, not redefine
    # escrow or stats state that a separate, already-correct code path owns.

    await db.flush()
    await _recalc_seller_rating(deal.seller_id, db)
    await db.commit()

    return {"message": "Review submitted. Thank you!", "review_id": review.id}


@router.get("/check/{deal_id}")
async def check_review(
    deal_id:     str,
    current_user = Depends(get_current_user),
    db:          AsyncSession = Depends(get_db),
):
    """Check whether the current user has already reviewed this deal."""
    result = await db.execute(
        select(Review).where(
            and_(Review.deal_id == deal_id,
                 Review.reviewer_id == current_user["id"])
        )
    )
    reviewed = result.scalar_one_or_none() is not None
    return {"already_reviewed": reviewed}


@router.get("/my-deals")
async def my_reviewable_deals(
    current_user = Depends(get_current_user),
    db:          AsyncSession = Depends(get_db),
):
    """Return deals where this user is the buyer and can still leave a review."""
    buyer_id = current_user["id"]

    # All deals as buyer
    dr = await db.execute(
        select(Deal).where(Deal.buyer_id == buyer_id)
        .order_by(Deal.created_at.desc())
    )
    deals = dr.scalars().all()

    # Which ones already have a review from this buyer?
    reviewed_ids: set[str] = set()
    if deals:
        rv = await db.execute(
            select(Review.deal_id).where(
                and_(Review.reviewer_id == buyer_id,
                     Review.deal_id.in_([d.id for d in deals]))
            )
        )
        reviewed_ids = {row[0] for row in rv.all()}

    result = []
    reviewable_deals = [d for d in deals if d.status in (DealStatus.agreed, DealStatus.released)]
    # DealStatus.completed doesn't exist - see submit_review's identical fix above.

    # Batched: one query for every seller and every listing this buyer's
    # deals reference, instead of 2 queries per deal (was a real N+1 - a
    # buyer with many past deals triggered that many round trips just to
    # list which ones are reviewable).
    seller_ids = list({d.seller_id for d in reviewable_deals})
    listing_ids = list({d.listing_id for d in reviewable_deals})
    sellers_by_id: dict = {}
    listing_names_by_id: dict = {}
    if seller_ids:
        sr = await db.execute(select(User).where(User.id.in_(seller_ids)))
        sellers_by_id = {u.id: u for u in sr.scalars().all()}
    if listing_ids:
        from api.database import Listing
        lr = await db.execute(select(Listing.id, Listing.name).where(Listing.id.in_(listing_ids)))
        listing_names_by_id = {lid: name for lid, name in lr.all()}

    for d in reviewable_deals:
        seller = sellers_by_id.get(d.seller_id)
        listing_name = listing_names_by_id.get(d.listing_id, "Listing")

        result.append({
            "deal_id":       d.id,
            "seller_id":     d.seller_id,
            "seller_name":   seller.name if seller else "Seller",
            "listing_name":  listing_name,
            "agreed_price":  d.agreed_price,
            "created_at":    d.created_at.isoformat(),
            "already_reviewed": d.id in reviewed_ids,
        })

    return {"deals": result}


@router.get("/summary/{seller_id}")
async def review_summary(seller_id: str, db: AsyncSession = Depends(get_db)):
    """Return avg rating, count, and star distribution for a seller."""
    result = await db.execute(
        select(Review).where(Review.seller_id == seller_id)
    )
    reviews = result.scalars().all()
    if not reviews:
        return {"avg": 0.0, "count": 0, "distribution": {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}}

    dist = {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
    total = 0
    for r in reviews:
        dist[r.rating] = dist.get(r.rating, 0) + 1
        total += r.rating
    avg = round(total / len(reviews), 1)
    return {"avg": avg, "count": len(reviews), "distribution": dist}


@router.get("/{seller_id}")
async def get_reviews(
    seller_id: str,
    limit:     int = 20,
    offset:    int = 0,
    db:        AsyncSession = Depends(get_db),
):
    """List reviews for a seller - newest first, with reviewer display name."""
    result = await db.execute(
        select(Review)
        .where(Review.seller_id == seller_id)
        .order_by(Review.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    reviews = result.scalars().all()

    out = []
    for r in reviews:
        ur = await db.execute(select(User).where(User.id == r.reviewer_id))
        user = ur.scalar_one_or_none()
        display_name = "Anonymous"
        photo = None
        if user:
            nickname = getattr(user, "nickname", None)
            display_name = nickname or user.name or "Broka User"
            # Truncate to first name + initial for privacy
            parts = display_name.strip().split()
            if len(parts) >= 2:
                display_name = f"{parts[0]} {parts[1][0]}."
            photo = user.profile_photo
        out.append({
            "id":             r.id,
            "reviewer_name":  display_name,
            "reviewer_photo": photo,
            "rating":         r.rating,
            "comment":        r.comment or "",
            "created_at":     r.created_at.isoformat(),
        })
    return {"reviews": out}
