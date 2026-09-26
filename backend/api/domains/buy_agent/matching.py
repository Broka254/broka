"""Flexible match scoring for the conversational Buying Agent.

WHY THIS EXISTS, AND WHY IT ISN'T list_listings()
=================================================
ListingService.list_listings answers "show me everything that satisfies
these filters". That is the right shape for a browse screen and the wrong
shape for an agent, because a filter can only ever return nothing. A buyer
who tells Zeno "iPhone 14, at least 12GB RAM, at least 128GB" and gets
"0 results found" has learned nothing: they don't know whether the problem
is the RAM, the storage, the model, or that nobody on Broka sells iPhones.

A real buying agent answers the question a person actually asked, which is
"what's the closest you can do?". So this module keeps only the filters
that would make a result *wrong* as hard SQL filters, and turns every
other stated criterion into a SCORE plus an explicit record of what the
listing missed by. That record is the whole point: it is what lets Zeno
say "I found two, but they're 8GB, not the 12GB you wanted - can you live
with that?" instead of "0 results found".

HARD vs SOFT
------------
Hard (a violation makes the result wrong, never relaxed):
  * the listing is live
  * the top-level category, when the buyer named one - a sofa is not a
    near-miss iPhone, however well it scores on price
  * the buyer's own listings, which are never a match for their own search

Soft (scored, and reported when missed):
  * price ceiling/floor, distance, condition
  * per-category attributes (ram, storage, year, mileage, bedrooms...)
  * free-text relevance against the listing's own words

Soft, and deliberately NOT reported as a shortfall:
  * subcategory. Listing.subcategory_id is nullable and routinely null -
    the sell wizard's subcategory step is optional - so hard-filtering on
    it is the single fastest way back to "0 results found" for a listing
    that is obviously right (this was a real bug on the old
    SEARCH_PRODUCTS path, and the first thing these tests caught here). It
    ranks a correctly-tagged listing above an untagged one and stops
    there. It is also our taxonomy metadata rather than something the
    buyer asserted about the item, so a mismatch is not a promise broken
    to them and never appears in what Zeno apologises for.

HONESTY
-------
Every number here is computed from real columns. The score orders results
and decides whether Zeno opens with "found it" or "closest I could get";
it is deliberately NOT shown to the buyer as a match percentage, because
it is not a calibrated probability of anything (Design v2 §23: "do not
invent match percentages unless a real scoring model exists"). What the
buyer sees is the concrete miss - "8GB, not 12GB" - which is a fact, not
a number we made up.
"""
from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

# Attribute fields where a bigger number is what the buyer meant: "at least
# 12GB RAM", "2018 or newer", "3 bedrooms or more". A listing that beats
# the ask is a full match, not a partial one.
HIGHER_IS_BETTER = {
    "ram", "storage", "year", "bedrooms", "bathrooms", "acreage",
    "square_footage", "seating_capacity", "capacity", "payload_capacity",
    "screen_size", "engine_size",
}
# ...and where a smaller one is. Nobody asking about mileage wants more.
LOWER_IS_BETTER = {"mileage"}

# Score for an attribute the listing simply doesn't state. Deliberately
# BELOW a known partial match (8GB against a 12GB ask scores 0.67) and
# above a known failure: a seller who left the field blank is less useful
# than one who filled it in with something short of the ask, but not as
# bad as one who filled it in with the wrong thing.
UNKNOWN_ATTRIBUTE_SCORE = 0.45

_NUMBER = re.compile(r"(\d+(?:[.,]\d+)?)")


def _as_number(value: Any) -> Optional[float]:
    """First number in a value like "8GB", "128 GB", "2014", "45,000 km"."""
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    if value is None:
        return None
    m = _NUMBER.search(str(value).replace(",", ""))
    return float(m.group(1)) if m else None


def _ratio(have: float, want: float) -> float:
    """How close `have` gets to `want`, 0-1, for a want that is a floor."""
    if want <= 0:
        return 1.0
    return max(0.0, min(1.0, have / want))


