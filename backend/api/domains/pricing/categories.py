"""Per-category pricing parameters - BROKA's starting guesses, to be replaced by data.

There are no completed deals yet, so every number here is a hypothesis with
its reasoning written next to it (PRICING.md, "The category table"). They
are grouped in one table so that replacing a guess with a measurement is a
one-line change, and the listing-fee engine never hardcodes a category.

  prior_completion  The share of this category's agreed deals expected to
                    complete THROUGH BROKA (a deal only completes if the
                    money goes through escrow). It is what a seller with no
                    record of their own is assumed to do, and the value every
                    seller's own record is smoothed toward. Low where the
                    trade habitually settles off-platform: land and property
                    close through advocates and agents, cars need an
                    inspection and a logbook transfer, services are paid
                    after the job. High where escrow answers a real fear:
                    phones are the most-scammed item in Nairobi's online
                    groups. Replace with the measured rate once a category
                    has ~200 completed deals.
  chats_per_month   Buyer negotiations one listing attracts in 30 days - the
                    driver of Zeno's cost for it.
  max_fee           The most one unit of a listing in this category ever
                    pays for a month, however valuable. The "list price"
                    ceiling a seller's discount is measured from.
  days_to_sell      How long a typical item takes to find a buyer - drives
                    the duration recommendation.
  typical_price     A middle-of-the-market price, so pricier items are
                    recommended longer listings than cheap ones.
  memory_days       Half-life of a deal's influence on the completion rate
                    used for pricing. Twice as long for categories whose
                    deals are rare (land, cars, property), so a seller's
                    last plot sale is not forgotten before the next one.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class CategoryPricing:
    name: str
    prior_completion: float
    chats_per_month: float
    max_fee: int
    days_to_sell: int
    typical_price: int
    memory_days: int = 180


_TABLE = [
    #               name                  prior  chats   max  days     typical  memory
    # Land, cars and property cap at KES 3,000 a month: at 1,500 the square
    # root of the price hit the cap at KES 2.25M, so a KES 20M house paid
    # what a KES 2.25M plot did. Nothing under KES 2.25M is affected.
    CategoryPricing("Automobiles",          0.45,  2.5, 3000,   60,    800_000, 360),
    CategoryPricing("Property",             0.40,  2.5, 3000,   75,  3_000_000, 360),
    CategoryPricing("Land",                 0.35,  2.0, 3000,  120,  1_500_000, 360),
    CategoryPricing("Electronics",          0.80,  1.5,  400,   14,     20_000),
    CategoryPricing("Fashion",              0.70,  0.8,  100,   10,      1_500),
    CategoryPricing("Agriculture",          0.50,  1.2,  600,   21,     10_000),
    CategoryPricing("Home & Furniture",     0.62,  1.0,  300,   30,     15_000),
    CategoryPricing("Food & Beverages",     0.55,  0.8,  100,    5,      1_000),
    CategoryPricing("Construction",         0.55,  1.0,  600,   30,     20_000),
    CategoryPricing("Beauty & Personal Care", 0.70, 0.6, 100,   10,      1_500),
    CategoryPricing("Health & Medical",     0.68,  0.6,  200,   14,      3_000),
    CategoryPricing("Baby & Kids",          0.72,  0.8,  150,   14,      3_000),
    CategoryPricing("Gaming",               0.80,  1.2,  300,   14,     15_000),
    CategoryPricing("Sports & Fitness",     0.72,  0.8,  200,   21,      5_000),
    CategoryPricing("Books & Education",    0.72,  0.5,  100,   21,      1_000),
    CategoryPricing("Music & Instruments",  0.72,  0.8,  300,   30,     15_000),
    CategoryPricing("Arts & Crafts",        0.72,  0.6,  150,   30,      3_000),
    CategoryPricing("Business & Industrial", 0.55, 1.0,  800,   45,    100_000),
    CategoryPricing("Pets & Animals",       0.55,  1.0,  400,   14,     10_000),
    CategoryPricing("Services",             0.45,  1.0,  300,   30,      3_000),
    CategoryPricing("Other",                0.65,  0.8,  200,   21,      3_000),
]

CATEGORIES: dict[str, CategoryPricing] = {c.name: c for c in _TABLE}
FALLBACK = CATEGORIES["Other"]

# Names listings may still carry from before the 2026-09-25 taxonomy
# (categories/seed.py RENAMED_CATEGORIES).
_ALIASES = {"vehicles": "Automobiles"}
_BY_KEY = {c.name.casefold(): c for c in _TABLE}


def stored_names(category: CategoryPricing) -> set[str]:
    """Every Listing.category value (lowercased) that means this category."""
    names = {category.name.casefold()}
    names.update(old for old, new in _ALIASES.items() if new == category.name)
    return names


def for_category(name: Optional[str]) -> CategoryPricing:
    """The parameters for a listing's category; "Other" for anything unknown.

    Listing.category is the top-level name, but older listings and
    hand-typed requests vary in case and spacing - and an unknown name must
    still get a price rather than an error.
    """
    key = (name or "").strip().casefold()
    key = _ALIASES.get(key, key).casefold()
    return _BY_KEY.get(key, FALLBACK)
