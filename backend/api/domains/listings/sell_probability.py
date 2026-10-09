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

WHAT CHANGED ON 2026-10-09
==========================
A fifth of the score was the like rate, and nothing collected likes: the
`wishlists` table had no endpoint and the app no button, so every listing
scored 0 on it - and every listing with 20 views was told "20 views and no
saves", an accusation built on a number that could only ever be zero. Saves
are now collected (POST /listings/{id}/save, the heart on a listing), and
the model was rebuilt around what is really measured:

  * the save rate is smoothed toward a prior, so a listing nobody has had
    the chance to save yet is not scored as one nobody wants;
  * "buyers asking" counts everyone who has started a conversation about
    the listing, not only the availability button (`Interest`) - most
    buyers simply write;
  * an offer near the asking price is the closest thing to a sale short of
    one, and now counts;
  * the listing itself - photos, a description - is a term: it is the part
    the seller controls completely;
  * a listing that has sat for weeks with nobody asking is marked down;
  * evidence counts buyers and saves, not only views, so three buyers
    asking about a listing with eight views is not "too early to tell".

THE SIGNALS, AND WHY EACH IS IN
===============================
  Demand — views per day. The raw measure of whether anyone is looking.
  Intent — saves ÷ views, smoothed. A save is a buyer saying "I want this
           but not today": they looked, they considered, and something
           stopped them. Usually price.
  Commitment — buyers who have asked or written about it, and how close
           their best offer is to the price. The strongest per-listing
           signal there is, because asking costs effort and exposes the
           buyer to a reply.
  Seller — DCR and response time. The same listing sells at different rates
           depending on who is answering the messages, and this is the term
           that makes the seller's own behaviour visible on the listing
           screen rather than only on the dashboard.
  Price — position against the category's current median.
  Listing — photos and a description. Listings with one photo and no words
           are the ones buyers scroll past.

THE CONFIDENCE PROBLEM, AGAIN
=============================
A listing with 3 views and 1 save has a 33% save rate, which naively reads
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
W_DEMAND      = 0.15
W_INTENT      = 0.15
W_COMMITMENT  = 0.25   # largest: asking about it costs effort
W_SELLER      = 0.15
W_PRICE       = 0.15
W_QUALITY     = 0.15

# ── Normalisation ───────────────────────────────────────────────────────────
VIEWS_PER_DAY_HALF   = 5.0    # 5 views/day scores 0.5 on demand
GOOD_LIKE_RATE       = 0.15   # 15% of viewers saving it is strong
INTEREST_HALF        = 3.0    # 3 buyers asking scores 0.5 on commitment

# The save rate is smoothed as if every listing started with PRIOR_VIEWS
# views and PRIOR_SAVE_RATE of them saved. Without it a listing's first
# viewer decides its whole intent score: one save is 100%, no save is 0%.
PRIOR_VIEWS          = 20.0
PRIOR_SAVE_RATE      = 0.05

# An offer at this share of the price or more is a buyer ready to deal.
STRONG_OFFER_RATIO   = 0.9
# Below this an offer says more about the buyer than about the listing.
WEAK_OFFER_RATIO     = 0.6

# Photos and words that make a complete listing.
GOOD_PHOTO_COUNT       = 4
GOOD_DESCRIPTION_CHARS = 120

# After this many days with nobody asking, a listing is going stale: the
# buyers who will ever find it mostly have.
STALE_AFTER_DAYS     = 21.0
STALE_FLOOR          = 0.6    # the most staleness can take off: 40%

