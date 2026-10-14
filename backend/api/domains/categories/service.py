"""Categories Service — top-level categories, subcategories, and their
filter metadata (Design Journal Volume 6, Ch.24).

Order: categories come back in the curated order seed.py lists them in -
the most common first, "Other" last - not alphabetically. Alphabetical put
"Agriculture" at the top of the Home rail and "Other" in the middle of it,
and in the sell wizard's vertical category list a seller would scan past
"Business & Industrial" to find their car. Rows the seed doesn't know
(added by hand, or by a test) follow, alphabetically.
"""
from __future__ import annotations

import json
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Category, CategoryFilter
from .seed import CANONICAL_CATEGORIES, SUBCATEGORIES

_TOP_RANK = {name: i for i, name in enumerate(CANONICAL_CATEGORIES)}
_SUB_RANK = {
    parent: {name: i for i, name in enumerate(names)}
    for parent, names in SUBCATEGORIES.items()
}


def _top_order(c: Category) -> tuple:
    return (_TOP_RANK.get(c.name, len(_TOP_RANK)), c.name.lower())


def _sub_order(parent_name: str | None):
    ranks = _SUB_RANK.get(parent_name or "", {})
    return lambda c: (ranks.get(c.name, len(ranks)), c.name.lower())


class CategoriesService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_top_level(self) -> list[dict]:
        result = await self.db.execute(select(Category).where(Category.parent_id.is_(None)))
        rows = sorted(result.scalars().all(), key=_top_order)
        return [self._category_dict(c) for c in rows]

    async def list_subcategories(self, category_id: str) -> list[dict]:
        parent = await self.db.get(Category, category_id)
        result = await self.db.execute(select(Category).where(Category.parent_id == category_id))
        rows = sorted(result.scalars().all(), key=_sub_order(parent.name if parent else None))
        return [self._category_dict(c) for c in rows]

    async def tree(self) -> list[dict]:
        """Every top-level category with its subcategories, in display
        order - what the sell wizard's category step needs, in one request
        instead of one per category (a seller searching "maize" has to
        search every category's subcategories at once)."""
        rows = (await self.db.execute(select(Category))).scalars().all()
        children: dict[str, list[Category]] = {}
        for c in rows:
            if c.parent_id is not None:
                children.setdefault(c.parent_id, []).append(c)
        tops = sorted((c for c in rows if c.parent_id is None), key=_top_order)
        return [
            {
                **self._category_dict(top),
                "subcategories": [
                    self._category_dict(sub)
                    for sub in sorted(children.get(top.id, []), key=_sub_order(top.name))
                ],
            }
            for top in tops
        ]

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
