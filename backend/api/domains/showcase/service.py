"""
BROKA - AI Showcase/Cover Image Service
─────────────────────────────────────────────────────────────────────────────
Orchestrates the showcase image feature end to end. The actual Hugging Face
HTTP mechanics live in api/core/hf_image_client.py (reusable technical client,
mirrors api/core/sms.py); this file is the business logic: ownership,
the premium allowance, prompt construction, and the
generate -> download -> persist pipeline.

Two image concepts, kept strictly separate (never conflate them):
  - verified_photos  - the seller's actual product photos. Mandatory,
    untouched by this feature, still what View Deal shows.
  - showcase_image_url - optional, promotional, homescreen-only. This
    file is the only place that writes it.

Two entry points into generation, because the listing wizard creates the
Listing row only at the very end (Publish/_activate() in
sell_review_screen.dart - everything before that is client-side draft
state in SellWizardData, same as every other wizard step already works):
  - generate_showcase_preview() - listing already exists (post-creation /
    Edit Listing). Looks facts up from the real row; ownership-checked.
  - generate_showcase_preview_standalone() - no listing yet (the wizard's
    Showcase step). Facts come straight from the request body instead.
Both funnel into the same _run_generation() core so the model call,
prompt shape, and preservation instructions can't drift between the two.
"""
from __future__ import annotations

import asyncio
import base64
import binascii
import logging
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing
from api.core import hf_image_client

logger = logging.getLogger(__name__)

# Sent on every generation regardless of what the seller asks for - the
# creative description shapes style, this shapes what must never change.
_PRESERVATION_INSTRUCTIONS = (
    "Keep the exact same product shown in the reference photo: same model, "
    "same color, same visible condition, same components as photographed. "
    "Do not add, remove, or invent accessories or parts. Do not change the "
    "product's identity or turn it into a different product. Only change "
    "the surrounding presentation - lighting, background, composition, and "
    "overall photographic quality."
)

# Image models draw text readily, and a cover with invented lettering - a
# made-up brand, a price sticker - misdescribes the item on the one image
# every buyer sees first.
_NO_TEXT_INSTRUCTIONS = (
    "Do not add any text, lettering, numbers, price tags, logos, watermarks, "
    "stickers or borders anywhere in the image."
)

_DEFAULT_CREATIVE_BRIEF = (
    "Professional marketplace showcase photo: clean, attractive lighting "
    "and a simple, uncluttered background."
)

# The looks the sell wizard offers (sell_showcase_screen.dart paints a
# preview of each). The client sends the key, never a prompt: what reaches
# the model is ours, and a new build can't ask for a look that isn't here.
THEMES: dict[str, str] = {
    "studio": (
        "Clean studio product photo: the item on a seamless soft white backdrop, "
        "bright even diffused lighting, a soft natural shadow beneath it, crisp "
        "focus - premium online-store style."
    ),
    "luxury": (
        "Luxury night look: the item on a deep black backdrop with dramatic rim "
        "lighting, subtle warm gold reflections and a glossy dark surface - "
        "elegant and high-end."
    ),
    "wood": (
        "Warm lifestyle look: the item on a natural wooden tabletop in soft warm "
        "window light, with a gently blurred, cosy room behind it."
    ),
    "nature": (
        "Fresh outdoor look: the item in bright natural daylight with soft green "
        "foliage blurred in the background - clean, fresh and natural."
    ),
    "neon": (
        "Futuristic tech look: the item in a dark scene lit by cyan and magenta "
        "neon glow, reflected on a glossy floor - sleek and modern."
    ),
    "pastel": (
        "Pastel pop look: the item on a round podium against a soft pastel "
        "backdrop of peach, lilac and mint, with clean soft shadows - bright "
        "and playful."
    ),
}

# The seller's own words, and the listing facts, are bounded: they go into
# a paid prompt, and nothing used to stop a 30 MB "description".
MAX_BRIEF_LEN = 300
MAX_FACT_LEN = 120


def _bounded(value: Optional[str], limit: int) -> str:
    return " ".join((value or "").split())[:limit]


async def _first_actual_photo_data_uri(db: AsyncSession, listing: Listing) -> str:
    """The first photo as a JPEG data URI - from the image assets when the
    listing has them (listings created by current app builds carry no
    base64 at all), otherwise from the legacy verified_photos."""
    from api.core.image_processing import to_jpeg
    from api.domains.media.service import load_assets, parse_id_list, read_variant

    ids = parse_id_list(listing.photo_ids)
    if ids:
        asset = (await load_assets(db, ids[:1])).get(ids[0])
        data = await read_variant(asset, "large") if asset else None
        if data:
            jpeg = await asyncio.to_thread(to_jpeg, data)
            return f"data:image/jpeg;base64,{base64.b64encode(jpeg).decode()}"
    return _legacy_first_photo_data_uri(listing)


