"""The monthly listing fee: f = C x R.

  C  what the listing costs to list for a month at full price: a banded
     share of its value - price x quantity - and never under the cost of
     serving it (costs.listing_month_cost). This is the "list price" a
     seller sees crossed out.
  R  the risk coefficient, 0.4-1.0: how likely this seller's deals are to
     leave BROKA before the money moves. 1.0 pays the full list price; a
     seller whose deals reliably complete through escrow pays as little as
     40% of it. Worked out from the seller's own completion record, smoothed
     toward their category's (Bayesian smoothing - see completion_estimate).
     Only while buyers pay through BROKA (quote's `discounts_apply`).

The fee never goes below what the listing costs to serve, whatever the
discount - counting only what BROKA keeps after VAT. Paying for several
months at once costs less per month (bundle_total), and the rate is fixed
for the period paid - a seller is never surprised by a fee that moved
mid-listing.

Pure functions only: no database, no I/O. service.py gathers the inputs.
Every constant is argued for in PRICING.md.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from api.domains.pricing import costs
from api.domains.pricing.categories import CategoryPricing

# ── C: the list price ────────────────────────────────────────────────────────

# The fee is charged on what the listing is worth: its price times the units
# it offers. 200 phones are 200 phones' worth of stock and pay on that, not
# on one phone's price nudged up for quantity - the old square-root-per-unit
# fee, capped per category and grown only by the log of the quantity, had 200
# KES 180k iPhones (KES 36M) paying 3.7 times what one did.
#
# Marginal bands, like income-tax brackets: each rate applies only to the
# part of the value inside its band, so the fee rises smoothly with no edge
# where one more shilling of price jumps the fee. The rates fall as value
# rises because a listing fee is paid whether or not anything sells - a flat
# percentage of KES 36M of stock would be an up-front commission with no sale
# behind it. PRICING.md §2 has the worked examples.
VALUE_BANDS: tuple[tuple[float, float], ...] = (
    (20_000, 0.0035),          # 0.35% of the first KES 20,000
    (200_000, 0.0015),         # 0.15% of KES 20,000 - 200,000
    (2_000_000, 0.0008),       # 0.08% of KES 200,000 - 2M
    (math.inf, 0.0002),        # 0.02% above KES 2M
)

# The most one listing pays for a month, however much it offers. Reached at
# about KES 43M; a seller listing that much stock wants a store.
MAX_MONTHLY_FEE = 10_000

# Only the duration advice caps quantity: stock past this clears at the same
# pace. The fee itself counts every unit.
QUANTITY_CAP = 1_000


def listing_value(unit_price: float, quantity: int = 1) -> float:
    """What the listing offers, in shillings: price x units."""
    return max(unit_price, 0.0) * max(int(quantity or 1), 1)


def value_fee(value: float) -> float:
    """The banded fee on a listing worth `value` shillings."""
    fee, lower = 0.0, 0.0
    for upper, rate in VALUE_BANDS:
        if value <= lower:
            break
        fee += (min(value, upper) - lower) * rate
        lower = upper
    return fee


def list_price(category: CategoryPricing, unit_price: float, quantity: int = 1) -> float:
    """C for the whole listing: the full monthly fee before any discount.

    Never under what serving the listing costs (with the VAT on it): a KES
    300 shirt's 0.35% is a shilling, and Zeno answering its buyers is not.
    """
    cost = costs.listing_month_cost(category.chats_per_month)
    banded = min(value_fee(listing_value(unit_price, quantity)), MAX_MONTHLY_FEE)
    return max(costs.with_vat(cost), banded)


# ── R: the risk coefficient ──────────────────────────────────────────────────

# How many deals' worth of weight the category's completion rate carries.
# A seller's own record outweighs it once they have more than ten deals -
# Part XVI of the design journal's bar for trusting a seller's own record.
PRIOR_WEIGHT = 10.0


def completion_estimate(
    category_rate: float, completed_weight: float, leaked_weight: float,
    quality: float = 1.0, prior_weight: float = PRIOR_WEIGHT,
) -> float:
    """The completion rate BROKA prices on: the seller's own, smoothed.

    Bayesian smoothing, in plain terms: before anything is known about a
    seller, assume they behave like their category - PRIOR_WEIGHT imaginary
    deals completed at the category's rate. Every real deal is then added on
    top. A new seller is priced like their category; a seller with 100 deals
    is priced almost entirely on their own record.

    That is what keeps a seller who completed 2 of 2 from beating one who
    completed 98 of 100: (2 + 10 x 0.80) / (2 + 10) = 83% against
    (98 + 8) / (100 + 10) = 96%. Raw rates would have said 100% against 98%.

    `quality` (0-1) discounts completed deals that look farmed - all with
    one buyer, or all below KES 500 (trust/seller_rating.quality_factor) -
    so they buy little. Leaked deals are never discounted.
    """
    completed = max(completed_weight, 0.0) * min(max(quality, 0.0), 1.0)
    leaked = max(leaked_weight, 0.0)
    return (completed + prior_weight * category_rate) / (completed + leaked + prior_weight)


def own_record_share(completed_weight: float, leaked_weight: float, quality: float = 1.0,
                     prior_weight: float = PRIOR_WEIGHT) -> float:
    """How much of completion_estimate comes from the seller's own deals, 0-1."""
    own = max(completed_weight, 0.0) * min(max(quality, 0.0), 1.0) + max(leaked_weight, 0.0)
    return own / (own + prior_weight)


