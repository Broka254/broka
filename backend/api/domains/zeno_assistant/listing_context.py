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
"""
from __future__ import annotations

import json
from typing import Optional

from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, User
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


def _one_line(value, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _minutes(m: float) -> str:
    if m < 60:
        return f"{round(m)} minutes"
    if m < 1440:
        return f"{m / 60:.1f} hours"
    return f"{m / 1440:.1f} days"


def _details(raw: Optional[str]) -> list[str]:
    """Category details ("storage: 128GB"), as the seller entered them."""
    try:
        attrs = json.loads(raw) if raw else {}
    except (TypeError, ValueError):
        return []
    if not isinstance(attrs, dict):
        return []
    out = []
    for key, value in list(attrs.items())[:MAX_DETAILS]:
        if value in (None, "", [], {}):
            continue
        out.append(f"{_one_line(key, 30)}: {_one_line(value, DETAIL_MAX)}")
    return out


def _standing_lines(standing: Optional[dict]) -> list[str]:
    if not standing:
        return ["Seller's BROKA standing: not measured yet"]
    lines = []
    if standing.get("overall_rating") is not None:
        lines.append(f"Seller's overall BROKA rating: {standing['overall_rating']}/10")
    if standing.get("dcr") is not None:
        note = " (provisional - under 10 deals)" if standing.get("dcr_provisional") else ""
        lines.append(f"Seller's deal completion rate: {standing['dcr']:.0f}%{note}")
    else:
        lines.append("Seller's deal completion rate: none yet - no completed deals through BROKA")
    minutes = standing.get("median_response_minutes")
    lines.append(
        f"Seller's typical reply time: {_minutes(minutes)}" if minutes is not None
        else "Seller's typical reply time: not measured yet (too few conversations)"
    )
    return lines


async def load(db: AsyncSession, viewer_id: str, listing_id: str) -> Optional[dict]:
    """{"own", "facts", "seller_text"} for the listing, or None when there
    is no such listing - or none this user may see: an unpaid or lapsed
    listing is not there for buyers (ListingService.get_listing), so it is
    not there for Zeno either."""
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
    if listing.delivery_available is True:
        facts.append("Delivery: the seller CAN arrange delivery (their note on it, if any, is below)")
    elif listing.delivery_available is False:
        facts.append("Delivery: NO - the buyer collects it from the seller")
    else:
        facts.append("Delivery: the seller has not said whether they deliver")
    if listing.condition in CONDITIONS:
        facts.append(f"Condition: {listing.condition}")
    if status != "active":
        facts.append(f"Listing status: {status} - it may no longer be available")
    if listing.created_at:
        facts.append(f"Listed on: {listing.created_at.date().isoformat()}")
    facts.append(f"Views: {int(listing.views or 0)}")
    if seller is not None:
        facts.append(f"Seller ID-verified: {'yes' if seller.is_verified else 'no'}")
    facts.extend(_standing_lines(await public_seller_standing(db, listing.seller_id)))

    text = [
        f"Title: {_one_line(listing.name, TITLE_MAX)}",
        f"Category: {_one_line(listing.category, 40)}",
    ]
    if listing.location_name:
        text.append(f"Location: {_one_line(listing.location_name, PLACE_MAX)}")
    if listing.delivery_note:
        text.append(f"Delivery note: {_one_line(listing.delivery_note, NOTE_MAX)}")
    details = _details(listing.attributes)
    if details:
        text.append("Details: " + "; ".join(details))
    description = (listing.description or "").strip()[:DESCRIPTION_MAX]
    text.append(f"Description: {description}" if description else "Description: (none given)")

    # The fence is "<<<LISTING ... LISTING>>>": a description that closes
    # it could carry on as if it were the prompt's own text.
    seller_text = "\n".join(text).replace("<<<", "‹‹‹").replace(">>>", "›››")
    return {"own": own, "facts": "\n".join(facts), "seller_text": seller_text}
