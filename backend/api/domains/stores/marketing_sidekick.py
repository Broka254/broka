"""The AI Marketing Sidekick: practical marketing guidance for a seller's own
store, and the guided tools that turn advice into action.

What this module is for
-----------------------
The Marketing Studio already writes platform-ready campaigns from the
seller's real catalogue (`api/domains/stores/marketing.py`). This module adds
the conversation in front of it: a seller asks "how do I market this?" or
"what should I post this week?", and gets an answer built from their store,
their live products and their recent campaigns - plus buttons that open the
Creative Studio, a platform guide, a script builder or Meta Ads guidance with
the same product already selected.

Boundaries it keeps
-------------------
* **The catalogue is the only source of product facts.** Products are loaded
  through `marketing._load_products`, which refuses another store's listing,
  an archived one, or one buyers cannot currently see. The request never
  supplies a price, title or description.
* **No invented claims.** The model is told not to add warranties,
  certifications, discounts, stock counts, delivery promises or deadlines;
  its answer is checked against the seller's own records before it is shown.
  A check failure is not a broken screen: the deterministic guidance below is
  used instead and the reply says so.
* **Advice is not a publication.** BROKA does not post to WhatsApp,
  Instagram, TikTok, Facebook or X, does not create Meta campaigns and does
  not process buyer-to-seller payments. Ads guidance stops at the checklist
  and the Meta Ads Manager link.
* **Scripts are scripts.** Video output is a concept, script or storyboard
  for the seller's own camera, labelled as such; no video file is produced.
* **Existing AI infrastructure only.** Gemini first, then DeepSeek, both
  already configured for Zeno; cost accounting goes through the same
  `record_ai_cost`. With no provider configured the Sidekick still answers
  from the playbooks and the seller's data.

The conversation is held by the app for the length of the session (bounded
history), so nothing new is stored here and a seller can pick up a thread
without a migration.
"""
from __future__ import annotations

import json
import logging
import re
from datetime import datetime
from typing import Optional

import httpx
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import gemini
from api.core.config import settings
from api.database import Listing, ListingStatus
from api.domains.listings.paid import is_live
from api.domains.stores import marketing
from api.models.marketing import MarketingCampaign
from api.models.store import Store

logger = logging.getLogger(__name__)

MAX_MESSAGE = 1200
MAX_HISTORY_TURNS = 12
MAX_HISTORY_CHARS = 2000
MAX_PRODUCTS = 6

VIDEO_PLATFORMS = ("tiktok", "instagram", "facebook")
VIDEO_KINDS = ("concept", "script", "storyboard", "voice_over")

# Meta's self-serve entry point. Opening it is not creating a campaign: the
# seller still chooses everything there, and BROKA never claims otherwise.
META_ADS_MANAGER_URL = "https://adsmanager.facebook.com/adsmanager/manage/campaigns"

# The claims the model is refused for. Deliberately narrower than the
# campaign writer's list: "in stock" is ordinary advice ("keep your best
# product in stock") and blocking it would cost honest answers. Prices and
# discounts have their own checks below.
_CLAIM_PHRASES = (
    "warranty", "guarantee", "guaranteed", "certified", "authentic", "genuine",
    "original packaging", "free delivery", "free shipping", "same day",
    "same-day", "next day", "next-day", "while stocks last", "limited stock",
    "today only", "money back", "money-back",
)

_DISCOUNT_RE = re.compile(r"\b([0-9]{1,3})\s*%\s*(?:off|discount|saving)", re.I)
_MONEY_RE = re.compile(r"\b(?:kes|ksh|shs?|shillings?)\s*([0-9][0-9,]*(?:\.[0-9]+)?)", re.I)

# ── Platform playbooks ───────────────────────────────────────────────────────
#
# Written for a Kenyan small shop with a phone, not for an agency. Each
# platform's advice is different on purpose: the same caption pasted five
# ways is the problem this Studio exists to fix.

