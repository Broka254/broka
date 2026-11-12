"""The listing a user is asking Zeno about, when they opened Zeno from it.

The assistant's prompt otherwise holds the user's own words and nobody
else's (ZENO_ACTIONS.md), so no other party can write instructions into
it. A listing breaks that on purpose - "does it come with a charger?" is
answered by the seller's description or not at all - so the listing is
split in two:

  * FACTS: what BROKA's records say, as numbers, yes/no and values from a
    fixed list - the price, whether it is negotiable, whether the seller
    delivers, the seller's standing. Nothing a seller typed freely.
  * THE SELLER'S WORDS: title, description, delivery note, place, details
    and category - clipped, and fenced as data in the prompt, the way the
    Buying Agent fences listing names (ai_broker/service.py,
    narrate_matches).

It is loaded here, by id, never taken from the request: the app says which
listing, not what it says, so a client cannot hand Zeno a lower price or a
verified seller the listing does not have. No names: the seller is "the
seller", as nobody's name reaches this prompt.

A hostile description can still make Zeno say something; it cannot make
the app do anything. The actions stay the closed vocabulary (intents.py),
a call or a chat still resolves only against the user's own threads
(contacts.py), and a search Zeno proposes from here waits for a tap
(service.py).

WHAT THE THREE QUESTIONS ON THE LISTING'S CARD ARE ANSWERED FROM (2026-11-12)
===========================================================================
  * "Is this a fair price?" - the asking price against what similar live
    listings from other sellers on BROKA ask (found with the Buying Agent's
    search, kept only when their titles match), and the listing's own price
    changes. It used to be told BROKA had no market figures and to estimate
    from general knowledge, whatever BROKA knew.
  * "Is this seller reliable?" - how long they have been on BROKA, the
    deals they completed, their buyers' reviews, ID verification, the
    standing tiles. With DCR_ENABLED off (the default) every seller was
    described as having "no completed deals through BROKA" - dozens or not.
  * "Find me something similar" - see similar_to() and service.py.

Whether the listing can still be bought is a fact too: a listing reported
sold out, or with no units left, says so, instead of letting Zeno answer
"is it still available?" from a price and a description.
"""
from __future__ import annotations

import json
import re
import statistics
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Category, Listing, ListingPriceChange, User
from api.domains.listings.handover import IN_PLACE_NOTE, is_deliverable
from api.domains.listings.paid import is_live
from api.domains.listings.validation import CONDITIONS, MAX_PRICE_UNIT_LEN, _PRICE_UNIT
from api.domains.trust.public_standing import public_seller_standing

# Enough for a real description; short enough that one cannot bury the
# prompt's own rules under a wall of text.
TITLE_MAX = 120
DESCRIPTION_MAX = 1500
NOTE_MAX = 120
PLACE_MAX = 80
MAX_DETAILS = 12
DETAIL_MAX = 60
# The listing's own price changes the prompt is given, newest last.
MAX_PRICE_CHANGES = 4
# Similar listings a price is compared with - the Buying Agent's best ten,
# less those that only share a category.
MAX_SIMILAR = 10
# What a "something like this" search looks for: the title's first words.
SIMILAR_QUERY_MAX = 60

# A question about the price - the turns that get the market comparison.
# It is two queries and a ranked scan, so not every "does it have a box?".
_PRICE_WORDS = re.compile(
    r"\b(?:price[ds]?|pricing|fair|worth|value|cost[s]?|expensive|cheap(?:er|est)?|overpriced|"
    r"underpriced|bargain|deal|discount|offer|budget|afford|negotiat\w*|haggl\w*|how much|"
    r"bei|ghali|rahisi|thamani|punguz\w*)\b",
    re.IGNORECASE,
)

OWN = "own"
VISIBLE = "visible"
GONE = "gone"


def is_price_question(message: str, history: Optional[list[dict]] = None) -> bool:
    """The newest message - or the one before it, for a follow-up like "and
    compared to the others?" - asks about the price."""
    if _PRICE_WORDS.search(message or ""):
        return True
    for h in reversed(history or []):
        if h.get("role") == "user":
            return bool(_PRICE_WORDS.search(str(h.get("content") or "")))
    return False


