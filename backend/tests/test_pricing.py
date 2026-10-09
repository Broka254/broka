"""Pricing (PRICING.md): the listing fee f = C x R, the plans, and commission.

Every test here pins a claim PRICING.md makes to sellers or to the founders -
"a proven seller pays less than a new one", "no plan loses money on its
heaviest user", "the fee never goes below what the listing costs" - so a
constant tuned later cannot quietly break one of them.
"""
import math
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, ListingType, SellerTier, User,
    init_db, reset_engine,
)
from api.domains.categories import seed
from api.domains.pricing import costs, engine, plans
from api.domains.pricing.categories import CATEGORIES, FALLBACK, for_category
from api.security import create_access_token

ELECTRONICS = CATEGORIES["Electronics"]
LAND = CATEGORIES["Land"]
FASHION = CATEGORIES["Fashion"]
NEW = engine.SellerRecord()


def _fee(record, category=ELECTRONICS, price=20_000, quantity=1, in_category=10_000):
    return engine.quote(category, price, quantity, record, in_category)


# ── R: the risk coefficient ──────────────────────────────────────────────────

class TestRiskCoefficient:
    def test_proven_seller_pays_less_than_a_perfect_newcomer(self):
        """The unfairness the founder named: 2 of 2 must not beat 98 of 100.

        Raw completion rates say 100% against 98%. Smoothed toward the
        category they say 83% against 96%, and the veteran pays less.
        """
        newcomer = engine.SellerRecord(completed_weight=2, completed_deals=2)
        veteran = engine.SellerRecord(completed_weight=98, leaked_weight=2,
                                      completed_deals=98, leaked_deals=2)
        assert engine.completion_estimate(0.80, 2, 0) == pytest.approx(10 / 12)
        assert engine.completion_estimate(0.80, 98, 2) == pytest.approx(106 / 110)
        assert _fee(veteran)["monthly_fee"] < _fee(newcomer)["monthly_fee"]

    def test_a_new_seller_is_priced_as_their_category(self):
        assert engine.completion_estimate(0.35, 0, 0) == pytest.approx(0.35)
        assert _fee(NEW, LAND, 1_500_000)["risk"]["completion_rate"] == LAND.prior_completion
        assert _fee(NEW)["risk"]["own_record_share"] == 0

    def test_the_category_barely_moves_an_established_seller(self):
        """A good furniture seller must not be punished for furniture's rate."""
        in_good_category = engine.completion_estimate(0.80, 100, 2)
        in_poor_category = engine.completion_estimate(0.35, 100, 2)
        assert in_good_category - in_poor_category < 0.05

    def test_leaking_deals_raises_the_fee(self):
        clean = engine.SellerRecord(completed_weight=20, completed_deals=20)
        leaky = engine.SellerRecord(completed_weight=20, leaked_weight=15,
                                    completed_deals=20, leaked_deals=15)
        assert _fee(leaky)["monthly_fee"] > _fee(clean)["monthly_fee"]

    def test_farmed_deals_buy_little(self):
        """Ten deals with one buyer under KES 500 (quality ~0.3) are not ten deals."""
        honest = engine.SellerRecord(completed_weight=10, quality=1.0, completed_deals=10)
        farmed = engine.SellerRecord(completed_weight=10, quality=0.3, completed_deals=10)
        assert _fee(farmed)["risk"]["coefficient"] > _fee(honest)["risk"]["coefficient"]

    def test_r_is_bounded_and_falls_smoothly_as_the_record_improves(self):
        rates = [i / 100 for i in range(0, 101)]
        rs = [engine.risk_coefficient(r) for r in rates]
        assert all(a > b for a, b in zip(rs, rs[1:])), "strictly falling - no flat bands to game"
        assert max(rs) <= 1.0 and min(rs) >= 1 - engine.DISCOUNT_MAX
        # No step anywhere worth farming a deal to cross.
        assert max(a - b for a, b in zip(rs, rs[1:])) < 0.02


# ── C: the list price ────────────────────────────────────────────────────────