PLATFORM_GUIDES: dict[str, dict] = {
    "whatsapp": {
        "label": "WhatsApp Business",
        "summary": (
            "WhatsApp is where a seller already talks to people who know the "
            "shop. It is best for closing a sale with someone who has already "
            "shown interest, announcing to contacts who agreed to hear from "
            "you, and sharing a catalogue link."
        ),
        "best_for": "Direct selling, repeat buyers, order follow-up, price lists.",
        "formats": [
            {"value": "message", "label": "Personal message",
             "tip": "Product photo, real price, one next step. Five short lines at most."},
            {"value": "status", "label": "Status",
             "tip": "One product per status, vertical image, a line of text; it disappears after 24 hours."},
            {"value": "catalogue", "label": "Catalogue item",
             "tip": "Set up the Business catalogue once, then send the item instead of retyping details."},
            {"value": "voice_note", "label": "Voice note",
             "tip": "Good for explaining a product to a buyer who prefers listening."},
        ],
        "sections": [
            {"key": "content", "title": "What to post",
             "summary": "A product photo or short clip, the real price, and one clear next step.",
             "steps": [
                 "Photograph the actual product in daylight, on a plain surface.",
                 "Write the product name, the price in KES and delivery coverage - nothing you cannot support.",
                 "End with one instruction: reply with the item name, or tap the catalogue link.",
             ]},
            {"key": "engaging", "title": "How to make posts engaging",
             "summary": "Short, personal and specific beats a poster with ten prices on it.",
             "steps": [
                 "Lead with the product, not the shop name: buyers scan the first line.",
                 "Send one product per message; a wall of offers gets ignored.",
                 "Use a voice note for a product that needs explaining, and keep it under 30 seconds.",
             ]},
            {"key": "promotion", "title": "Product promotion",
             "summary": "Promote what is live and in front of you, with the catalogue as the source of truth.",
             "steps": [
                 "Pick one live product with a real photo and a complete description.",
                 "Send the message to people who have contacted the shop before, and to a status.",
                 "Keep the store link in your status and business profile so a new buyer can browse.",
             ]},
            {"key": "reach", "title": "Reaching the right people",
             "summary": "Permission first: a broadcast list is only for people who asked to hear from you.",
             "steps": [
                 "Use the Business profile's catalogue and greeting message to answer common questions.",
                 "Post to Status daily; contacts see it without a notification.",
                 "Ask a satisfied buyer whether they are happy for you to share their feedback - never invent a testimonial.",
             ]},
            {"key": "cta", "title": "Calls to action",
             "summary": "One action per message, phrased as a reply.",
             "steps": [
                 "Try: \"Reply with the item name and I'll confirm availability.\"",
                 "For a catalogue send: \"Tap the catalogue to see the full range.\"",
                 "Avoid deadlines or discounts you have not decided on.",
             ]},
            {"key": "organic", "title": "Organic routine",
             "summary": "A small, steady routine that fits a shop's day.",
             "steps": [
                 "One status in the morning, one in the evening.",
                 "Answer messages inside your opening hours; the Business profile says when you are open.",
                 "After a sale, ask for permission to send the next new arrival.",
             ]},
            {"key": "paid", "title": "Paid options",
             "summary": "WhatsApp itself does not sell ads. Click-to-WhatsApp ads are bought in Meta Ads Manager.",
             "steps": [
                 "In Meta Ads Manager choose Messages as the objective and WhatsApp as the destination.",
                 "Use a real product photo and a message that starts a conversation.",
                 "Start small (a few hundred KES a day) for several days before changing anything.",
             ]},
        ],
    },
    "instagram": {
        "label": "Instagram",
        "summary": (
            "Instagram rewards how the product looks. It suits fashion, beauty, "
            "food, home, crafts and anything with a visible finish. Reels reach "
            "new people; feed posts and stories hold the people who already follow."
        ),
        "best_for": "Visual products, lifestyle shots, reels, carousels, stories.",
        "formats": [
            {"value": "caption", "label": "Feed post",
             "tip": "Hook in the first line, then product and price, then the ask; 5-8 hashtags."},
            {"value": "story", "label": "Story",
             "tip": "One product or one offer, vertical, with a link sticker."},
            {"value": "carousel", "label": "Carousel",
             "tip": "3-5 slides: product, detail, price, how to buy."},
            {"value": "reel_script", "label": "Reel script",
             "tip": "A 10-20 second plan with a hook, two scenes and an end card."},
        ],
        "sections": [
            {"key": "content", "title": "What to post",
             "summary": "Real photos of the product in use, and short vertical video.",
             "steps": [
                 "Shoot in daylight; clean the surface and remove clutter from the frame.",
                 "Use a carousel to show the product from several angles, with the price on the last slide.",
                 "Post one product per post rather than a catalogue page.",
             ]},
            {"key": "engaging", "title": "How to make posts engaging",
             "summary": "The first line and the first frame decide whether anyone sees the price.",
             "steps": [
                 "Open the caption with the buyer's problem or the product's most obvious use.",
                 "Add text to the first frame of a reel; most people watch with sound off.",
                 "Reply to comments with a question, and pin the comment that answers the price.",
             ]},
            {"key": "promotion", "title": "Product promotion",
             "summary": "Show the product where it would be used, not floating on a white background.",
             "steps": [
                 "Choose one live product with a good photo and a clear price.",
                 "Write five short lines: hook, product, real price, delivery coverage, and the ask.",
                 "Use the campaign's tracked store link in the bio or a story link sticker, never a link invented in the caption.",
             ]},
            {"key": "reach", "title": "Reaching the right people",
             "summary": "Reels and local context do more for a small shop than generic hashtags.",
             "steps": [
                 "Put the town or county in the caption and the location tag where it is true.",
                 "Use a mix of broad and specific hashtags, including the product and Kenya.",
                 "Ask a customer to collaborate on a post about their purchase, with their permission.",
             ]},
            {"key": "cta", "title": "Calls to action",
             "summary": "Say exactly what to do next, and where.",
             "steps": [
                 "Try: \"Tap the link in bio to see it in the store.\"",
                 "For a DM-led sale: \"Message us the size you want.\"",
                 "For saves: \"Save this for when you are ready.\"",
             ]},
            {"key": "organic", "title": "Organic routine",
             "summary": "A few posts a week plus daily stories is enough to keep the shop visible.",
             "steps": [
                 "Three feed posts or reels a week, each about one product.",
                 "Stories most days: a new arrival, a packing video, a question box.",
                 "Keep a highlight for prices and one for how to order.",
             ]},
            {"key": "paid", "title": "Paid options",
             "summary": "Instagram ads are bought through Meta Ads Manager, the same place as Facebook.",
             "steps": [
                 "Choose one product and one clear objective - traffic to the store or messages.",
                 "Let Meta place the ad on Instagram and Facebook unless you have a reason not to.",
                 "Run one small test for several days before changing the creative or audience.",
             ]},
        ],
    },
    "tiktok": {
        "label": "TikTok",
        "summary": (
            "TikTok is discovery rather than a shop window: short, honest video "
            "of a product being used reaches people who were not looking for "
            "your shop. It suits demonstrations, behind-the-scenes packing and "
            "products with an obvious before/after."
        ),
        "best_for": "Product demos, unboxings, packing orders, reaching new buyers.",
        "formats": [
            {"value": "script", "label": "Short video script",
             "tip": "Vertical 9:16, hook in 3 seconds, 15-30 seconds total, text on screen."},
            {"value": "video_plan", "label": "Video concept",
             "tip": "A repeatable idea you can film several times, not a one-off ad."},
            {"value": "storyboard", "label": "Storyboard",
             "tip": "Scene-by-scene shots, on-screen text and voice-over lines."},
        ],
        "sections": [
            {"key": "content", "title": "What to post",
             "summary": "The product doing something, filmed on a phone, in the first three seconds.",
             "steps": [
                 "Start with the product already in frame - not a logo or an intro.",
                 "Show one thing clearly: how it works, how it fits, or what it looks like up close.",
                 "Keep it 15-30 seconds; end on the product and the store name.",
             ]},
            {"key": "engaging", "title": "How to make posts engaging",
             "summary": "Watch time comes from the first frame and a reason to keep watching.",
             "steps": [
                 "Open with a question or a small surprise: \"This is what KES 2,500 looks like.\"",
                 "Put the price or the key line on screen as text.",
                 "Film several takes of the same idea; post the one where the product is clearest.",
             ]},
            {"key": "promotion", "title": "Product promotion",
             "summary": "Demonstrate, do not announce. A product in use is the advertisement.",
             "steps": [
                 "Pick a live product whose use can be shown in under 20 seconds.",
                 "Film a wide shot, a close-up of the detail, and a shot of the product with its real price on screen.",
                 "Caption the video with what it shows and where to buy, and add the tracked store link in your bio.",
             ]},
            {"key": "reach", "title": "Reaching the right people",
             "summary": "TikTok search and local language bring buyers a generic ad never reaches.",
             "steps": [
                 "Write the caption the way a buyer would search: product, town, use.",
                 "Use a few specific hashtags (product, Kenya, town) rather than a long generic list.",
                 "Reply to a good comment with a video; it is another post with a built-in audience.",
             ]},
            {"key": "cta", "title": "Calls to action",
             "summary": "Say where the link is, because a TikTok caption cannot carry a clickable one.",
             "steps": [
                 "Say \"Link in bio\" and keep the store link there.",
                 "Invite a question: \"Comment 'price' and I'll send the details.\"",
                 "Ask for the follow only when the next video will be useful to them.",
             ]},
            {"key": "organic", "title": "Organic routine",
             "summary": "Consistency and a repeatable idea beat one expensive video.",
             "steps": [
                 "Post three to five short videos a week if you can; one good idea filmed several ways is enough.",
                 "Keep a list of the questions buyers ask and turn each into a video.",
                 "Do not delete a video that underperformed; it may still be found in search.",
             ]},
            {"key": "paid", "title": "Paid options",
             "summary": "TikTok ads are bought in TikTok Ads Manager, separate from Meta. Spark Ads boost an existing organic post.",
             "steps": [
                 "Post the video organically first; if it gets watch time, consider putting budget behind it.",
                 "In TikTok Ads Manager choose a simple objective such as traffic or video views.",
                 "Start with a small daily budget and one audience, and judge it after several days.",
             ]},
        ],
    },
    "facebook": {
        "label": "Facebook",
        "summary": (
            "Facebook still reaches a broad Kenyan audience, especially buyers "
            "over 30 and local community groups. A shop page plus a few honest "
            "product posts works well for physical stores, services and "
            "household goods."
        ),
        "best_for": "Local reach, community groups, launches, services, older buyers.",
        "formats": [
            {"value": "post", "label": "Page post",
             "tip": "Offer and place in the first two lines; photo plus a short explanation."},
            {"value": "story", "label": "Story",
             "tip": "One announcement, vertical, with a link sticker."},
            {"value": "video_script", "label": "Video script",
             "tip": "30 seconds, product in use, price on screen, where to buy."},
            {"value": "live", "label": "Live video",
             "tip": "Answer questions about one product; say the price and coverage plainly."},
        ],
        "sections": [
            {"key": "content", "title": "What to post",
             "summary": "One product, one photo, a plain explanation and the price.",
             "steps": [
                 "Use a real photo of the product, not a supplier's catalogue image you cannot verify.",
                 "Write the first two lines as the whole offer; the rest is hidden behind \"See more\".",
                 "Include the town or delivery area where it is true.",
             ]},
            {"key": "engaging", "title": "How to make posts engaging",
             "summary": "Questions and replies do more than reach-boosting tricks.",
             "steps": [
                 "Ask one easy question in the post: which colour, which size, who it is for.",
                 "Reply to every comment with the price or a next step.",
                 "Post a short video of the product being used; it usually travels further than a poster.",
             ]},
            {"key": "promotion", "title": "Product promotion",
             "summary": "Promote the live catalogue, and let the product photo do the work.",
             "steps": [
                 "Pick one live product and describe only what the listing says.",
                 "Post the product, then share the same post to relevant local groups where the rules allow selling.",
                 "Keep the store link in the first comment if the post's link preview looks wrong.",
             ]},
            {"key": "reach", "title": "Reaching the right people",
             "summary": "Local groups and your page's own followers are the honest starting audience.",
             "steps": [
                 "Join local buy/sell groups and read their selling rules before posting.",
                 "Invite people who have bought from you to follow the page, without mass-inviting strangers.",
                 "Use the page's location and opening hours so a buyer can tell if you are nearby.",
             ]},
            {"key": "cta", "title": "Calls to action",
             "summary": "One action, in the post and in the button.",
             "steps": [
                 "Try: \"Message the page with the item you want.\"",
                 "Or: \"Open the store link to see the full range.\"",
                 "For a launch: \"Comment 'notify me' and we'll reply with the price.\"",
             ]},
            {"key": "organic", "title": "Organic routine",
             "summary": "Three or four posts a week, and fast replies.",
             "steps": [
                 "Post a new arrival, a product in use, a question, and a behind-the-scenes shot each week.",
                 "Pin the post for your best current offer.",
                 "Keep the page's contact and location details current.",
             ]},
            {"key": "paid", "title": "Paid options",
             "summary": "Boosting is a Meta Ads Manager campaign with a smaller setup screen.",
             "steps": [
                 "Choose the objective before the budget: messages, traffic, or awareness.",
                 "Target a radius around the shop for a physical store; use the delivery area for an online one.",
                 "Test one product and one audience for several days before scaling.",
             ]},
        ],
    },
    "x": {
        "label": "X",
        "summary": (
            "X suits electronics, tech, services and time-sensitive offers, and "
            "buyers who like a direct, text-first post. A single clear post with "
            "a real photo and a price usually beats a long thread."
        ),
        "best_for": "Electronics, tech, services, announcements, direct offers.",
        "formats": [
            {"value": "post", "label": "Post",
             "tip": "Under 200 characters plus the link and 2-3 hashtags; one idea."},
            {"value": "thread", "label": "Thread",
             "tip": "3-4 posts only: what it is, what it costs, where to buy."},
            {"value": "poll", "label": "Poll",
             "tip": "Ask which colour or model buyers want; answer the result with the product."},
        ],
        "sections": [
            {"key": "content", "title": "What to post",
             "summary": "A short, factual post with the product name and its real price.",
             "steps": [
                 "Write one sentence about the product, then the price in KES.",
                 "Attach a real photo; a link card alone is easy to scroll past.",
                 "Keep the link to the store, not a link to another marketplace.",
             ]},
            {"key": "engaging", "title": "How to make posts engaging",
             "summary": "Specific replies and useful details, not engagement bait.",
             "steps": [
                 "Reply to people asking about similar products with the actual item and price.",
                 "Use a poll to choose which model to feature next, then post the winner.",
                 "Quote a relevant local conversation only when your product genuinely answers it.",
             ]},
            {"key": "promotion", "title": "Product promotion",
             "summary": "One product per post, priced and linked.",
             "steps": [
                 "Choose a live product with a complete listing.",
                 "Post the name, the real price and one reason it is useful, taken from the description.",
                 "Pin the post for the week while the product is available.",
             ]},
            {"key": "reach", "title": "Reaching the right people",
             "summary": "Search and replies reach more buyers than a pile of hashtags.",
             "steps": [
                 "Use two or three hashtags at most, including the product category and Kenya.",
                 "Follow and reply to local conversations about the category you sell.",
                 "Post when your buyers are likely online, and keep the same handle on the store.",
             ]},
            {"key": "cta", "title": "Calls to action",
             "summary": "One instruction that fits the character limit.",
             "steps": [
                 "Try: \"Open the store link for the full range.\"",
                 "Or: \"Reply for the price list.\"",
                 "Avoid promising a reply time you cannot keep.",
             ]},
            {"key": "organic", "title": "Organic routine",
             "summary": "A post or two a day, and replies in between.",
             "steps": [
                 "Post one product or one useful update a day.",
                 "Spend ten minutes replying to relevant conversations.",
                 "Do not paste the same post to every platform; X needs its own short shape.",
             ]},
            {"key": "paid", "title": "Paid options",
             "summary": "X Ads is separate from Meta and is usually billed in USD.",
             "steps": [
                 "Promote an organic post that already got replies or clicks.",
                 "Choose website clicks if the goal is the storefront.",
                 "Check the daily budget in USD against your KES limit before confirming.",
             ]},
        ],
    },
}

