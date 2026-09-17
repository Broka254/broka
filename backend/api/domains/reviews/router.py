"""Reviews Router v3.0"""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends
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
    db: AsyncSession = Depends(get_db),
):
    svc = ReviewService(db)
    return await svc.get_seller_reviews(seller_id)
