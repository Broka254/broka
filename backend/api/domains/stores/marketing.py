"""The AI Marketing Studio: campaign configuration, platform-specific content
generation, saved drafts, tracked links and measured attribution.

Boundaries this module keeps
----------------------------
* **The seller's real catalogue is the only source of facts.** Prices,
  titles, descriptions and images are read from `listings` filtered by the
  store and its owner - never from the request. A client cannot make the
  studio advertise a price the seller never set.
* **No invented claims.** The model is told, in the prompt and again in the
  output check, not to add warranties, specifications, certification,
  discounts, stock quantities or delivery promises. A discount campaign
  requires the seller to state the discount; without it the request is
  refused rather than made up.
* **Generated is not published.** BROKA does not post to WhatsApp,
  Instagram, TikTok, Facebook or X in this release. The studio produces
  ready-to-share text, design specifications and scripts; a script is
  labelled a script, never a finished video. Nothing here claims a post was
  scheduled or sent.
* **Measured, not estimated.** Campaign events are counters for things
  BROKA actually observed: a campaign was generated; the seller tapped
  download/share; a storefront visit arrived carrying the campaign token.
  There are no impressions, reach, ad spend, sales or revenue figures in
  this module because BROKA does not measure them.

Provider choice
---------------
The existing AI stack is reused: Gemini first, then DeepSeek, both already
configured for Zeno (`GEMINI_API_KEY`, `DEEPSEEK_API_KEY`). No new provider
or package is introduced. If neither is configured or both fail, the
campaign is still generated from the seller's own product facts by the
deterministic template writer below and labelled `template` - the studio
does not stop working because a model is unavailable.
"""
from __future__ import annotations

import asyncio
import hashlib
import io
import json
import logging
import re
import secrets
from datetime import date, datetime, timedelta, timezone
from typing import Optional

import httpx
from fastapi import HTTPException
from sqlalchemy import delete, func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import gemini
from api.core.config import settings
from api.database import Listing, ListingStatus
from api.domains.listings.paid import is_live
from api.models.marketing import (
    LANGUAGES, OBJECTIVES, PLATFORMS, TONES, MarketingCampaign,
    MarketingCampaignEvent, MarketingCreative,
)
from api.models.media import AttachState, MediaAsset, MediaPurpose
from api.models.store import Store, StoreDailyCount

logger = logging.getLogger(__name__)

# Shop-local day for the event counters, the same definition the store
# dashboard uses (api/domains/stores/stats.py).
KENYA = timezone(timedelta(hours=3))

MAX_PRODUCTS = 10
MAX_PLATFORMS = 5
MAX_INSTRUCTIONS = 600
MAX_AUDIENCE = 120
MAX_TITLE = 120
MAX_CREATIVES = 12


class GenerationUnavailable(Exception):
    """The AI provider errored on a campaign that already has creatives.

    Regenerating must not trade the seller's edited posts for template
    output they did not ask for, so the caller turns this into an
    actionable error and leaves the campaign exactly as it was.
    """


# Each platform has its own shape and limits. They are applied to model
# output too - a 900-character "tweet" is truncated at a sentence boundary,
# not published as an X post.
PLATFORM_SPECS: dict[str, dict] = {
    "whatsapp": {
        "formats": ("message", "status"),
        "body_limit": 900,
        "status_limit": 300,
        "hashtags": 0,
        "aspect": "9:16",
        "guidance": (
            "A WhatsApp promotional message is read on a phone in a chat. "
            "Lead with the product and price, keep paragraphs short, one "
            "clear next step. A status creative is a single short line for "
            "an image."
        ),
    },
    "instagram": {
        "formats": ("caption", "story", "carousel"),
        "body_limit": 2200,
        "status_limit": 280,
        "hashtags": 12,
        "aspect": "1:1",
        "guidance": (
            "An Instagram caption opens with a hook before the fold, then "
            "the product and price, then a call to action, then hashtags. A "
            "story is one short line. A carousel is 3-5 slide ideas."
        ),
    },
    "tiktok": {
        "formats": ("script", "video_plan"),
        "body_limit": 1800,
        "status_limit": 150,
        "hashtags": 6,
        "aspect": "9:16",
        "guidance": (
            "TikTok output is a SCRIPT and storyboard, not a video. Give a "
            "3-second hook, 3-5 scenes with what is on screen and what is "
            "said, on-screen text, and a final call to action. Vertical 9:16."
        ),
    },
    "facebook": {
        "formats": ("post", "story"),
        "body_limit": 1500,
        "status_limit": 300,
        "hashtags": 5,
        "aspect": "1:1",
        "guidance": (
            "A Facebook post can be a little longer than X, but leads with "
            "the offer and the place to buy. A story is a short announcement."
        ),
    },
    "x": {
        "formats": ("post",),
        "body_limit": 280,
        "status_limit": 280,
        "hashtags": 3,
        "aspect": "16:9",
        "guidance": (
            "An X post is at most 280 characters INCLUDING the link and "
            "hashtags. Be concise: product, price, one reason, link."
        ),
    },
}

OBJECTIVE_GUIDANCE = {
    "new_store": "Introduce the store itself: who it is, what it sells, and why someone should visit.",
    "product": "Promote the chosen product(s), with their real names and prices.",
    "new_stock": "Announce that the chosen products are now in stock. Do not state quantities.",
    "discount": "Promote a discount THE SELLER STATED in the extra instructions. Never invent a percentage or amount.",
    "awareness": "Build familiarity with the store without claiming a sale or a deadline.",
    "seasonal": "A seasonal angle using only the seller's own offer; do not invent a holiday promotion.",
    "storefront": "Encourage the reader to open the store link and browse.",
    "enquiries": "Encourage a question or a negotiation through BROKA; do not promise a price will be held.",
}

LANGUAGE_NAME = {"en": "English", "sw": "Kiswahili"}

_SAFE_HASHTAG = re.compile(r"^[A-Za-z0-9_]{1,40}$")


def today_kenya() -> date:
    return datetime.now(KENYA).date()


def _clean(value: object, limit: int) -> Optional[str]:
    if not isinstance(value, str):
        return None
    text = " ".join(value.split())
    return text[:limit] or None


def _sentence_trim(text: str, limit: int) -> str:
    """Cut to `limit`, preferring a sentence or word boundary - a truncated
    post that stops mid-word looks like a bug, not brevity."""
    text = " ".join((text or "").split())
    if len(text) <= limit:
        return text
    window = text[:limit]
    for mark in (". ", "! ", "? ", "; "):
        cut = window.rfind(mark)
        if cut >= limit * 0.5:
            return window[: cut + 1].strip()
    cut = window.rfind(" ")
    return (window[:cut] if cut > 0 else window).strip()


def _hashtags_for(store: Store, products: list[dict], platform: str) -> list[str]:
    maximum = int(PLATFORM_SPECS[platform]["hashtags"])
    if maximum <= 0:
        return []
    tags = ["BROKA", "Kenya"]
    for piece in [store.name, *(p["name"] for p in products[:2])]:
        word = re.sub(r"[^A-Za-z0-9]", "", piece or "")
        if 3 <= len(word) <= 24:
            tag = word[0].upper() + word[1:]
            if tag.lower() not in {t.lower() for t in tags}:
                tags.append(tag)
    return tags[:maximum]