OBJECTIVE_LABELS = {
    "new_store": "Introduce the store",
    "product": "Promote a product",
    "new_stock": "Announce new stock",
    "discount": "Promote a stated discount",
    "awareness": "Build awareness",
    "seasonal": "Seasonal offer",
    "storefront": "Bring visitors to the store",
    "enquiries": "Start conversations",
}

# Which platform to lead with, when the seller has not chosen one. Based on
# the kind of product and whether buyers can walk in - not on a claim about
# where their customers already are, which BROKA cannot see.
_CATEGORY_PLATFORMS = (
    (("fashion", "beauty", "jewel", "cloth", "shoe", "bag"), ("instagram", "tiktok")),
    (("electronic", "phone", "computer", "tech", "gadget"), ("facebook", "x")),
    (("food", "grocery", "restaurant", "bakery", "farm"), ("whatsapp", "facebook")),
    (("home", "furniture", "decor", "kitchen"), ("facebook", "instagram")),
    (("service", "repair", "salon", "cleaning"), ("facebook", "whatsapp")),
)


def _preferred_platforms(store: Store) -> list[str]:
    text = f"{store.category or ''} {store.description or ''}".lower()
    for words, platforms in _CATEGORY_PLATFORMS:
        if any(word in text for word in words):
            return list(platforms)
    if (store.store_type or "physical") == "virtual":
        return ["instagram", "tiktok", "facebook"]
    return ["whatsapp", "facebook", "instagram"]


