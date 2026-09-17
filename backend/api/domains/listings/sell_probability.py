"""Probability that a listing sells — and what is holding it back.

WHAT THIS IS
============
A calibrated score over signals the platform already has, not a trained
model. There is no outcome data to train on yet: the honest version of this
number today is a transparent weighted combination whose every term can be
explained to the seller, which is also what makes the per-listing advice
panel possible at all.

When enough listings have resolved (sold / expired), the weights here are
the obvious thing to replace with fitted ones — the shape stays, the
constants stop being guesses. Until then they are stated in one place and
argued for individually rather than buried.

THE SIGNALS, AND WHY EACH IS IN
===============================
  Demand — views per day. The raw measure of whether anyone is looking.
  Intent — likes ÷ views. A like is a buyer saying "I want this but not
           today", which is a far stronger signal than a view: they looked,
           they considered, and something stopped them. Usually price.
  Commitment — interested buyers (people who asked about availability).
           The strongest per-listing signal there is, because asking costs
           effort and exposes the buyer to a reply.
  Seller — DCR and response time. The same listing sells at different rates
           depending on who is answering the messages, and this is the term
           that makes the seller's own behaviour visible on the listing
           screen rather than only on the dashboard.
  Price — position against the category's current median.
  Category — how much the category moves on BROKA at all.

THE CONFIDENCE PROBLEM, AGAIN
=============================
A listing with 3 views and 1 like has a 33% like rate, which naively reads
as extraordinary demand. Same trap as the seller rating: thin evidence
produces extreme numbers. So the score is shrunk toward the category base
rate by an evidence weight, and a brand-new listing reports roughly what the
category does rather than a confident number invented from four data points.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Dict, List, Optional

# ── Weights (sum to 1.0) ────────────────────────────────────────────────────
W_DEMAND      = 0.20
W_INTENT      = 0.20
W_COMMITMENT  = 0.25   # largest: asking about availability costs effort
W_SELLER      = 0.20
W_PRICE       = 0.15

# ── Normalisation ───────────────────────────────────────────────────────────
VIEWS_PER_DAY_HALF   = 5.0    # 5 views/day scores 0.5 on demand
GOOD_LIKE_RATE       = 0.15   # 15% of viewers liking it is strong
INTEREST_HALF        = 3.0    # 3 people asking scores 0.5 on commitment

# Evidence needed before the listing's own numbers outweigh the category
# base rate. 20 views is roughly a day or two of normal traffic.
VIEWS_FOR_FULL_CONFIDENCE = 20.0

# Fallback when a category has too little history to have its own rate.
DEFAULT_CATEGORY_SELL_RATE = 0.35

# How many OTHER listings a category needs before a price comparison means
# anything.
#
# Below this there is no benchmark, and inventing one is worse than saying
# nothing: an Airtel router listed at KES 30,000 in a category containing
# only itself compared against its own price, scored 0% off the median, and
# was told it was competitively priced. The seller's own judgement was the
# one thing being measured, and it was handed back to them as confirmation.
#
# Five is the smallest sample where a median is not simply one arbitrary
# listing. It will still be wrong sometimes; it will not be circular.
MIN_COMPARABLE_LISTINGS = 5


@dataclass(frozen=True)
class ListingSignals:
    views: int = 0
    likes: int = 0
    interested_buyers: int = 0
    days_listed: float = 1.0
    seller_dcr_percent: Optional[float] = None
    seller_response_minutes: Optional[float] = None
    price: Optional[float] = None
    category_median_price: Optional[float] = None
    category_sell_rate: Optional[float] = None   # 0-1
    # How many OTHER listings the median was computed from. None or below
    # MIN_COMPARABLE_LISTINGS means there is no usable benchmark.
    comparable_count: Optional[int] = None


@dataclass(frozen=True)
class SellProbability:
    probability: float          # 0-100, what the seller sees
    confidence: float           # 0-1
    demand: float
    intent: float
    commitment: float
    seller: float
    price_fit: Optional[float]   # None when there is no benchmark
    price_delta_percent: Optional[float]   # + = above category median


def _views_per_day(s: ListingSignals) -> float:
    return s.views / max(s.days_listed, 1.0)


def has_price_benchmark(s: ListingSignals) -> bool:
    """Is there a real comparison to make?

    Requires a median AND enough other listings behind it. Both, because a
    median computed from one listing is still a number - it is just this
    listing's own price wearing a different label.
    """
    if not s.price or not s.category_median_price:
        return False
    if s.comparable_count is None:
        return False
    return s.comparable_count >= MIN_COMPARABLE_LISTINGS


def price_fit(price: Optional[float], median: Optional[float]) -> float:
    """1.0 at or just below the category median, falling away above it.

    Asymmetric on purpose. Being 30% over the median is a real obstacle to
    selling; being 30% under is not a symmetric advantage — it sells faster,
    but it is also the seller leaving money behind, and a score that rewarded
    it without limit would quietly push every listing toward the floor.

    So: full marks from a little below the median up to it, a penalty above
    it, and only a small bonus for going under.
    """
    if not price or not median or median <= 0:
        return 0.6   # unknown: neutral-ish, neither rewarded nor punished
    ratio = price / median
    if ratio <= 0.85:
        return 0.9                       # cheap, but capped
    if ratio <= 1.05:
        return 1.0                       # at market
    # Decays past the median; ~0.5 at +35%, ~0.25 at +70%.
    return max(0.05, math.exp(-2.0 * (ratio - 1.05)))


def compute_sell_probability(s: ListingSignals) -> SellProbability:
    vpd = _views_per_day(s)
    demand = vpd / (vpd + VIEWS_PER_DAY_HALF)

    # Like rate only means something once there are views to divide by.
    like_rate = (s.likes / s.views) if s.views > 0 else 0.0
    intent = min(1.0, like_rate / GOOD_LIKE_RATE)

    commitment = s.interested_buyers / (s.interested_buyers + INTEREST_HALF)

    # Seller term: reuses the rating module's response curve so a seller
    # cannot see one reply-speed story on the dashboard and a different one
    # on their listing.
    from api.domains.trust.seller_rating import response_score
    dcr_norm = ((s.seller_dcr_percent if s.seller_dcr_percent is not None else 80.0)
                / 100.0)
    seller = 0.5 * min(max(dcr_norm, 0.0), 1.0) + 0.5 * response_score(
        s.seller_response_minutes)

    # Price only enters the score when there is something to compare
    # against. With no benchmark the weight is REDISTRIBUTED across the
    # other four terms rather than filled with a neutral guess - a
    # fabricated 0.6 on 15% of the score is a fabricated 9% of the answer,
    # and it moves in the direction of "this listing is fine".
    benchmark = has_price_benchmark(s)
    pfit = price_fit(s.price, s.category_median_price) if benchmark else None

    if benchmark:
        raw = (W_DEMAND * demand + W_INTENT * intent + W_COMMITMENT * commitment
               + W_SELLER * seller + W_PRICE * pfit)
    else:
        scale = 1.0 / (W_DEMAND + W_INTENT + W_COMMITMENT + W_SELLER)
        raw = (W_DEMAND * demand + W_INTENT * intent + W_COMMITMENT * commitment
               + W_SELLER * seller) * scale

    base = (s.category_sell_rate if s.category_sell_rate is not None
            else DEFAULT_CATEGORY_SELL_RATE)
    confidence = min(1.0, s.views / VIEWS_FOR_FULL_CONFIDENCE)
    prob = confidence * raw + (1 - confidence) * base

    # No benchmark, no delta. The screen shows "not enough comparable
    # listings" rather than a percentage against nothing.
    delta = None
    if benchmark and s.category_median_price:
        delta = round((s.price / s.category_median_price - 1) * 100, 1)

    return SellProbability(
        probability=round(min(max(prob, 0.0), 1.0) * 100, 1),
        confidence=round(confidence, 3),
        demand=round(demand, 3),
        intent=round(intent, 3),
        commitment=round(commitment, 3),
        seller=round(seller, 3),
        price_fit=round(pfit, 3) if pfit is not None else None,
        price_delta_percent=delta,
    )


def listing_advice(s: ListingSignals, p: SellProbability) -> Dict[str, List[Dict]]:
    """Per-listing "working for you / against you", same rules as the seller
    panel: every card cites a number, and says what to do about it.

    The ordering matters more here than on the dashboard. A seller looking at
    one listing wants the single thing to change, so price — the only lever
    that is immediate, free and entirely theirs — sorts above everything
    slower.
    """
    pos: List[Dict] = []
    neg: List[Dict] = []
    vpd = _views_per_day(s)

    # Price cards need a real benchmark. Without one the only honest thing
    # to say is that there is nothing to compare against - which the screen
    # now states outright instead of implying the price is fine.
    if not has_price_benchmark(s):
        pos.append({
            "code": "no_benchmark", "severity": 0,
            "title": "No comparable listings yet",
            "detail": "There are not enough similar items on BROKA to tell you "
                      "whether this is priced well. Once more sellers list in "
                      "this category you will see where you sit.",
        })
    elif p.price_delta_percent is not None and p.price_delta_percent > 20:
        neg.append({
            "code": "price_high", "severity": 5,
            "title": f"Priced {p.price_delta_percent:.0f}% above similar listings",
            "detail": "The closest comparable items in this category sit lower. "
                      "Price is the fastest thing you can change, and it is the "
                      "usual reason people like a listing without buying it.",
        })
    elif p.price_delta_percent is not None and -15 <= p.price_delta_percent <= 5:
        pos.append({
            "code": "price_good", "severity": 0,
            "title": "Your price is competitive",
            "detail": "Within a few percent of comparable listings in this "
                      "category — buyers comparing options won't rule you out "
                      "on price.",
        })

    if s.interested_buyers >= 2:
        pos.append({
            "code": "buyers_asking", "severity": 0,
            "title": f"{s.interested_buyers} buyers have asked about this",
            "detail": "Asking about availability is the strongest signal a "
                      "buyer gives. Replying quickly to these is worth more "
                      "than any other action on this listing.",
        })

    if s.views >= 20 and s.likes == 0:
        neg.append({
            "code": "views_no_likes", "severity": 4,
            "title": f"{s.views} views and no saves",
            "detail": "People are finding it and moving on. That usually points "
                      "at the photos or the price rather than demand.",
        })
    elif s.views > 0 and (s.likes / s.views) >= GOOD_LIKE_RATE:
        pos.append({
            "code": "strong_interest", "severity": 0,
            "title": "People are saving this listing",
            "detail": f"{s.likes} of {s.views} viewers saved it. They want it — "
                      f"a small price move often converts saves into offers.",
        })

    if vpd < 1.0 and s.days_listed >= 3:
        neg.append({
            "code": "low_visibility", "severity": 3,
            "title": "Very few people are seeing this",
            "detail": f"About {vpd:.1f} views a day. Listings rank partly on "
                      f"your seller score, so improving your reply time lifts "
                      f"every listing you have — or boost this one directly.",
        })

    if (s.seller_response_minutes is not None
            and s.seller_response_minutes >= 180 and s.interested_buyers > 0):
        neg.append({
            "code": "slow_with_buyers_waiting", "severity": 5,
            "title": "Buyers asked, and you're slow to reply",
            "detail": "There is interest in this listing and your median reply "
                      "time is over three hours. This is the most expensive "
                      "gap on the whole screen.",
        })

    if s.views < 10 and s.days_listed <= 2:
        pos.append({
            "code": "too_early", "severity": 0,
            "title": "Still early",
            "detail": "This listing is new — the numbers above will mean more "
                      "after a couple of days of traffic.",
        })

    neg.sort(key=lambda c: -c["severity"])

    # The store recommendation appears here too, not only on the dashboard.
    #
    # A seller looking at one listing that is not moving is in exactly the
    # frame of mind the feature answers - "why is nobody seeing this" - and
    # this screen gets opened far more often than the dashboard's
    # recommendation block gets scrolled to.
    from api.domains.trust.seller_advice import _STORE_RECOMMENDATION
    return {
        "positives": pos[:4],
        "negatives": neg[:4],
        "recommendations": [dict(_STORE_RECOMMENDATION)],
    }
