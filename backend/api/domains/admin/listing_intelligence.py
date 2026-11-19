"""Admin listing intelligence: rankings, trending, per-listing performance.

Read-only. Nothing here changes a listing's status, price or ranking - the
seller-facing rank is computed elsewhere from different signals. These routes
answer "what is popular, what is growing, what is stuck", and every response
carries the model that produced it.
"""
from __future__ import annotations

from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import listing_intelligence
from api.core.permissions import Permission, require_permission
from api.database import User, get_db

router = APIRouter()


@router.get("/intelligence/listings")
async def listing_rankings(
    window: Literal["24h", "7d", "30d"] = Query("7d"),
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    sort: Literal[
        "trending", "unique_viewers", "saves", "likes", "contacts", "negotiations"
    ] = Query("trending"),
    limit: int = Query(25, ge=1, le=100),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Rankings for one window. `trending` compares against the equal-length
    window immediately before, and discloses its weights in the response."""
    try:
        start, end, _label = listing_intelligence.parse_range(
            window=window, from_raw=from_, to_raw=to
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    try:
        return await listing_intelligence.rankings(
            db, start=start, end=end, sort=sort, limit=limit
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))


# Declared before /{listing_id}: "insights" is a literal segment, and a path
# parameter declared first would swallow it.
@router.get("/intelligence/listings/insights")
async def listing_insights(
    window: Literal["24h", "7d", "30d"] = Query("7d"),
    from_: Optional[str] = Query(None, alias="from"),
    to: Optional[str] = Query(None),
    limit: int = Query(20, ge=1, le=100),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Listings with a reason to look at them now, each with its evidence."""
    try:
        start, end, _label = listing_intelligence.parse_range(
            window=window, from_raw=from_, to_raw=to
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc))
    return await listing_intelligence.listing_insights(
        db, start=start, end=end, limit=limit
    )


@router.get("/intelligence/listings/{listing_id}")
async def listing_performance(
    listing_id: str,
    days: int = Query(30, ge=1, le=180),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    detail = await listing_intelligence.listing_detail(db, listing_id, days=days)
    if detail is None:
        raise HTTPException(status_code=404, detail="Listing not found")
    return detail