class TestListPrice:
    def test_the_fee_is_charged_on_price_times_quantity(self):
        """The founder's case: 200 iPhones are not 3 iPhones.

        Regression: the fee used to be the square root of ONE unit's price,
        capped per category, grown only by the log of the quantity. Now the
        fee is on the listing's whole value, up to the monthly ceiling.
        """
        one = engine.list_price(ELECTRONICS, 180_000, 1)
        three = engine.list_price(ELECTRONICS, 180_000, 3)
        two_hundred = engine.list_price(ELECTRONICS, 180_000, 200)
        assert one < three < two_hundred == engine.MAX_MONTHLY_FEE
        # Only the value counts: ten KES 20k phones are one KES 200k item.
        assert engine.list_price(ELECTRONICS, 20_000, 10) == engine.list_price(ELECTRONICS, 200_000, 1)

    @pytest.mark.parametrize("x, f", [
        # The founder's own test values (2026-10-09), from their reference
        # implementation of f(x) = 8.91822 x cbrt(x) - 42.1011 in [10, 2000].
        (0, 10.0),
        (100, 10.0),
        (200, 10.053),
        (1_500, 59.987),
        (10_000, 150.036),
        (20_000, 199.977),
        (1_000_000, 849.721),
        (12_000_000, 1_999.662),
        (20_000_000, 2_000.0),
    ])
    def test_one_month_is_the_founders_cube_root(self, x, f):
        assert engine.value_fee(x) == pytest.approx(f, abs=0.001)

    @pytest.mark.parametrize("price, quantity, fee", [
        (1_500, 1, 60),             # a dress (10 on the old value bands)
        (20_000, 1, 200),           # a phone (100)
        (180_000, 1, 460),          # an iPhone (420)
        (180_000, 3, 685),          # three of them (835)
        (180_000, 200, 2_000),      # two hundred (12,640)
        (800_000, 1, 785),          # a car (1,120)
        (1_500_000, 1, 980),        # a plot (1,890)
    ])
    def test_the_worked_examples_in_pricing_md(self, price, quantity, fee):
        assert engine.round_kes(engine.list_price(ELECTRONICS, price, quantity)) == fee

    def test_the_fee_rises_smoothly_with_no_step_to_game(self):
        values = sorted([10 ** e for e in range(2, 10)] + [12_000_000])
        fees = [engine.value_fee(v) for v in values]
        assert all(a <= b for a, b in zip(fees, fees[1:]))
        assert all(engine.MIN_MONTHLY_FEE <= f <= engine.MAX_MONTHLY_FEE for f in fees)
        # Between the floor and the ceiling a shilling more never jumps it.
        for v in (300, 20_000, 1_000_000, 11_000_000):
            assert 0 < engine.value_fee(v + 1) - engine.value_fee(v) < 0.1

    def test_the_monthly_ceiling_holds_however_valuable_the_listing(self):
        for c in CATEGORIES.values():
            assert engine.list_price(c, 10**9, 100) == engine.MAX_MONTHLY_FEE == 2_000

    def test_quantity_is_not_capped_for_the_fee(self):
        """QUANTITY_CAP limits only the duration advice; 5,000 units are priced as 5,000."""
        assert engine.quote(ELECTRONICS, 1_000, 5_000, NEW, 0)["quantity"] == 5_000
        assert engine.list_price(ELECTRONICS, 1_000, 5_000) > engine.list_price(ELECTRONICS, 1_000, 1_000)

    def test_cheap_items_pay_ten_shillings_or_the_cost_of_serving_them(self):
        """KES 10 is the least f gives; where serving the listing costs more
        than that (Zeno answers more buyers for cars and property), the cost."""
        assert engine.list_price(FASHION, 100) == engine.MIN_MONTHLY_FEE
        assert engine.list_price(FASHION, 300) == pytest.approx(engine.value_fee(300))
        cars = CATEGORIES["Automobiles"]
        cost = costs.with_vat(costs.listing_month_cost(cars.chats_per_month))
        assert cost > engine.MIN_MONTHLY_FEE
        assert engine.list_price(cars, 100) == pytest.approx(cost)

    def test_never_below_what_the_listing_costs(self):
        """The best record plus the full launch offer still covers the cost -
        with what BROKA keeps once VAT is taken out.

        Regression: a fee sitting on the floor (KES 7.12) rounded to the
        nearest shilling came out at KES 7 - under cost. With VAT the floor
        is 7.12 x 1.16 = 8.26, so 9.
        """
        best = engine.SellerRecord(completed_weight=500, completed_deals=500)
        for c in CATEGORIES.values():
            for price in (10, 300, 5_000, 2_000_000):
                q = engine.quote(c, price, 1, best, 0)
                cost = costs.listing_month_cost(c.chats_per_month)
                assert costs.net_of_vat(q["monthly_fee"]) >= cost
                assert all(costs.net_of_vat(o["total"]) >= o["months"] * cost for o in q["options"])
        assert engine.monthly_fee(15, 0.4, 0.3, 7.12) == 9

    def test_the_fee_never_exceeds_the_list_price(self):
        worst = engine.SellerRecord(leaked_weight=50, leaked_deals=50)
        for c in CATEGORIES.values():
            q = engine.quote(c, c.typical_price, 3, worst, 10_000)
            assert q["monthly_fee"] <= q["list_price"]
            assert q["discount_percent"] >= 0


