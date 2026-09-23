"""Convert images still stored as base64 into image assets.

Rows written before image assets existed - and rows still written by app
builds that send base64 - carry their images inline. This turns them into
assets a batch at a time:

  listings  verified_photos     -> photo_ids     (base64 kept for older app
            showcase_image_url  -> showcase_id    builds' product pages)
  stores    logo_url            -> logo_id       (base64 cleared once
            photos              -> photo_ids      converted)
  users     profile_photo       -> profile_photo_id (base64 kept: profile
                                                  endpoints still return it)

"Pending" is the id column being NULL while the legacy column has data.
Anything that changes a legacy column sets its id back to NULL, so it is
converted again. A value that can't be converted gets "[]" / "" so it
isn't retried on every pass; readers treat those as "no asset" and fall
back to the legacy data.

Every write is a compare-and-swap: the id column is only set if it is
still NULL and the legacy value is still the one that was converted. A
seller who edits their photos while a pass is converting the old ones
keeps the edit; two instances converting the same row can't both win.
Assets from a lost race are left unreferenced.

Runs a bounded pass from the 5-minute sweep (api/core/workers.py) and from
POST /admin/media/backfill.
"""
from __future__ import annotations

import json
import logging
import time

from sqlalchemy import func, select, update

from api.core.image_processing import ImageRejected
from api.core.media_storage import StorageError
from api.database import AsyncSessionLocal, Listing, User
from api.models.media import MediaPurpose
from api.models.store import Store
from .service import (
    MAX_LISTING_PHOTOS, MAX_STORE_PHOTOS, create_image_asset, decode_legacy_image,
    dump_id_list, split_legacy_photos,
)

logger = logging.getLogger(__name__)

ROWS_PER_KIND = 10
TIME_BUDGET_SECONDS = 20.0


class _Budget:
    def __init__(self, seconds: float):
        self.deadline = time.monotonic() + seconds

    @property
    def spent(self) -> bool:
        return time.monotonic() >= self.deadline


async def _convert(db, owner_id: str, purpose: str, values: list[str]) -> list[str]:
    """Asset ids for the values that are real images. StorageError
    propagates: storage being down must stop the pass, not mark rows as
    unconvertible."""
    ids: list[str] = []
    for value in values:
        raw = decode_legacy_image(value)
        if raw is None:
            continue
        try:
            asset = await create_image_asset(db, owner_id, purpose, raw)
        except ImageRejected:
            continue
        ids.append(asset.id)
    return ids


async def _cas(db, stmt) -> bool:
    result = await db.execute(stmt)
    if result.rowcount:
        await db.commit()
        return True
    await db.rollback()
    return False


def _pending_listing_photos():
    return select(Listing).where(
        Listing.photo_ids.is_(None),
        Listing.verified_photos.isnot(None), Listing.verified_photos != "",
    )


def _pending_showcases():
    return select(Listing).where(
        Listing.showcase_id.is_(None), Listing.showcase_image_url.like("data:%"),
    )


def _pending_store_logos():
    return select(Store).where(
        Store.logo_id.is_(None), Store.logo_url.isnot(None), Store.logo_url != "",
    )


def _pending_store_photos():
    return select(Store).where(
        Store.photo_ids.is_(None), Store.photos.isnot(None),
        Store.photos != "", Store.photos != "[]",
    )


def _pending_avatars():
    return select(User).where(
        User.profile_photo_id.is_(None),
        User.profile_photo.isnot(None), User.profile_photo != "",
    )