def _legacy_first_photo_data_uri(listing: Listing) -> str:
    """The seller's primary actual product photo, as a data: URI the
    model can use directly as image_url. verified_photos stores raw base64
    chunks with no data: prefix and no per-photo mime tag (see
    product_card.dart's base64Decode(parts.first)), so this defaults the
    mime type the same way media.py's own upload endpoint does when a
    client doesn't supply one."""
    raw = (listing.verified_photos or "").strip()
    first = raw.split(",")[0].strip() if raw else ""
    if not first:
        raise HTTPException(
            status_code=400,
            detail="Upload your product photos first — AI showcase needs "
                   "a real photo of your item to work from.",
        )
    return f"data:image/jpeg;base64,{first}"


def _build_prompt_from_facts(
    name: str, category: str, condition: Optional[str], price: Optional[float],
    user_description: Optional[str], theme: Optional[str] = None,
) -> str:
    """`price` is accepted and deliberately NOT used. It used to be in the
    prompt ("Price: KES 45,000"), and an image model given a price paints
    it - a price sticker on the product, or text across the backdrop - which
    goes stale the first time the seller changes the price."""
    facts = [f"Product: {_bounded(name, MAX_FACT_LEN)}", f"Category: {_bounded(category, MAX_FACT_LEN)}"]
    if condition:
        facts.append(f"Condition: {_bounded(condition, MAX_FACT_LEN)}")
    listing_context = " | ".join(facts)

    note = _bounded(user_description, MAX_BRIEF_LEN)
    look = THEMES.get(theme or "")
    if look:
        creative = f"{look} Seller's note: {note}" if note else look
    else:
        creative = note or _DEFAULT_CREATIVE_BRIEF

    return (
        f"{creative}\n\nListing context: {listing_context}\n\n"
        f"{_PRESERVATION_INSTRUCTIONS} {_NO_TEXT_INSTRUCTIONS}"
    )


def _build_prompt(listing: Listing, user_description: Optional[str], theme: Optional[str] = None) -> str:
    return _build_prompt_from_facts(
        listing.name, listing.category, listing.condition, listing.price, user_description, theme,
    )


async def _get_owned_listing(db: AsyncSession, listing_id: str, user_id: str) -> Listing:
    r = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = r.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")
    # Ownership is checked against the authenticated user from the JWT
    # (get_current_user), never a client-supplied id, per the showcase
    # spec's explicit security requirement.
    if listing.seller_id != user_id:
        raise HTTPException(status_code=403, detail="Only the seller can manage this listing's showcase image")
    return listing


async def _spend_a_cover(db: AsyncSession, user_id: str) -> None:
    """An AI cover is premium (PRICING.md): each try spends one of the
    plan's monthly AI covers, or the one free one. Checked fresh from the
    database every time, never from anything cached in the token - a plan
    can start or end after the token was issued.

    While PREMIUM_ENABLED is off, every other premium feature is free, but
    AI covers are off: entitlements counts nothing then, so each cover would
    be a paid generation for anyone, with no plan that could pay for it.

    Called once the request is one that will reach the model: a missing
    photo or a bad theme must not use up a try. _run_generation gives it
    back if the model then fails.
    """
    from api.domains.premium import entitlements
    if not entitlements.enabled():
        raise _failure(hf_image_client.ImageGenerationError(
            "PREMIUM_ENABLED is off - AI covers are premium only", code="unavailable"))
    await entitlements.consume(db, user_id, entitlements.Feature.AI_COVER)


async def _give_the_cover_back(db: AsyncSession, user_id: str) -> None:
    """No cover reached the seller, so no try was used."""
    from api.domains.premium import entitlements
    await entitlements.release(db, user_id, entitlements.Feature.AI_COVER)


async def _check_generation_rate(user_id: str) -> None:
    """Per-seller limits on paid generations (api/core/rate_limit.py), in
    words a seller can act on."""
    from api.core import rate_limit
    for limiter, span in (
        (rate_limit.showcase_generate_limiter, "hour"),
        (rate_limit.showcase_generate_daily_limiter, "day"),
    ):
        try:
            await limiter.check_and_record(user_id)
        except HTTPException as exc:
            if exc.status_code != 429:
                raise
            raise HTTPException(
                status_code=429,
                detail={
                    "code": "SHOWCASE_LIMIT",
                    "message": f"You've made as many AI covers as we allow in a {span}. "
                               f"Try again later, or upload a cover from your gallery.",
                },
                headers=exc.headers,
            )