# ── Months, the launch offer, the recommendation ─────────────────────────────

class TestPeriods:
    def test_longer_is_cheaper_per_month_in_the_shape_asked_for(self):
        """'If one month is 100, two might be 180 and three 250.'"""
        q = _fee(NEW, LAND, 1_500_000)
        monthly = q["monthly_fee"]
        totals = [o["total"] for o in q["options"]]
        assert [o["months"] for o in q["options"]] == [1, 2, 3, 4, 5, 6]
        assert all(a < b for a, b in zip(totals, totals[1:]))
        per_month = [o["per_month"] for o in q["options"]]
        assert all(a > b for a, b in zip(per_month, per_month[1:]))
        assert totals[1] / monthly == pytest.approx(1.78, abs=0.02)
        assert totals[2] / monthly == pytest.approx(2.49, abs=0.02)

    def test_six_months_is_the_most_on_offer(self):
        assert max(o["months"] for o in _fee(NEW)["options"]) == 6 == engine.MAX_MONTHS

    def test_launch_offer_fades_with_the_categorys_trade(self):
        assert engine.launch_discount(0) == pytest.approx(0.30)
        assert engine.launch_discount(100) == pytest.approx(0.30 / math.e)
        assert engine.launch_discount(400) == 0
        assert _fee(NEW, in_category=0)["monthly_fee"] < _fee(NEW, in_category=10_000)["monthly_fee"]

    def test_land_is_pressed_to_list_for_months_a_phone_is_not(self):
        land = _fee(NEW, LAND, 1_500_000)["recommendation"]
        phone = _fee(NEW, ELECTRONICS, 20_000)["recommendation"]
        assert land["months"] >= 4 and land["strength"] == "strong"
        assert phone["months"] == 1 and phone["strength"] == "none"
        recommended = [o for o in _fee(NEW, LAND, 1_500_000)["options"] if o["recommended"]]
        assert [o["months"] for o in recommended] == [land["months"]]

    def test_more_units_take_longer_to_clear(self):
        one = engine.recommend_months(ELECTRONICS, 15_000, 1)
        many = engine.recommend_months(ELECTRONICS, 15_000, 200)
        assert many.months > one.months


# ── The category table ───────────────────────────────────────────────────────

class TestCategories:
    def test_every_listing_category_has_its_own_row(self):
        """A category missing here would silently be priced as "Other"."""
        assert set(seed.CANONICAL_CATEGORIES) == set(CATEGORIES)

    def test_names_are_matched_loosely(self):
        assert for_category(" electronics ") is ELECTRONICS
        assert for_category("Vehicles") is CATEGORIES["Automobiles"]
        assert for_category("Spaceships") is FALLBACK
        assert for_category(None) is FALLBACK

    def test_rates_are_rates(self):
        for c in CATEGORIES.values():
            assert 0 < c.prior_completion < 1


# ── Plans ────────────────────────────────────────────────────────────────────

ALL_PLANS = list(plans.PREMIUM_PLANS) + list(plans.STORE_PLANS)


