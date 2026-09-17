"""Categories Service — top-level categories, subcategories, and their
filter metadata (Design Journal Volume 6, Ch.24).
"""
from __future__ import annotations

import json
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Category, CategoryFilter


class CategoriesService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_top_level(self) -> list[dict]:
        result = await self.db.execute(
            select(Category).where(Category.parent_id.is_(None)).order_by(Category.name)
        )
        return [self._category_dict(c) for c in result.scalars().all()]

    async def list_subcategories(self, category_id: str) -> list[dict]:
        result = await self.db.execute(
            select(Category).where(Category.parent_id == category_id).order_by(Category.name)
        )
        return [self._category_dict(c) for c in result.scalars().all()]

    async def list_filters(self, category_id: str) -> list[dict]:
        result = await self.db.execute(
            select(CategoryFilter).where(CategoryFilter.category_id == category_id)
        )
        return [
            {
                "field_name": f.field_name,
                "field_type": f.field_type,
                "options": json.loads(f.options) if f.options else None,
            }
            for f in result.scalars().all()
        ]

    def _category_dict(self, c: Category) -> dict:
        return {"id": c.id, "name": c.name, "icon": c.icon, "parent_id": c.parent_id}
