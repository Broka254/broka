"""A store's category: one of BROKA's top-level categories.

Stores used to carry a free-text "specialization" from an 11-item list
of the old setup screen, and sellers' signup business category comes from
a different 9-item list. Both are mapped onto the canonical taxonomy here,
so every store - old or new - reports a category the app can show with
the same icon and colour as the home screen's category rail.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import select, update

from api.domains.categories.seed import (
    CANONICAL_CATEGORIES, RENAMED_CATEGORIES, canonical_category_name,
)

OTHER = "Other"

_CANONICAL_BY_LOWER = {c.lower(): c for c in CANONICAL_CATEGORIES}

# Old store-setup "specializations" and signup business categories that
# aren't themselves canonical names.
_LEGACY = {
    "wholesale": "Business & Industrial",
    "clothing & fashion": "Fashion",
    "furniture": "Home & Furniture",
    "appliances": "Home & Furniture",
    "automotive": "Automobiles",
    "building materials": "Construction",
    "phones & accessories": "Electronics",
    "general merchandise": "Other",
    "supermarket": "Other",
}


def canonical(value: Optional[str]) -> Optional[str]:
    """The canonical category for `value` if it is one (any case), else
    None. For validating what a client sends."""
    if not value:
        return None
    # A renamed category's old name ("Vehicles") still means that category.
    return _CANONICAL_BY_LOWER.get(canonical_category_name(value).strip().lower())


def from_legacy(value: Optional[str]) -> Optional[str]:
    """Best canonical category for an old specialization or a signup
    business category. Unknown free text maps to "Other"; nothing maps to
    None."""
    if not value or not value.strip():
        return None
    key = value.strip().lower()
    return canonical(value) or _LEGACY.get(key) or "Other"


def for_listing(value: Optional[str]) -> str:
    """The top-level category a listing counts under in a store's
    category rail. Listing.category is canonical for anything posted
    through the current sell flow; older free text lands in "Other"."""
    return canonical(value) or OTHER


def named_listing_categories() -> list[str]:
    """Every lower-cased Listing.category that for_listing() files under a
    category of its own, not under "Other": the canonical names and the old
    names of renamed ones. A store's "Other" shelf is every listing outside
    this list - exactly what the category rail counts as "Other"."""
    names = {c.lower() for c in CANONICAL_CATEGORIES if c != OTHER}
    names.update(old.lower() for old, new in RENAMED_CATEGORIES.items() if new != OTHER)
    return sorted(names)


async def backfill_store_categories() -> int:
    """Give every store that only has a legacy specialization its
    canonical category, so filtering the directory by category finds old
    stores too. Idempotent (only touches rows with no category) and cheap:
    stores number in the thousands at most, and after the first run there
    is nothing left to do. Returns how many stores were updated."""
    from api.database import AsyncSessionLocal
    from api.models.store import Store

    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(Store.id, Store.specialization)
            .where(Store.category.is_(None), Store.specialization.is_not(None))
        )).all()
        for store_id, specialization in rows:
            await db.execute(
                update(Store).where(Store.id == store_id, Store.category.is_(None))
                .values(category=from_legacy(specialization))
            )
        await db.commit()
    return len(rows)