@dataclass
class Miss:
    """One stated criterion a listing does not fully meet.

    `actual` is None when the listing is silent on it - a different thing
    from failing it, and worded differently to the buyer.
    """
    field: str
    wanted: str
    actual: Optional[str] = None

    def as_dict(self) -> dict:
        return {"field": self.field, "wanted": self.wanted, "actual": self.actual}


@dataclass
class Assessment:
    score: float
    misses: List[Miss] = field(default_factory=list)

    @property
    def is_perfect(self) -> bool:
        return not self.misses


def _score_attribute(key: str, wanted: Any, stored: Dict[str, Any]) -> Tuple[float, Optional[Miss]]:
    key_l = key.lower()
    raw_actual = None
    for k, v in stored.items():
        if str(k).lower() == key_l:
            raw_actual = v
            break

    if raw_actual in (None, ""):
        return UNKNOWN_ATTRIBUTE_SCORE, Miss(key, str(wanted), None)

    want_n, have_n = _as_number(wanted), _as_number(raw_actual)

    if want_n is not None and have_n is not None and key_l in LOWER_IS_BETTER:
        if have_n <= want_n:
            return 1.0, None
        return _ratio(want_n, have_n), Miss(key, str(wanted), str(raw_actual))

    if want_n is not None and have_n is not None and key_l in HIGHER_IS_BETTER:
        if have_n >= want_n:
            return 1.0, None
        return _ratio(have_n, want_n), Miss(key, str(wanted), str(raw_actual))

    # Anything else (brand, make, model, transmission, fuel...) is a name,
    # not a quantity: substring either way so "Galaxy A54" matches "A54"
    # and "Toyota" matches "Toyota Prado".
    w, a = str(wanted).strip().lower(), str(raw_actual).strip().lower()
    if w and (w in a or a in w):
        return 1.0, None

    # Two numbers with no direction (an odd engine_size, say) still deserve
    # partial credit for being close rather than a flat zero.
    if want_n is not None and have_n is not None:
        closeness = 1.0 - min(1.0, abs(have_n - want_n) / max(want_n, 1.0))
        return closeness, Miss(key, str(wanted), str(raw_actual))

    return 0.0, Miss(key, str(wanted), str(raw_actual))


def states_a_shortfall(key: str, wanted: Any, stored: Dict[str, Any]) -> bool:
    """True when the listing STATES a value for `key` that falls short of
    `wanted` - the same judgement assess() makes, reduced to yes/no for
    the standing-request matcher (core/buy_agent_subscribers.py). A listing
    that doesn't state the field is not a shortfall here: the matcher lets
    unknowns through, like every other optional field it checks."""
    if wanted in (None, ""):
        return False
    _score, miss = _score_attribute(str(key), wanted, stored)
    return miss is not None and miss.actual is not None


def _relevance(query: str, listing: dict) -> float:
    """Word overlap against the listing's own words. A heuristic, and named
    as one - there is no search index in this codebase to do better."""
    q_words = {w for w in re.split(r"\W+", query.lower()) if len(w) > 1}
    if not q_words:
        return 1.0
    haystack = f"{listing.get('name') or ''} {listing.get('description') or ''}".lower()
    hay_words = {w for w in re.split(r"\W+", haystack) if w}
    hit = sum(1 for w in q_words if w in hay_words or w in haystack)
    return hit / len(q_words)