def _price_label(product: dict) -> Optional[str]:
    price = product.get("price")
    if price is None:
        return None
    unit = product.get("price_unit")
    return f"KES {price:,.0f}" + (f" per {unit}" if unit else "")


def _premises(store: Store) -> Optional[str]:
    """Where a buyer can walk in, or None for a store without premises.

    A virtual store keeps any address it had (the switch never destroys
    it), so this checks the TYPE, not the presence of a county: reusing
    the stored county as "where we are" would put a shopfront in copy for
    a business that has none.
    """
    if (store.store_type or "physical") == "virtual":
        return None
    return ", ".join(x for x in [store.subcounty, store.county] if x) or None


def _coverage(store: Store) -> Optional[str]:
    """Where the store delivers - its declared service areas, then (for a
    shop only) its own town. Delivery coverage is not the address: a shop
    in Kisumu may deliver nationwide."""
    try:
        areas = json.loads(store.service_areas or "[]")
    except (TypeError, ValueError):
        areas = []
    areas = (
        [a for a in areas if isinstance(a, str) and a.strip()]
        if isinstance(areas, list) else []
    )
    if areas:
        return "Nationwide" if len(areas) == 1 and areas[0].lower() == "nationwide" \
            else ", ".join(areas)
    return _premises(store)


def _coverage_sentence(store: Store, swahili: bool) -> Optional[str]:
    """A full sentence about delivery, or None when nothing is declared.

    "Delivers to Nationwide" is not English; the national case gets its own
    wording in both languages.
    """
    coverage = _coverage(store)
    if not coverage:
        return None
    if coverage == "Nationwide":
        return "Tunawasilisha nchini kote." if swahili else "Delivers nationwide."
    return f"Tunawasilisha {coverage}." if swahili else f"Delivers to {coverage}."


def _coverage_bullet(store: Store) -> Optional[str]:
    """The short form used in a WhatsApp message's bullet list."""
    coverage = _coverage(store)
    if not coverage:
        return None
    return "Nationwide delivery" if coverage == "Nationwide" else f"Delivers to {coverage}"


def campaign_link(store: Store, token: str, platform: str) -> str:
    """The storefront link a campaign hands out. It carries both the
    platform and the campaign token, so a visit can be attributed to the
    exact campaign without collecting anything about the visitor."""
    from api.domains.stores.service import store_link
    base = store_link(store.slug)
    return f"{base}?via={platform}&c={token}"


# ── Loading the seller's real catalogue ──────────────────────────────────────

async def _load_products(db: AsyncSession, store: Store, product_ids: list[str],
                         require_live: bool = True) -> list[dict]:
    """The selected listings, refusing anything this store may not promote.

    A product from another store, another seller, an archived one, or one
    buyers cannot currently see (unpaid listing fee, in a deal, sold) is
    refused with a message naming it - promoting something that isn't for
    sale wastes the seller's effort and misleads buyers.

    Saved campaigns are read with `require_live=False`: a campaign is a
    record of what was promoted, and it must still open after its product
    sells. Generating again is always strict.
    """
    ids = list(dict.fromkeys(product_ids))
    if not ids:
        return []
    rows = (await db.execute(
        select(Listing).where(Listing.id.in_(ids), Listing.store_id == store.id)
    )).scalars().all()
    found = {row.id: row for row in rows}
    missing = [i for i in ids if i not in found]
    if missing:
        raise HTTPException(
            status_code=400,
            detail="Some of those products aren't in this store. Choose them again.",
        )
    now = datetime.utcnow()
    blocked: list[str] = []
    for row in rows:
        status = getattr(row.status, "value", row.status)
        if row.seller_id != store.owner_id:
            blocked.append(row.name)
        elif require_live and (status != ListingStatus.active.value or not is_live(row, now)):
            blocked.append(row.name)
    if blocked:
        raise HTTPException(
            status_code=400,
            detail="These products aren't available to buyers right now, so they can't be "
                   "promoted yet: " + ", ".join(blocked[:5]) + ".",
        )
    from api.domains.media.service import asset_urls, load_assets, parse_id_list
    asset_ids: set[str] = set()
    for row in rows:
        asset_ids.update(parse_id_list(row.photo_ids))
    assets = await load_assets(db, asset_ids)
    out = []
    for row in rows:
        image = None
        for asset_id in parse_id_list(row.photo_ids):
            if asset_id in assets:
                image = asset_urls(assets[asset_id])
                break
        attributes = {}
        try:
            attributes = json.loads(row.attributes or "{}")
        except (TypeError, ValueError):
            attributes = {}
        out.append({
            "id": row.id,
            "name": row.name,
            "price": float(row.price) if row.price is not None else None,
            "price_unit": row.price_unit,
            "category": row.category,
            "description": (row.description or "").strip()[:600],
            "condition": row.condition,
            "brand": next(
                (str(v) for k, v in attributes.items() if "brand" in k.lower() and v), None,
            ),
            "image": image,
            "image_asset_id": next(
                (i for i in parse_id_list(row.photo_ids) if i in assets), None,
            ),
        })
    return out


# ── Provider calls ───────────────────────────────────────────────────────────

def _provider_available() -> str:
    if settings.gemini_api_key:
        return "gemini"
    if settings.deepseek_api_key:
        return "deepseek"
    return ""


def _prompt(store: Store, campaign: MarketingCampaign, products: list[dict],
            platforms: list[str]) -> str:
    product_lines = []
    for p in products:
        bits = [f"- {p['name']}", _price_label(p) or "", p.get("brand") or "",
                p.get("category") or "", (p.get("description") or "")[:240]]
        product_lines.append(" · ".join(b for b in bits if b))
    links = "\n".join(f"{p}: {campaign_link(store, campaign.link_token, p)}" for p in platforms)
    specs = "\n".join(
        f"- {p.upper()}: {PLATFORM_SPECS[p]['guidance']} Output formats: "
        f"{', '.join(PLATFORM_SPECS[p]['formats'])}. Body ≤ {PLATFORM_SPECS[p]['body_limit']} "
        f"characters, at most {PLATFORM_SPECS[p]['hashtags']} hashtags."
        for p in platforms
    )
    discount_note = (
        f"The seller's stated discount: {campaign.instructions}"
        if campaign.objective == "discount" else
        f"Extra instructions from the seller: {campaign.instructions or '(none)'}"
    )
    # A virtual store has no shop to visit, and its stored county is not an
    # address the model may hand to readers. Giving it the coverage instead
    # keeps the copy factual and stops "come to our shop in X" appearing
    # for a business that has no shopfront.
    virtual = (store.store_type or "physical") == "virtual"
    if virtual:
        place_line = "No shop customers can visit - an online store only."
    else:
        place_line = _premises(store) or "Kenya (no town stated)"
    coverage_line = ("nationwide" if _coverage(store) == "Nationwide"
                     else _coverage(store) or "not stated")
    return f"""You write social media marketing for a Kenyan small business on BROKA.
Store: {store.name}
Type: {"virtual (online only, no shop to visit)" if virtual else "physical (a shop customers can visit)"}
What it sells: {store.category or 'general goods'}
Where it is: {place_line}
Delivers to: {coverage_line}
Products (these are the ONLY facts you may state):
{chr(10).join(product_lines) or '(the store itself, no single product)'}

Objective: {OBJECTIVE_GUIDANCE.get(campaign.objective, campaign.objective)}
Audience: {campaign.audience or 'Kenyan shoppers'}
Tone: {campaign.tone}
Language: {LANGUAGE_NAME.get(campaign.language, 'English')} - write the body in this language.
{discount_note}

Tracked links (use the link for the platform each creative is for):
{links}

Platform requirements:
{specs}

Rules:
- Use only the product facts above. Do not invent warranties, specifications, certifications,
  stock counts, delivery promises, prices, discounts, deadlines or brand claims.
- Never say BROKA holds payments, guarantees delivery or verifies the product.
- Never invent a shop address or tell readers to visit a shop that is not the
  physical location above. If the store is virtual, never imply it has premises.
- The delivery line is the seller's coverage. Do not narrow it or widen it.
- WhatsApp messages and Instagram/Facebook captions may be multi-line. X must be ≤280
  characters including its link. TikTok output is a script/storyboard, never called a video.
- Each platform must get genuinely different copy - not the same text with the platform name changed.
- Calls to action must be honest: "Open the link", "Ask on BROKA", "Browse the store".

Return ONLY valid JSON in exactly this shape:
{{"title": "short campaign title", "creatives": [{{"platform": "whatsapp",
"format": "message", "headline": "short headline or null", "body": "the copy",
"hashtags": ["tag"], "cta": "short call to action",
"media": {{"aspect_ratio": "9:16", "template": "bold_offer",
"slides": [{{"text": "on-screen text"}}]}}}}],
"plan": [{{"day": "Monday", "platform": "whatsapp", "format": "message",
"product": "product name or null", "idea": "what to post"}}]}}
Generate one main creative and one secondary format for each platform asked for.
The plan should cover a simple week, grounded in these products."""