async def run_backfill_pass(
    rows_per_kind: int = ROWS_PER_KIND, time_budget: float = TIME_BUDGET_SECONDS,
) -> dict:
    """Convert up to `rows_per_kind` rows of each kind, stopping early when
    the time budget is spent or storage fails. Returns what it did."""
    done = {"listing_photos": 0, "showcases": 0, "store_logos": 0,
            "store_photos": 0, "avatars": 0, "unconvertible": 0}
    budget = _Budget(time_budget)

    async with AsyncSessionLocal() as db:
        try:
            # ── Listing photos ─────────────────────────────────────────────
            for listing in (await db.execute(_pending_listing_photos().limit(rows_per_kind))).scalars().all():
                if budget.spent:
                    break
                legacy = listing.verified_photos
                ids = await _convert(
                    db, listing.seller_id, MediaPurpose.LISTING_PHOTO,
                    split_legacy_photos(legacy)[:MAX_LISTING_PHOTOS],
                )
                if await _cas(db, update(Listing).where(
                    Listing.id == listing.id, Listing.photo_ids.is_(None),
                    Listing.verified_photos == legacy,
                ).values(photo_ids=dump_id_list(ids))):
                    done["listing_photos" if ids else "unconvertible"] += 1

            # ── Listing showcases ──────────────────────────────────────────
            for listing in (await db.execute(_pending_showcases().limit(rows_per_kind))).scalars().all():
                if budget.spent:
                    break
                legacy = listing.showcase_image_url
                ids = await _convert(db, listing.seller_id, MediaPurpose.LISTING_SHOWCASE, [legacy])
                if await _cas(db, update(Listing).where(
                    Listing.id == listing.id, Listing.showcase_id.is_(None),
                    Listing.showcase_image_url == legacy,
                ).values(showcase_id=ids[0] if ids else "")):
                    done["showcases" if ids else "unconvertible"] += 1

            # ── Store logos (legacy copy cleared once converted) ───────────
            for store in (await db.execute(_pending_store_logos().limit(rows_per_kind))).scalars().all():
                if budget.spent:
                    break
                legacy = store.logo_url
                ids = await _convert(db, store.owner_id, MediaPurpose.STORE_LOGO, [legacy])
                values = {"logo_id": ids[0], "logo_url": None} if ids else {"logo_id": ""}
                if await _cas(db, update(Store).where(
                    Store.id == store.id, Store.logo_id.is_(None), Store.logo_url == legacy,
                ).values(**values)):
                    done["store_logos" if ids else "unconvertible"] += 1

            # ── Store photos ───────────────────────────────────────────────
            for store in (await db.execute(_pending_store_photos().limit(rows_per_kind))).scalars().all():
                if budget.spent:
                    break
                legacy = store.photos
                try:
                    values_in = json.loads(legacy)
                except (TypeError, ValueError):
                    values_in = []
                values_in = [v for v in values_in if isinstance(v, str)] if isinstance(values_in, list) else []
                ids = await _convert(db, store.owner_id, MediaPurpose.STORE_PHOTO, values_in[:MAX_STORE_PHOTOS])
                values = {"photo_ids": dump_id_list(ids), "photos": None} if ids else {"photo_ids": "[]"}
                if await _cas(db, update(Store).where(
                    Store.id == store.id, Store.photo_ids.is_(None), Store.photos == legacy,
                ).values(**values)):
                    done["store_photos" if ids else "unconvertible"] += 1

            # ── Avatars ────────────────────────────────────────────────────
            for user in (await db.execute(_pending_avatars().limit(rows_per_kind))).scalars().all():
                if budget.spent:
                    break
                legacy = user.profile_photo
                ids = await _convert(db, user.id, MediaPurpose.AVATAR, [legacy])
                if await _cas(db, update(User).where(
                    User.id == user.id, User.profile_photo_id.is_(None),
                    User.profile_photo == legacy,
                ).values(profile_photo_id=ids[0] if ids else "")):
                    done["avatars" if ids else "unconvertible"] += 1
        except StorageError as exc:
            await db.rollback()
            logger.error("[media-backfill] stopped: storage unavailable (%s)", exc)
            done["stopped"] = "storage unavailable"

    converted = sum(v for k, v in done.items() if isinstance(v, int))
    if converted:
        logger.info("[media-backfill] pass done %s", done)
    return done


async def pending_counts() -> dict:
    """How many rows of each kind still wait for conversion."""
    async with AsyncSessionLocal() as db:
        async def count(q) -> int:
            return (await db.execute(select(func.count()).select_from(q.subquery()))).scalar_one()
        return {
            "listing_photos": await count(_pending_listing_photos()),
            "showcases": await count(_pending_showcases()),
            "store_logos": await count(_pending_store_logos()),
            "store_photos": await count(_pending_store_photos()),
            "avatars": await count(_pending_avatars()),
        }
