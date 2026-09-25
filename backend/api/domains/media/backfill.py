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
    dump_id_list, resolve_own_asset, split_legacy_photos,
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
    """Asset ids for the values that are real images, in order.

    A value that is one of BROKA's own image URLs (an app build that
    predates assets re-saving what it was shown) resolves to that asset
    when the owner uploaded it for a compatible purpose. Anything else
    that can't be used - not an image, damaged, too large - is skipped.

    StorageError propagates: storage being down must stop the pass, not
    mark rows as unconvertible. Any other failure on one value is that
    value's problem only; it used to escape and abort the whole pass, on
    the same row, every five minutes."""
    ids: list[str] = []
    for value in values:
        own = await resolve_own_asset(db, owner_id, value, purpose)
        if own is not None:
            if own not in ids:
                ids.append(own)
            continue
        raw = decode_legacy_image(value)
        if raw is None:
            continue
        try:
            asset = await create_image_asset(db, owner_id, purpose, raw, attached=True)
        except StorageError:
            raise
        except ImageRejected:
            continue
        except Exception:
            logger.exception("[media-backfill] skipped an image for owner %s", owner_id)
            continue
        ids.append(asset.id)
    return ids


async def _row(db, label: str, row_id: str, work, give_up) -> bool:
    """Runs one row's conversion. StorageError stops the pass. Any other
    error is logged, the row is marked unconvertible with `give_up()` (an
    UPDATE statement) so it doesn't come back first on every pass, and the
    pass moves on. Returns whether the row gave up."""
    try:
        await work()
        return False
    except StorageError:
        raise
    except Exception:
        logger.exception("[media-backfill] %s %s failed; marking it unconvertible", label, row_id)
        try:
            await db.rollback()
            return await _cas(db, give_up())
        except Exception:
            logger.exception("[media-backfill] could not mark %s %s", label, row_id)
            try:
                await db.rollback()
            except Exception:
                pass
            return False


async def _cas(db, stmt) -> bool:
    result = await db.execute(stmt)
    if result.rowcount:
        await db.commit()
        return True
    await db.rollback()
    return False


# Each query selects plain columns, never ORM rows: a lost compare-and-swap
# rolls the session back, and a rollback expires every loaded object, so
# reading the next ORM row would try a lazy load - which fails outright
# under asyncio. Tuples can't expire. Oldest first, so the backlog drains
# in a stable order.

def _pending_listing_photos():
    return select(Listing.id, Listing.seller_id, Listing.verified_photos).where(
        Listing.photo_ids.is_(None),
        Listing.verified_photos.isnot(None), Listing.verified_photos != "",
    ).order_by(Listing.created_at, Listing.id)


def _pending_showcases():
    return select(Listing.id, Listing.seller_id, Listing.showcase_image_url).where(
        Listing.showcase_id.is_(None), Listing.showcase_image_url.like("data:%"),
    ).order_by(Listing.created_at, Listing.id)


def _pending_store_logos():
    return select(Store.id, Store.owner_id, Store.logo_url).where(
        Store.logo_id.is_(None), Store.logo_url.isnot(None), Store.logo_url != "",
    ).order_by(Store.created_at, Store.id)


def _pending_store_photos():
    return select(Store.id, Store.owner_id, Store.photos).where(
        Store.photo_ids.is_(None), Store.photos.isnot(None),
        Store.photos != "", Store.photos != "[]",
    ).order_by(Store.created_at, Store.id)


def _pending_avatars():
    return select(User.id, User.id.label("owner_id"), User.profile_photo).where(
        User.profile_photo_id.is_(None),
        User.profile_photo.isnot(None), User.profile_photo != "",
    ).order_by(User.created_at, User.id)


def _json_strings(raw) -> list[str]:
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return [v for v in value if isinstance(v, str)] if isinstance(value, list) else []


