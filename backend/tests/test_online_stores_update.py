"""Online-store update: excluded listing categories, '6 km from you'
distances, and KES 40-a-listing-per-two-months pricing."""
from api.core.geo import format_distance_km, round_distance_km
from api.domains.pricing import plans
from api.domains.stores import categories as store_categories


class TestExcludedListingCategories:
    def test_online_store_hides_five_trades(self):
        assert store_categories.ONLINE_STORE_EXCLUDED == frozenset({
            "Property", "Automobiles", "Land", "Services", "Other",
        })

    def test_filter_keeps_order_and_goods(self):
        names = ["Electronics", "Property", "Fashion", "Services", "Other", "Land"]
        assert store_categories.filter_online_store_categories(names) == [
            "Electronics", "Fashion",
        ]

    def test_is_online_listing_category(self):
        assert store_categories.is_online_store_listing_category("Electronics")
        assert not store_categories.is_online_store_listing_category("Property")
        assert not store_categories.is_online_store_listing_category("Automobiles")
        assert not store_categories.is_online_store_listing_category("Land")
        assert not store_categories.is_online_store_listing_category("Services")
        assert not store_categories.is_online_store_listing_category("Other")


class TestDistanceLabels:
    def test_six_km_label(self):
        assert format_distance_km(6.0) == "6.0 km from you"
        assert format_distance_km(6) == "6.0 km from you"

    def test_rounding_and_units(self):
        assert format_distance_km(0.45) == "450 m from you"
        assert format_distance_km(12.34) == "12 km from you"
        assert format_distance_km(None) is None
        assert format_distance_km(float("nan")) is None

    def test_round_distance_drops_bad_input(self):
        assert round_distance_km(3.24) == 3.2
        assert round_distance_km(float("nan")) is None
        assert round_distance_km(float("inf")) is None


class TestOnlinePricing:
    def test_twenty_is_smallest_at_799_for_two_months(self):
        goods = plans.STORE_RATE_CARDS_BY_ID["goods"]
        assert goods.min_listings == 20
        assert goods.setup_fee == 0
        assert goods.price(20) == 400
        assert plans.store_period_prices(400)[0]["total"] == 799

    def test_thirty_is_1099_not_1200(self):
        goods = plans.STORE_RATE_CARDS_BY_ID["goods"]
        assert goods.price(30) == 550
        assert plans.store_period_prices(550)[0]["total"] == 1_099

    def test_store_periods_are_bi_monthly(self):
        assert sorted(plans.STORE_PERIODS) == [2, 4, 6, 12]