def _premises(store: Store) -> Optional[str]:
    if (store.store_type or "physical") == "virtual":
        return None
    return ", ".join(x for x in [store.subcounty, store.county] if x) or None


def _coverage(store: Store) -> Optional[str]:
    try:
        areas = json.loads(store.service_areas or "[]")
    except (TypeError, ValueError):
        areas = []
    areas = [a for a in areas if isinstance(a, str) and a.strip()] if isinstance(areas, list) else []
    if areas:
        return "Nationwide" if len(areas) == 1 and areas[0].lower() == "nationwide" \
            else ", ".join(areas)
    return _premises(store)


def _price(product: dict) -> Optional[str]:
    return marketing._price_label(product)


def _product_summary(product: dict) -> str:
    bits = [product["name"], _price(product) or ""]
    if product.get("category"):
        bits.append(product["category"])
    bits.append("live in your store")
    return " · ".join(b for b in bits if b)


async def _owned_store(db: AsyncSession, store_id: str, requester_id: str) -> Store:
    from api.domains.stores.service import StoreService
    return await StoreService(db).get_owned(store_id, requester_id)


async def _top_products(db: AsyncSession, store: Store, limit: int = MAX_PRODUCTS) -> list[dict]:
    """The seller's newest live products, loaded through the campaign
    module's loader so promotion eligibility is checked in exactly one
    place."""
    rows = (await db.execute(
        select(Listing).where(
            Listing.store_id == store.id,
            Listing.seller_id == store.owner_id,
            Listing.status == ListingStatus.active.value,
        ).order_by(Listing.created_at.desc()).limit(limit * 3)
    )).scalars().all()
    now = datetime.utcnow()
    ids = [row.id for row in rows if is_live(row, now)][:limit]
    if not ids:
        return []
    try:
        return await marketing._load_products(db, store, ids)
    except HTTPException:
        return []


async def _selected_products(db: AsyncSession, store: Store, product_ids: list[str]) -> list[dict]:
    if not product_ids:
        return await _top_products(db, store)
    return await marketing._load_products(db, store, product_ids)


async def _campaign_activity(db: AsyncSession, store: Store) -> list[dict]:
    rows = (await db.execute(
        select(MarketingCampaign).where(
            MarketingCampaign.store_id == store.id,
            MarketingCampaign.owner_id == store.owner_id,
            MarketingCampaign.deleted_at.is_(None),
        ).order_by(MarketingCampaign.created_at.desc()).limit(3)
    )).scalars().all()
    out = []
    for row in rows:
        try:
            platforms = json.loads(row.platforms or "[]")
        except (TypeError, ValueError):
            platforms = []
        out.append({
            "title": row.title,
            "objective": row.objective,
            "platforms": [p for p in platforms if isinstance(p, str)],
            "status": row.status,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        })
    return out


# ── Claim checks ─────────────────────────────────────────────────────────────

def _facts(store: Store, products: list[dict]) -> str:
    return marketing._seller_facts(store, products)


def _unsupported_claim(text: str, store: Store, products: list[dict]) -> Optional[str]:
    """The first claim in a model's answer that the seller's records do not
    support. Advisory sentences are exempt from the campaign writer's number
    check (\"post three times a week\" is a instruction, not a product fact),
    but a price, a discount percentage or a warranty is still a claim."""
    facts = _facts(store, products)
    lowered = (text or "").lower()
    for phrase in _CLAIM_PHRASES:
        if phrase in lowered and phrase not in facts:
            return phrase
    allowed = {
        marketing._amount(str(p["price"])) for p in products if p.get("price") is not None
    }
    allowed.update(
        marketing._amount(m.group(1)) for m in _MONEY_RE.finditer(facts) if m.group(1)
    )
    for match in _MONEY_RE.finditer(text or ""):
        value = marketing._amount(match.group(1))
        if value is not None and value not in allowed:
            return match.group(0)
    stated = set(marketing._PERCENT_RE.findall(facts))
    for match in _DISCOUNT_RE.finditer(text or ""):
        if match.group(1) not in stated:
            return match.group(0)
    return None


# ── Provider calls (text, not JSON) ──────────────────────────────────────────

async def _gemini_text(prompt: str, reply_tokens: int = 900) -> str:
    if not settings.gemini_api_key:
        raise RuntimeError("GEMINI_API_KEY not set")
    async with httpx.AsyncClient(timeout=30) as client:
        response = await client.post(
            f"{gemini.endpoint()}?key={settings.gemini_api_key}",
            json={
                "contents": [{"role": "user", "parts": [{"text": prompt}]}],
                "generationConfig": {
                    "temperature": 0.65,
                    "maxOutputTokens": gemini.output_budget(reply_tokens),
                },
            },
        )
    if response.status_code != 200:
        raise RuntimeError(f"Gemini HTTP {response.status_code}")
    data = response.json()
    from api.core.cost_ledger import record_ai_cost
    await record_ai_cost(
        provider="gemini", response_data=data,
        model=settings.gemini_model, call_site="marketing_sidekick",
    )
    return gemini.reply_text(data)


async def _deepseek_text(prompt: str, reply_tokens: int = 900) -> str:
    if not settings.deepseek_api_key:
        raise RuntimeError("DEEPSEEK_API_KEY not set")
    async with httpx.AsyncClient(timeout=settings.deepseek_timeout_seconds + 10) as client:
        response = await client.post(
            f"{settings.deepseek_base_url.rstrip('/')}/chat/completions",
            headers={"Authorization": f"Bearer {settings.deepseek_api_key}"},
            json={
                "model": settings.deepseek_model,
                "messages": [
                    {"role": "system",
                     "content": "You are a practical marketing adviser for a Kenyan small "
                                "business. Answer in plain text, no markdown headings."},
                    {"role": "user", "content": prompt},
                ],
                "temperature": 0.65,
                "max_tokens": reply_tokens,
            },
        )
    if response.status_code != 200:
        raise RuntimeError(f"DeepSeek HTTP {response.status_code}")
    data = response.json()
    text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content")
    if not text:
        raise RuntimeError("DeepSeek returned no content")
    from api.core.cost_ledger import record_ai_cost
    await record_ai_cost(
        provider="deepseek", response_data=data,
        model=settings.deepseek_model, call_site="marketing_sidekick",
    )
    return text.strip()


async def _ask_model(prompt: str, reply_tokens: int = 900) -> tuple[str, str]:
    provider = marketing._provider_available()
    if provider == "gemini":
        return provider, await _gemini_text(prompt, reply_tokens)
    if provider == "deepseek":
        return provider, await _deepseek_text(prompt, reply_tokens)
    raise RuntimeError("no AI provider configured")


# ── Prompts ──────────────────────────────────────────────────────────────────