class TestPlans:
    @pytest.mark.parametrize("plan", ALL_PLANS, ids=lambda p: p.id)
    def test_no_plan_loses_money_on_its_heaviest_user(self, plan):
        """Prices include VAT, so the rule is checked on what BROKA keeps."""
        worst = plan.max_monthly_cost()
        assert costs.net_of_vat(plan.monthly_price) >= plans.MIN_MARGIN_MULTIPLE * worst
        for period in plans.period_prices(plan.monthly_price):
            assert costs.net_of_vat(period["total"] / period["months"]) >= worst, period

    def test_each_premium_tier_gives_at_least_as_much_as_the_one_below(self):
        tiers = plans.PREMIUM_PLANS
        for lower, upper in zip(tiers, tiers[1:]):
            assert upper.monthly_price > lower.monthly_price
            for field in ("voice_requests", "sms_alerts", "agent_watches", "auto_negotiations",
                          "ai_covers", "auctions_hosted", "ai_descriptions", "price_checks",
                          "priority_support_minutes"):
                assert getattr(upper, field) >= getattr(lower, field), field

    @pytest.mark.parametrize("card", plans.STORE_RATE_CARDS, ids=lambda c: c.id)
    def test_a_store_of_any_size_never_loses_money(self, card):
        """Sellers pick any size, so the margin rule is checked at every one,
        prepaid periods included - not only at the example plans."""
        for n in range(1, card.max_listings + 1):
            plan = card.plan(n)
            worst = plan.max_monthly_cost()
            assert costs.net_of_vat(plan.monthly_price) >= plans.MIN_MARGIN_MULTIPLE * worst, n
            for period in plans.period_prices(plan.monthly_price):
                assert costs.net_of_vat(period["total"] / period["months"]) >= worst, (n, period)

    @pytest.mark.parametrize("card", plans.STORE_RATE_CARDS, ids=lambda c: c.id)
    def test_one_more_listing_never_jumps_the_price(self, card):
        """No cliffs: each listing adds at most its band's rate, and a bigger
        store never pays more per listing."""
        prices = [card.price(n) for n in range(card.included, card.max_listings + 1)]
        steps = [b - a for a, b in zip(prices, prices[1:])]
        assert all(0 < s <= max(rate for _, rate in card.bands) for s in steps)
        per_listing = [p / n for n, p in enumerate(prices, start=card.included)]
        assert all(a >= b for a, b in zip(per_listing, per_listing[1:]))

    def test_a_goods_store_is_599_for_30_and_any_size_after(self):
        """The founder's call (2026-10-06): 599 covers 30 listings, and a
        seller with 40 pays for 40 rather than for the next plan up."""
        goods = plans.STORE_RATE_CARDS_BY_ID["goods"]
        assert goods.price(1) == goods.price(30) == 599
        assert goods.plan(10).listings == 30
        assert goods.price(40) == 599 + 10 * 16 == 759
        # At or under every fixed plan it replaces (50: 999, 100: 1,799,
        # 250: 3,999, 500: 6,999).
        for n, old in ((50, 999), (100, 1_799), (250, 3_999), (500, 6_999)):
            assert goods.price(n) <= old, n

    @pytest.mark.parametrize("card, category, price", [
        ("goods", ELECTRONICS, 20_000),
        ("vehicles", CATEGORIES["Automobiles"], 800_000),
        ("property", CATEGORIES["Land"], 1_500_000),
    ])
    def test_a_store_listing_costs_less_than_listing_it_alone(self, card, category, price):
        """The store is the considerate price for long-term sellers."""
        alone = _fee(NEW, category, price)["list_price"]
        rate_card = plans.STORE_RATE_CARDS_BY_ID[card]
        assert max(rate_card.price(n) / n
                   for n in range(rate_card.included, rate_card.max_listings + 1)) < alone / 2

    def test_vehicle_and_property_stores_are_for_dealers_and_agents(self):
        """A one-house 'store' would undercut that house's listing fee."""
        for card in ("vehicles", "property"):
            rate_card = plans.STORE_RATE_CARDS_BY_ID[card]
            assert rate_card.min_listings >= 5 and rate_card.categories

    def test_ai_covers_come_in_listings_worth_of_tries(self):
        """Covers are made while posting, a few tries per listing: an
        allowance under one listing's worth is not a feature (PRICING.md)."""
        for plan in plans.PREMIUM_PLANS:
            assert plan.ai_covers >= 2 * costs.AI_COVER_TRIES_PER_LISTING
        assert 0 < plans.FREE_TRIAL["ai_covers"] < costs.AI_COVER_TRIES_PER_LISTING

    def test_the_setup_fee_covers_setting_a_store_up(self):
        assert costs.net_of_vat(plans.STORE_SETUP_FEE) >= costs.STORE_SETUP * costs.OVERHEAD

    def test_commission(self):
        c = plans.commission()
        assert c["negotiated"] == {"broka_percent": 3.49, "broka_minimum_kes": 20.0,
                                   "escrow_provider_percent": 1.0, "total_percent": 4.49}
        assert c["auction"]["total_percent"] == 5.0


def test_mpesa_collection_bands():
    assert costs.mpesa_collection_cost(100) == 0
    assert costs.mpesa_collection_cost(101) == 3
    assert costs.mpesa_collection_cost(1_000) == 5
    assert costs.mpesa_collection_cost(5_000) == 28
    assert costs.mpesa_collection_cost(1_000_000) == 54


