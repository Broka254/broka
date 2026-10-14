"""What Zeno knows about the user it is talking to - fetched only when a
question needs it.

"What do you think of my rating?" is unanswerable from the conversation
alone, and putting a user's whole account into every prompt would bill
for a page of numbers on every "hi". So the data is split into TOPICS,
each a short block of facts, and a turn gets only the blocks it is about:

  - picked by rules from the words of the question (topics_for) - free;
  - or asked for by the model itself (a NEED_INFO action) when the rules
    missed - one more model call, at most once per turn (service.py).

Every block is the user's OWN data, computed here from the database, and
contains no other user's words: ratings arrive as numbers and a
distribution, never review text; listing titles are the user's own. So
nothing another person wrote can reach the prompt through here - the same
property the assistant's contacts keep (contacts.py).
"""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta
from statistics import median
from typing import Iterable, Optional

from sqlalchemy import distinct, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import (
    Deal, DealStatus, Listing, ListingStatus, NegotiationMessage, Review, User,
)

TOPICS = ("profile", "listings", "sales", "store", "watch")

# What each topic is, for the model's list of what it may ask for.
TOPIC_HELP = {
    "profile": "their rating, reviews count and spread, verification, deals completed, how long on BROKA",
    "listings": "their active listings: price vs similar listings, views, photos, enquiries, days listed",
    "sales": "their deals as seller and buyer, by status, and recent earnings",
    "store": "their online store, if any, or whether they can open one",
    "watch": "what the Buying Agent is watching for, for them",
}

# Words that say a question is about the user's own account. Deliberately
# generous: a block too many costs a few hundred tokens; a block missing
# costs a second model call.
_TOPIC_WORDS = {
    "profile": r"ratings?|rated|stars?|reputation|reviews?|feedback|trust(?:ed)?|verified|verification|"
               r"my profile|my account|how am i doing|my score|nyota|sifa",
    "listings": r"listings?|my ads?|my items?|my posts?|views|nobody|no one|not selling|isn'?t selling|"
                r"aren'?t selling|sell faster|sell quicker|sell more|price (?:it|them|my)|pricing|photos?|"
                r"bidhaa zangu|matangazo",
    "sales": r"sales|sold|deals?|orders?|earn(?:ed|ings?)?|revenue|income|made (?:so far|this)|payouts?|mauzo",
    "store": r"stores?|shops?|storefront|duka",
    "watch": r"watch(?:ing)?|buying agent|looking for (?:a|an|my)",
}


def topics_for(message: str) -> set[str]:
    t = (message or "").lower()
    # Whole words: "start" is not a question about stars.
    return {topic for topic, words in _TOPIC_WORDS.items() if re.search(rf"\b(?:{words})\b", t)}


def _kes(v) -> str:
    return f"KES {float(v):,.0f}"


def _photo_count(listing: Listing) -> int:
    for raw in (listing.photo_ids, listing.verified_photos):
        if not raw:
            continue
        try:
            value = json.loads(raw)
            if isinstance(value, list):
                return len(value)
        except (ValueError, TypeError):
            # A single legacy inline image.
            return 1
    return 0


async def _profile(db: AsyncSession, user_id: str) -> Optional[str]:
    user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
    if user is None:
        return None
    count, avg = (await db.execute(
        select(func.count(Review.id), func.avg(Review.rating)).where(Review.seller_id == user_id)
    )).one()
    spread = dict((await db.execute(
        select(Review.rating, func.count(Review.id)).where(Review.seller_id == user_id).group_by(Review.rating)
    )).all())
    recent = [r for (r,) in (await db.execute(
        select(Review.rating).where(Review.seller_id == user_id).order_by(Review.created_at.desc()).limit(5)
    )).all()]
    seller = getattr(user.account_type, "value", user.account_type) == "buyer_seller"
    tier = getattr(user.seller_tier, "value", user.seller_tier)
    account = (f"seller ({tier.replace('_', ' ')})" if tier else "seller") if seller else "buyer only"
    verified = (f"yes ({user.verify_tier})" if user.verify_tier else "yes") if user.is_verified else "no"
    parts = [
        f"Member since {user.created_at:%B %Y}." if user.created_at else "",
        f"Account: {account}.",
        f"Verified: {verified}.",
        f"Completed deals: {user.completed_deals or 0}.",
    ]
    if count:
        stars = ", ".join(f"{s}★ {spread.get(s, 0)}" for s in (5, 4, 3, 2, 1))
        parts.append(f"Rating: {float(avg):.1f} from {count} review{'s' if count != 1 else ''} ({stars}).")
        if len(recent) >= 3:
            parts.append(f"Last {len(recent)} reviews average {sum(recent) / len(recent):.1f}.")
    else:
        parts.append("Rating: no reviews yet.")
    if user.trust_score is not None:
        parts.append(f"Trust score: {user.trust_score}/100.")
    return " ".join(p for p in parts if p)