def _store_lines(store: Store, products: list[dict], campaigns: list[dict]) -> str:
    virtual = (store.store_type or "physical") == "virtual"
    location = "online (no shop)" if virtual else (_premises(store) or "Kenya (no town stated)")
    lines = [
        f"Store: {store.name}",
        f"Kind: {'online only, no shop to visit' if virtual else 'physical shop'}",
        f"Sells: {store.category or 'general goods'}",
        f"Location: {location}",
        f"Delivers to: {_coverage(store) or 'not stated'}",
        f"Store description: {(store.description or '(none)').strip()[:400]}",
    ]
    if products:
        lines.append("Live products (the ONLY product facts you may use):")
        for product in products:
            bits = [product["name"], _price(product) or "", product.get("category") or "",
                    (product.get("description") or "")[:220]]
            lines.append("- " + " · ".join(b for b in bits if b))
    else:
        lines.append("Live products: none yet.")
    if campaigns:
        lines.append("Recent campaigns:")
        for campaign in campaigns:
            lines.append(
                f"- {campaign['title']} ({OBJECTIVE_LABELS.get(campaign['objective'], campaign['objective'])}; "
                f"{', '.join(campaign['platforms']) or 'no platform'}; {campaign['status']})"
            )
    return "\n".join(lines)


def _platform_block(platform: Optional[str]) -> str:
    if platform and platform in PLATFORM_GUIDES:
        guide = PLATFORM_GUIDES[platform]
        sections = "\n".join(
            f"- {s['title']}: {s['summary']} " + " ".join(s["steps"][:2])
            for s in guide["sections"]
        )
        return (
            f"The seller is asking about {guide['label']}. Use this playbook as your "
            f"knowledge, not as text to copy:\n{guide['summary']}\n{sections}"
        )
    return (
        "No platform was chosen. Recommend the one or two that suit this store and "
        "say why in one sentence each."
    )


def _chat_prompt(store: Store, products: list[dict], campaigns: list[dict],
                 platform: Optional[str], history: list[dict], message: str,
                 language: str) -> str:
    conversation = "\n".join(
        f"{'Seller' if turn['role'] == 'user' else 'Sidekick'}: {turn['text']}"
        for turn in history[-MAX_HISTORY_TURNS:]
    )
    return f"""You are BROKA's AI Marketing Sidekick advising a Kenyan small business seller.
{_store_lines(store, products, campaigns)}

{_platform_block(platform)}

The seller asks (write your answer in {marketing.LANGUAGE_NAME.get(language, 'English')}):
{message}

Earlier in this conversation (do not ask for these details again):
{conversation or '(this is the first message)'}

Rules:
- Be practical, not generic. Give instructions the seller can carry out today on a phone.
  For each recommendation say what to do, why it works, and how to execute it.
- Use only the product facts above. Never invent a price, discount, warranty, certification,
  stock count, delivery promise, deadline or brand claim. Never state a discount the seller
  has not given.
- Never say BROKA posts, schedules, publishes or boosts anything, holds or verifies payments,
  or guarantees sales. BROKA does not process buyer-to-seller payments.
- Mention the BROKA tools by name when they are the next step: Creative Studio (images and
  captions), Platform Guides, Video Scripts, Meta Ads guidance.
- If the seller named a product, use it. If not, suggest one of the live products above by name.
- 150-260 words. Plain text with short paragraphs; numbered steps are fine. No markdown headings.
"""


def _video_prompt(store: Store, products: list[dict], platform: str, kind: str,
                  language: str) -> str:
    guide = PLATFORM_GUIDES[platform]
    return f"""Write a {kind.replace('_', ' ')} for a short promotional video for a Kenyan shop.
{_store_lines(store, products, [])}
Platform: {guide['label']} ({guide['summary']})
Language for on-screen text and voice-over: {marketing.LANGUAGE_NAME.get(language, 'English')}

Return ONLY valid JSON:
{{"title":"short title","hook":"first 3 seconds","duration_seconds":24,
"scenes":[{{"shot":"what the camera shows","on_screen_text":"short text",
"voice_over":"what is said"}}],"caption":"post caption","hashtags":["tag"],
"cta":"one honest call to action"}}

Rules: 3-5 scenes; use only the products above; never invent prices, discounts, warranties,
certifications, stock counts or delivery promises; describe shots the seller can film on a
phone; this is a script, not a finished video."""


# ── Deterministic guidance (no provider, or model output rejected) ───────────

def _store_intro(store: Store) -> str:
    bits = [store.name]
    if store.category:
        bits.append(f"sells {store.category}")
    place = _premises(store)
    if place:
        bits.append(f"at {place}")
    coverage = _coverage(store)
    if coverage:
        bits.append(f"delivers to {coverage}")
    return ", ".join(bits)


def _fallback_reply(store: Store, products: list[dict], platform: Optional[str],
                    objective: Optional[str], reason: Optional[str]) -> str:
    guide = PLATFORM_GUIDES.get(platform) if platform else None
    primary = products[0] if products else None
    lines: list[str] = []
    if guide:
        lines.append(f"For {store.name} on {guide['label']}: {guide['summary']}")
        content = next(s for s in guide["sections"] if s["key"] == "content")
        promotion = next(s for s in guide["sections"] if s["key"] == "promotion")
        cta = next(s for s in guide["sections"] if s["key"] == "cta")
        paid = next(s for s in guide["sections"] if s["key"] == "paid")
        steps = list(content["steps"][:2]) + list(promotion["steps"][:2]) + list(cta["steps"][:1])
        for i, step in enumerate(steps, 1):
            lines.append(f"{i}. {step}")
        if primary:
            lines.append(
                f"Use {primary['name']}"
                + (f" at {_price(primary)}" if _price(primary) else "")
                + " as the first product. That is the price in your catalogue, so it is "
                  "safe to state."
            )
        lines.append(f"Paid: {paid['summary']}")
    else:
        picks = _preferred_platforms(store)
        lines.append(f"A practical starting point for {_store_intro(store)}:")
        lines.append(
            f"1. Start on {', '.join(PLATFORM_GUIDES[p]['label'] for p in picks[:2])}. "
            f"{PLATFORM_GUIDES[picks[0]]['summary']}"
        )
        if primary:
            lines.append(
                f"2. Promote {primary['name']}"
                + (f" at {_price(primary)}" if _price(primary) else "")
                + " first: it is live in your store, so the facts are already there."
            )
        else:
            lines.append(
                "2. Add at least one live product with a real photo and a complete "
                "description - there is nothing to promote yet."
            )
        lines.append(
            f"3. Post it on {PLATFORM_GUIDES[picks[1]]['label']} too, but rewrite it for "
            f"that platform instead of pasting the same caption."
        )
        lines.append(
            "4. Make one image and caption in Creative Studio, share it yourself, then "
            "use the campaign link to see which posts brought store visits."
        )
    if objective:
        lines.append(
            f"Your objective is \"{OBJECTIVE_LABELS.get(objective, objective)}\": keep every "
            f"post pointed at that single outcome."
        )
    lines.append(
        "BROKA does not post for you and does not handle buyer payments; you share the "
        "post and buyers reach you through your store."
    )
    if reason:
        lines.append(reason)
    return "\n\n".join(lines)


