"""Premium plans, store plans and commission - the prices, and the costs they cover.

THE RULE EVERY PRICE HERE FOLLOWS
=================================
Prices include VAT. What BROKA keeps of a monthly price once VAT is taken
out is at least 1.25x what the plan costs BROKA when its holder uses every
allowance to the last unit (max_monthly_cost). So:

  * no subscriber, however heavy, is served at a loss, before or after
    BROKA registers for VAT;
  * a typical subscriber (about a third of the allowances) leaves ~70%;
  * a longer prepaid period may cut the price, but never below that
    maxed-out cost.

The rule is a floor, not the price. Where a price sits above it is set
by what the feature is worth next to what Kenyans already pay for (PRICING.md
§4 and §5), not by cost alone.

The allowances are fair-use caps, not "unlimited": voice minutes and
auto-negotiations cost real money per use (costs.py), and an unlimited plan
priced for the average user is a plan the heaviest users make unprofitable.

tests/test_pricing.py checks the rule for every plan and period, so a price
cut that would lose money fails CI rather than reaching users.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

from api.core.config import settings
from api.domains.pricing import costs
from api.domains.pricing.categories import for_category

MIN_MARGIN_MULTIPLE = 1.25

# Prepaying: 3 months 8% off, 6 months 15%, 12 months 20%. Shallower than
# the listing-fee curve on purpose: a listing's cost is fixed once it is up,
# but a plan's allowances renew every month, so its cost grows with every
# month prepaid.
PLAN_PERIODS: dict[int, float] = {1: 0.0, 3: 0.08, 6: 0.15, 12: 0.20}


def charm(amount: float) -> int:
    """To the nearest ten, less one: 1,101 -> 1,099; 2,035 -> 2,039."""
    return max(1, int(math.floor(amount / 10 + 0.5)) * 10 - 1)


def period_prices(monthly: int) -> list[dict]:
    out = []
    for months, off in PLAN_PERIODS.items():
        total = monthly if months == 1 else charm(monthly * months * (1 - off))
        out.append({
            "months": months,
            "total": total,
            "per_month": round(total / months, 2),
            "saving_percent": round(100 * (1 - total / (monthly * months))),
        })
    return out


# ── Premium ──────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class PremiumPlan:
    """A plan's monthly allowances. Each counts a thing that costs BROKA
    money every time it happens, so each is a number, not "unlimited"."""
    id: str
    name: str
    monthly_price: int
    pitch: str
    voice_requests: int             # things said to Zeno in voice mode
    sms_alerts: int                 # texts Zeno sends: a buyer waiting, a message you asked it to send
    agent_watches: int              # Buying Agent watches running at once (not a monthly count)
    auto_negotiations: int          # sellers Zeno opens a negotiation with for you
    ai_covers: int                  # AI cover tries while posting listings
    auctions_hosted: int            # auctions you start (bidding is free for everyone)
    ai_descriptions: int = 0        # descriptions Zeno writes from a listing's photo
    price_checks: int = 0           # Zeno pricing a listing against similar ones on BROKA
    priority_support_minutes: int = 0

    def max_monthly_cost(self) -> float:
        usage = (
            self.voice_requests * costs.VOICE_REQUEST
            + self.sms_alerts * costs.SMS
            + self.agent_watches * costs.AGENT_WATCH_MONTH
            + self.auto_negotiations * costs.AI_PER_AUTO_NEGOTIATION
            + self.ai_covers * costs.AI_SHOWCASE_IMAGE
            + self.auctions_hosted * costs.AUCTION_HOSTED
            + self.ai_descriptions * costs.AI_LISTING_DESCRIPTION
            + self.price_checks * costs.AI_PRICE_CHECK
            + self.priority_support_minutes * costs.SUPPORT_PER_MINUTE
        )
        return usage * costs.OVERHEAD + costs.mpesa_collection_cost(self.monthly_price)

    def allowance(self, feature: str) -> int:
        return int(getattr(self, feature))

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "pitch": self.pitch,
            "monthly_price": self.monthly_price,
            "periods": period_prices(self.monthly_price),
            "allowances": {
                "voice_requests": self.voice_requests,
                "sms_alerts": self.sms_alerts,
                "agent_watches": self.agent_watches,
                "auto_negotiations": self.auto_negotiations,
                "ai_covers": self.ai_covers,
                # What the tries come to in listings: a seller thinks in
                # "covers for how many listings", not in model calls. Rounded,
                # not floored: the app says "about", and 20 tries are nearer
                # 7 listings than 6.
                "ai_cover_listings": round(self.ai_covers / costs.AI_COVER_TRIES_PER_LISTING),
                "auctions_hosted": self.auctions_hosted,
                "ai_descriptions": self.ai_descriptions,
                "price_checks": self.price_checks,
                "priority_support_minutes": self.priority_support_minutes,
            },
        }


# AI covers are made while posting, a few tries per listing, at KES 5.18 a
# try - the most expensive allowance per use after a support minute. They
# are sized in listings (AI_COVER_TRIES_PER_LISTING tries each): Plus about
# 2 listings a month, Pro about 7, Elite about 20.
#
# 199 / 599 / 1,499 include VAT. At the earlier 169 / 499 / 1,249, VAT
# would leave a maxed-out subscriber costing BROKA about what they pay
# (1.1x). The new prices sit where Kenyans already pay for a digital
# subscription - Netflix Kenya KES 200-1,100, Spotify KES 419 - and one
# negotiation Zeno wins for a Pro buyer (5% off a KES 20,000 phone) is
# worth more than the month.
#
# Zeno's selling help (2026-10-05) is what the listing wizard offers to
# make a listing sell faster: a description written from the photo on
# every plan, and price checks against similar BROKA listings from Pro up -
# "pro sellers" are who it is for. Both cost cents a use (costs.py), so the
# allowances are sized for a busy seller, not for the margin.
PREMIUM_PLANS: tuple[PremiumPlan, ...] = (
    PremiumPlan(
        id="plus", name="Plus", monthly_price=199,
        pitch="Zeno writes your listings from their photos, gives them AI covers, "
              "talks with you and texts you when a buyer is waiting.",
        voice_requests=90, sms_alerts=30, agent_watches=1, auto_negotiations=0,
        ai_covers=6, auctions_hosted=0, ai_descriptions=30,
    ),
    PremiumPlan(
        id="pro", name="Pro", monthly_price=599,
        pitch="Zeno prices your listings against the market, hunts and haggles for you, "
              "covers for a week of listings, and your own auctions.",
        voice_requests=180, sms_alerts=80, agent_watches=3, auto_negotiations=25,
        ai_covers=20, auctions_hosted=2, ai_descriptions=100, price_checks=40,
    ),
    PremiumPlan(
        id="elite", name="Elite", monthly_price=1499,
        pitch="Everything, in volume - for people who buy and sell for a living.",
        voice_requests=360, sms_alerts=150, agent_watches=10, auto_negotiations=50,
        ai_covers=60, auctions_hosted=5, ai_descriptions=300, price_checks=150,
        priority_support_minutes=15,
    ),
)
PREMIUM_BY_ID: dict[str, PremiumPlan] = {p.id: p for p in PREMIUM_PLANS}

# What someone without a plan may try before being asked to subscribe: one
# AI cover, once. About KES 5 - an acquisition cost, and the only way a
# seller learns what a cover does to a listing before paying for more.
FREE_TRIAL: dict[str, int] = {"ai_covers": 1}


# ── Stores ───────────────────────────────────────────────────────────────────

# Opening a store, once. Covers reviewing it and an onboarding call, and
# puts a price on a store name so names are not squatted. Waived when the
# first payment covers six months or more.
STORE_SETUP_FEE = 299
STORE_SETUP_WAIVED_FROM_MONTHS = 6

# What one listing slot in a store costs at full use: a listing drawing an
# average category's demand (one negotiation a month).
STORE_SLOT_MONTH = costs.listing_month_cost(1.0)

# Texts for new buyers and orders: one a month per listing, up to this many.
STORE_SMS_CAP = 300


@dataclass(frozen=True)
class StorePlan:
    id: str
    name: str
    monthly_price: int
    listings: int          # listings the plan covers - no listing fee on these
    sms_alerts: int        # texts for new orders and new buyers
    slot_cost: float = STORE_SLOT_MONTH   # one listing's cost at full use, by trade
    trade: str = "goods"

    def max_monthly_cost(self) -> float:
        return (
            (costs.STORE_MONTH + self.sms_alerts * costs.SMS) * costs.OVERHEAD
            + self.listings * self.slot_cost
            + costs.mpesa_collection_cost(self.monthly_price)
        )

    def to_dict(self) -> dict:
        periods = period_prices(self.monthly_price)
        for p in periods:
            p["setup_fee"] = 0 if p["months"] >= STORE_SETUP_WAIVED_FROM_MONTHS else STORE_SETUP_FEE
        return {
            "id": self.id,
            "name": self.name,
            "trade": self.trade,
            "monthly_price": self.monthly_price,
            "listings": self.listings,
            "price_per_listing": round(self.monthly_price / self.listings, 2),
            "sms_alerts": self.sms_alerts,
            "periods": periods,
        }


@dataclass(frozen=True)
class StoreRateCard:
    """What a store costs for however many listings its owner picks.

    The base price covers the first `included` listings; each listing past
    that adds the rate of its band, and the rates fall as the store grows.
    Bands like the listing fee's, so one more listing never jumps the price:
    the fixed plans this replaces did (listing 21 moved a store from 499 to
    999), and a seller with 40 listings had to buy 50.

    Priced by count, not by the stock's value. Count is something BROKA can
    see; value is whatever the seller types, and tiers on it had cliffs
    that put a shop's 16th phone up KES 1,000 a month
    (BUSINESS_MODEL_REVIEW.md section 6). Value comes in through the trade
    instead: a car yard's card prices a slot well above a phone shop's.
    """
    id: str
    name: str
    included: int                          # listings the base price covers
    base_price: int
    bands: tuple[tuple[int, int], ...]     # (up to this many listings, KES a listing in the band)
    max_listings: int                      # the most the app sells; above it, priced by hand
    categories: tuple[str, ...] = ()       # what it may hold; () = everything no other card takes
    # A vehicle or property store with a single KES 20M house would undercut
    # that house's own listing fee (KES 7,840 a month against 2,999), so a
    # store of those trades is a dealer's or an agent's: store billing must
    # hold it to this many live listings.
    min_listings: int = 1
    slot_cost: float = STORE_SLOT_MONTH

    def price(self, listings: int) -> int:
        n = min(max(int(listings), 1), self.max_listings)
        total, lower = self.base_price, self.included
        for upper, rate in self.bands:
            if n <= lower:
                break
            total += (min(n, upper) - lower) * rate
            lower = upper
        return total

    def plan(self, listings: int) -> StorePlan:
        """The plan for `listings`, never smaller than what the base price covers."""
        n = min(max(int(listings), self.included), self.max_listings)
        return StorePlan(
            id=f"{self.id}-{n}", name=f"{self.name}, {n} listings",
            monthly_price=self.price(n), listings=n,
            sms_alerts=min(n, STORE_SMS_CAP), slot_cost=self.slot_cost, trade=self.id,
        )

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "included_listings": self.included,
            "base_price": self.base_price,
            "per_listing_bands": [{"up_to": up, "price": rate} for up, rate in self.bands],
            "min_listings": self.min_listings,
            "max_listings": self.max_listings,
            "categories": list(self.categories),
        }


def _slot_cost(category: str) -> float:
    return costs.listing_month_cost(for_category(category).chats_per_month)


# VAT included. A goods store is KES 599 for up to 30 listings (the founder's
# call, 2026-10-06: 20 a month for each, a fifth of what a KES 20,000 phone
# pays listed alone), then 16 a listing to 100, 14 to 250 and 12 to 1,000:
# 40 listings 759, 100 listings 1,719, 500 listings 6,819 - each size at or
# under the fixed plans it replaces. Car yards and agents start at 2,999 for
# 10: KES 167-300 a car, against ~866 a month for a KABA member's Sunday spot
# at Jamhuri and 1,120 for one KES 800,000 car listed alone; Househunt
# charges agents 10,000 for 20 listings. tests/test_pricing.py checks the
# margin rule at every size of every card.
STORE_RATE_CARDS: tuple[StoreRateCard, ...] = (
    StoreRateCard(id="goods", name="Store", included=30, base_price=599,
                  bands=((100, 16), (250, 14), (1_000, 12)), max_listings=1_000),
    StoreRateCard(id="vehicles", name="Car yard", included=10, base_price=2_999,
                  bands=((25, 200), (60, 114), (200, 100)), max_listings=200,
                  categories=("Automobiles",), min_listings=5,
                  slot_cost=_slot_cost("Automobiles")),
    StoreRateCard(id="property", name="Agent", included=10, base_price=2_999,
                  bands=((30, 150), (100, 57), (300, 50)), max_listings=300,
                  categories=("Property", "Land"), min_listings=5,
                  slot_cost=_slot_cost("Property")),
)
STORE_RATE_CARDS_BY_ID: dict[str, StoreRateCard] = {c.id: c for c in STORE_RATE_CARDS}

# Sizes shown as examples next to the cards; any size in between is sold too.
STORE_PLANS: tuple[StorePlan, ...] = tuple(
    STORE_RATE_CARDS_BY_ID[card].plan(n)
    for card, sizes in (("goods", (30, 50, 100, 250, 500, 1_000)),
                        ("vehicles", (10, 25, 60, 200)),
                        ("property", (10, 30, 100, 300)))
    for n in sizes
)


# ── Commission ───────────────────────────────────────────────────────────────

def commission() -> dict:
    """What a buyer pays on top of the price, and whose it is.

    The escrow provider's 1% is E-Confirm's, passed through untouched; only
    BROKA's share is BROKA's to discount. BROKA's share is never under
    `broka_minimum_kes` (escrow/service.py _commission).
    """
    provider = settings.escrow_provider_fee_rate
    minimum = settings.commission_minimum_kes
    return {
        "negotiated": {
            "broka_percent": round(100 * settings.commission_rate, 2),
            "broka_minimum_kes": minimum,
            "escrow_provider_percent": round(100 * provider, 2),
            "total_percent": round(100 * (settings.commission_rate + provider), 2),
        },
        "auction": {
            "broka_percent": round(100 * settings.auction_commission_rate, 2),
            "broka_minimum_kes": minimum,
            "escrow_provider_percent": round(100 * provider, 2),
            "total_percent": round(100 * (settings.auction_commission_rate + provider), 2),
        },
    }


def catalog() -> dict:
    return {
        "currency": "KES",
        "premium": [p.to_dict() for p in PREMIUM_PLANS],
        "free_trial": FREE_TRIAL,
        "stores": {
            "setup_fee": STORE_SETUP_FEE,
            "setup_fee_waived_from_months": STORE_SETUP_WAIVED_FROM_MONTHS,
            # Any size is sold: GET /pricing/store-plan prices the one a
            # seller picks. `plans` are examples along each card.
            "rate_cards": [c.to_dict() for c in STORE_RATE_CARDS],
            "plans": [s.to_dict() for s in STORE_PLANS],
        },
        "commission": commission(),
        # False while buyers pay sellers outside BROKA: no commission is
        # charged, so the app must not show the rates above as a price.
        "commission_charged": settings.in_app_payments_enabled,
    }