# Evidence needed before the listing's own numbers outweigh the category
# base rate. 20 views is roughly a day or two of normal traffic; a buyer
# asking is worth five views of evidence, a save three.
VIEWS_FOR_FULL_CONFIDENCE = 20.0
EVIDENCE_PER_BUYER        = 5.0
EVIDENCE_PER_SAVE         = 3.0

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
    likes: int = 0                  # saves (the wishlists table)
    interested_buyers: int = 0      # distinct buyers who asked or wrote
    days_listed: float = 1.0
    seller_dcr_percent: Optional[float] = None
    seller_response_minutes: Optional[float] = None
    price: Optional[float] = None
    category_median_price: Optional[float] = None
    category_sell_rate: Optional[float] = None   # 0-1
    # How many OTHER listings the median was computed from. None or below
    # MIN_COMPARABLE_LISTINGS means there is no usable benchmark.
    comparable_count: Optional[int] = None
    # The highest offer a buyer has made, when any has.
    best_offer: Optional[float] = None
    # None when the caller did not look: the listing term is then left out
    # rather than scored as a listing with no photos.
    photo_count: Optional[int] = None
    description_chars: Optional[int] = None


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
    quality: Optional[float] = None        # None when not measured
    freshness: float = 1.0                 # 1 = not stale


def _views_per_day(s: ListingSignals) -> float:
    return s.views / max(s.days_listed, 1.0)


def smoothed_save_rate(s: ListingSignals) -> float:
    """Saves per view, shrunk toward PRIOR_SAVE_RATE while views are few."""
    return ((max(s.likes, 0) + PRIOR_SAVE_RATE * PRIOR_VIEWS)
            / (max(s.views, 0) + PRIOR_VIEWS))


def offer_strength(best_offer: Optional[float], price: Optional[float]) -> Optional[float]:
    """0-1: how close the best offer is to the asking price. None: no offer."""
    if not best_offer or not price or price <= 0:
        return None
    ratio = best_offer / price
    if ratio >= STRONG_OFFER_RATIO:
        return 1.0
    if ratio <= WEAK_OFFER_RATIO:
        return 0.0
    return (ratio - WEAK_OFFER_RATIO) / (STRONG_OFFER_RATIO - WEAK_OFFER_RATIO)


def listing_quality(photo_count: Optional[int],
                    description_chars: Optional[int]) -> Optional[float]:
    """0-1 for the listing itself: photos weigh most, then the words."""
    if photo_count is None and description_chars is None:
        return None
    photos = min(max(photo_count or 0, 0), GOOD_PHOTO_COUNT) / GOOD_PHOTO_COUNT
    words = min(max(description_chars or 0, 0), GOOD_DESCRIPTION_CHARS) / GOOD_DESCRIPTION_CHARS
    return 0.7 * photos + 0.3 * words