def _actions(store: Store, products: list[dict], platform: Optional[str],
             objective: Optional[str]) -> list[dict]:
    """Buttons the app can honour. Each one only opens a real tool with the
    same context already chosen - nothing is created until the seller acts."""
    primary = products[0] if products else None
    chosen = platform if platform in PLATFORM_GUIDES else None
    out: list[dict] = []
    if primary and chosen:
        fmt = marketing.PLATFORM_SPECS[chosen]["formats"][0]
        out.append({
            "type": "creative_studio",
            "label": f"Create a {PLATFORM_GUIDES[chosen]['label']} post",
            "description": f"Open Creative Studio with {primary['name']} already selected.",
            "platform": chosen,
            "product_id": primary["id"],
            "objective": objective or "product",
            "creative_format": fmt,
        })
    elif primary:
        out.append({
            "type": "creative_studio",
            "label": "Create a promotional image",
            "description": f"Open Creative Studio with {primary['name']} already selected.",
            "product_id": primary["id"],
            "objective": objective or "product",
        })
    if chosen:
        out.append({
            "type": "platform_guide",
            "label": f"See the full {PLATFORM_GUIDES[chosen]['label']} guide",
            "description": "Content, formats, reach, calls to action and paid options.",
            "platform": chosen,
        })
        if chosen in VIDEO_PLATFORMS:
            out.append({
                "type": "video_script",
                "label": f"Write a {PLATFORM_GUIDES[chosen]['label']} video script",
                "description": "A scene-by-scene script or storyboard - not a finished video.",
                "platform": chosen,
                "product_id": primary["id"] if primary else None,
            })
    if primary:
        out.append({
            "type": "meta_ads",
            "label": f"Plan a Meta ad for {primary['name']}",
            "description": "A guided checklist; the campaign is finished in Meta Ads Manager.",
            "product_id": primary["id"],
        })
    return out


def _suggestions(platform: Optional[str], has_products: bool, store: Store) -> list[str]:
    picks = _preferred_platforms(store)
    label = PLATFORM_GUIDES[platform]["label"] if platform in PLATFORM_GUIDES else \
        PLATFORM_GUIDES[picks[0]]["label"]
    out = [
        f"How should I market my store this week?",
        f"Which social media platform suits my business?",
    ]
    if has_products:
        out.append(f"What should I post on {label} this week?")
        out.append(f"How do I advertise my products on {label}?")
    else:
        out.append("How do I get my first product ready to promote?")
    return out


def _video_label(platform: str, kind: str) -> str:
    base = PLATFORM_GUIDES[platform]["label"]
    return {
        "concept": f"{base} video concept",
        "script": f"{base} video script",
        "storyboard": f"{base} storyboard",
        "voice_over": f"{base} voice-over script",
    }.get(kind, f"{base} video script")