async def _call_gemini(prompt: str) -> str:
    if not settings.gemini_api_key:
        raise RuntimeError("GEMINI_API_KEY not set")
    async with httpx.AsyncClient(timeout=25) as client:
        response = await client.post(
            f"{gemini.endpoint()}?key={settings.gemini_api_key}",
            json={
                "contents": [{"role": "user", "parts": [{"text": prompt}]}],
                "generationConfig": {
                    "temperature": 0.8,
                    "maxOutputTokens": gemini.output_budget(3000),
                    "responseMimeType": "application/json",
                },
            },
        )
    if response.status_code != 200:
        raise RuntimeError(f"Gemini HTTP {response.status_code}")
    return gemini.reply_text(response.json())


async def _call_deepseek(prompt: str) -> str:
    if not settings.deepseek_api_key:
        raise RuntimeError("DEEPSEEK_API_KEY not set")
    async with httpx.AsyncClient(timeout=settings.deepseek_timeout_seconds + 10) as client:
        response = await client.post(
            f"{settings.deepseek_base_url.rstrip('/')}/chat/completions",
            headers={"Authorization": f"Bearer {settings.deepseek_api_key}"},
            json={
                "model": settings.deepseek_model,
                "messages": [
                    {"role": "system", "content": "You are a careful social media copywriter. Reply with JSON only."},
                    {"role": "user", "content": prompt},
                ],
                "temperature": 0.8,
                "response_format": {"type": "json_object"},
            },
        )
    if response.status_code != 200:
        raise RuntimeError(f"DeepSeek HTTP {response.status_code}")
    data = response.json()
    text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content")
    if not text:
        raise RuntimeError("DeepSeek returned no content")
    return text


def _json_from(text: str) -> dict:
    cleaned = (text or "").strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```[a-zA-Z]*\s*|\s*```$", "", cleaned)
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in the model's reply")
    value = json.loads(cleaned[start:end + 1])
    if not isinstance(value, dict):
        raise ValueError("model reply was not a JSON object")
    return value


# ── Output validation and template fallback ──────────────────────────────────

def _creative_dict(item: dict, platform: str, index: int, store: Store,
                   products: list[dict]) -> Optional[dict]:
    """One validated creative, or None when the model's item is unusable.

    Lengths are enforced here rather than trusted: the provider's "280
    characters" can be 400, and publishing that to X would be a broken post.
    """
    if not isinstance(item, dict):
        return None
    spec = PLATFORM_SPECS[platform]
    formats = spec["formats"]
    fmt = item.get("format") if item.get("format") in formats else formats[index % len(formats)]
    body = _sentence_trim(str(item.get("body") or ""), spec["body_limit"])
    if not body:
        return None
    headline = _clean(item.get("headline"), 160)
    cta = _clean(item.get("cta"), 160)
    raw_tags = item.get("hashtags")
    tags: list[str] = []
    if isinstance(raw_tags, list):
        for tag in raw_tags[: spec["hashtags"]]:
            if isinstance(tag, str):
                clean = tag.strip().lstrip("#")
                if _SAFE_HASHTAG.match(clean) and clean.lower() not in {t.lower() for t in tags}:
                    tags.append(clean)
    if not tags:
        tags = _hashtags_for(store, products, platform)
    media = item.get("media") if isinstance(item.get("media"), dict) else {}
    media = {
        **{k: v for k, v in media.items() if k in ("template", "slides", "scenes", "palette")},
        "aspect_ratio": media.get("aspect_ratio") if media.get("aspect_ratio") in (
            "1:1", "9:16", "16:9", "4:5") else spec["aspect"],
    }
    if platform == "tiktok" and fmt in ("script", "video_plan"):
        media.setdefault("duration_seconds", 20)
        media.setdefault("aspect_ratio", "9:16")
    return {
        "platform": platform, "format": fmt, "headline": headline, "body": body,
        "hashtags": tags, "cta": cta, "media": media,
    }


def _validate_ai_output(raw: dict, store: Store, products: list[dict],
                        platforms: list[str]) -> Optional[dict]:
    creatives = raw.get("creatives")
    if not isinstance(creatives, list):
        return None
    out: list[dict] = []
    for platform in platforms:
        mine = [c for c in creatives if isinstance(c, dict) and c.get("platform") == platform]
        for i, item in enumerate(mine[:2]):
            creative = _creative_dict(item, platform, i, store, products)
            if creative:
                out.append(creative)
    # Every requested platform must have at least one usable creative,
    # otherwise the reply is treated as a failure and the template writer
    # covers the whole campaign. A half-finished social kit is worse than a
    # consistent one.
    if {c["platform"] for c in out} != set(platforms):
        return None
    plan = []
    for row in raw.get("plan") or []:
        if not isinstance(row, dict):
            continue
        platform = row.get("platform")
        if platform not in platforms:
            continue
        plan.append({
            "day": _clean(row.get("day"), 20) or "This week",
            "platform": platform,
            "format": _clean(row.get("format"), 24) or PLATFORM_SPECS[platform]["formats"][0],
            "product": _clean(row.get("product"), 120),
            "idea": _clean(row.get("idea"), 240) or "Post this campaign's creative.",
        })
    return {"title": _clean(raw.get("title"), MAX_TITLE), "creatives": out, "plan": plan[:7]}


