"""
BROKA - AI Showcase/Cover Image Service
─────────────────────────────────────────────────────────────────────────────
Orchestrates the showcase image feature end to end. The actual fal.ai HTTP
mechanics live in api/core/fal_client.py (reusable technical client,
mirrors api/core/sms.py); this file is the business logic: ownership,
the (currently disabled) premium gate, prompt construction, and the
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
Both funnel into the same _run_generation() core so the fal.ai call,
prompt shape, and preservation instructions can't drift between the two.
"""
from __future__ import annotations

import base64
import logging
from typing import Optional

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, User
from api.core import fal_client
from api.core.config import settings

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

_DEFAULT_CREATIVE_BRIEF = (
    "Professional marketplace showcase photo: clean, attractive lighting "
    "and a simple, uncluttered background."
)


def _first_actual_photo_data_uri(listing: Listing) -> str:
    """The seller's primary actual product photo, as a data: URI fal.ai
    can use directly as image_url. verified_photos stores raw base64
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
    user_description: Optional[str],
) -> str:
    facts = [f"Product: {name}", f"Category: {category}"]
    if condition:
        facts.append(f"Condition: {condition}")
    if price:
        facts.append(f"Price: KES {price:,.0f}")
    listing_context = " | ".join(facts)

    creative = user_description.strip() if user_description and user_description.strip() else _DEFAULT_CREATIVE_BRIEF

    return f"{creative}\n\nListing context: {listing_context}\n\n{_PRESERVATION_INSTRUCTIONS}"


def _build_prompt(listing: Listing, user_description: Optional[str]) -> str:
    return _build_prompt_from_facts(
        listing.name, listing.category, listing.condition, listing.price, user_description,
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


async def _require_premium_if_enabled(db: AsyncSession, user_id: str) -> None:
    """Debugging/testing phase: SHOWCASE_AI_REQUIRE_PREMIUM defaults off
    (see config.py), so this is currently a no-op for everyone. Re-checks
    is_premium fresh from the DB rather than trusting anything cached in
    the JWT, since entitlement can change after a token is issued."""
    if not settings.showcase_ai_require_premium:
        return
    r = await db.execute(select(User.is_premium).where(User.id == user_id))
    is_premium = r.scalar_one_or_none()
    if not is_premium:
        raise HTTPException(
            status_code=403,
            detail={"code": "premium_required",
                    "message": "AI showcase generation is a Premium feature."},
        )


async def _run_generation(prompt: str, photo_data_uri: str) -> dict:
    """The actual fal.ai call + download + re-encode sequence, shared by
    both entry points below. Never touches the DB - callers decide what,
    if anything, gets persisted."""
    fal_url = await fal_client.generate_showcase_image_url(prompt, photo_data_uri)
    image_bytes, mime = await fal_client.download_generated_image(fal_url)
    b64 = base64.b64encode(image_bytes).decode()
    return {"image_data_uri": f"data:{mime};base64,{b64}", "prompt_used": prompt}


async def generate_showcase_preview(
    db: AsyncSession, listing_id: str, user_id: str, description: Optional[str],
) -> dict:
    """Post-creation path (Edit Listing regenerating an existing listing's
    showcase). Generates and returns a preview - does NOT save it. The
    seller previews it and calls set_showcase_image() to actually use it,
    or discards it by simply not calling that."""
    listing = await _get_owned_listing(db, listing_id, user_id)
    await _require_premium_if_enabled(db, user_id)
    image_ref = _first_actual_photo_data_uri(listing)
    prompt = _build_prompt(listing, description)
    return await _run_generation(prompt, image_ref)


async def generate_showcase_preview_standalone(
    db: AsyncSession, user_id: str, photo_data_uri: str,
    name: str, category: str, condition: Optional[str], price: Optional[float],
    description: Optional[str],
) -> dict:
    """Pre-creation path: the listing wizard's Showcase step, called
    before a Listing row exists. No ownership check (nothing to own yet) -
    facts come straight from the wizard's in-memory draft (SellWizardData),
    the same way every other wizard step already stays client-side until
    Publish creates the whole listing in one call. The returned preview
    flows back into the draft too (showcaseImageDataUri) and is only sent
    to the backend for real as part of that same POST /listings body -
    this endpoint itself never writes anything."""
    await _require_premium_if_enabled(db, user_id)
    if not photo_data_uri or not photo_data_uri.startswith("data:image/"):
        raise HTTPException(
            status_code=400,
            detail="Upload your product photos first — AI showcase needs "
                   "a real photo of your item to work from.",
        )
    prompt = _build_prompt_from_facts(name, category, condition, price, description)
    return await _run_generation(prompt, photo_data_uri)


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
    await db.commit()
    return {"showcase_image_url": None, "showcase_image_source": None}
