"""Zeno helping a seller while they write a listing (2026-10-05).

Two things the sell wizard offers to make a listing sell faster, both
premium (PRICING.md section 4, entitlements.py):

  * DESCRIBE (every plan): Zeno writes the description from the listing's
    first photo and what the seller has entered. The seller reads and edits
    it before it goes anywhere - it lands in their description box, not on
    a listing.
  * PRICE (Pro and Elite): a conversation in the Zeno screen about what to
    ask, and - when the seller taps for it - a check of what similar live
    listings on BROKA ask, found with the Buying Agent's search
    (buy_agent/conversation.search_for), the same scoring that decides
    what a buyer is shown. Each check spends one of the plan's price
    checks; the conversation around it does not.

There is no listing yet, so the draft travels with each request. It is the
seller's own words about their own item, which is why it may go into the
prompt as given (the assistant's rule: a prompt holds the user's own words,
ZENO_ACTIONS.md). Other sellers' titles reach the model only fenced, as the
Buying Agent fences them.
"""
from __future__ import annotations

import asyncio
import base64
import logging
import statistics
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from api.domains.listings.validation import CONDITIONS, MAX_DESCRIPTION_LEN
from api.domains.premium import entitlements

logger = logging.getLogger(__name__)

# The most BROKA holds in escrow for one deal (escrow/service.py), and the
# wizard's own ceiling - a suggestion above it could not be listed.
MAX_SUGGESTED_PRICE = 20_000_000

# A comparable must score at least this against the draft (matching.assess,
# 0-1) to count: below it the search's "closest I could get" is a different
# item, and its price says nothing about this one.
MIN_COMPARABLE_SCORE = 0.5

# What the app shows as cards and the model reads, at most.
MAX_COMPARABLES = 8

_TITLE_MAX = 60


def _one_line(value, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def draft_lines(draft: dict) -> list[str]:
    """The draft as "Field: value" lines - for both prompts."""
    lines = []
    if draft.get("name"):
        lines.append(f"Title: {_one_line(draft['name'], 120)}")
    if draft.get("category"):
        sub = f" > {_one_line(draft['subcategory'], 60)}" if draft.get("subcategory") else ""
        lines.append(f"Category: {_one_line(draft['category'], 60)}{sub}")
    if draft.get("condition") in CONDITIONS:
        lines.append(f"Condition: {draft['condition']}")
    for key, value in list((draft.get("attributes") or {}).items())[:12]:
        if value not in (None, ""):
            lines.append(f"{_one_line(key, 30)}: {_one_line(value, 60)}")
    if draft.get("listing_type") == "auction":
        lines.append("Sale type: auction (the price is where bidding starts)")
    if draft.get("asking_price"):
        unit = f" per {_one_line(draft['price_unit'], 20)}" if draft.get("price_unit") else ""
        lines.append(f"Their price so far: KES {float(draft['asking_price']):,.0f}{unit}")
    if draft.get("price_negotiable") is not None:
        lines.append("Open to offers" if draft["price_negotiable"] else "Fixed price, no offers")
    if draft.get("location"):
        lines.append(f"Location: {_one_line(draft['location'], 80)}")
    if draft.get("description"):
        lines.append(f"Description: {_one_line(draft['description'], 800)}")
    return lines


# ── Describe ─────────────────────────────────────────────────────────────────

async def _photo_from_asset(db: AsyncSession, user_id: str, photo_id: str) -> str:
    """The seller's uploaded listing photo as raw base64 JPEG at the medium
    size (960px) - what a model reads, and what core/vision.py would make of
    it. Read, never marked used: the listing doesn't exist yet."""
    from api.core.image_processing import to_jpeg
    from api.domains.media.service import IMAGE_GONE, IMAGE_GONE_HEADERS, load_assets, read_variant
    from api.models.media import MediaPurpose

    asset = (await load_assets(db, [photo_id])).get(photo_id)
    if asset is None:
        raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
    # Someone else's photo would have Zeno describe their item as yours.
    if asset.owner_id != user_id:
        raise HTTPException(status_code=403, detail="You can only use images you uploaded.")
    if asset.purpose != MediaPurpose.LISTING_PHOTO:
        raise HTTPException(status_code=400, detail="That image was uploaded for something else.")
    data = await read_variant(asset, "medium")
    if not data:
        raise HTTPException(status_code=400, detail=IMAGE_GONE, headers=IMAGE_GONE_HEADERS)
    jpeg = await asyncio.to_thread(to_jpeg, data)
    return base64.b64encode(jpeg).decode()


async def describe(
    db: AsyncSession,
    user_id: str,
    draft: dict,
    language: str,
    photo_id: Optional[str] = None,
    image_base64: Optional[str] = None,
) -> dict:
    """{"description": str} written from the draft's photo, spending one of
    the plan's AI descriptions - given back if no description came of it."""
    from api.core.vision import ImageRejected, prepare_for_model
    from api.domains.ai_broker.service import AIBrokerService
    from api.routers.negotiate import _language_instruction  # router module; imported late

    # The photo first: one that can't be used must not cost a description.
    if photo_id:
        image = await _photo_from_asset(db, user_id, photo_id)
    elif image_base64:
        try:
            image = await prepare_for_model(image_base64)
        except ImageRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc))
    else:
        raise HTTPException(status_code=400, detail="Take your listing photos first - Zeno writes from them.")

    await entitlements.consume(db, user_id, entitlements.Feature.AI_DESCRIPTION)
    try:
        # Not the price: a description with a price in it goes stale the
        # first time the seller changes their mind.
        details = draft_lines({**draft, "description": None, "asking_price": None})
        text = await AIBrokerService().write_listing_description(
            image_base64=image,
            details=details,
            existing=str(draft.get("description") or ""),
            language_instruction=_language_instruction(language),
        )
    except Exception:
        await entitlements.release(db, user_id, entitlements.Feature.AI_DESCRIPTION)
        raise
    if not text:
        await entitlements.release(db, user_id, entitlements.Feature.AI_DESCRIPTION)
        raise HTTPException(status_code=502, detail="Zeno couldn't write that one. Please try again.")
    return {"description": text[:MAX_DESCRIPTION_LEN]}