async def run_backfill_pass(
    rows_per_kind: int = ROWS_PER_KIND, time_budget: float = TIME_BUDGET_SECONDS,
) -> dict:
    """Convert up to `rows_per_kind` rows of each kind, stopping early when
    the time budget is spent or storage fails. Returns what it did.

    One row that can't be converted never stops the pass: its images are
    skipped (see _convert) and the row is marked so it isn't retried; an
    unexpected error on a row is logged and the pass moves on."""
    done = {"listing_photos": 0, "showcases": 0, "store_logos": 0,
            "store_photos": 0, "avatars": 0, "unconvertible": 0}
    budget = _Budget(time_budget)

    async with AsyncSessionLocal() as db:
        async def each(query, label: str, convert, give_up) -> None:
            for row_id, owner_id, legacy in (await db.execute(query.limit(rows_per_kind))).all():
                if budget.spent:
                    return
                if await _row(
                    db, label, row_id,
                    lambda: convert(row_id, owner_id, legacy),
                    lambda: give_up(row_id, legacy),
                ):
                    done["unconvertible"] += 1

        async def listing_photos(listing_id, seller_id, legacy):
            ids = await _convert(
                db, seller_id, MediaPurpose.LISTING_PHOTO,
                split_legacy_photos(legacy)[:MAX_LISTING_PHOTOS],
            )
            if await _cas(db, update(Listing).where(
                Listing.id == listing_id, Listing.photo_ids.is_(None),
                Listing.verified_photos == legacy,
            ).values(photo_ids=dump_id_list(ids))):
                done["listing_photos" if ids else "unconvertible"] += 1

        async def showcases(listing_id, seller_id, legacy):
            ids = await _convert(db, seller_id, MediaPurpose.LISTING_SHOWCASE, [legacy])
            if await _cas(db, update(Listing).where(
                Listing.id == listing_id, Listing.showcase_id.is_(None),
                Listing.showcase_image_url == legacy,
            ).values(showcase_id=ids[0] if ids else "")):
                done["showcases" if ids else "unconvertible"] += 1

        async def store_logos(store_id, owner_id, legacy):
            # The legacy copy is cleared once converted.
            ids = await _convert(db, owner_id, MediaPurpose.STORE_LOGO, [legacy])
            values = {"logo_id": ids[0], "logo_url": None} if ids else {"logo_id": ""}
            if await _cas(db, update(Store).where(
                Store.id == store_id, Store.logo_id.is_(None), Store.logo_url == legacy,
            ).values(**values)):
                done["store_logos" if ids else "unconvertible"] += 1

        async def store_photos(store_id, owner_id, legacy):
            ids = await _convert(
                db, owner_id, MediaPurpose.STORE_PHOTO, _json_strings(legacy)[:MAX_STORE_PHOTOS],
            )
            values = {"photo_ids": dump_id_list(ids), "photos": None} if ids else {"photo_ids": "[]"}
            if await _cas(db, update(Store).where(
                Store.id == store_id, Store.photo_ids.is_(None), Store.photos == legacy,
            ).values(**values)):
                done["store_photos" if ids else "unconvertible"] += 1

        async def avatars(user_id, _owner_id, legacy):
            ids = await _convert(db, user_id, MediaPurpose.AVATAR, [legacy])
            if await _cas(db, update(User).where(
                User.id == user_id, User.profile_photo_id.is_(None),
                User.profile_photo == legacy,
            ).values(profile_photo_id=ids[0] if ids else "")):
                done["avatars" if ids else "unconvertible"] += 1

        try:
            await each(
                _pending_listing_photos(), "listing", listing_photos,
                lambda i, legacy: update(Listing).where(
                    Listing.id == i, Listing.photo_ids.is_(None), Listing.verified_photos == legacy,
                ).values(photo_ids="[]"),
            )
            await each(
                _pending_showcases(), "listing showcase", showcases,
                lambda i, legacy: update(Listing).where(
                    Listing.id == i, Listing.showcase_id.is_(None),
                    Listing.showcase_image_url == legacy,
                ).values(showcase_id=""),
            )
            await each(
                _pending_store_logos(), "store logo", store_logos,
                lambda i, legacy: update(Store).where(
                    Store.id == i, Store.logo_id.is_(None), Store.logo_url == legacy,
                ).values(logo_id=""),
            )
            await each(
                _pending_store_photos(), "store photos", store_photos,
                lambda i, legacy: update(Store).where(
                    Store.id == i, Store.photo_ids.is_(None), Store.photos == legacy,
                ).values(photo_ids="[]"),
            )
            await each(
                _pending_avatars(), "avatar", avatars,
                lambda i, legacy: update(User).where(
                    User.id == i, User.profile_photo_id.is_(None), User.profile_photo == legacy,
                ).values(profile_photo_id=""),
            )
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
            return (await db.execute(
                select(func.count()).select_from(q.order_by(None).subquery())
            )).scalar_one()
        return {
            "listing_photos": await count(_pending_listing_photos()),
            "showcases": await count(_pending_showcases()),
            "store_logos": await count(_pending_store_logos()),
            "store_photos": await count(_pending_store_photos()),
            "avatars": await count(_pending_avatars()),
        }
