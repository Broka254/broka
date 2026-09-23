"""Image assets: create them, turn them into URLs, check who may use them.

The rest of the backend talks to images only through this module:

  * create_image_asset  - process an upload and store its sizes
  * asset_urls          - the public URL of each size, for a response
  * load_assets         - one query for every asset a page needs
  * require_owned_assets- the ids a client sent are theirs, live, and of
                          the right purpose (a store logo is not a listing
                          photo), in the order sent
  * ids / legacy helpers used by listings, stores and the backfill
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import json
import logging
import uuid
from typing import Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.image_processing import VARIANTS, process_image
from api.core.media_storage import current_storage, storage_named
from api.models.media import MediaAsset

logger = logging.getLogger(__name__)

MAX_LISTING_PHOTOS = 6
MAX_STORE_PHOTOS = 6


# ── Create ────────────────────────────────────────────────────────────────────

async def create_image_asset(
    db: AsyncSession, owner_id: str, purpose: str, raw: bytes,
) -> MediaAsset:
    """Process `raw` and store every size. Adds the asset to `db`; the
    caller commits. Raises ImageRejected for an unusable image and
    StorageError if storing failed.

    Deliberately no flush here: a flushed INSERT holds SQLite's write lock
    until commit, and the database storage driver writes each size through
    its own session - so converting a listing's second photo would wait on
    the first photo's uncommitted row and fail with "database is locked".
    The row is written when the caller commits (or runs its next query)."""
    processed = await asyncio.to_thread(process_image, raw)
    storage = current_storage()
    asset_id = str(uuid.uuid4())
    variants: dict[str, dict] = {}
    for name, (data, w, h) in processed.variants.items():
        key = f"img/{asset_id}/{name}.webp"
        await storage.put(key, data, "image/webp")
        variants[name] = {"key": key, "w": w, "h": h, "bytes": len(data)}

    asset = MediaAsset(
        id=asset_id,
        owner_id=owner_id,
        purpose=purpose,
        storage=storage.name,
        width=processed.width,
        height=processed.height,
        sha256=processed.sha256,
        variants=json.dumps(variants),
    )
    db.add(asset)
    return asset


# ── Read ──────────────────────────────────────────────────────────────────────

def asset_urls(asset: Optional[MediaAsset]) -> Optional[dict]:
    """{"id", "thumb", "medium", "large", "width", "height"} for a response.

    A size the asset doesn't have (none today, but an asset written by an
    older VARIANTS list could lack one) falls back to the nearest larger
    size, then smaller, so every key is always a usable URL.
    """
    if asset is None:
        return None
    storage = storage_named(asset.storage)
    stored = asset.variant_map()
    names = [name for name, _ in VARIANTS]
    urls: dict[str, str] = {}
    for i, name in enumerate(names):
        candidates = [name, *names[i + 1:], *reversed(names[:i])]
        for c in candidates:
            if c in stored and stored[c].get("key"):
                urls[name] = storage.public_url(stored[c]["key"])
                break
    if not urls:
        return None
    return {"id": asset.id, **urls, "width": asset.width, "height": asset.height}


async def load_assets(db: AsyncSession, ids: Iterable[str]) -> dict[str, MediaAsset]:
    """Every live asset among `ids`, in one query."""
    wanted = {i for i in ids if i}
    if not wanted:
        return {}
    rows = (await db.execute(
        select(MediaAsset).where(MediaAsset.id.in_(wanted), MediaAsset.deleted_at.is_(None))
    )).scalars().all()
    return {a.id: a for a in rows}


async def read_variant(asset: MediaAsset, name: str = "large") -> Optional[bytes]:
    stored = asset.variant_map()
    for candidate in (name, "large", "medium", "thumb"):
        entry = stored.get(candidate)
        if entry and entry.get("key"):
            found = await storage_named(asset.storage).get(entry["key"])
            if found:
                return found[0]
    return None


# ── Validate what a client sends ──────────────────────────────────────────────

async def require_owned_assets(
    db: AsyncSession, owner_id: str, ids: list[str], purposes: set[str],
) -> list[str]:
    """`ids` in the order given (duplicates dropped), after checking each
    exists, isn't deleted, belongs to `owner_id`, and was uploaded for one
    of `purposes`. Raises 400/403 naming the problem, never a 500."""
    ordered: list[str] = []
    for i in ids:
        if isinstance(i, str) and i and i not in ordered:
            ordered.append(i)
    found = await load_assets(db, ordered)
    for i in ordered:
        asset = found.get(i)
        if asset is None:
            raise HTTPException(status_code=400, detail="An image wasn't found. Please upload it again.")
        if asset.owner_id != owner_id:
            raise HTTPException(status_code=403, detail="You can only use images you uploaded.")
        if asset.purpose not in purposes:
            raise HTTPException(status_code=400, detail="That image was uploaded for something else.")
    return ordered


# ── Id lists as stored in Text columns ────────────────────────────────────────

def parse_id_list(raw: Optional[str]) -> list[str]:
    """Never raises: a corrupt value reads as no images."""
    if not raw:
        return []
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return []
    return [v for v in value if isinstance(v, str) and v] if isinstance(value, list) else []


def dump_id_list(ids: list[str]) -> str:
    return json.dumps(list(ids))


# ── Legacy base64 ─────────────────────────────────────────────────────────────

def split_legacy_photos(raw: Optional[str]) -> list[str]:
    """Listing.verified_photos is bare base64 chunks joined with commas.

    base64 has no commas, so splitting on them is exact for what the app
    writes. A data URI ("data:image/jpeg;base64,<payload>") has one comma
    of its own, so a chunk that is a data-URI header is rejoined with the
    payload after it rather than treated as two photos.
    """
    if not raw:
        return []
    parts = [p.strip() for p in raw.split(",")]
    out: list[str] = []
    i = 0
    while i < len(parts):
        part = parts[i]
        if part.startswith("data:") and i + 1 < len(parts):
            out.append(f"{part},{parts[i + 1]}")
            i += 2
            continue
        if part:
            out.append(part)
        i += 1
    return out


def decode_legacy_image(value: Optional[str]) -> Optional[bytes]:
    """Bytes from a data URI or bare base64 string, or None if it isn't
    valid base64. Whether the bytes are an image is process_image's job."""
    if not value or not isinstance(value, str):
        return None
    payload = value.strip()
    if payload.startswith("data:"):
        comma = payload.find(",")
        if comma < 0:
            return None
        payload = payload[comma + 1:]
    payload = "".join(payload.split())
    if not payload:
        return None
    try:
        return base64.b64decode(payload + "=" * (-len(payload) % 4), validate=True)
    except (binascii.Error, ValueError):
        return None
