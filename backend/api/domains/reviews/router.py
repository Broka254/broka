"""Reviews Router v3.0

The app's profile and review screens called /reviews/summary/{id},
/reviews/my-deals and /reviews/{id} - routes of the unmounted legacy router
(api/routers/reviews.py) - so every request 404ed: every seller showed
"No reviews yet" and the review screen could never list a deal to review.
They are served here now.
"""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import ReviewService

router = APIRouter()


class ReviewIn(BaseModel):
    deal_id: str
    rating: int
    comment: Optional[str] = ""


@router.post("/", status_code=201)
async def submit_review(
    body: ReviewIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ReviewService(db)
    return await svc.submit_review(
        deal_id=body.deal_id,
        reviewer_id=current_user["id"],
        rating=body.rating,
        comment=body.comment or "",
    )


@router.get("/seller/{seller_id}")
async def get_seller_reviews(
    seller_id: str,
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    svc = ReviewService(db)
    return await svc.get_seller_reviews(seller_id, limit=limit, offset=offset)


@router.get("/summary/{seller_id}")
async def get_review_summary(
    seller_id: str,
    db: AsyncSession = Depends(get_db),
):
    return await ReviewService(db).get_summary(seller_id)


@router.get("/my-deals")
async def my_reviewable_deals(
    seller_id: Optional[str] = None,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    deals = await ReviewService(db).my_reviewable_deals(current_user["id"], seller_id)
    return {"deals": deals}