# What a seller is told when generation fails, by ImageGenerationError.code.
# The exception's own text is for the log ("HF_TOKEN unset", "status=ERROR").
_FAILURE_REPLIES = {
    "unavailable": (503, "AI covers aren't available right now. Upload a cover from your "
                         "gallery, or skip this step - your photos are enough."),
    "rejected": (422, "The AI couldn't use this photo. Try again with a clearer photo of "
                      "the item, or upload a cover from your gallery."),
    "failed": (502, "The AI couldn't finish your cover. Please try again."),
}


def _failure(exc: "hf_image_client.ImageGenerationError") -> HTTPException:
    """The generation error used to escape every endpoint here as a bare 500,
    so the seller saw "generation failed" whatever the cause - including
    "not configured", which no retry can fix."""
    logger.warning("[showcase] generation failed code=%s: %s", exc.code, exc)
    status, message = _FAILURE_REPLIES.get(exc.code, _FAILURE_REPLIES["failed"])
    return HTTPException(
        status_code=status,
        detail={"code": f"SHOWCASE_{exc.code.upper()}", "message": message},
    )


async def _photo_from_asset(db: AsyncSession, user_id: str, photo_id: str) -> str:
    """The seller's own uploaded photo as a JPEG data URI. Read, never
    marked as used: the listing it's for doesn't exist yet."""
    from api.core.image_processing import to_jpeg
    from api.domains.media.service import IMAGE_GONE, IMAGE_GONE_HEADERS, load_assets, read_variant
    from api.models.media import MediaPurpose

    asset = (await load_assets(db, [photo_id])).get(photo_id)
    if asset is None:
        raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
    if asset.owner_id != user_id:
        raise HTTPException(status_code=403, detail="You can only use images you uploaded.")
    if asset.purpose not in (MediaPurpose.LISTING_PHOTO, MediaPurpose.LISTING_SHOWCASE):
        raise HTTPException(status_code=400, detail="That image was uploaded for something else.")
    data = await read_variant(asset, "large")
    if not data:
        raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
    jpeg = await asyncio.to_thread(to_jpeg, data)
    return f"data:image/jpeg;base64,{base64.b64encode(jpeg).decode()}"


async def _photo_from_data_uri(photo_data_uri: Optional[str]) -> str:
    """A photo sent inline, decoded and re-encoded before it goes anywhere.
    It used to be forwarded to the model as sent - any bytes at all behind a
    "data:image/" prefix, of any size, paid for whether or not they were a
    photo - and at full camera size."""
    from api.core.image_processing import ImageRejected, process_image, to_jpeg

    if not photo_data_uri or not photo_data_uri.startswith("data:image/"):
        raise HTTPException(
            status_code=400,
            detail="Upload your product photos first — AI showcase needs "
                   "a real photo of your item to work from.",
        )
    try:
        raw = base64.b64decode(photo_data_uri.split(",", 1)[1], validate=False)
        processed = await asyncio.to_thread(process_image, raw)
    except (IndexError, ValueError, binascii.Error, ImageRejected):
        raise HTTPException(
            status_code=400,
            detail="That photo couldn't be read. Take the photo again and retry.",
        )
    large, _w, _h = processed.variants["large"]
    jpeg = await asyncio.to_thread(to_jpeg, large)
    return f"data:image/jpeg;base64,{base64.b64encode(jpeg).decode()}"


async def _run_generation(
    db: AsyncSession, user_id: str, prompt: str, photo_data_uri: str, as_asset: bool,
) -> dict:
    """The model call + download, shared by both entry points below.

    as_asset=True (current app builds): the result is stored as the
    seller's own image asset (purpose listing_showcase, not yet attached -
    unused ones are cleaned up after a week like any upload) and returned
    as its id and URLs. The seller previews the medium size and, if they
    use it, the listing references the id. It used to come back as a
    base64 data URI - a megabyte or two of JSON over mobile data, held in
    the phone's memory as a string, decoded again on every rebuild, and
    uploaded back to BROKA at Activate.

    as_asset=False: the old data-URI response, for app builds before it.
    """
    try:
        image_url = await hf_image_client.generate_showcase_image_url(prompt, photo_data_uri)
        image_bytes, mime = await hf_image_client.download_generated_image(image_url)
    except hf_image_client.ImageGenerationError as exc:
        await _give_the_cover_back(db, user_id)
        raise _failure(exc)

    if not as_asset:
        b64 = base64.b64encode(image_bytes).decode()
        return {"image_data_uri": f"data:{mime};base64,{b64}", "prompt_used": prompt}

    from api.core.image_processing import ImageRejected
    from api.domains.media.service import asset_urls, create_image_asset
    from api.models.media import MediaPurpose

    try:
        asset = await create_image_asset(db, user_id, MediaPurpose.LISTING_SHOWCASE, image_bytes)
        await db.commit()
    except ImageRejected as exc:
        await db.rollback()
        await _give_the_cover_back(db, user_id)
        raise _failure(hf_image_client.ImageGenerationError(f"unreadable result: {exc}"))
    return {"asset": asset_urls(asset), "prompt_used": prompt}