# ── Price ────────────────────────────────────────────────────────────────────

def _same_unit(a: Optional[str], b: Optional[str]) -> bool:
    """KES 3,500 per bag and KES 3,500 for the lot are not the same price."""
    return (a or "").strip().lower() == (b or "").strip().lower()


async def comparables(db: AsyncSession, user_id: str, draft: dict) -> dict:
    """What similar live listings on BROKA ask, found the way the Buying
    Agent finds a buyer's item: hard-filtered to the draft's category,
    scored on its title, condition and details, the seller's own listings
    left out. Only direct sales priced in the same unit count - an
    auction's figure is where bidding starts, not what it sells for.

    {"count", "low", "median", "high", "typical_low", "typical_high",
     "listings": [listing dicts, best match first]}; the numbers are None
    when nothing comparable is live.
    """
    from api.domains.buy_agent.conversation import _taxonomy, search_for

    _names, _subs, top_by_name, children_by_cat = await _taxonomy(db)
    slots = {
        "category": draft.get("category") if draft.get("category") in top_by_name else None,
        "subcategory": draft.get("subcategory"),
        "query": _one_line(draft.get("name"), 120) or None,
        "condition": draft.get("condition") if draft.get("condition") in CONDITIONS else None,
        "attributes": {k: v for k, v in (draft.get("attributes") or {}).items() if v not in (None, "")},
    }
    ranked, _unmet = await search_for(db, slots, user_id, top_by_name, children_by_cat)
    found = [
        item for item in ranked
        if item.get("match_score", 0) >= MIN_COMPARABLE_SCORE
        and item.get("listing_type") != "auction"
        and (item.get("price") or 0) > 0
        and _same_unit(item.get("price_unit"), draft.get("price_unit"))
    ][:MAX_COMPARABLES]
    prices = sorted(float(item["price"]) for item in found)
    out = {"count": len(prices), "low": None, "median": None, "high": None,
           "typical_low": None, "typical_high": None, "listings": found}
    if prices:
        out.update(low=prices[0], median=statistics.median(prices), high=prices[-1])
        # The middle half, once there are enough for a middle to mean much.
        if len(prices) >= 4:
            q = statistics.quantiles(prices, n=4)
            out.update(typical_low=q[0], typical_high=q[2])
    return out