# ── Over HTTP ────────────────────────────────────────────────────────────────

@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_pricing.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


async def _user(tier=None) -> tuple[User, dict]:
    user = User(name="Pricing Tester", phone=f"+2547{uuid.uuid4().hex[:10]}",
                password_hash="x", seller_tier=tier)
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user, {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _deals(seller: User, completed: int, leaked: int = 0, category="Electronics"):
    """Give a seller a history: each deal with its own buyer, KES 20,000, a week old."""
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller.id, name="Phone", category=category,
                          price=20_000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        for i in range(completed + leaked):
            buyer = User(name="Buyer", phone=f"+2547{uuid.uuid4().hex[:10]}", password_hash="x")
            db.add(buyer)
            await db.flush()
            done = i < completed
            db.add(Deal(listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
                        agreed_price=20_000, commission=698,
                        status=DealStatus.released if done else DealStatus.agreed,
                        leak_flag=not done,
                        created_at=datetime.utcnow() - timedelta(days=7)))
        await db.commit()


QUOTE = "/pricing/listing-fee/quote?category=Electronics&price=20000"


class TestQuoteEndpoint:
    @pytest.mark.asyncio
    async def test_needs_sign_in(self, client):
        assert (await client.get(QUOTE)).status_code == 401

    @pytest.mark.asyncio
    @pytest.mark.parametrize("query", ["category=Electronics&price=0",
                                       "category=Electronics&price=-5",
                                       "category=Electronics&price=20000&quantity=0",
                                       "price=20000"])
    async def test_refuses_nonsense(self, client, query):
        _, headers = await _user()
        r = await client.get(f"/pricing/listing-fee/quote?{query}", headers=headers)
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_a_record_of_completed_deals_lowers_the_fee(self, client):
        _, new_headers = await _user(SellerTier.short_term)
        proven, proven_headers = await _user(SellerTier.short_term)
        await _deals(proven, completed=30)

        new_q = (await client.get(QUOTE, headers=new_headers)).json()
        proven_q = (await client.get(QUOTE, headers=proven_headers)).json()
        assert proven_q["risk"]["completed_deals"] == 30
        assert proven_q["monthly_fee"] < new_q["monthly_fee"]
        assert proven_q["discount_percent"] > new_q["discount_percent"]
        assert [o["months"] for o in new_q["options"]] == [1, 2, 3, 4, 5, 6]

    @pytest.mark.asyncio
    async def test_leaked_deals_raise_it(self, client):
        clean, clean_headers = await _user()
        leaky, leaky_headers = await _user()
        await _deals(clean, completed=10)
        await _deals(leaky, completed=10, leaked=10)
        clean_q = (await client.get(QUOTE, headers=clean_headers)).json()
        leaky_q = (await client.get(QUOTE, headers=leaky_headers)).json()
        assert leaky_q["risk"]["leaked_deals"] == 10
        assert leaky_q["monthly_fee"] > clean_q["monthly_fee"]

    @pytest.mark.asyncio
    async def test_featured_is_offered_to_short_term_sellers_only(self, client):
        _, short = await _user(SellerTier.short_term)
        _, long_ = await _user(SellerTier.long_term)
        assert (await client.get(QUOTE, headers=short)).json()["featured"]["available"] is True
        long_q = (await client.get(QUOTE, headers=long_)).json()["featured"]
        assert long_q["available"] is False and long_q["plans"] == []


class TestPublicEndpoints:
    @pytest.mark.asyncio
    async def test_plans(self, client):
        r = await client.get("/pricing/plans")
        assert r.status_code == 200
        body = r.json()
        assert [p["id"] for p in body["premium"]] == ["plus", "pro", "elite"]
        assert body["commission"]["negotiated"]["total_percent"] == 4.49
        assert body["stores"]["plans"][0]["periods"][-1]["setup_fee"] == 0
        assert [c["id"] for c in body["stores"]["rate_cards"]] == ["goods", "vehicles", "property"]

    @pytest.mark.asyncio
    async def test_a_store_of_the_size_the_seller_picks(self, client):
        r = await client.get("/pricing/store-plan", params={"listings": 40})
        assert r.status_code == 200
        plan = r.json()["plan"]
        assert plan["trade"] == "goods" and plan["listings"] == 40 and plan["monthly_price"] == 759
        yard = (await client.get("/pricing/store-plan",
                                 params={"trade": "vehicles", "listings": 25})).json()["plan"]
        assert yard["monthly_price"] == 5_999
        # Past the card's most, the app doesn't sell it - BROKA prices it by hand.
        too_big = await client.get("/pricing/store-plan", params={"listings": 1_001})
        assert too_big.status_code == 422 and "contact BROKA" in too_big.json()["detail"]
        assert (await client.get("/pricing/store-plan",
                                 params={"trade": "boats", "listings": 5})).status_code == 422

    @pytest.mark.asyncio
    async def test_categories(self, client):
        r = await client.get("/pricing/categories")
        assert r.status_code == 200
        rows = r.json()["categories"]
        assert {row["category"] for row in rows} == set(seed.CANONICAL_CATEGORIES)
        land = next(row for row in rows if row["category"] == "Land")
        phones = next(row for row in rows if row["category"] == "Electronics")
        assert land["new_seller_risk_coefficient"] > phones["new_seller_risk_coefficient"]


# ── Featured boosts: short-term sellers only ─────────────────────────────────

class TestBoostGate:
    @pytest.mark.asyncio
    async def test_a_long_term_seller_is_refused_before_any_payment_prompt(self, client, monkeypatch):
        from api.routers import featured

        async def must_not_run(*_a, **_k):
            raise AssertionError("the M-Pesa prompt must not be sent")

        monkeypatch.setattr(featured, "_get_token", must_not_run)
        seller, headers = await _user(SellerTier.long_term)
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Sofa", category="Home & Furniture",
                              price=30_000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            listing_id = listing.id
        r = await client.post("/featured/boost", headers=headers, json={
            "listing_id": listing_id, "plan": "week", "phone_number": "0712345678"})
        assert r.status_code == 403
        assert "occasional sellers" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_a_short_term_seller_still_gets_the_prompt(self, client, monkeypatch):
        from api.routers import featured

        async def token():
            return "t"

        async def send(_token, _phone, amount, _name):
            return {"CheckoutRequestID": f"ws_{uuid.uuid4().hex}", "MerchantRequestID": "m",
                    "ResponseCode": "0"}

        monkeypatch.setattr(featured, "_get_token", token)
        monkeypatch.setattr(featured, "_send_stk", send)
        seller, headers = await _user(SellerTier.short_term)
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                              price=20_000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            listing_id = listing.id
        r = await client.post("/featured/boost", headers=headers, json={
            "listing_id": listing_id, "plan": "week", "phone_number": "0712345678"})
        assert r.status_code == 200, r.text
        assert r.json()["amount"] == 99


# ── Commission on a deal ─────────────────────────────────────────────────────

class TestDealCommission:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("listing_type, rate", [
        (ListingType.direct, 0.0349), (ListingType.auction, 0.04)])
    async def test_rate_follows_the_listing(self, listing_type, rate):
        from api.domains.escrow.service import EscrowService

        seller, _ = await _user(SellerTier.short_term)
        buyer, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Item", category="Electronics",
                              price=100_000, lat=-1.28, lng=36.82, listing_type=listing_type)
            db.add(listing)
            await db.commit()
            result = await EscrowService(db).finalize_deal(
                listing_id=listing.id, buyer_id=buyer.id, agreed_price=100_000,
                current_user_id=buyer.id)
        assert result["commission"] == pytest.approx(100_000 * rate)
        assert settings.commission_rate + settings.escrow_provider_fee_rate == pytest.approx(0.0449)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("listing_type, price, expected", [
        (ListingType.direct, 300, 20.0), (ListingType.direct, 573, 20.0),
        (ListingType.direct, 1_500, 52.35),
        (ListingType.auction, 300, 20.0), (ListingType.auction, 1_500, 60.0)])
    async def test_never_under_the_minimum(self, listing_type, price, expected):
        """3.49% of a KES 300 item is KES 10.47 - less than the deal costs
        BROKA to carry. Above ~KES 573 the percentage is more than the
        minimum and nothing changes."""
        from api.domains.escrow.service import EscrowService

        seller, _ = await _user(SellerTier.short_term)
        buyer, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Item", category="Fashion",
                              price=price, lat=-1.28, lng=36.82, listing_type=listing_type)
            db.add(listing)
            await db.commit()
            result = await EscrowService(db).finalize_deal(
                listing_id=listing.id, buyer_id=buyer.id, agreed_price=price,
                current_user_id=buyer.id)
        assert result["commission"] == pytest.approx(expected)
