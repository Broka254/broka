"""One-off script: remove stores that were opened without a photo of the shop.

Why this exists: a store has been required to start with at least one real
photo of itself since phase 2 (StoreService.create_store), but the rule
arrived after the first shops did. Stores opened before it can sit in the
directory with nothing but BROKA's placeholder - a shopfront a buyer
cannot see.

This platform is in testing, so those rows are removed outright, the same
way an owner deleting their store does it (StoreService.delete_store):

  * Store.deleted_at is set - a soft delete, because payments, stats,
    audit rows and listings all point at the row, and a hard DELETE would
    either fail on a foreign key or orphan money records;
  * its listings are archived (status "cancelled") so no buyer-facing
    query shows them, while deals and chats on them keep their history;
  * the slug stays reserved, so a link already printed or shared cannot
    start showing a different shop.

A store with any real photo - `photo_ids` holding at least one asset id,
or legacy `photos` holding at least one data URI/URL - is untouched.
A logo or a cover does not count, exactly as on create.

Usage:
    python backend/cleanup_photoless_stores.py                # report only
    python backend/cleanup_photoless_stores.py --store grt    # one store, dry run
    python backend/cleanup_photoless_stores.py --apply        # remove them all
    python backend/cleanup_photoless_stores.py --store grt --apply

Safe to re-run: an already-deleted store is skipped and reported.
"""
from __future__ import annotations

import argparse
import asyncio
from datetime import datetime

from sqlalchemy import select

from api.database import AsyncSessionLocal, Listing, ListingStatus
from api.domains.media.service import parse_id_list
from api.domains.stores.media import parse_photo_list
from api.models.store import Store


def has_shop_photo(store: Store) -> bool:
    """A real photo of the shop: not a logo, not a cover."""
    if parse_id_list(store.photo_ids):
        return True
    return bool(parse_photo_list(store.photos))


async def photo_less(db) -> list[Store]:
    rows = (await db.execute(
        select(Store).where(Store.deleted_at.is_(None)).order_by(Store.name)
    )).scalars().all()
    return [s for s in rows if not has_shop_photo(s)]


async def remove(db, store: Store, apply: bool) -> bool:
    from api.core.audit import record_audit

    listings = (await db.execute(
        select(Listing).where(
            Listing.store_id == store.id,
            Listing.status == ListingStatus.active,
        )
    )).scalars().all()
    if not apply:
        print(f"  {store.slug:<32} {store.name!r:<28} "
              f"{len(listings)} listing(s) would be archived")
        return True

    now = datetime.utcnow()
    for listing in listings:
        listing.status = ListingStatus.cancelled
        listing.is_featured = False
    store.deleted_at = now
    store.is_active = False
    store.updated_at = now
    await record_audit(
        db, "system", "store_deleted_no_photo", "store", store.id,
        detail=f"slug={store.slug!r} name={store.name!r} archived_listings={len(listings)}",
    )
    await db.commit()
    print(f"  {store.slug:<32} {store.name!r:<28} removed, "
          f"{len(listings)} listing(s) archived")
    return True


async def main(slugs: list[str], apply: bool) -> None:
    async with AsyncSessionLocal() as db:
        stores = await photo_less(db)
        if slugs:
            wanted = {s.lower() for s in slugs}
            stores = [s for s in stores if s.slug.lower() in wanted or s.id in slugs]
            missing = wanted - {s.slug.lower() for s in stores} - {s.id for s in stores}
            for name in sorted(missing):
                print(f"  {name}: no open store with that slug/id and no photo - nothing to do.")
        if not stores:
            print("Every open store has a photo of the shop. Nothing to remove.")
            return
        print(f"{'Removing' if apply else 'Dry run - would remove'} "
              f"{len(stores)} store(s) with no photo of the shop:")
        for store in stores:
            await remove(db, store, apply)
        if not apply:
            print("\nRe-run with --apply to write.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Remove stores that have no photo of the shop.")
    parser.add_argument("--store", action="append", default=[], metavar="SLUG|ID",
                        help="limit to these stores (repeatable)")
    parser.add_argument("--apply", action="store_true",
                        help="write changes (default: dry run)")
    args = parser.parse_args()
    asyncio.run(main(args.store, args.apply))
