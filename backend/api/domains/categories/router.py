"""Categories Router v1 — GET /categories, /categories/{id}/subcategories, /categories/{id}/filters."""
from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from .service import CategoriesService

router = APIRouter()


@router.get("")
async def list_categories(db: AsyncSession = Depends(get_db)):
    return await CategoriesService(db).list_top_level()


@router.get("/{category_id}/subcategories")
async def list_subcategories(category_id: str, db: AsyncSession = Depends(get_db)):
    return await CategoriesService(db).list_subcategories(category_id)


@router.get("/{category_id}/filters")
async def list_filters(category_id: str, db: AsyncSession = Depends(get_db)):
    return await CategoriesService(db).list_filters(category_id)