def _deterministic_video(store: Store, products: list[dict], platform: str,
                         kind: str, language: str) -> dict:
    sw = language == "sw"
    primary = products[0] if products else None
    name = primary["name"] if primary else store.name
    price = _price(primary) if primary else None
    coverage = _coverage(store)
    premises = _premises(store)
    duration = {"tiktok": 24, "instagram": 20, "facebook": 30}.get(platform, 24)
    next_step = (
        "Fungua kiungo cha duka kuona zaidi." if sw
        else "Open the store link to see the full range."
    )
    hook = (f"Unatafuta {name}?" if sw else f"Looking for {name}?")
    place_line = (f"Tuko {premises}." if sw else f"Find us at {premises}.") if premises else None
    coverage_line = (
        ("Tunawasilisha nchini kote." if coverage == "Nationwide"
         else f"Tunawasilisha {coverage}.") if coverage and sw
        else ("Delivers nationwide." if coverage == "Nationwide"
              else f"Delivers to {coverage}.") if coverage
        else None
    )
    scenes = [
        {"shot": f"Hold {name} up to the camera, already in frame",
         "on_screen_text": name,
         "voice_over": hook,
         "seconds": 3},
        {"shot": f"Show {name} being used or held the way a buyer would use it",
         "on_screen_text": price or name,
         "voice_over": (
             f"{name}. Bei {price}." if sw and price else
             f"{name} at {price}." if price else f"Hii ni {name}." if sw else f"This is {name}."
         ),
         "seconds": max(5, duration // 3)},
        {"shot": "Close-up of the real detail buyers ask about",
         "on_screen_text": coverage_line or price or name,
         "voice_over": coverage_line or price or name,
         "seconds": max(5, duration // 3)},
        {"shot": f"End card: product, store name and the store link",
         "on_screen_text": next_step,
         "voice_over": next_step,
         "seconds": max(4, duration - 2 * max(5, duration // 3) - 3)},
    ]
    scenes = [s for s in scenes if s["seconds"] > 0]
    total = sum(s["seconds"] for s in scenes) or duration
    hashtags = marketing._hashtags_for(store, products, platform) if platform in marketing.PLATFORM_SPECS else []
    caption_parts = [
        f"{name}" + (f" · {price}" if price else ""),
        coverage_line,
        next_step,
    ]
    caption = "\n".join(x for x in caption_parts if x and x.strip())
    return {
        "platform": platform,
        "kind": kind,
        "label": _video_label(platform, kind),
        "is_video": False,
        "disclaimer": (
            "This is a script and storyboard to film yourself. BROKA has not filmed, "
            "generated or published a video."
        ),
        "title": f"{name} · {PLATFORM_GUIDES[platform]['label']}" if primary else store.name,
        "hook": hook,
        "duration_seconds": total,
        "aspect_ratio": "9:16" if platform in ("tiktok", "instagram") else "1:1",
        "scenes": scenes,
        "voice_over": "\n".join(s["voice_over"] for s in scenes if s["voice_over"]),
        "caption": caption[:2200],
        "hashtags": hashtags,
        "cta": next_step,
        "provider": "template",
        "fallback_reason": None,
    }


def _validated_video(raw: dict, store: Store, products: list[dict], platform: str,
                     kind: str) -> Optional[dict]:
    if not isinstance(raw, dict):
        return None
    scenes: list[dict] = []
    for item in raw.get("scenes") or []:
        if not isinstance(item, dict):
            continue
        shot = marketing._clean(item.get("shot"), 200)
        if not shot:
            continue
        scenes.append({
            "shot": shot,
            "on_screen_text": marketing._clean(item.get("on_screen_text"), 90) or "",
            "voice_over": marketing._clean(item.get("voice_over"), 220) or "",
            "seconds": max(1, min(int(item.get("seconds") or 4), 15)),
        })
    if len(scenes) < 3:
        return None
    claim_text = " ".join(
        " ".join(str(x) for x in [scene["on_screen_text"], scene["voice_over"]])
        for scene in scenes
    ) + " " + str(raw.get("caption") or "")
    if _unsupported_claim(claim_text, store, products):
        return None
    hashtags = marketing._hashtags_for(store, products, platform) if products else []
    raw_tags = raw.get("hashtags")
    if isinstance(raw_tags, list):
        tags = []
        for tag in raw_tags[: marketing.PLATFORM_SPECS[platform]["hashtags"]]:
            if isinstance(tag, str):
                clean = tag.strip().lstrip("#")
                if marketing._SAFE_HASHTAG.match(clean) and clean.lower() not in {
                        t.lower() for t in tags}:
                    tags.append(clean)
        hashtags = tags or hashtags
    return {
        "platform": platform,
        "kind": kind,
        "label": _video_label(platform, kind),
        "is_video": False,
        "disclaimer": (
            "This is a script and storyboard to film yourself. BROKA has not filmed, "
            "generated or published a video."
        ),
        "title": marketing._clean(raw.get("title"), 120) or _video_label(platform, kind),
        "hook": marketing._clean(raw.get("hook"), 160) or scenes[0]["voice_over"],
        "duration_seconds": sum(s["seconds"] for s in scenes),
        "aspect_ratio": "9:16" if platform in ("tiktok", "instagram") else "1:1",
        "scenes": scenes,
        "voice_over": "\n".join(s["voice_over"] for s in scenes if s["voice_over"]),
        "caption": marketing._clean(raw.get("caption"), 2200) or "",
        "hashtags": hashtags,
        "cta": marketing._clean(raw.get("cta"), 160) or "",
        "provider": "ai",
        "fallback_reason": None,
    }


# ── Meta Ads guidance ────────────────────────────────────────────────────────

META_OBJECTIVES = (
    ("awareness", "Awareness", "Get the store or product seen by more people."),
    ("traffic", "Traffic", "Send people to your BROKA storefront."),
    ("engagement", "Engagement", "Get messages, saves and comments."),
    ("leads", "Leads", "Collect enquiries from people who may buy."),
    ("sales", "Sales", "Send buyers to a product to complete the sale with you."),
)


def _budget_advice(price: Optional[float], requested: Optional[int]) -> dict:
    if requested:
        daily = requested
    elif price:
        # A starting point proportional to the product, rounded to KES 100,
        # kept inside a small shop's range. Advice, not a forecast.
        daily = int(min(max(round(price * 0.2 / 100) * 100, 300), 3000))
    else:
        daily = 500
    return {
        "daily_kes": daily,
        "trial_days": 5,
        "total_kes": daily * 5,
        "note": (
            "A starting point for testing, not a prediction of results. Meta sets its own "
            "minimum; you can change or stop the budget at any time in Ads Manager."
        ),
    }


def _ads_plan(store: Store, products: list[dict], product: Optional[dict], data: dict) -> dict:
    objective = data.get("objective") or "traffic"
    labels = dict((key, (label, when)) for key, label, when in META_OBJECTIVES)
    label, when = labels.get(objective, labels["traffic"])
    audience = marketing._clean(data.get("audience"), 160) or (
        f"People interested in {store.category}" if store.category else
        "People interested in what you sell"
    )
    location = marketing._clean(data.get("location"), 120) or _premises(store) or \
        _coverage(store) or "Kenya"
    budget = _budget_advice(product.get("price") if product else None,
                            data.get("budget_kes"))
    creative_name = product["name"] if product else store.name
    price_line = _price(product) if product else None

    stages = [
        {
            "key": "objective", "title": "1. Choose the objective",
            "summary": f"Recommended: {label}. {when}",
            "suggestion": label,
            "steps": [
                "Open Meta Ads Manager and choose Create.",
                f"Pick {label} as the campaign objective.",
                "Choose a name you will recognise later, for example "
                f"\"{store.name} - {creative_name}\".",
            ],
        },
        {
            "key": "audience", "title": "2. Choose the audience",
            "summary": f"Start broad: {audience}.",
            "suggestion": audience,
            "steps": [
                "Use one audience, not several at once, so you can tell what worked.",
                "If Meta suggests a very narrow audience, widen it; a small shop needs reach.",
                "Leave detailed targeting off at first unless you sell something specific.",
            ],
        },
        {
            "key": "location", "title": "3. Choose the location",
            "summary": f"Target {location}.",
            "suggestion": location,
            "steps": [
                "For a physical shop, target a radius you can actually serve or deliver to.",
                "For an online store, target the areas you deliver to - do not claim nationwide "
                "unless that is what your store says.",
                "Exclude places you cannot deliver to; an order you cannot fulfil is a wasted click.",
            ],
        },
        {
            "key": "budget", "title": "4. Set the budget in KES",
            "summary": f"Start at about KES {budget['daily_kes']:,} a day for "
                       f"{budget['trial_days']} days (about KES {budget['total_kes']:,}).",
            "suggestion": f"KES {budget['daily_kes']:,} / day",
            "steps": [
                budget["note"],
                "Keep the budget small until you know the ad reaches the right people.",
                "Judge it after several days, not after a few hours.",
            ],
        },
        {
            "key": "creative", "title": "5. Choose the creative",
            "summary": (
                f"Use a real photo of {creative_name}"
                + (f" and its real price, {price_line}." if price_line else ".")
            ),
            "suggestion": creative_name,
            "steps": [
                "Use your own product photo, not a supplier image or a picture of a different item.",
                "Keep the words short and put the price in the image only if it is the real price.",
                "If you need an image and caption, make them in Creative Studio first.",
            ],
        },
        {
            "key": "placements", "title": "6. Choose the placements",
            "summary": "Start with automatic placements, then look at where the ad ran.",
            "suggestion": "Automatic placements",
            "steps": [
                "Automatic placements lets Meta put the ad on Facebook and Instagram.",
                "A vertical image or video suits stories and reels; a square one suits the feed.",
                "After a few days, turn off a placement only if the numbers show it is wasting money.",
            ],
        },
        {
            "key": "review", "title": "7. Review before paying",
            "summary": "Check the facts, the destination and the total spend.",
            "suggestion": "Review checklist",
            "steps": [
                f"Confirm the price is {price_line}." if price_line else
                "Confirm every claim in the ad is something you can support.",
                "Open the destination link yourself; it must be your BROKA store, not another site.",
                f"Check the total: about KES {budget['total_kes']:,} over {budget['trial_days']} days.",
                "Make sure you can answer messages or enquiries during the campaign.",
            ],
        },
        {
            "key": "launch", "title": "8. Finish in Meta Ads Manager",
            "summary": "BROKA does not create or publish the campaign. You place it in Meta's own tool.",
            "suggestion": META_ADS_MANAGER_URL,
            "steps": [
                "Open Meta Ads Manager and complete the campaign there.",
                "Meta reviews the ad before it runs; that review is outside BROKA.",
                "Save the campaign name here so you can compare it with the store visits BROKA counts.",
            ],
        },
    ]
    return {
        "product": ({
            "id": product["id"], "name": product["name"],
            "price": product.get("price"), "price_label": price_line,
            "image": product.get("image"),
        } if product else None),
        "store": {"id": store.id, "name": store.name},
        "currency": "KES",
        "objective": objective,
        "objective_label": label,
        "objective_options": [
            {"value": key, "label": option_label, "when": option_when}
            for key, option_label, option_when in META_OBJECTIVES
        ],
        "audience": audience,
        "location": location,
        "budget": budget,
        "stages": stages,
        "manager_url": META_ADS_MANAGER_URL,
        "campaign_created": False,
        "disclaimer": (
            "BROKA has not created or published a campaign. This is a plan for you to "
            "complete in Meta Ads Manager, where Meta sets the final prices and rules. "
            "BROKA does not process buyer-to-seller payments."
        ),
    }


# ── Service ──────────────────────────────────────────────────────────────────

class MarketingSidekickService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def chat(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await _owned_store(self.db, store_id, requester_id)
        message = marketing._clean(data.get("message"), MAX_MESSAGE)
        if not message:
            raise HTTPException(status_code=400, detail="Type a question for the Sidekick.")
        platform = data.get("platform")
        if platform and platform not in PLATFORM_GUIDES:
            raise HTTPException(
                status_code=400,
                detail="Choose WhatsApp, Instagram, TikTok, Facebook or X.",
            )
        objective = data.get("objective")
        if objective and objective not in marketing.OBJECTIVES:
            objective = None
        language = data.get("language") or "en"
        if language not in marketing.LANGUAGES:
            language = "en"
        history: list[dict] = []
        for turn in (data.get("history") or [])[:MAX_HISTORY_TURNS]:
            if not isinstance(turn, dict):
                continue
            role = turn.get("role")
            text = marketing._clean(turn.get("text"), MAX_HISTORY_CHARS)
            if role in ("user", "assistant") and text:
                history.append({"role": role, "text": text})

        product_ids = [p for p in (data.get("product_ids") or []) if isinstance(p, str)]
        products = await _selected_products(self.db, store, product_ids[:MAX_PRODUCTS])
        campaigns = await _campaign_activity(self.db, store)

        provider = marketing._provider_available()
        reply = ""
        used = "template"
        fallback_reason: Optional[str] = None
        if provider:
            prompt = _chat_prompt(store, products, campaigns, platform, history, message,
                                  language)
            try:
                used, candidate = await _ask_model(prompt, reply_tokens=700)
                unsupported = _unsupported_claim(candidate, store, products)
                if unsupported:
                    logger.info(
                        "[sidekick] dropped provider answer with unsupported claim %r "
                        "for store %s", unsupported, store.id,
                    )
                    used, candidate = "template", ""
                if candidate.strip():
                    reply = candidate.strip()
                else:
                    fallback_reason = (
                        "The AI answer contained a claim your product details do not "
                        "support, so BROKA's own guidance is shown instead."
                    )
            except Exception as exc:  # noqa: BLE001 - guidance must still arrive
                logger.warning("[sidekick] provider %s failed: %s", provider, exc)
                used = "template"
                fallback_reason = (
                    "The AI provider didn't answer, so this is BROKA's standard guidance "
                    "for your store. Try again in a moment for a tailored answer."
                )
        else:
            fallback_reason = (
                "No AI provider is configured on the server, so this is BROKA's standard "
                "guidance built from your store details."
            )
        if not reply:
            reply = _fallback_reply(store, products, platform, objective, fallback_reason)
        return {
            "reply": reply,
            "provider": used,
            "available": used != "template",
            "fallback_reason": fallback_reason,
            "platform": platform,
            "language": language,
            "store": {"id": store.id, "name": store.name},
            "products": [
                {"id": p["id"], "name": p["name"], "price": p.get("price"),
                 "price_label": _price(p), "image": p.get("image")}
                for p in products[:3]
            ],
            "activity": campaigns,
            "actions": _actions(store, products, platform, objective),
            "suggestions": _suggestions(platform, bool(products), store),
        }

    async def platform_guide(self, store_id: str, requester_id: str,
                             platform: str) -> dict:
        store = await _owned_store(self.db, store_id, requester_id)
        if platform not in PLATFORM_GUIDES:
            raise HTTPException(
                status_code=404,
                detail="That platform is not supported. Choose WhatsApp, Instagram, "
                       "TikTok, Facebook or X.",
            )
        products = await _top_products(self.db, store, limit=3)
        guide = PLATFORM_GUIDES[platform]
        primary = products[0] if products else None
        example = None
        if primary:
            spec = marketing.PLATFORM_SPECS[platform]
            body = (
                f"{primary['name']}"
                + (f" · {_price(primary)}" if _price(primary) else "")
                + (f" · {_coverage(store)}" if _coverage(store) else "")
                + "\n\n" + ("Open the link to see more."
                            if platform != "whatsapp" else "Reply with the item name.")
            )
            example = {
                "label": f"{guide['label']} caption starter",
                "body": marketing._sentence_trim(body, int(spec["body_limit"])),
                "hashtags": marketing._hashtags_for(store, products, platform),
                "cta": ("Reply with the item name" if platform == "whatsapp"
                        else "Open the link to see more"),
                "note": "Built from your live product and its real price. Edit it before posting.",
            }
        return {
            "platform": platform,
            "label": guide["label"],
            "summary": guide["summary"],
            "best_for": guide["best_for"],
            "formats": guide["formats"],
            "sections": guide["sections"],
            "product": ({
                "id": primary["id"], "name": primary["name"],
                "price": primary.get("price"), "price_label": _price(primary),
                "image": primary.get("image"),
            } if primary else None),
            "example": example,
            "actions": _actions(store, products, platform, "product"),
            "note": (
                "BROKA does not post to this platform. You publish, and the campaign link "
                "tells you which shop visits came from it."
            ),
        }

    async def video_script(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await _owned_store(self.db, store_id, requester_id)
        platform = data.get("platform") or "tiktok"
        if platform not in VIDEO_PLATFORMS:
            raise HTTPException(
                status_code=400,
                detail="Video scripts are available for TikTok, Instagram Reels and Facebook.",
            )
        kind = data.get("kind") or "script"
        if kind not in VIDEO_KINDS:
            raise HTTPException(status_code=400, detail="Choose a script type from the list.")
        language = data.get("language") or "en"
        if language not in marketing.LANGUAGES:
            language = "en"
        product_ids = [p for p in (data.get("product_ids") or []) if isinstance(p, str)]
        products = await _selected_products(self.db, store, product_ids[:1])
        if product_ids and not products:
            raise HTTPException(
                status_code=400,
                detail="That product isn't available to promote right now. Choose another.",
            )
        fallback: Optional[dict] = None
        provider = marketing._provider_available()
        if provider:
            try:
                _, raw_text = await _ask_model(
                    _video_prompt(store, products, platform, kind, language),
                    reply_tokens=1100,
                )
                candidate = _validated_video(
                    marketing._json_from(raw_text), store, products, platform, kind,
                )
                if candidate:
                    return candidate
                fallback = self._video_fallback(
                    store, products, platform, kind, language,
                    "The AI answer contained a claim your product details do not support, "
                    "so BROKA's own script is shown instead.",
                )
            except Exception as exc:  # noqa: BLE001
                logger.warning("[sidekick] video provider %s failed: %s", provider, exc)
                fallback = self._video_fallback(
                    store, products, platform, kind, language,
                    "The AI provider didn't answer, so this script was built from your "
                    "product details.",
                )
        return fallback or self._video_fallback(
            store, products, platform, kind, language,
            "No AI provider is configured on the server, so this script was built from "
            "your product details.",
        )

    @staticmethod
    def _video_fallback(store: Store, products: list[dict], platform: str, kind: str,
                        language: str, reason: str) -> dict:
        script = _deterministic_video(store, products, platform, kind, language)
        script["fallback_reason"] = reason
        return script

    async def ads_plan(self, store_id: str, requester_id: str, data: dict) -> dict:
        store = await _owned_store(self.db, store_id, requester_id)
        product: Optional[dict] = None
        product_id = data.get("product_id")
        if product_id:
            products = await marketing._load_products(self.db, store, [product_id])
            product = products[0] if products else None
            if product is None:
                raise HTTPException(
                    status_code=400,
                    detail="That product isn't in your store. Choose one of your live products.",
                )
        else:
            products = await _top_products(self.db, store, limit=1)
            product = products[0] if products else None
        return _ads_plan(store, products, product, data)