def _template_creatives(store: Store, campaign: MarketingCampaign,
                        products: list[dict], platforms: list[str]) -> list[dict]:
    """Platform-specific copy built only from the seller's own records.

    This is the fallback when no AI provider is configured or the reply is
    unusable. It is deliberately plain: it states the product, the real
    price and the link, and nothing BROKA cannot verify.
    """
    sw = campaign.language == "sw"
    primary = products[0] if products else None
    name = primary["name"] if primary else store.name
    price = _price_label(primary) if primary else None
    # Two different facts, deliberately kept apart: where a buyer can walk
    # in (physical stores only) and where the store delivers (either kind).
    premises = _premises(store)
    coverage = _coverage(store)
    shop_line = (f"Duka la {store.name}" if sw else f"{store.name}")
    delivery = _coverage_sentence(store, sw)
    if sw:
        lead = f"{name} ipo {shop_line}."
        detail = (f"Bei: {price}. " if price else "") + (f"{delivery} " if delivery else "")
        cta = "Fungua kiungo kuona zaidi."
    else:
        lead = f"{name} is available at {store.name}."
        detail = (f"Price: {price}. " if price else "") + (f"{delivery} " if delivery else "")
        cta = "Open the link to see more."
    description = (primary or {}).get("description") or (store.description or "")
    description = _sentence_trim(description, 180)
    # The discount is the seller's own statement (a discount campaign is
    # refused without one). It is not a promise BROKA makes, and the
    # template never adds a figure of its own.
    offer = (f"Offer: {campaign.instructions}"
             if campaign.objective == "discount" and campaign.instructions else None)
    out: list[dict] = []
    for platform in platforms:
        link = campaign_link(store, campaign.link_token, platform)
        tags = _hashtags_for(store, products, platform)
        if platform == "whatsapp":
            # A chat message: short lines, price and place as bullets, one
            # link. Read on a phone in a conversation, not a web page.
            lines = [f"*{name}*", lead, "".join(f"• {x}\n" for x in [
                price,
                f"At {premises}" if premises else None,
                _coverage_bullet(store) if coverage and coverage != premises else None,
            ] if x).strip(), offer, description, f"{cta} {link}"]
            body = "\n".join(x for x in lines if x)
            out.append({
                "platform": platform, "format": "message",
                "headline": _sentence_trim(lead, 80), "body": _sentence_trim(body, 900),
                "hashtags": [], "cta": cta,
                "media": {"aspect_ratio": "1:1", "template": "product_card"},
            })
            out.append({
                "platform": platform, "format": "status",
                "headline": _sentence_trim(name, 60),
                "body": _sentence_trim(f"{lead} {price or ''}".strip(), 300),
                "hashtags": [], "cta": cta,
                "media": {"aspect_ratio": "9:16", "template": "bold_offer"},
            })
        elif platform == "instagram":
            # A caption: a hook line, then the detail, then the ask. Longer
            # and more visual in tone than the WhatsApp message.
            hook = (f"New at {store.name}: {name}" if campaign.objective != "awareness"
                    else f"Meet {store.name}")
            body = "\n\n".join(x for x in [
                hook, detail.strip(), offer, description,
                f"{cta} {link}", " ".join(f"#{t}" for t in tags),
            ] if x)
            out.append({
                "platform": platform, "format": "caption",
                "headline": _sentence_trim(name, 80), "body": _sentence_trim(body, 2200),
                "hashtags": tags, "cta": cta,
                "media": {"aspect_ratio": "1:1", "template": "product_card"},
            })
            out.append({
                "platform": platform, "format": "story",
                "headline": _sentence_trim(name, 60),
                "body": _sentence_trim(
                    f"{name} · {price or ''} · tap through to the store".strip(), 280),
                "hashtags": tags[:3], "cta": cta,
                "media": {"aspect_ratio": "9:16", "template": "bold_offer",
                          "slides": [{"text": _sentence_trim(name, 50)},
                                     {"text": price or cta}]},
            })
        elif platform == "tiktok":
            hook = _sentence_trim(
                (f"Unatafuta {name}?" if sw else f"Looking for {name}?"), 90)
            out.append({
                "platform": platform, "format": "script",
                "headline": hook,
                "body": _sentence_trim(
                    "\n".join([
                        f"HOOK (0-3s): {hook}",
                        f"SCENE 1: Show {name} clearly. On-screen: {name}.",
                        f"SCENE 2: Show the detail a buyer asks about. On-screen: {price or ''}",
                        f"SCENE 3: {cta}",
                    ]), 1800),
                "hashtags": tags, "cta": cta,
                "media": {"aspect_ratio": "9:16", "duration_seconds": 20,
                          "template": "vertical_script",
                          "scenes": [{"shot": "Product on a clean surface",
                                      "text": _sentence_trim(name, 50)},
                                     {"shot": "Close-up detail",
                                      "text": price or _sentence_trim(lead, 50)},
                                     {"shot": "Store link card", "text": cta}]},
            })
            out.append({
                "platform": platform, "format": "video_plan",
                "headline": "Video plan",
                "body": _sentence_trim(
                    f"Concept: a 20-second vertical clip showing {name} and its real price at "
                    f"{store.name}. No claims beyond the listing.", 1200),
                "hashtags": tags, "cta": cta,
                "media": {"aspect_ratio": "9:16", "duration_seconds": 20,
                          "template": "storyboard"},
            })
        elif platform == "facebook":
            # Facebook reads like a shop's community update: who, what,
            # where to ask - rather than a caption or a chat message.
            opening = f"Just in at {store.name}"
            body = "\n\n".join(x for x in [
                f"{opening}: {name}.", detail.strip(), offer, description,
                "Message the shop on BROKA or open the store link below.",
                link,
            ] if x)
            out.append({
                "platform": platform, "format": "post",
                "headline": _sentence_trim(name, 80), "body": _sentence_trim(body, 1500),
                "hashtags": tags, "cta": cta,
                "media": {"aspect_ratio": "1:1", "template": "product_card"},
            })
            out.append({
                "platform": platform, "format": "story",
                "headline": _sentence_trim(name, 60),
                "body": _sentence_trim(
                    f"{store.name} has {name}. {price or ''} Ask on BROKA today.".strip(), 300),
                "hashtags": tags[:2], "cta": cta,
                "media": {"aspect_ratio": "9:16", "template": "bold_offer"},
            })
        else:  # x
            body = _sentence_trim(f"{name} at {store.name}. {price or ''} {offer or ''} {link}", 280)
            out.append({
                "platform": platform, "format": "post",
                "headline": None, "body": body,
                "hashtags": tags, "cta": cta,
                "media": {"aspect_ratio": "16:9", "template": "link_card"},
            })
    return out


def _template_plan(store: Store, products: list[dict], platforms: list[str],
                   language: str) -> list[dict]:
    days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    plan = []
    for i, platform in enumerate(platforms):
        product = products[i % len(products)] if products else None
        plan.append({
            "day": days[i % len(days)],
            "platform": platform,
            "format": PLATFORM_SPECS[platform]["formats"][0],
            "product": product["name"] if product else None,
            "idea": ("Post the generated creative and the store link."
                     if language == "en" else "Chapisha tangazo na kiungo cha duka."),
        })
    return plan[:7]


# ── Creative art (deterministic; optional) ───────────────────────────────────