def _comparables_block(found: dict) -> str:
    if not found["count"]:
        return "No similar live listings on BROKA right now."
    lines = [
        f"{found['count']} similar live listing(s). Lowest KES {found['low']:,.0f}, "
        f"median KES {found['median']:,.0f}, highest KES {found['high']:,.0f}."
    ]
    if found["typical_low"] is not None:
        lines.append(f"Middle half asks KES {found['typical_low']:,.0f}-{found['typical_high']:,.0f}.")
    for item in found["listings"]:
        # The fence is "<<<COMPARABLES ... COMPARABLES>>>": a title that
        # closes it could carry on as if it were the prompt's own text.
        title = _one_line(item.get("name"), _TITLE_MAX).replace("<<<", "‹‹‹").replace(">>>", "›››")
        condition = item.get("condition") if item.get("condition") in CONDITIONS else "condition not stated"
        exact = "close match" if item.get("match_is_exact") else "partial match"
        lines.append(f"- KES {float(item['price']):,.0f} | {condition} | {exact} | {title}")
    return "\n".join(lines)


def _clean_price(value) -> Optional[int]:
    try:
        price = round(float(value))
    except (TypeError, ValueError):
        return None
    return price if 0 < price <= MAX_SUGGESTED_PRICE else None


def _fallback_reply(found: Optional[dict]) -> str:
    """What Zeno says when no model answers: the numbers, if there are any."""
    if found and found["count"]:
        return (f"I can't think it through right now, but I found {found['count']} similar "
                f"listing(s) on BROKA asking KES {found['low']:,.0f}-{found['high']:,.0f}, "
                f"most around KES {found['median']:,.0f}.")
    return "I can't think straight right now - please try again in a moment."


async def price_turn(
    db: AsyncSession,
    user_id: str,
    draft: dict,
    message: str,
    history: list[dict],
    language: str,
    research: bool,
) -> dict:
    """One turn of the pricing conversation.

    {"reply", "suggested_price", "offer_research", "comparables"}:
    comparables is set only on a turn that ran the check (research=True),
    which is the one step counted against the plan. The rest of the
    conversation is a typed Zeno turn, which is free everywhere else too,
    but it is Pro's: the screen is the feature.
    """
    from api.domains.ai_broker.service import AIBrokerService
    from api.routers.negotiate import _language_instruction  # router module; imported late
    from .service import _first_name

    await entitlements.require(db, user_id, entitlements.Feature.PRICE_CHECK)
    found = None
    if research:
        await entitlements.consume(db, user_id, entitlements.Feature.PRICE_CHECK)
        try:
            found = await comparables(db, user_id, draft)
        except Exception:
            await entitlements.release(db, user_id, entitlements.Feature.PRICE_CHECK)
            raise

    try:
        turn = await AIBrokerService().price_listing(
            message=message,
            history=history,
            draft="\n".join(draft_lines(draft)) or "(nothing entered yet)",
            comparables=_comparables_block(found) if found is not None else None,
            language_instruction=_language_instruction(language),
            user_name=await _first_name(db, user_id),
        )
    except Exception as exc:
        # The check still happened and its numbers are worth showing; a
        # failed model must not take them down with it.
        logger.warning("[zeno_selling] pricing model unavailable: %s", exc)
        suggested = round(found["median"]) if found and found["count"] else None
        return {"reply": _fallback_reply(found), "suggested_price": suggested,
                "offer_research": False, "comparables": found, "source": "fallback"}

    return {
        "reply": turn.get("reply") or _fallback_reply(found),
        "suggested_price": _clean_price(turn.get("suggested_price")),
        # Offered only before a check: after one, "check BROKA?" again
        # would spend another for the same answer.
        "offer_research": bool(turn.get("offer_research")) and found is None,
        "comparables": found,
        "source": "model",
    }
