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
import re
import uuid
from typing import Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.image_processing import VARIANTS, process_image
from api.core.media_storage import current_storage, storage_named
from api.models.media import AttachState, MediaAsset, MediaPurpose

logger = logging.getLogger(__name__)

MAX_LISTING_PHOTOS = 6
MAX_STORE_PHOTOS = 6


# ── Create ────────────────────────────────────────────────────────────────────

async def create_image_asset(
    db: AsyncSession, owner_id: str, purpose: str, raw: bytes, attached: bool = False,
) -> MediaAsset:
    """Process `raw` and store every size. Adds the asset to `db`; the
    caller commits. Raises ImageRejected for an unusable image and
    StorageError if storing failed.

    `attached`: the caller is putting it to use right away (the backfill
    converting a row's own images). An upload is not attached until a
    listing, store or profile references it (require_owned_assets); one
    never attached is cleaned up (api/domains/media/cleanup.py).

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
        attach_state=AttachState.ATTACHED if attached else AttachState.PENDING,
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


async def avatar_url(db: AsyncSession, user_id: Optional[str]) -> Optional[str]:
    """The small URL of `user_id`'s profile photo, for a push notification
    to show their face - or None when there is no photo stored as an image
    asset yet. A base64 selfie the backfill hasn't converted can't travel:
    FCM carries 4KB, the selfie is often a megabyte or more.

    The legacy column is read only as far as one of BROKA's own URLs could
    reach (an older app build saves the URL it was shown), never the whole
    base64 payload - this runs for every message pushed."""
    if not user_id:
        return None
    from sqlalchemy import func

    from api.database import User
    row = (await db.execute(
        select(User.profile_photo_id, func.substr(User.profile_photo, 1, 512))
        .where(User.id == user_id)
    )).one_or_none()
    if row is None:
        return None
    asset_id, legacy_head = row
    # "" is the backfill's "could not convert": the legacy value decides.
    asset_id = asset_id or own_asset_id(legacy_head)
    if not asset_id:
        return None
    urls = asset_urls((await load_assets(db, [asset_id])).get(asset_id))
    return urls.get("thumb") if urls else None


async def read_variant(asset: MediaAsset, name: str = "large") -> Optional[bytes]:
    stored = asset.variant_map()
    for candidate in (name, "large", "medium", "thumb"):
        entry = stored.get(candidate)
        if entry and entry.get("key"):
            found = await storage_named(asset.storage).get(entry["key"])
            if found:
                return found[0]
    return None


# ── Link previews ─────────────────────────────────────────────────────────────

PREVIEW_VARIANT = "og"
# Images that appear on public store and product pages. Profile photos are
# never turned into shareable previews.
PREVIEWABLE = frozenset({
    MediaPurpose.LISTING_PHOTO, MediaPurpose.LISTING_SHOWCASE,
    MediaPurpose.STORE_LOGO, MediaPurpose.STORE_COVER, MediaPurpose.STORE_PHOTO,
})


def preview_key(asset_id: str) -> str:
    return f"img/{asset_id}/{PREVIEW_VARIANT}.jpg"


async def link_preview(db: AsyncSession, asset: MediaAsset) -> Optional[tuple[str, Optional[bytes]]]:
    """(storage key, JPEG bytes if made just now) of the asset's 1200x630
    link-preview JPEG, made on first request and stored with its other
    sizes. None when the asset has no image to make it from."""
    from api.core.image_processing import to_link_preview

    stored = asset.variant_map()
    entry = stored.get(PREVIEW_VARIANT)
    if entry and entry.get("key"):
        return entry["key"], None
    source = await read_variant(asset, "large")
    if source is None:
        return None
    fit = "contain" if asset.purpose == MediaPurpose.STORE_LOGO else "cover"
    jpeg = await asyncio.to_thread(to_link_preview, source, fit)
    key = preview_key(asset.id)
    await storage_named(asset.storage).put(key, jpeg, "image/jpeg")
    stored[PREVIEW_VARIANT] = {"key": key, "width": 1200, "height": 630}
    asset.variants = json.dumps(stored)
    await db.commit()
    return key, jpeg


# ── Validate what a client sends ──────────────────────────────────────────────

IMAGE_GONE = "An image wasn't found. Please upload it again."
# Sent with IMAGE_GONE as the X-Error-Code header, so a client can tell this
# refusal from the others without matching the wording. The app uses it to
# upload a restored draft's photos again: an upload no listing used is
# cleaned up after a week (cleanup.py), and a week-old draft still holds
# the ids it was given. `detail` stays a plain string for older builds.
IMAGE_GONE_HEADERS = {"X-Error-Code": "IMAGE_GONE"}

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
            raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
        if asset.owner_id != owner_id:
            raise HTTPException(status_code=403, detail="You can only use images you uploaded.")
        if asset.purpose not in purposes:
            raise HTTPException(status_code=400, detail="That image was uploaded for something else.")
    if not await _mark_attached(db, [found[i] for i in ordered]):
        raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
    return ordered


async def _mark_attached(db: AsyncSession, assets: list[MediaAsset]) -> bool:
    """Record that these assets are in use, so the clean-up never removes
    them. Written in the caller's transaction: if the listing or store it
    was for is then refused and rolled back, so is this.

    A compare-and-swap from "pending": the clean-up claims an asset the
    same way, so an upload can't be attached and cleaned up at once. The
    loser is told to upload again - which in practice means an upload left
    unused for a week was used at the very moment it was being removed."""
    pending = [a.id for a in assets if a.attach_state == AttachState.PENDING]
    if not pending:
        return True
    result = await db.execute(
        update(MediaAsset)
        .where(MediaAsset.id.in_(pending), MediaAsset.attach_state == AttachState.PENDING)
        .values(attach_state=AttachState.ATTACHED)
        .execution_options(synchronize_session=False)
    )
    if result.rowcount != len(pending):
        return False
    for asset in assets:
        if asset.id in pending:
            asset.attach_state = AttachState.ATTACHED
    return True


# ── BROKA's own image URLs ────────────────────────────────────────────────────

# Purposes an existing asset may be re-used under, keyed by the purpose of
# the field it is being put in. Mirrors what the upload paths accept: a
# store cover may be any store photo, a showcase may be a listing photo.
COMPATIBLE_PURPOSES: dict[str, frozenset[str]] = {
    MediaPurpose.STORE_LOGO:       frozenset({MediaPurpose.STORE_LOGO}),
    MediaPurpose.STORE_COVER:      frozenset({MediaPurpose.STORE_COVER, MediaPurpose.STORE_PHOTO}),
    MediaPurpose.STORE_PHOTO:      frozenset({MediaPurpose.STORE_PHOTO, MediaPurpose.STORE_COVER}),
    MediaPurpose.LISTING_PHOTO:    frozenset({MediaPurpose.LISTING_PHOTO}),
    MediaPurpose.LISTING_SHOWCASE: frozenset({MediaPurpose.LISTING_SHOWCASE, MediaPurpose.LISTING_PHOTO}),
    MediaPurpose.AVATAR:           frozenset({MediaPurpose.AVATAR}),
}

_OWN_KEY_RE = re.compile(
    r"img/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/(?:thumb|medium|large)\.webp"
)


def _own_url_prefixes() -> list[str]:
    """Where BROKA's image URLs start: what each storage driver's
    public_url() produces for a key."""
    from api.core.config import settings
    prefixes = ["/media/i/"]
    if settings.public_api_base_url:
        prefixes.append(f"{settings.public_api_base_url}/media/i/")
    if settings.media_public_base_url:
        prefixes.append(f"{settings.media_public_base_url}/")
    return prefixes


def own_asset_id(value: Optional[str]) -> Optional[str]:
    """The asset id in one of BROKA's own image URLs, or None for anything
    else - including a URL on another host that copies the same path."""
    if not isinstance(value, str):
        return None
    v = value.strip()
    for prefix in _own_url_prefixes():
        if v.startswith(prefix):
            match = _OWN_KEY_RE.fullmatch(v[len(prefix):])
            if match:
                return match.group(1)
    return None


async def resolve_own_asset(
    db: AsyncSession, owner_id: str, value: Optional[str], purpose: str,
) -> Optional[str]:
    """The id of the live asset `value` points at, when it is one of
    BROKA's own URLs, `owner_id` uploaded it, and its purpose fits `purpose`.
    App builds that predate assets show the URL they were given and send it
    back unchanged when the owner saves; this turns that back into the id."""
    asset_id = own_asset_id(value)
    if asset_id is None:
        return None
    asset = (await load_assets(db, [asset_id])).get(asset_id)
    if asset is None or asset.owner_id != owner_id:
        return None
    if asset.purpose not in COMPATIBLE_PURPOSES.get(purpose, frozenset({purpose})):
        return None
    if not await _mark_attached(db, [asset]):
        return None
    return asset.id


def is_inline_image(value: Optional[str]) -> bool:
    """True for what the legacy image fields were made for: a base64 data
    URI of an image, or bare base64. Whether the bytes really are an image
    is decided later, by process_image."""
    if not isinstance(value, str):
        return False
    v = value.strip()
    if not v:
        return False
    if v.startswith("data:"):
        header, sep, _ = v.partition(",")
        return bool(sep) and header.lower().startswith("data:image/") and header.lower().endswith(";base64")
    # Bare base64. Nothing in base64 can make it a link: a scheme needs ':'
    # and a host needs '.', neither of which is a base64 character, and a
    # scheme-relative "//host" is refused outright (no image's base64 starts
    # that way). Plain substring checks, not a regex over the whole value:
    # these are megabytes long and read on every list page.
    return ":" not in v and "." not in v and not v.startswith("//")

LEGACY_IMAGE_REFUSED = (
    "Add pictures by uploading them. Links to images on other sites aren't accepted."
)


def is_acceptable_legacy_image(value: Optional[str]) -> bool:
    """What a legacy image field may hold: an inline image, or one of
    BROKA's own image URLs. Anything else - a link to another site - would
    be shown to buyers as if BROKA had checked it, and a third-party image
    on a store page tells that site who is looking."""
    return is_inline_image(value) or own_asset_id(value) is not None


def legacy_image_or_none(value: Optional[str]) -> Optional[str]:
    """`value` when it is acceptable (see above), else None. For reading
    rows saved before these fields were checked."""
    return value if is_acceptable_legacy_image(value) else None


async def check_legacy_images(
    db: AsyncSession, owner_id: Optional[str], values: Iterable[Optional[str]], purpose: str,
) -> None:
    """Refuses (400/403) any value an older app build sent in a legacy
    image field that isn't an inline image or an image `owner_id` uploaded.
    Empty values are fine: they clear the field."""
    for value in values:
        if not isinstance(value, str) or not value.strip() or is_inline_image(value):
            continue
        if own_asset_id(value) is not None:
            if owner_id and await resolve_own_asset(db, owner_id, value, purpose):
                continue
            raise HTTPException(status_code=403, detail="You can only use images you uploaded.")
        raise HTTPException(status_code=400, detail=LEGACY_IMAGE_REFUSED)


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