def _theme_or_400(theme: Optional[str]) -> Optional[str]:
    if theme is None or theme == "":
        return None
    if theme not in THEMES:
        raise HTTPException(status_code=400, detail="That look isn't available. Choose another.")
    return theme


async def generate_showcase_preview(
    db: AsyncSession, listing_id: str, user_id: str, description: Optional[str],
    theme: Optional[str] = None, as_asset: bool = False,
) -> dict:
    """Post-creation path (Edit Listing regenerating an existing listing's
    showcase). Generates and returns a preview - does NOT save it. The
    seller previews it and calls set_showcase_image() to actually use it,
    or discards it by simply not calling that."""
    listing = await _get_owned_listing(db, listing_id, user_id)
    theme = _theme_or_400(theme)
    image_ref = await _first_actual_photo_data_uri(db, listing)
    await _check_generation_rate(user_id)
    await _spend_a_cover(db, user_id)
    prompt = _build_prompt(listing, description, theme)
    return await _run_generation(db, user_id, prompt, image_ref, as_asset)


async def generate_showcase_preview_standalone(
    db: AsyncSession, user_id: str, photo_data_uri: Optional[str],
    name: str, category: str, condition: Optional[str], price: Optional[float],
    description: Optional[str], *, theme: Optional[str] = None,
    photo_id: Optional[str] = None, as_asset: bool = False,
) -> dict:
    """Pre-creation path: the listing wizard's Showcase step, called
    before a Listing row exists. No ownership check (nothing to own yet) -
    facts come straight from the wizard's in-memory draft (SellWizardData),
    the same way every other wizard step already stays client-side until
    Publish creates the whole listing in one call. Nothing about the
    listing is written here; with as_asset the generated image is stored
    as the seller's unattached upload, which the listing references at
    Publish (or which is cleaned up with other unused uploads).

    The photo is `photo_id` - the seller's first photo, already uploaded
    when it was taken, so nothing is sent twice - or, from older builds,
    `photo_data_uri`, the photo itself."""
    theme = _theme_or_400(theme)
    if photo_id:
        photo = await _photo_from_asset(db, user_id, photo_id)
    else:
        photo = await _photo_from_data_uri(photo_data_uri)
    # Counted only once the request is one that will reach the model: a
    # missing photo shouldn't use up a seller's allowance.
    await _check_generation_rate(user_id)
    await _spend_a_cover(db, user_id)
    prompt = _build_prompt_from_facts(name, category, condition, price, description, theme)
    return await _run_generation(db, user_id, prompt, photo, as_asset)


async def set_showcase_image(
    db: AsyncSession, listing_id: str, user_id: str, image_data_uri: str, source: str,
) -> dict:
    """Persists a showcase image - either a freshly-approved AI preview
    handed back from generate_showcase_preview(), or a gallery pick sent
    straight from the client. Only this function (and remove, below)
    writes Listing.showcase_image_url."""
    if source not in ("gallery", "ai"):
        raise HTTPException(status_code=400, detail="source must be 'gallery' or 'ai'")
    if not image_data_uri.startswith("data:image/"):
        raise HTTPException(status_code=400, detail="Invalid image data")

    listing = await _get_owned_listing(db, listing_id, user_id)
    listing.showcase_image_url = image_data_uri
    listing.showcase_image_source = source
    # The media backfill turns this data URI into an image asset; until it
    # does, cards fall back to the data URI.
    listing.showcase_id = None
    await db.commit()
    return {"showcase_image_url": listing.showcase_image_url,
            "showcase_image_source": listing.showcase_image_source}


async def remove_showcase_image(db: AsyncSession, listing_id: str, user_id: str) -> dict:
    """Clears the showcase image only. Never touches verified_photos -
    removing a showcase falls back to the first actual photo on the
    homescreen (product_card.dart), it never blanks the card."""
    listing = await _get_owned_listing(db, listing_id, user_id)
    listing.showcase_image_url = None
    listing.showcase_image_source = None
    listing.showcase_id = None
    await db.commit()
    return {"showcase_image_url": None, "showcase_image_source": None}