def freshness(s: ListingSignals) -> float:
    """1.0, falling toward STALE_FLOOR as a listing nobody asks about ages.

    Only when nobody has asked: an old listing with buyers in conversation
    is not stale, it is being negotiated.
    """
    if s.interested_buyers > 0 or s.days_listed <= STALE_AFTER_DAYS:
        return 1.0
    over = (s.days_listed - STALE_AFTER_DAYS) / STALE_AFTER_DAYS
    return max(STALE_FLOOR, 1.0 - (1.0 - STALE_FLOOR) * min(over, 1.0))


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

    intent = min(1.0, smoothed_save_rate(s) / GOOD_LIKE_RATE)

    buyers = s.interested_buyers / (s.interested_buyers + INTEREST_HALF)
    offer = offer_strength(s.best_offer, s.price)
    # An offer near the price lifts the term; one far below it does not
    # drag it under what the buyers alone are worth - a lowball is still
    # a buyer.
    commitment = buyers if offer is None else max(buyers, 0.5 * buyers + 0.5 * offer)

    # Seller term: reuses the rating module's response curve so a seller
    # cannot see one reply-speed story on the dashboard and a different one
    # on their listing.
    from api.domains.trust.seller_rating import response_score
    dcr_norm = ((s.seller_dcr_percent if s.seller_dcr_percent is not None else 80.0)
                / 100.0)
    seller = 0.5 * min(max(dcr_norm, 0.0), 1.0) + 0.5 * response_score(
        s.seller_response_minutes)

    # Price and the listing term only enter the score when they were
    # measured. Otherwise their weight is REDISTRIBUTED across the others
    # rather than filled with a neutral guess - a fabricated 0.6 on 15% of
    # the score is a fabricated 9% of the answer, and it moves in the
    # direction of "this listing is fine".
    benchmark = has_price_benchmark(s)
    pfit = price_fit(s.price, s.category_median_price) if benchmark else None
    quality = listing_quality(s.photo_count, s.description_chars)

    terms = [(W_DEMAND, demand), (W_INTENT, intent), (W_COMMITMENT, commitment),
             (W_SELLER, seller)]
    if pfit is not None:
        terms.append((W_PRICE, pfit))
    if quality is not None:
        terms.append((W_QUALITY, quality))
    raw = sum(w * v for w, v in terms) / sum(w for w, _ in terms)

    fresh = freshness(s)
    raw *= fresh

    base = (s.category_sell_rate if s.category_sell_rate is not None
            else DEFAULT_CATEGORY_SELL_RATE)
    evidence = (s.views + EVIDENCE_PER_BUYER * s.interested_buyers
                + EVIDENCE_PER_SAVE * s.likes)
    confidence = min(1.0, evidence / VIEWS_FOR_FULL_CONFIDENCE)
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
        quality=round(quality, 3) if quality is not None else None,
        freshness=round(fresh, 3),
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

    offer = offer_strength(s.best_offer, s.price)
    if offer is not None and offer >= 1.0:
        pos.append({
            "code": "strong_offer", "severity": 0,
            "title": "A buyer has offered close to your price",
            "detail": f"The best offer is KES {s.best_offer:,.0f}, within "
                      f"{int(round((1 - STRONG_OFFER_RATIO) * 100))}% of what you're "
                      f"asking. Replying to it is the shortest way to a sale.",
        })

    # Saves only began to be collected on 2026-10-09, so views from before
    # then had no chance to become one. A higher bar than one day's traffic
    # keeps an old listing from being told nobody saved it when nobody could.
    if s.views >= 40 and s.likes == 0:
        neg.append({
            "code": "views_no_likes", "severity": 4,
            "title": f"{s.views} views and no saves yet",
            "detail": "People are finding it and moving on. That usually points "
                      "at the photos or the price rather than demand.",
        })
    elif s.likes >= 3 and s.views > 0 and (s.likes / s.views) >= GOOD_LIKE_RATE:
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

    if s.photo_count is not None and s.photo_count < 3:
        neg.append({
            "code": "few_photos", "severity": 4,
            "title": ("No photos" if s.photo_count == 0
                      else f"Only {s.photo_count} photo{'s' if s.photo_count != 1 else ''}"),
            "detail": f"Listings with {GOOD_PHOTO_COUNT} or more clear photos - "
                      f"front, back, close-ups, any flaws - get far more buyers "
                      f"asking. It is free and takes a minute.",
        })
    if s.description_chars is not None and s.description_chars < 40:
        neg.append({
            "code": "thin_description", "severity": 2,
            "title": "Say more about it",
            "detail": "A line or two on condition, age and what's included "
                      "answers the questions buyers would otherwise ask - or "
                      "skip the listing over.",
        })

    fresh = freshness(s)
    if fresh < 1.0:
        neg.append({
            "code": "going_stale", "severity": 3,
            "title": f"Listed {s.days_listed:.0f} days and nobody has asked",
            "detail": "Most buyers who will find a listing have found it by "
                      "now. A new main photo or a price move puts it in front "
                      "of them again.",
        })

    if (s.seller_response_minutes is not None
            and s.seller_response_minutes >= 180 and s.interested_buyers > 0):
        neg.append({
            "code": "slow_with_buyers_waiting", "severity": 5,
            "title": "Buyers asked, and you're slow to reply",
            "detail": "There is interest in this listing and your average reply "
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