async def listing_facts(db: AsyncSession, user_id: str, limit: int = 5) -> list[dict]:
    """The user's newest active listings, with what a buyer sees and how they
    compare. Shared with the sell-faster guide (guides.py)."""
    listings = (await db.execute(
        select(Listing).where(Listing.seller_id == user_id, Listing.status == ListingStatus.active)
        .order_by(Listing.created_at.desc()).limit(limit)
    )).scalars().all()
    if not listings:
        return []
    ids = [l.id for l in listings]
    # visibility-ok: counts distinct buyers per listing, no message content
    enquiries = dict((await db.execute(
        select(NegotiationMessage.listing_id, func.count(distinct(NegotiationMessage.buyer_id)))
        .where(NegotiationMessage.listing_id.in_(ids), NegotiationMessage.buyer_id.isnot(None),
               NegotiationMessage.buyer_id != user_id)
        .group_by(NegotiationMessage.listing_id)
    )).all())
    medians: dict[str, tuple[float, int]] = {}
    for category in {l.category for l in listings if l.category}:
        prices = [p for (p,) in (await db.execute(
            select(Listing.price).where(
                Listing.category == category, Listing.status == ListingStatus.active,
                Listing.seller_id != user_id, Listing.price > 0,
            ).limit(300)
        )).all()]
        # Too few to compare against says nothing.
        if len(prices) >= 5:
            medians[category] = (median(prices), len(prices))
    now = datetime.utcnow()
    facts = []
    for l in listings:
        m = medians.get(l.category)
        facts.append({
            "id": l.id,
            "name": (l.name or "")[:60],
            "category": l.category,
            "price": l.price or 0,
            "views": l.views or 0,
            "photos": _photo_count(l),
            "description_chars": len((l.description or "").strip()),
            "days_listed": max(0, (now - l.created_at).days) if l.created_at else None,
            "enquiries": enquiries.get(l.id, 0),
            "featured": bool(l.is_featured),
            "median": m[0] if m else None,
            "compared_with": m[1] if m else 0,
        })
    return facts


async def _listings(db: AsyncSession, user_id: str) -> Optional[str]:
    total = (await db.execute(
        select(func.count(Listing.id)).where(Listing.seller_id == user_id, Listing.status == ListingStatus.active)
    )).scalar_one()
    if not total:
        return "No active listings."
    lines = [f"{total} active listing{'s' if total != 1 else ''}; newest:"]
    for f in await listing_facts(db, user_id):
        vs = ""
        if f["median"]:
            diff = (f["price"] - f["median"]) / f["median"] * 100
            vs = f", {abs(diff):.0f}% {'above' if diff >= 0 else 'below'} the median {_kes(f['median'])} " \
                 f"of {f['compared_with']} similar {f['category']} listings"
        lines.append(
            f"- \"{f['name']}\": {_kes(f['price'])}{vs}; {f['views']} views; {f['photos']} photos; "
            f"description {f['description_chars']} chars; {f['enquiries']} buyer(s) enquired; "
            f"listed {f['days_listed']} days ago{'; boosted' if f['featured'] else ''}."
        )
    return "\n".join(lines)


async def _sales(db: AsyncSession, user_id: str) -> Optional[str]:
    def row(counts: dict) -> str:
        return ", ".join(f"{getattr(k, 'value', k)} {v}" for k, v in counts.items()) or "none"

    as_seller = dict((await db.execute(
        select(Deal.status, func.count(Deal.id)).where(Deal.seller_id == user_id).group_by(Deal.status)
    )).all())
    as_buyer = dict((await db.execute(
        select(Deal.status, func.count(Deal.id)).where(Deal.buyer_id == user_id).group_by(Deal.status)
    )).all())
    since = datetime.utcnow() - timedelta(days=30)
    earned = (await db.execute(
        select(func.coalesce(func.sum(Deal.agreed_price), 0)).where(
            Deal.seller_id == user_id, Deal.status == DealStatus.released, Deal.released_at >= since)
    )).scalar_one()
    return (f"Deals as seller: {row(as_seller)}. Deals as buyer: {row(as_buyer)}. "
            f"Released to them in the last 30 days: {_kes(earned or 0)}.")


async def _store(db: AsyncSession, user_id: str) -> Optional[str]:
    from api.models.store import Store

    store = (await db.execute(
        select(Store).where(Store.owner_id == user_id, Store.is_active.is_(True))
        .order_by(Store.created_at.desc()).limit(1)
    )).scalar_one_or_none()
    if store is None:
        user = (await db.execute(select(User).where(User.id == user_id))).scalar_one_or_none()
        tier = getattr(getattr(user, "seller_tier", None), "value", getattr(user, "seller_tier", None))
        can = tier == "long_term"
        return ("No store yet. " + ("They are a business seller, so they can open one now."
                                    if can else "A store needs a business (long-term) seller account first."))
    listed = (await db.execute(
        select(func.count(Listing.id)).where(Listing.store_id == store.id, Listing.status == ListingStatus.active)
    )).scalar_one()
    missing = [what for what, have in (("a logo", store.logo_id or store.logo_url),
                                       ("a description", store.description),
                                       ("photos", store.photo_ids or store.photos)) if not have]
    return (f"Store \"{store.name[:60]}\" ({store.category or 'no category'}), {listed} active listing(s) in it"
            + (f"; missing {', '.join(missing)}" if missing else "") + ".")


async def _watch(db: AsyncSession, user_id: str) -> Optional[str]:
    from api.domains.buy_agent.service import BuyAgentService

    req = await BuyAgentService(db).get_active_for_buyer(user_id)
    if not req:
        return "The Buying Agent is not watching for anything."
    return (f"The Buying Agent is watching for {req.get('category')} under {_kes(req.get('max_price') or 0)}; "
            f"{req.get('match_count') or 0} match(es) so far.")


_BUILDERS = {
    "profile": _profile,
    "listings": _listings,
    "sales": _sales,
    "store": _store,
    "watch": _watch,
}


async def gather(db: AsyncSession, user_id: str, topics: Iterable[str]) -> dict[str, str]:
    """The blocks for [topics], in a fixed order. Unknown topics are ignored."""
    out: dict[str, str] = {}
    for topic in TOPICS:
        if topic in topics:
            block = await _BUILDERS[topic](db, user_id)
            if block:
                out[topic] = block
    return out