def _one_line(value, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _minutes(m: float) -> str:
    if m < 60:
        return f"{round(m)} minutes"
    if m < 1440:
        return f"{m / 60:.1f} hours"
    return f"{m / 1440:.1f} days"


def _kes(v) -> str:
    return f"KES {float(v):,.0f}"


def _attributes(raw: Optional[str]) -> dict:
    try:
        attrs = json.loads(raw) if raw else {}
    except (TypeError, ValueError):
        return {}
    return attrs if isinstance(attrs, dict) else {}


def _details(raw: Optional[str]) -> list[str]:
    """Category details ("storage: 128GB"), as the seller entered them."""
    out = []
    for key, value in list(_attributes(raw).items())[:MAX_DETAILS]:
        if value in (None, "", [], {}):
            continue
        out.append(f"{_one_line(key, 30)}: {_one_line(value, DETAIL_MAX)}")
    return out


def _standing_lines(standing: Optional[dict], completed: int) -> list[str]:
    """The seller tiles' figures, as facts. `completed` is the account's own
    count of completed deals - published whether or not DCR is."""
    lines = []
    if standing and standing.get("overall_rating") is not None:
        lines.append(f"Seller's overall BROKA rating: {standing['overall_rating']}/10")
    if standing and standing.get("dcr") is not None:
        note = " (provisional - under 10 deals)" if standing.get("dcr_provisional") else ""
        lines.append(f"Seller's deal completion rate: {standing['dcr']:.0f}%{note}")
    elif completed <= 0:
        lines.append("Seller's deal completion rate: none yet - no completed deals through BROKA")
    # Otherwise BROKA doesn't publish a completion rate (DCR_ENABLED off):
    # nothing is said about one, rather than "none yet" over a real record.
    minutes = standing.get("median_response_minutes") if standing else None
    lines.append(
        f"Seller's typical first-reply time: {_minutes(minutes)} (how long buyers wait for the "
        f"seller's first answer to their first message)" if minutes is not None
        else "Seller's typical first-reply time: not measured yet (too few conversations)"
    )
    if not standing:
        lines.append("Seller's BROKA standing: not measured yet")
    return lines


async def _seller_lines(db: AsyncSession, seller: Optional[User], seller_id: str) -> list[str]:
    from api.domains.reviews.stats import seller_review_figures

    lines = []
    standing = await public_seller_standing(db, seller_id)
    # The account's live count, or last night's snapshot when that is
    # ahead of it - a deal never un-completes, so the larger is the truer.
    completed = max(int(getattr(seller, "completed_deals", 0) or 0),
                    int((standing or {}).get("completed_deals") or 0))
    if seller is not None:
        lines.append(f"Seller ID-verified: {'yes' if seller.is_verified else 'no'}")
        if seller.created_at:
            lines.append(f"Seller on BROKA since: {seller.created_at:%B %Y}")
        lines.append(f"Seller's completed deals through BROKA: {completed or 'none yet'}")
        count, average = (await seller_review_figures(db, [seller_id])).get(seller_id, (0, None))
        lines.append(
            f"Seller's reviews from buyers: {average:.1f} out of 5 from {count} review"
            f"{'s' if count != 1 else ''}" if count and average is not None
            else "Seller's reviews from buyers: none yet"
        )
    lines.extend(_standing_lines(standing, completed))
    return lines


async def _availability_lines(db: AsyncSession, listing: Listing, status: str) -> list[str]:
    from api.domains.listings.stock import is_stocked, units_left, units_total

    lines = []
    reported = getattr(listing, "sold_out_reported_at", None)
    if reported is not None:
        lines.append(
            f"Availability: a buyer reported on {reported.date().isoformat()} that it is no longer "
            f"available; it is hidden from buyers until the seller confirms it is still for sale"
        )
    if status != "active":
        lines.append(f"Listing status: {status} - it may no longer be available")
    elif is_stocked(listing):
        total = units_total(listing)
        left = await units_left(db, listing)
        if left <= 0:
            lines.append("Availability: sold out - every unit is sold or in a deal under way")
        elif total > 1:
            lines.append(f"Units left: {left} of {total}")
    return lines


def _words(text: str) -> set[str]:
    return {w for w in re.split(r"\W+", (text or "").lower()) if len(w) > 1}


async def _similar_listings(db: AsyncSession, listing: Listing, subcategory: Optional[str]) -> list[dict]:
    """Live direct sales from other sellers like this one, found the way the
    Buying Agent finds a buyer's item (search_for), kept only when their
    title shares at least half of this one's words.

    The Buying Agent's score alone lets anything in: a "used" phone scores
    0.53 against a "used" pair of earbuds on condition alone, and a median
    over those says nothing about earbuds.
    """
    from api.domains.buy_agent.conversation import _taxonomy, search_for

    title = _one_line(listing.name, TITLE_MAX)
    wanted = _words(title)
    if not wanted:
        return []
    _names, _subs, top_by_name, children_by_cat = await _taxonomy(db)
    slots = {
        "category": listing.category if listing.category in top_by_name else None,
        "subcategory": subcategory,
        "query": title,
        "condition": listing.condition if listing.condition in CONDITIONS else None,
    }
    # The seller as the searcher: their own listings - this one among them -
    # are never what it is compared with.
    ranked, _unmet = await search_for(db, slots, listing.seller_id, top_by_name, children_by_cat,
                                      exclude_ids={listing.id})
    unit = (listing.price_unit or "").strip().lower()
    out = []
    for item in ranked:
        if (item.get("listing_type") == "auction" or (item.get("price") or 0) <= 0
                or (item.get("price_unit") or "").strip().lower() != unit):
            continue
        if len(wanted & _words(str(item.get("name") or ""))) * 2 < len(wanted):
            continue
        out.append(item)
    return out[:MAX_SIMILAR]


async def _market_lines(db: AsyncSession, listing: Listing, subcategory: Optional[str]) -> list[str]:
    """What similar live listings from other sellers ask, and how this
    listing's own price moved. Numbers only: the similar listings' titles
    are other sellers' words and stay out of the prompt."""
    lines = []
    try:
        similar = await _similar_listings(db, listing, subcategory)
    except Exception:
        similar = []
    prices = sorted(float(item["price"]) for item in similar)
    if prices:
        median = statistics.median(prices)
        line = (f"Similar live listings on BROKA from other sellers: {len(prices)} "
                f"(matched on the title, same category). Lowest {_kes(prices[0])}, "
                f"median {_kes(median)}, highest {_kes(prices[-1])}")
        if len(prices) >= 4:
            q = statistics.quantiles(prices, n=4)
            line += f"; the middle half ask {_kes(q[0])}-{_kes(q[2])}"
        lines.append(line)
        if median > 0 and listing.price:
            diff = (float(listing.price) - median) / median * 100
            where = ("about the same as" if abs(diff) < 5 else
                     f"{abs(diff):.0f}% {'above' if diff > 0 else 'below'}")
            lines.append(f"This asking price is {where} the median of those similar listings")
        conditions = {}
        for item in similar:
            c = item.get("condition") if item.get("condition") in CONDITIONS else "not stated"
            conditions[c] = conditions.get(c, 0) + 1
        lines.append("Their condition: " + ", ".join(f"{n} {c}" for c, n in sorted(conditions.items())))
    else:
        lines.append("Similar live listings on BROKA from other sellers: none found right now")
    changes = (await db.execute(
        select(ListingPriceChange.old_price, ListingPriceChange.new_price, ListingPriceChange.changed_at)
        .where(ListingPriceChange.listing_id == listing.id)
        .order_by(ListingPriceChange.changed_at.desc())
        .limit(MAX_PRICE_CHANGES)
    )).all()
    if changes:
        moves = [f"{_kes(old)} to {_kes(new)} on {at.date().isoformat()}"
                 for old, new, at in reversed(changes) if old is not None and at is not None]
        if moves:
            lines.append("The seller changed this listing's price: " + "; ".join(moves))
    return lines


async def _subcategory_name(db: AsyncSession, listing: Listing) -> Optional[str]:
    if not listing.subcategory_id:
        return None
    sub = await db.get(Category, listing.subcategory_id)
    # Listing.subcategory_id may hold the top-level category itself.
    return sub.name if sub is not None and sub.parent_id is not None else None


async def access(db: AsyncSession, viewer_id: str, listing_id: str) -> str:
    """OWN (the viewer's own listing), VISIBLE (one buyers may see), or GONE
    (no such listing, or one buyers may not see - unpaid or lapsed)."""
    listing = await db.get(Listing, listing_id)
    if listing is None:
        return GONE
    if listing.seller_id == viewer_id:
        return OWN
    return VISIBLE if is_live(listing) else GONE


async def similar_to(db: AsyncSession, viewer_id: str, listing_id: str) -> Optional[dict]:
    """What "find me something similar" means from this listing:
    {"listing_id", "title", "slots"} - the Buying Agent's criteria for
    listings like it (its category, its subcategory, its title) - or None
    for a listing buyers can't see.

    The title is the seller's words, but here it only becomes a search
    query, which reaches nothing but a search.
    """
    listing = await db.get(Listing, listing_id)
    if listing is None or (listing.seller_id != viewer_id and not is_live(listing)):
        return None
    title = " ".join(re.sub(r"[^\w\s.+&'-]", " ", listing.name or "").split())[:SIMILAR_QUERY_MAX].strip()
    slots = {"category": listing.category}
    sub = await _subcategory_name(db, listing)
    if sub:
        slots["subcategory"] = sub
    if title:
        slots["query"] = title
    return {"listing_id": listing.id, "title": title or (listing.category or "this"), "slots": slots}


async def load(db: AsyncSession, viewer_id: str, listing_id: str, *, market: bool = False) -> Optional[dict]:
    """{"own", "facts", "seller_text", "market"} for the listing, or None
    when there is no such listing - or none this user may see: an unpaid or
    lapsed listing is not there for buyers (ListingService.get_listing), so
    it is not there for Zeno either.

    `market`: add what similar listings ask (a price question). The result's
    "market" says whether that comparison is in the facts.
    """
    listing = await db.get(Listing, listing_id)
    if listing is None:
        return None
    own = listing.seller_id == viewer_id
    if not own and not is_live(listing):
        return None
    seller = await db.get(User, listing.seller_id)

    listing_type = getattr(listing.listing_type, "value", listing.listing_type) or "direct"
    status = getattr(listing.status, "value", listing.status) or "active"
    unit = (listing.price_unit or "").strip()
    per = (f" per {unit}" if unit and len(unit) <= MAX_PRICE_UNIT_LEN and _PRICE_UNIT.fullmatch(unit)
           else "")

    facts = [
        f"Sale type: {'auction' if listing_type == 'auction' else 'direct sale'}",
        f"Asking price: KES {listing.price:,.0f}{per}",
        ("Price terms: NEGOTIABLE - the seller takes offers; the buyer can negotiate through "
         "BROKA's negotiation room" if listing.price_negotiable else
         "Price terms: FIXED - the seller said they do not take offers"),
    ]
    if listing.quantity and listing.quantity > 1:
        facts.append(f"Quantity available: {listing.quantity}")
    if not is_deliverable(listing.category):
        facts.append(f"Delivery: {IN_PLACE_NOTE}")
    elif listing.delivery_available is True:
        facts.append("Delivery: the seller CAN arrange delivery (their note on it, if any, is below)")
    elif listing.delivery_available is False:
        facts.append("Delivery: NO - the buyer collects it from the seller")
    else:
        facts.append("Delivery: the seller has not said whether they deliver")
    if listing.condition in CONDITIONS:
        facts.append(f"Condition: {listing.condition}")
    facts.extend(await _availability_lines(db, listing, status))
    if listing.created_at:
        facts.append(f"Listed on: {listing.created_at.date().isoformat()}")
    facts.append(f"Views: {int(listing.views or 0)}")
    facts.extend(await _seller_lines(db, seller, listing.seller_id))
    with_market = bool(market) and listing_type != "auction"
    if with_market:
        facts.extend(await _market_lines(db, listing, await _subcategory_name(db, listing)))

    text = [
        f"Title: {_one_line(listing.name, TITLE_MAX)}",
        f"Category: {_one_line(listing.category, 40)}",
    ]
    if listing.location_name:
        text.append(f"Location: {_one_line(listing.location_name, PLACE_MAX)}")
    if listing.delivery_note and is_deliverable(listing.category):
        text.append(f"Delivery note: {_one_line(listing.delivery_note, NOTE_MAX)}")
    details = _details(listing.attributes)
    if details:
        text.append("Details: " + "; ".join(details))
    description = (listing.description or "").strip()[:DESCRIPTION_MAX]
    text.append(f"Description: {description}" if description else "Description: (none given)")

    # The fence is "<<<LISTING ... LISTING>>>": a description that closes
    # it could carry on as if it were the prompt's own text.
    seller_text = "\n".join(text).replace("<<<", "‹‹‹").replace(">>>", "›››")
    return {"own": own, "facts": "\n".join(facts), "seller_text": seller_text,
            "market": with_market}