def _render_poster(image_bytes: Optional[bytes], headline: str, body: str,
                   cta: str, aspect: str) -> Optional[bytes]:
    """A simple, honest promotional image: the seller's real product photo
    with their own words. Not an AI-generated picture of a product that
    doesn't exist. Returns None when no usable image was supplied, in which
    case the creative is text + design spec only."""
    if not image_bytes:
        return None
    try:
        from PIL import Image, ImageDraw, ImageFont, ImageOps

        sizes = {"1:1": (1080, 1080), "9:16": (1080, 1920), "16:9": (1200, 675),
                 "4:5": (1080, 1350)}
        width, height = sizes.get(aspect, (1080, 1080))
        canvas = Image.new("RGB", (width, height), (11, 14, 24))
        photo = Image.open(io.BytesIO(image_bytes)).convert("RGB")
        photo = ImageOps.fit(photo, (width, int(height * 0.66)), method=Image.LANCZOS)
        canvas.paste(photo, (0, 0))
        draw = ImageDraw.Draw(canvas)
        draw.rectangle([0, int(height * 0.58), width, height], fill=(11, 14, 24))
        # Pillow 10.1+ can size the built-in font; the repository's pinned
        # Pillow is 10.3. A font file is not required (Render's slim image
        # has none), and no text is drawn outside the canvas.
        try:
            title_font = ImageFont.load_default(size=max(30, width // 18))
            body_font = ImageFont.load_default(size=max(20, width // 32))
        except TypeError:  # pragma: no cover - Pillow < 10.1
            title_font = body_font = ImageFont.load_default()

        def wrap(text: str, font, max_width: int, max_lines: int) -> list[str]:
            words = (text or "").split()
            lines: list[str] = []
            current = ""
            for word in words:
                trial = f"{current} {word}".strip()
                if draw.textlength(trial, font=font) <= max_width or not current:
                    current = trial
                else:
                    lines.append(current)
                    current = word
                    if len(lines) >= max_lines:
                        break
            if current and len(lines) < max_lines:
                lines.append(current)
            return lines

        y = int(height * 0.62)
        for line in wrap(headline, title_font, width - 120, 2):
            draw.text((60, y), line, font=title_font, fill=(237, 232, 248))
            y += int(title_font.size * 1.2 if hasattr(title_font, "size") else 44)
        for line in wrap(body, body_font, width - 120, 3):
            draw.text((60, y), line, font=body_font, fill=(150, 160, 190))
            y += int(body_font.size * 1.35 if hasattr(body_font, "size") else 30)
        if cta:
            draw.rounded_rectangle(
                [60, height - 140, min(width - 60, 60 + int(draw.textlength(cta, font=body_font)) + 80), height - 70],
                radius=20, fill=(139, 92, 246),
            )
            draw.text((100, height - 122), cta[:60], font=body_font, fill=(255, 255, 255))
        out = io.BytesIO()
        canvas.save(out, format="PNG", optimize=True)
        return out.getvalue()
    except Exception as exc:  # noqa: BLE001 - art must never fail the campaign
        logger.warning("[marketing] poster render skipped: %s", exc)
        return None


# ── Events ──────────────────────────────────────────────────────────────────

async def record_event(campaign: MarketingCampaign, kind: str, platform: str = "",
                       db: Optional[AsyncSession] = None) -> None:
    """Increment the day's counter. Called inside the request's session, and
    deliberately never allowed to fail the action it describes."""
    from api.database import AsyncSessionLocal

    day = today_kenya()
    try:
        if db is None:
            async with AsyncSessionLocal() as own_db:
                await _increment_event(own_db, campaign, kind, platform, day)
        else:
            await _increment_event(db, campaign, kind, platform, day)
    except Exception as exc:  # noqa: BLE001
        logger.warning("[marketing] could not record %s for %s: %s", kind, campaign.id, exc)


async def _increment_event(db: AsyncSession, campaign: MarketingCampaign, kind: str,
                           platform: str, day: date) -> None:
    """UPDATE then INSERT, with the unique constraint resolving two
    concurrent first-events-of-the-day - the same rule as StoreDailyCount."""
    match = (
        MarketingCampaignEvent.campaign_id == campaign.id,
        MarketingCampaignEvent.kind == kind,
        MarketingCampaignEvent.platform == platform,
        MarketingCampaignEvent.day == day,
    )
    for _ in range(3):
        result = await db.execute(
            update(MarketingCampaignEvent).where(*match)
            .values(count=MarketingCampaignEvent.count + 1)
            .execution_options(synchronize_session=False)
        )
        if result.rowcount:
            await db.commit()
            return
        db.add(MarketingCampaignEvent(
            campaign_id=campaign.id, store_id=campaign.store_id,
            kind=kind, platform=platform, day=day, count=1,
        ))
        try:
            await db.commit()
            return
        except IntegrityError:
            await db.rollback()


# ── The service ─────────────────────────────────────────────────────────────

class MarketingService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def _store(self, store_id: str, requester_id: str) -> Store:
        from api.domains.stores.service import StoreService
        return await StoreService(self.db).get_owned(store_id, requester_id)

    async def _campaign(self, store: Store, campaign_id: str) -> MarketingCampaign:
        campaign = (await self.db.execute(
            select(MarketingCampaign).where(
                MarketingCampaign.id == campaign_id,
                MarketingCampaign.store_id == store.id,
                MarketingCampaign.owner_id == store.owner_id,
                MarketingCampaign.deleted_at.is_(None),
            )
        )).scalar_one_or_none()
        if campaign is None:
            # 404, not 403: another seller's campaign should not be
            # confirmable by id from here.
            raise HTTPException(status_code=404, detail="Campaign not found")
        return campaign

    async def _creatives(self, campaign_id: str) -> list[MarketingCreative]:
        return (await self.db.execute(
            select(MarketingCreative).where(MarketingCreative.campaign_id == campaign_id)
            .order_by(MarketingCreative.created_at, MarketingCreative.platform)
        )).scalars().all()

    async def _events(self, campaign_id: str) -> dict:
        rows = (await self.db.execute(
            select(
                MarketingCampaignEvent.kind, MarketingCampaignEvent.platform,
                func.sum(MarketingCampaignEvent.count),
            ).where(MarketingCampaignEvent.campaign_id == campaign_id)
            .group_by(MarketingCampaignEvent.kind, MarketingCampaignEvent.platform)
        )).all()
        by_kind: dict[str, int] = {}
        by_platform: dict[str, int] = {}
        for kind, platform, count in rows:
            n = int(count or 0)
            by_kind[kind] = by_kind.get(kind, 0) + n
            if platform:
                by_platform[platform] = by_platform.get(platform, 0) + n
        return {
            "by_kind": by_kind,
            "by_platform": by_platform,
            # What these numbers are - and are not. The dashboard must not
            # turn a generated creative into an impression or a sale.
            "measured": [
                "created", "generated", "downloaded", "shared",
                "visit", "product_view",
            ],
            "not_measured": [
                "impressions", "reach", "advertising_spend", "sales", "revenue",
            ],
        }

    async def _payload(self, store: Store, campaign: MarketingCampaign,
                       include_events: bool = True) -> dict:
        creatives = await self._creatives(campaign.id)
        products = await _load_products(
            self.db, store, [i for i in self._json_list(campaign.product_ids)],
            require_live=False,
        ) if self._json_list(campaign.product_ids) else []
        platforms = [p for p in self._json_list(campaign.platforms) if p in PLATFORMS]
        from api.domains.media.service import asset_urls, load_assets
        asset_ids = {c.asset_id for c in creatives if c.asset_id}
        assets = await load_assets(self.db, asset_ids)
        return {
            "id": campaign.id,
            "title": campaign.title,
            "objective": campaign.objective,
            "audience": campaign.audience,
            "tone": campaign.tone,
            "language": campaign.language,
            "instructions": campaign.instructions,
            "product_ids": self._json_list(campaign.product_ids),
            "products": products,
            "platforms": platforms,
            "status": campaign.status,
            "link_token": campaign.link_token,
            "links": {p: campaign_link(store, campaign.link_token, p) for p in platforms},
            "store_url": campaign_link(store, campaign.link_token, "direct"),
            "creatives": [self._creative_payload(c, assets) for c in creatives],
            "plan": self._json_list(campaign.plan),
            "generation": self._json_list(campaign.generation, parsed=True),
            "events": await self._events(campaign.id) if include_events else None,
            "created_at": campaign.created_at.isoformat() if campaign.created_at else None,
            "updated_at": campaign.updated_at.isoformat() if campaign.updated_at else None,
        }

    @staticmethod
    def _json_list(raw: Optional[str], parsed: bool = False):
        try:
            value = json.loads(raw) if raw else []
        except (TypeError, ValueError):
            return [] if not parsed else {}
        if parsed:
            return value if isinstance(value, dict) else {}
        return value if isinstance(value, list) else []

    @staticmethod
    def _creative_payload(creative: MarketingCreative, assets: dict) -> dict:
        from api.domains.media.service import asset_urls
        try:
            media = json.loads(creative.media or "{}")
        except (TypeError, ValueError):
            media = {}
        try:
            tags = json.loads(creative.hashtags or "[]")
        except (TypeError, ValueError):
            tags = []
        asset = assets.get(creative.asset_id) if creative.asset_id else None
        return {
            "id": creative.id,
            "platform": creative.platform,
            "format": creative.format,
            "headline": creative.headline,
            "body": creative.body,
            "hashtags": tags if isinstance(tags, list) else [],
            "cta": creative.cta,
            "media": media if isinstance(media, dict) else {},
            "asset": asset_urls(asset),
            "source": creative.source,
        }

    # ── Create and generate ──────────────────────────────────────────────

    async def create_campaign(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await self._store(store_id, requester_id)
        campaign = self._build_campaign(store, requester_id, data)
        self.db.add(campaign)
        await self.db.commit()
        await self.db.refresh(campaign)
        await record_event(campaign, "created", db=self.db)
        if data.get("generate", True):
            await self._generate(store, campaign)
            await record_event(campaign, "generated", db=self.db)
            await self.db.refresh(campaign)
        return await self._payload(store, campaign)

    def _build_campaign(self, store: Store, owner_id: str, data: dict) -> MarketingCampaign:
        objective = data.get("objective") or "product"
        if objective not in OBJECTIVES:
            raise HTTPException(status_code=400, detail="Choose a campaign objective.")
        platforms = [p for p in (data.get("platforms") or []) if isinstance(p, str)]
        platforms = list(dict.fromkeys(platforms))
        if not platforms:
            raise HTTPException(status_code=400, detail="Choose at least one platform.")
        if len(platforms) > MAX_PLATFORMS or any(p not in PLATFORMS for p in platforms):
            raise HTTPException(
                status_code=400, detail="Choose from WhatsApp, Instagram, TikTok, Facebook or X.")
        language = data.get("language") or "en"
        if language not in LANGUAGES:
            raise HTTPException(status_code=400, detail="Choose English or Kiswahili.")
        tone = data.get("tone") or "friendly"
        if tone not in TONES:
            raise HTTPException(status_code=400, detail="Choose a tone from the list.")
        product_ids = data.get("product_ids") or []
        if not isinstance(product_ids, list) or not all(isinstance(i, str) for i in product_ids):
            raise HTTPException(status_code=400, detail="Choose products from your store.")
        product_ids = list(dict.fromkeys(product_ids))
        if len(product_ids) > MAX_PRODUCTS:
            raise HTTPException(
                status_code=400, detail=f"Choose at most {MAX_PRODUCTS} products for one campaign.")
        if objective in ("product", "new_stock", "discount") and not product_ids:
            raise HTTPException(
                status_code=400, detail="Choose the product or products this campaign is about.")
        instructions = _clean(data.get("instructions"), MAX_INSTRUCTIONS)
        if objective == "discount" and not instructions:
            # A discount is the seller's to state. Generating one from
            # nothing is exactly the invented claim this studio forbids.
            raise HTTPException(
                status_code=400,
                detail="Describe the real discount (for example \"10% off until Friday\") - "
                       "BROKA won't invent one.",
            )
        title = _clean(data.get("title"), MAX_TITLE)
        if not title:
            title = (f"Promote {len(product_ids)} products" if len(product_ids) > 1
                     else "Promote your store" if not product_ids else "Product campaign")
        return MarketingCampaign(
            store_id=store.id, owner_id=owner_id, title=title, objective=objective,
            audience=_clean(data.get("audience"), MAX_AUDIENCE), tone=tone,
            language=language, instructions=instructions,
            product_ids=json.dumps(product_ids), platforms=json.dumps(platforms),
            status="draft", link_token="k" + secrets.token_urlsafe(12),
        )

    async def _generate(self, store: Store, campaign: MarketingCampaign,
                        keep_on_provider_error: bool = False) -> None:
        """Generate and persist creatives, replacing the campaign's old set.

        On a first generation the campaign has nothing to lose, so a
        provider failure falls through to the template writer. An explicit
        regenerate (`keep_on_provider_error`) is different: the seller may
        have edited every caption, and a provider outage must not silently
        overwrite that with template output - it raises
        GenerationUnavailable and leaves the campaign untouched.
        """
        existing = await self._creatives(campaign.id) if keep_on_provider_error else []
        previous_assets = {c.asset_id for c in existing if c.asset_id}
        products = await _load_products(
            self.db, store, self._json_list(campaign.product_ids),
        )
        platforms = [p for p in self._json_list(campaign.platforms) if p in PLATFORMS]
        source = "template"
        generation: dict = {"provider": "template", "fallback": True}
        creatives: list[dict] = []
        plan: list[dict] = []
        provider = _provider_available()
        if provider:
            prompt = _prompt(store, campaign, products, platforms)
            try:
                raw_text = await (_call_gemini(prompt) if provider == "gemini"
                                  else _call_deepseek(prompt))
                validated = _validate_ai_output(_json_from(raw_text), store, products, platforms)
                if validated:
                    creatives = validated["creatives"]
                    plan = validated["plan"] or _template_plan(
                        store, products, platforms, campaign.language)
                    default_titles = {
                        "Product campaign", "Promote your store",
                        f"Promote {len(products)} products",
                    }
                    if validated.get("title") and campaign.title in default_titles:
                        campaign.title = validated["title"]
                    source = "ai"
                    generation = {"provider": provider, "fallback": False}
            except Exception as exc:  # noqa: BLE001 - fall back, never fail
                logger.warning("[marketing] %s generation failed: %s", provider, exc)
                if existing:
                    # Nothing has been written yet at this point; the old
                    # creatives and their poster are still the campaign.
                    raise GenerationUnavailable("provider error") from exc
                generation = {"provider": provider, "fallback": True,
                              "reason": "The AI provider didn't answer usefully; "
                                        "this campaign was written from your product details."}
        if not creatives and provider and existing:
            # Configured, answered, and the answer was unusable - the same
            # rule as an error: a rewrite that would lose the seller's
            # edited posts is refused rather than silently replaced.
            raise GenerationUnavailable("unusable provider output")
        if not creatives:
            creatives = _template_creatives(store, campaign, products, platforms)
            plan = plan or _template_plan(store, products, platforms, campaign.language)

        # Replace the generated set. Editing happens afterwards on the new
        # rows; nothing is silently overwritten by a reload.
        old_asset_ids = previous_assets or await self._creative_asset_ids(campaign.id)
        await self.db.execute(
            delete(MarketingCreative).where(MarketingCreative.campaign_id == campaign.id)
        )
        await self._retire_assets(old_asset_ids)
        rows: list[MarketingCreative] = []
        for item in creatives[:MAX_CREATIVES]:
            row = MarketingCreative(
                campaign_id=campaign.id, platform=item["platform"], format=item["format"],
                headline=item["headline"], body=item["body"],
                hashtags=json.dumps(item["hashtags"]), cta=item["cta"],
                media=json.dumps(item["media"]), source=source,
            )
            self.db.add(row)
            rows.append(row)
        campaign.plan = json.dumps(plan)
        campaign.generation = json.dumps(generation)
        campaign.status = "generated"
        campaign.updated_at = datetime.utcnow()
        await self.db.flush()
        # Commit the text BEFORE drawing the poster: the database storage
        # driver writes each size through its own session, so an open write
        # transaction locks it out on SQLite (see media/service.py). The
        # worst case if the second commit fails is a campaign with copy and
        # no image, which the studio already handles.
        await self.db.commit()

        # One downloadable image per campaign, built from the first real
        # product photo. A campaign without products (store introduction)
        # still gets a poster when the store has a cover/photo.
        if rows:
            await self._refresh_poster(store, rows[0], products)
            await self.db.commit()

    async def _refresh_poster(self, store: Store, creative: MarketingCreative,
                              products: list[dict]) -> None:
        """Draw this creative's poster from its current text.

        Used on generation and again after the seller edits a caption: the
        PNG carries the headline and body, so a stale file would let them
        save an image that no longer matches the post (a removed discount,
        a corrected price). Art failure never fails the campaign - the text
        is still the campaign, and no image is better than a wrong one.
        """
        try:
            media = json.loads(creative.media or "{}")
        except (TypeError, ValueError):
            media = {}
        aspect = media.get("aspect_ratio") if isinstance(media, dict) else None
        image_bytes = await self._poster_source(store, products)
        poster = await asyncio.to_thread(
            _render_poster, image_bytes, creative.headline or store.name,
            creative.body or "", creative.cta or "Open the store", aspect or "1:1",
        )
        if not poster:
            return
        old_asset_id = creative.asset_id
        try:
            from api.domains.media.service import create_image_asset
            asset = await create_image_asset(
                self.db, store.owner_id, MediaPurpose.MARKETING_CREATIVE,
                poster, attached=True,
            )
        except Exception as exc:  # noqa: BLE001 - text still works
            logger.warning("[marketing] poster storage skipped: %s", exc)
            return
        creative.asset_id = asset.id
        if old_asset_id:
            await self._retire_assets({old_asset_id})

    async def _creative_asset_ids(self, campaign_id: str) -> set[str]:
        rows = (await self.db.execute(
            select(MarketingCreative.asset_id).where(
                MarketingCreative.campaign_id == campaign_id,
                MarketingCreative.asset_id.is_not(None),
            )
        )).scalars().all()
        return {row for row in rows if row}

    async def _retire_assets(self, asset_ids: set[str]) -> None:
        """Queue replaced or deleted campaign posters for the media sweep.

        Without this every regenerate left the previous PNG attached
        forever - attached assets are deliberately exempt from the
        abandoned-upload cleanup, so nothing else would ever remove them.
        The row is marked `deleting` in this transaction; the 5-minute
        sweep purges the stored files (api/domains/media/cleanup.py).
        """
        if not asset_ids:
            return
        await self.db.execute(
            update(MediaAsset)
            .where(MediaAsset.id.in_(asset_ids),
                   MediaAsset.attach_state == AttachState.ATTACHED)
            .values(attach_state=AttachState.DELETING, deleted_at=datetime.utcnow())
            .execution_options(synchronize_session=False)
        )

    async def _poster_source(self, store: Store, products: list[dict]) -> Optional[bytes]:
        from api.domains.media.service import load_assets, read_variant, parse_id_list
        asset_id = next((p.get("image_asset_id") for p in products if p.get("image_asset_id")), None)
        if not asset_id:
            asset_id = store.cover_id or next(iter(parse_id_list(store.photo_ids)), None)
        if not asset_id:
            return None
        asset = (await load_assets(self.db, [asset_id])).get(asset_id)
        return await read_variant(asset, "medium") if asset else None

    # ── Reads and edits ──────────────────────────────────────────────────

    async def list_campaigns(self, store_id: str, requester_id: str,
                             limit: int = 20, offset: int = 0) -> dict:
        store = await self._store(store_id, requester_id)
        base = select(MarketingCampaign).where(
            MarketingCampaign.store_id == store.id,
            MarketingCampaign.owner_id == store.owner_id,
            MarketingCampaign.deleted_at.is_(None),
        )
        total = (await self.db.execute(
            select(func.count()).select_from(base.order_by(None).subquery())
        )).scalar_one()
        rows = (await self.db.execute(
            base.order_by(MarketingCampaign.created_at.desc()).limit(limit).offset(offset)
        )).scalars().all()
        return {
            "items": [await self._payload(store, c, include_events=True) for c in rows],
            "total": int(total or 0),
        }

    async def get_campaign(self, store_id: str, requester_id: str, campaign_id: str) -> dict:
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        return await self._payload(store, campaign)

    async def update_creative(self, store_id: str, requester_id: str, campaign_id: str,
                              creative_id: str, data: dict) -> dict:
        """Edit generated copy. Only text fields change; the platform, the
        products and the listing itself are untouched. The seller's listing
        is never rewritten by the studio."""
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        creative = (await self.db.execute(
            select(MarketingCreative).where(
                MarketingCreative.id == creative_id,
                MarketingCreative.campaign_id == campaign.id,
            )
        )).scalar_one_or_none()
        if creative is None:
            raise HTTPException(status_code=404, detail="Creative not found")
        if "body" in data:
            body = _clean(data.get("body"), 2200)
            if not body:
                raise HTTPException(status_code=400, detail="The caption can't be empty.")
            creative.body = body
        if "headline" in data:
            creative.headline = _clean(data.get("headline"), 160)
        if "cta" in data:
            creative.cta = _clean(data.get("cta"), 160)
        if "hashtags" in data:
            raw = data.get("hashtags") or []
            if not isinstance(raw, list):
                raise HTTPException(status_code=400, detail="Hashtags must be a list.")
            tags = [t.strip().lstrip("#") for t in raw if isinstance(t, str)]
            tags = [t for t in tags if _SAFE_HASHTAG.match(t)][:12]
            creative.hashtags = json.dumps(tags)
        creative.updated_at = datetime.utcnow()
        redraw = bool(creative.asset_id) and bool({"headline", "body", "cta"} & set(data))
        # The edit is saved first; a poster that cannot be redrawn must never
        # cost the seller the words they just wrote (same lock reason as
        # _generate: blobs are written through their own session).
        await self.db.commit()
        if redraw:
            # The poster is the seller's to save, so it has to say what the
            # post now says. Products are read without the live check: a
            # campaign whose product just sold must still be editable.
            products = await _load_products(
                self.db, store, self._json_list(campaign.product_ids), require_live=False,
            )
            await self._refresh_poster(store, creative, products)
            await self.db.commit()
        return await self._payload(store, campaign)

    async def update_campaign(self, store_id: str, requester_id: str,
                              campaign_id: str, data: dict) -> dict:
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        if "title" in data:
            title = _clean(data.get("title"), MAX_TITLE)
            if not title:
                raise HTTPException(status_code=400, detail="Give the campaign a title.")
            campaign.title = title
        if "instructions" in data:
            campaign.instructions = _clean(data.get("instructions"), MAX_INSTRUCTIONS)
        if "audience" in data:
            campaign.audience = _clean(data.get("audience"), MAX_AUDIENCE)
        campaign.updated_at = datetime.utcnow()
        await self.db.commit()
        return await self._payload(store, campaign)

    async def delete_campaign(self, store_id: str, requester_id: str, campaign_id: str) -> dict:
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        campaign.deleted_at = datetime.utcnow()
        # Its posters go too: a deleted campaign is gone from every read, so
        # nothing can ever show those images again.
        await self._retire_assets(await self._creative_asset_ids(campaign.id))
        await self.db.commit()
        return {"deleted": True, "campaign_id": campaign.id}

    async def regenerate(self, store_id: str, requester_id: str, campaign_id: str) -> dict:
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        try:
            await self._generate(store, campaign, keep_on_provider_error=True)
        except GenerationUnavailable:
            await self.db.rollback()
            raise HTTPException(
                status_code=502,
                detail="The AI provider didn't answer, so your saved posts are unchanged. "
                       "Try again in a moment, or edit the posts you have.",
            )
        await record_event(campaign, "generated", db=self.db)
        await self.db.refresh(campaign)
        return await self._payload(store, campaign)

    async def record_owner_event(self, store_id: str, requester_id: str,
                                 campaign_id: str, kind: str, platform: str = "") -> dict:
        store = await self._store(store_id, requester_id)
        campaign = await self._campaign(store, campaign_id)
        if kind not in ("downloaded", "shared"):
            raise HTTPException(status_code=400, detail="Unsupported event.")
        if platform and platform not in (*PLATFORMS, "copy", "other"):
            platform = "other"
        await record_event(campaign, kind, platform, db=self.db)
        return await self._events(campaign.id)

    # ── Attribution (public) ─────────────────────────────────────────────

    async def attribute(self, store_id: str, token: str, kind: str) -> bool:
        """Count a campaign visit/product view from a public storefront.

        The token must belong to a campaign of THIS store; an unknown token
        or another store's is simply not counted (the page still opens).
        No visitor identifier is stored: the counter says how many times a
        campaign link was used, not who used it.
        """
        if kind not in ("visit", "product_view"):
            return False
        campaign = (await self.db.execute(
            select(MarketingCampaign).where(
                MarketingCampaign.link_token == token,
                MarketingCampaign.store_id == store_id,
                MarketingCampaign.deleted_at.is_(None),
            )
        )).scalar_one_or_none()
        if campaign is None:
            return False
        await record_event(campaign, kind, "campaign", db=self.db)
        return True

    async def campaign_for_token(self, store_id: str, token: str) -> Optional[MarketingCampaign]:
        return (await self.db.execute(
            select(MarketingCampaign).where(
                MarketingCampaign.link_token == token,
                MarketingCampaign.store_id == store_id,
                MarketingCampaign.deleted_at.is_(None),
            )
        )).scalar_one_or_none()

    # ── Copywriter ───────────────────────────────────────────────────────

    async def copy_suggestions(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await self._store(store_id, requester_id)
        field = data.get("field") or "description"
        if field not in ("title", "description", "caption", "store_description"):
            raise HTTPException(status_code=400, detail="Choose what to improve.")
        language = data.get("language") or "en"
        if language not in LANGUAGES:
            raise HTTPException(status_code=400, detail="Choose English or Kiswahili.")
        tone = data.get("tone") or "friendly"
        if tone not in TONES:
            tone = "friendly"

        listing = None
        listing_id = data.get("listing_id")
        if listing_id:
            listing = (await self.db.execute(
                select(Listing).where(Listing.id == listing_id, Listing.store_id == store.id,
                                      Listing.seller_id == store.owner_id)
            )).scalar_one_or_none()
            if listing is None:
                raise HTTPException(status_code=404, detail="Product not found in this store")
        current = ""
        if listing is not None and field == "title":
            current = listing.name
        elif listing is not None and field == "description":
            current = listing.description or ""
        elif field == "store_description":
            current = store.description or ""
        else:
            current = _clean(data.get("text"), 2200) or ""
        if not current:
            raise HTTPException(
                status_code=400,
                detail="There is no text to improve yet. Write a first version, then ask for suggestions.",
            )

        if not _provider_available():
            return {
                "field": field, "language": language,
                "suggestions": [],
                "available": False,
                "message": "AI copy suggestions need GEMINI_API_KEY or DEEPSEEK_API_KEY on the "
                           "server. Your listing is unchanged.",
            }
        facts = {
            "store": store.name,
            "field": field,
            "current_text": current[:1500],
            "language": LANGUAGE_NAME.get(language, "English"),
            "tone": tone,
        }
        if listing is not None:
            facts.update({
                "product": listing.name,
                "price": _price_label({"price": listing.price, "price_unit": listing.price_unit}),
                "category": listing.category,
                "condition": listing.condition,
                "description": (listing.description or "")[:600],
            })
        prompt = (
            "Improve the following BROKA store text. Return JSON only: "
            '{"suggestions":[{"text":"...","why":"one short reason"}]} with at most 3. '
            "Preserve every fact and number that is already there; do not invent warranties, "
            "specifications, certifications, stock, discounts or delivery promises. "
            "Do not change the price. Write in the requested language.\n\n"
            + json.dumps(facts, ensure_ascii=False)
        )
        provider = _provider_available()
        try:
            raw = await (_call_gemini(prompt) if provider == "gemini" else _call_deepseek(prompt))
            parsed = _json_from(raw)
            suggestions = []
            for item in (parsed.get("suggestions") or [])[:3]:
                if not isinstance(item, dict):
                    continue
                text = _clean(item.get("text"), 2200)
                if text:
                    suggestions.append({"text": text, "why": _clean(item.get("why"), 160)})
            if suggestions:
                return {"field": field, "language": language, "suggestions": suggestions,
                        "available": True, "provider": provider}
        except Exception as exc:  # noqa: BLE001
            logger.warning("[marketing] copy suggestion failed: %s", exc)
        return {
            "field": field, "language": language, "suggestions": [], "available": False,
            "message": "The AI provider didn't answer. Your listing is unchanged - try again shortly.",
        }
