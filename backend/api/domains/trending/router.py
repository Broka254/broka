"""Trending Router v1 — GET /trending."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from .service import TrendingService

router = APIRouter()


@router.get("")
async def get_trending(
    category_id: Optional[str] = None,
    limit: int = 20,
    offset: int = 0,
    db: AsyncSession = Depends(get_db),
):
    return await TrendingService(db).list_trending(limit=limit, offset=offset, category_id=category_id)