# The discount curve. A smooth S rather than bands: a band edge ("90% and
# above pays half") is worth gaming - a seller at 89% farms one fake deal to
# cross it - and a curve has no edge to game. Centred on a 70% completion
# rate, it flattens near the top so the last few points are worth little,
# and near the bottom so a poor record cannot go below the full list price.
DISCOUNT_MAX = 0.60
DISCOUNT_MIDPOINT = 0.70
DISCOUNT_SLOPE = 10.0


def risk_coefficient(completion_rate: float) -> float:
    """R: 1.0 = full list price; 0.4 = the best a seller can reach."""
    x = DISCOUNT_SLOPE * (completion_rate - DISCOUNT_MIDPOINT)
    return 1.0 - DISCOUNT_MAX * (1.0 / (1.0 + math.exp(-x)))


# ── The launch offer ─────────────────────────────────────────────────────────

# Until a category has real trade, every listing in it is cheaper - the
# design journal's cold-start subsidy (Parts XV-XVI), on the listing fee
# where it answers "why pay when Jiji is free". It fades smoothly as the
# category completes deals: 30% off at the start, 11% after 100 completed
# deals, gone (under 1%) after about 340. No cutoff date to rush toward.
LAUNCH_DISCOUNT_MAX = 0.30
LAUNCH_DISCOUNT_DEALS = 100.0


def launch_discount(completed_deals_in_category: int) -> float:
    d = LAUNCH_DISCOUNT_MAX * math.exp(-max(completed_deals_in_category, 0) / LAUNCH_DISCOUNT_DEALS)
    return d if d >= 0.01 else 0.0


# ── Money shapes ─────────────────────────────────────────────────────────────

def round_kes(amount: float) -> int:
    """Whole shillings; to the nearest 5 from KES 100 and 10 from KES 1,000.

    Round half up, so a price never lands a shilling under its floor by
    banker's rounding.
    """
    if amount >= 1_000:
        step = 10
    elif amount >= 100:
        step = 5
    else:
        step = 1
    return int(math.floor(amount / step + 0.5) * step)


def monthly_fee(list_price_: float, risk: float, launch: float, cost: float) -> int:
    """This seller's price for one month: list x R x launch offer, never under cost.

    "Under cost" is judged on what BROKA keeps once VAT is taken out
    (costs.VAT_RATE), so the floor holds after VAT registration too.
    """
    discounted = list_price_ * risk * (1.0 - launch)
    # The floor is rounded UP and applied after rounding: rounding a fee
    # that sits on the floor to the nearest shilling would otherwise land
    # it under cost (7.12 -> 7).
    floor = math.ceil(costs.with_vat(cost + costs.mpesa_collection_cost(discounted)))
    fee = max(round_kes(discounted), floor)
    return min(fee, max(round_kes(list_price_), math.ceil(costs.with_vat(cost))))


# Paying for months together: the total grows as months^0.83, so 2 months
# cost 1.78x one month, 3 cost 2.49x and 6 cost 4.42x - the "100 for one,
# 180 for two, 250 for three" shape, which makes the longer option the
# easier yes. Never below the cost of serving the listing that long.
MAX_MONTHS = 6
BUNDLE_EXPONENT = 0.83


def bundle_total(monthly: int, months: int, cost: float) -> int:
    total = round_kes(monthly * months ** BUNDLE_EXPONENT)
    floor = math.ceil(costs.with_vat(months * cost + costs.mpesa_collection_cost(total)))
    return max(total, floor)


# ── How long to list ─────────────────────────────────────────────────────────

