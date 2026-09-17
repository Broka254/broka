"""
Store Media — small abstraction over Store.logo_url / Store.photos.

The rest of this codebase already stores images as inline base64 data URIs
(Listing.verified_photos, NegotiationMessage.media_url, showcase's
generated images — see api/routers/media.py's own module docstring). This
file does NOT change that today: Store branding media is stored the same
way, so nothing here introduces a second, incompatible media format.

What it DOES do is stop every caller (StoreService, the future Flutter
Store screens' API layer) from talking to raw base64 strings and a
hand-rolled JSON list directly. Store.photos is read/written only through
parse_photo_list/normalize_photo_list below — so the day this becomes
Cloudflare R2 object keys + CDN URLs instead of inline base64 (doc's own
"do not expand the database-bloat problem" warning), that swap happens in
this one file's implementation, not in every place a store photo is
touched. No actual object-storage integration is built here — that's
explicitly future work (spec §8/§29) — this is only the seam that makes it
possible without a rewrite.
"""
from __future__ import annotations

import json
from typing import List, Optional

# A merchant's Store gallery, not a per-listing gallery — kept small
# deliberately. Raised later if real usage shows it's too tight; not
# configurable via settings yet since nothing else needs it to be.
MAX_STORE_PHOTOS = 12

# Hardening pass: this file previously normalized/serialized whatever
# base64 string arrived with no size check at all - an arbitrarily large
# payload could be sent as a "logo" and land straight in the database.
# 10 MB per image matches this codebase's one existing image-size
# convention (api/routers/media.py's MAX_IMAGE_MB, used for negotiation-
# thread image uploads) rather than inventing a different number for
# Store specifically. Measured against the base64 STRING length (a ~4/3
# overestimate of the real decoded size) rather than decoding first -
# close enough for an abuse-prevention bound, and avoids spending CPU
# decoding a payload that's about to be rejected anyway.
MAX_IMAGE_MB = 10
_MAX_B64_CHARS = MAX_IMAGE_MB * 1024 * 1024 * 4 // 3


class MediaTooLargeError(ValueError):
    """A single media item exceeded _MAX_B64_CHARS. Deliberately a plain
    ValueError subclass, not an HTTPException - this module stays free of
    any API-framework dependency (see the module docstring), so the
    caller (StoreService) is the one that turns this into an HTTP 413."""


def _check_size(value: str) -> None:
    if len(value) > _MAX_B64_CHARS:
        raise MediaTooLargeError(f"Image exceeds the {MAX_IMAGE_MB}MB limit")


def normalize_photo_list(raw: Optional[List[str]]) -> Optional[str]:
    """Validate + serialize a list of image strings (data URIs today; any
    future URL shape transparently once the storage backend changes) into
    the JSON-as-Text form Store.photos stores. Returns None for an empty/
    absent list, matching this codebase's existing convention that an
    empty optional collection is stored as NULL, not "[]" (see
    Listing.attributes for the same pattern).

    Raises MediaTooLargeError if any single item is oversized - raised
    before the count-cap truncation below, so an oversized item is
    rejected outright rather than silently dropped by being sliced off
    the end of an already-too-long list."""
    if not raw:
        return None
    cleaned = [item.strip() for item in raw if isinstance(item, str) and item.strip()]
    if not cleaned:
        return None
    for item in cleaned:
        _check_size(item)
    if len(cleaned) > MAX_STORE_PHOTOS:
        cleaned = cleaned[:MAX_STORE_PHOTOS]
    return json.dumps(cleaned)


def parse_photo_list(stored: Optional[str]) -> List[str]:
    """Inverse of normalize_photo_list. Never raises — a corrupt/legacy
    value degrades to an empty list rather than a 500 on every store read."""
    if not stored:
        return []
    try:
        parsed = json.loads(stored)
    except (TypeError, ValueError):
        return []
    return [p for p in parsed if isinstance(p, str)] if isinstance(parsed, list) else []


def normalize_single_media(raw: Optional[str]) -> Optional[str]:
    """Same normalize-or-None handling as normalize_photo_list, for the
    single-image fields (logo_url). Raises MediaTooLargeError - see
    normalize_photo_list."""
    if not raw or not isinstance(raw, str) or not raw.strip():
        return None
    value = raw.strip()
    _check_size(value)
    return value