def assess(listing: dict, criteria: dict) -> Assessment:
    """Score one listing against everything the buyer actually stated.

    Criteria the buyer never mentioned are not scored at all - they are
    absent from the weighting, not scored as neutral, so a buyer who only
    said "iPhone" isn't ranked by a budget they never gave.
    """
    weighted: List[Tuple[float, float]] = []   # (weight, score)
    misses: List[Miss] = []

    def add(weight: float, score: float, miss: Optional[Miss] = None) -> None:
        weighted.append((weight, score))
        if miss is not None:
            misses.append(miss)

    price = listing.get("price")

    max_price = criteria.get("max_price")
    if max_price and price is not None:
        if price <= max_price:
            add(1.0, 1.0)
        else:
            over = (price - max_price) / max_price
            add(1.0, max(0.0, 1.0 - over),
                Miss("max_price", f"{max_price:,.0f}", f"{price:,.0f}"))

    min_price = criteria.get("min_price")
    if min_price and price is not None:
        if price >= min_price:
            add(0.5, 1.0)
        else:
            add(0.5, _ratio(price, min_price),
                Miss("min_price", f"{min_price:,.0f}", f"{price:,.0f}"))

    condition = criteria.get("condition")
    if condition:
        actual = listing.get("condition")
        if not actual:
            add(0.8, UNKNOWN_ATTRIBUTE_SCORE, Miss("condition", condition, None))
        elif str(actual).lower() == str(condition).lower():
            add(0.8, 1.0)
        else:
            add(0.8, 0.0, Miss("condition", condition, str(actual)))

    max_km = criteria.get("max_distance_km")
    distance = listing.get("distance_km")
    if max_km and distance is not None:
        if distance <= max_km:
            add(0.8, 1.0)
        else:
            add(0.8, _ratio(max_km, distance),
                Miss("max_distance_km", f"{max_km:g} km", f"{distance:g} km"))

    attributes = criteria.get("attributes") or {}
    if isinstance(attributes, dict):
        stored = listing.get("attributes")
        if isinstance(stored, str):
            try:
                stored = json.loads(stored)
            except (TypeError, ValueError):
                stored = {}
        if not isinstance(stored, dict):
            stored = {}
        for key, wanted in attributes.items():
            if wanted in (None, ""):
                continue
            score, miss = _score_attribute(str(key), wanted, stored)
            add(1.0, score, miss)

    wanted_sub = criteria.get("subcategory_id")
    if wanted_sub:
        actual_sub = listing.get("subcategory_id")
        if actual_sub == wanted_sub:
            add(0.6, 1.0)
        elif not actual_sub:
            # Untagged. Very common, and no evidence against the listing.
            add(0.6, 0.6)
        else:
            add(0.6, 0.2)

    query = criteria.get("query")
    if query:
        # Relevance is weighted below a hard spec: a listing named
        # "iPhone 14" that fails the RAM ask should not outrank one that
        # meets every spec but is named "Apple 14 Pro".
        add(0.7, _relevance(str(query), listing))

    if not weighted:
        # Nothing to discriminate on - the buyer gave only a category.
        return Assessment(score=1.0, misses=[])

    total_w = sum(w for w, _ in weighted)
    return Assessment(score=sum(w * s for w, s in weighted) / total_w, misses=misses)


def rank(listings: List[dict], criteria: dict, limit: int = 10) -> Tuple[List[dict], List[str]]:
    """Score, sort and cut to the best `limit`.

    Returns (results, unmet_everywhere). Each result carries `match_misses`
    and an internal `match_score`. `unmet_everywhere` names the criteria
    that NOT ONE returned listing fully met - that is what entitles Zeno to
    say "I couldn't find any with 12GB" rather than leaving the buyer to
    work it out from the cards.
    """
    scored = []
    for listing in listings:
        a = assess(listing, criteria)
        enriched = dict(listing)
        enriched["match_score"] = round(a.score, 4)
        enriched["match_misses"] = [m.as_dict() for m in a.misses]
        enriched["match_is_exact"] = a.is_perfect
        scored.append((a, enriched))

    # Best score first; cheaper wins a tie, since between two equally good
    # matches a buyer wants the cheaper one.
    scored.sort(key=lambda pair: (-pair[0].score, pair[1].get("price") or math.inf))
    top = scored[:limit]

    stated = _stated_fields(criteria)
    unmet = [
        f for f in stated
        if all(any(m["field"] == f for m in item["match_misses"]) for _, item in top)
    ] if top else []

    return [item for _, item in top], unmet


def _stated_fields(criteria: dict) -> List[str]:
    fields: List[str] = []
    for key in ("max_price", "min_price", "condition", "max_distance_km"):
        if criteria.get(key):
            fields.append(key)
    for key in (criteria.get("attributes") or {}):
        fields.append(str(key))
    return fields