# Pricier than the category's typical item takes longer to sell (^0.3); more
# units take longer to clear (^0.35); and the recommendation covers 20% more
# than the expected wait, so the listing is still up when the buyer comes.
PRICE_ELASTICITY = 0.3
QUANTITY_ELASTICITY = 0.35
SAFETY_MARGIN = 1.2
# From this listing value up, a long listing is pressed rather than offered:
# a seller of land or a car who lists for a month and gives up has lost a
# sale BROKA could have made.
STRONG_RECOMMENDATION_VALUE = 250_000


@dataclass(frozen=True)
class DurationAdvice:
    months: int
    expected_days: int
    strength: str        # "none" | "suggested" | "strong"


def recommend_months(category: CategoryPricing, unit_price: float, quantity: int = 1) -> DurationAdvice:
    price_ratio = max(unit_price, 1.0) / max(category.typical_price, 1)
    q = min(max(int(quantity or 1), 1), QUANTITY_CAP)
    days = category.days_to_sell * price_ratio ** PRICE_ELASTICITY * q ** QUANTITY_ELASTICITY
    months = min(MAX_MONTHS, max(1, math.ceil(days * SAFETY_MARGIN / 30)))
    if months == 1:
        strength = "none"
    elif months >= 3 and unit_price * q >= STRONG_RECOMMENDATION_VALUE:
        strength = "strong"
    else:
        strength = "suggested"
    return DurationAdvice(months=months, expected_days=max(1, round(days)), strength=strength)


# ── The quote ────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class SellerRecord:
    """A seller's deals as the risk coefficient needs them (service.py)."""
    completed_weight: float = 0.0   # recency-weighted deals completed through escrow
    leaked_weight: float = 0.0      # recency-weighted deals that left BROKA
    quality: float = 1.0            # trust/seller_rating.quality_factor
    completed_deals: int = 0
    leaked_deals: int = 0


def quote(
    category: CategoryPricing, unit_price: float, quantity: int,
    record: SellerRecord, category_completed_deals: int,
    discounts_apply: bool = True,
) -> dict:
    """Everything the sell screen shows: list price, today's price, why, and 1-6 months.

    `discounts_apply` is False while buyers pay sellers outside BROKA
    (IN_APP_PAYMENTS_ENABLED off): R and the launch offer are both measured
    in deals completed through BROKA's escrow, and with no such deals
    possible they would only price every seller on a guess.
    """
    quantity = max(int(quantity or 1), 1)
    cost = costs.listing_month_cost(category.chats_per_month)
    full = list_price(category, unit_price, quantity)
    list_kes = max(round_kes(full), math.ceil(costs.with_vat(cost)))

    rate = completion_estimate(category.prior_completion, record.completed_weight,
                               record.leaked_weight, record.quality)
    risk = risk_coefficient(rate) if discounts_apply else 1.0
    launch = launch_discount(category_completed_deals) if discounts_apply else 0.0
    fee = monthly_fee(full, risk, launch, cost)

    advice = recommend_months(category, unit_price, quantity)
    options = []
    for months in range(1, MAX_MONTHS + 1):
        total = fee if months == 1 else bundle_total(fee, months, cost)
        options.append({
            "months": months,
            "total": total,
            "per_month": round(total / months, 2),
            "saving_percent": max(0, round(100 * (1 - total / (fee * months)))),
            "recommended": months == advice.months,
        })

    return {
        "category": category.name,
        "unit_price": unit_price,
        "quantity": quantity,
        "listing_value": listing_value(unit_price, quantity),
        "currency": "KES",
        "list_price": list_kes,
        "max_monthly_fee": MAX_MONTHLY_FEE,
        "monthly_fee": fee,
        "discount_percent": max(0, round(100 * (1 - fee / list_kes))) if list_kes else 0,
        "discounts": {
            "apply": discounts_apply,
            "record_percent": round(100 * (1 - risk)),
            "launch_percent": round(100 * launch),
        },
        "risk": {
            "coefficient": round(risk, 3),
            "completion_rate": round(rate, 3),
            "category_completion_rate": category.prior_completion,
            "own_record_share": round(own_record_share(
                record.completed_weight, record.leaked_weight, record.quality), 3),
            "completed_deals": record.completed_deals,
            "leaked_deals": record.leaked_deals,
        },
        "cost_to_serve": round(cost, 2),
        "options": options,
        "recommendation": {
            "months": advice.months,
            "expected_days_to_sell": advice.expected_days,
            "strength": advice.strength,
        },
    }
