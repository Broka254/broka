"""One-off script: backfills listings.subcategory_id from old free-text
listings.category values, for databases that have real historical
listings predating the categories table (Design Journal Volume 6, Ch.13;
taxonomy finalized per broka_mockup_actualization_spec.md §2-3).

The canonical taxonomy itself (categories, subcategories, filter fields)
is reference/application data, not historical data - it now lives in
api.domains.categories.seed and is seeded automatically on every app
startup (api.database.init_db), so a fresh/testing database gets a
working category selector with NO manual step. This script is ONLY for
the separate, optional job of converting pre-existing free-text
listings.category values into structured subcategory_id links - run it
only when there is actually old free-text listing data to convert.

Usage:
    python backend/migrate_categories_from_freetext.py            # dry run
    python backend/migrate_categories_from_freetext.py --apply     # writes

Safe to re-run: seed_categories() is idempotent, and the subcategory_id
backfill only ever touches listings where subcategory_id IS NULL - it
never overwrites a value that's already set (by this script or by hand).
"""
import argparse
import asyncio
from collections import Counter

from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AsyncSessionLocal, Category, Listing
from api.domains.categories.seed import seed_categories

# Old freetext value (lowercased, trimmed) -> new top-level category name.
# Covers both the placeholder taxonomy this script used to seed AND the
# actual live options in sell_basics_screen.dart (Vehicles/Property/
# Electronics/Livestock/General) since real listings.category values were
# written from that screen, not from the canonical taxonomy.
RENAME_MAP: dict[str, str] = {
    "automobiles": "Vehicles", "vehicles": "Vehicles",
    "property": "Property",
    "electronics": "Electronics",
    "gaming": "Gaming",
    "furniture": "Home & Furniture", "home appliances": "Home & Furniture",
    "clothing": "Fashion",
    "farm equipment": "Agriculture", "livestock": "Agriculture",
    "construction": "Construction",
    "beauty": "Beauty & Personal Care",
    "sports": "Sports & Fitness",
    "books": "Books & Education",
    "musical instruments": "Music & Instruments",
    "phones": "Electronics", "computers": "Electronics",
    "general": "Other",
}

# Old freetext value (lowercased, trimmed) -> (top-level name, exact
# subcategory name), for the cases specific enough to safely assign
# listings.subcategory_id directly rather than just the top-level. This is
# deliberately a short list: "Vehicles"/"Property"/"Electronics" alone
# don't imply which child, so those stay top-level-only (see RENAME_MAP)
# and subcategory_id is left null for them, per spec §5's explicit rule
# ("leave uncertain subcategory_id values null rather than corrupting
# data") — there's no separate top-level column on Listing to fall back
# to, so "confident about the top level but not the child" has nowhere
# safe to write and is reported only, not persisted.
CONFIDENT_SUBCATEGORY_MAP: dict[str, tuple[str, str]] = {
    "phones": ("Electronics", "Phones"),
    "computers": ("Electronics", "Laptops & Computers"),
    "livestock": ("Agriculture", "Livestock"),
}


async def migrate_categories_from_freetext(db: AsyncSession) -> int:
    """Historical-data pass only: backfill listings.subcategory_id for the
    CONFIDENT_SUBCATEGORY_MAP matches, where it's currently null. Assumes
    the canonical taxonomy already exists (main() calls seed_categories()
    first) - returns the number of listings updated.
    """
    all_cats = (await db.execute(select(Category))).scalars().all()
    by_parent_and_name = {(c.parent_id, c.name): c for c in all_cats}
    top_level_by_name = {c.name: c for c in all_cats if c.parent_id is None}

    backfilled = 0
    for map_key, (top_name, sub_name) in CONFIDENT_SUBCATEGORY_MAP.items():
        # map_key is already lowercase (it's a dict literal key above) -
        # compare against a lower+trim of the stored value so casing/
        # whitespace in the DB doesn't matter.
        top_cat = top_level_by_name.get(top_name)
        if not top_cat:
            continue
        sub_cat = by_parent_and_name.get((top_cat.id, sub_name))
        if not sub_cat:
            continue
        result = await db.execute(
            update(Listing)
            .where(
                func.lower(func.trim(Listing.category)) == map_key,
                Listing.subcategory_id.is_(None),
            )
            .values(subcategory_id=sub_cat.id)
        )
        backfilled += result.rowcount or 0
    await db.commit()
    return backfilled


async def main(apply: bool) -> None:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(Listing.category))).scalars().all()
        counts = Counter(rows)

        confident, top_level_only, unmatched = {}, {}, []
        for raw_value, n in counts.most_common():
            key = (raw_value or "").strip().lower()
            if key in CONFIDENT_SUBCATEGORY_MAP:
                confident[raw_value] = CONFIDENT_SUBCATEGORY_MAP[key]
            elif key in RENAME_MAP:
                top_level_only[raw_value] = RENAME_MAP[key]
            else:
                unmatched.append((raw_value, n))

        print(f"{len(confident)} distinct value(s) map to a specific subcategory:")
        for raw_value, (top, sub) in confident.items():
            print(f"  {counts[raw_value]:>5}  listings  ->  {raw_value!r}  =>  {top} / {sub}")
        print(f"{len(top_level_only)} distinct value(s) match a top-level category only")
        print("  (no safe specific subcategory - subcategory_id stays null for these):")
        for raw_value, top in top_level_only.items():
            print(f"  {counts[raw_value]:>5}  listings  ->  {raw_value!r}  =>  {top} (top-level only)")
        print(f"{len(unmatched)} distinct value(s) did NOT match anything - review list:")
        for raw_value, n in unmatched:
            print(f"  {n:>5}  listings  ->  {raw_value!r}")

        if not apply:
            print("\nDry run only. Re-run with --apply to write changes.")
            return

    # Canonical taxonomy: idempotent, safe even if init_db() already
    # seeded it on this app instance's last startup. Own session, run
    # after the read-only report's session above has closed - and before
    # the backfill opens a fresh one below - so the backfill is guaranteed
    # to see the newly-seeded Category rows regardless of backend/
    # isolation level, no same-transaction-visibility assumptions needed.
    seed_result = await seed_categories()
    print(f"\nCategories table seeded: {seed_result}")

    async with AsyncSessionLocal() as db:
        backfilled = await migrate_categories_from_freetext(db)
        print(f"{backfilled} listing(s) backfilled with subcategory_id.")
        print(
            f"{sum(counts[v] for v in top_level_only)} listing(s) have a known top-level "
            "category but no confident subcategory - left as-is (see list above)."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    asyncio.run(main(args.apply))
