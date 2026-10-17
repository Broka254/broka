"""Online-store update: excluded listing categories, '6 km from you'
distances, and KES 40-a-listing-per-two-months pricing."""
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.core.geo import format_distance_km, round_distance_km
from api.database import init_db, reset_engine
from api.domains.pricing import plans
from api.domains.stores import categories as store_categories
from main import app


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


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_online_update.db"
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


async def _register_at(client, phone: str, name: str, lat: float, lng: float) -> str:
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": name,
        "email": f"{phone}@test.ke", "password": "OwnerPass123!",
        "lat": lat, "lng": lng, "account_type": "buyer_seller",
        "seller_tier": "long_term", "business_name": name,
        "business_category": "Electronics", "business_location": "Test",
    })
    assert reg.status_code == 201, reg.text
    login = await client.post("/auth/login", json={"phone": phone, "password": "OwnerPass123!"})
    return login.json()["access_token"]


async def _open_store(client, token: str, name: str) -> dict:
    r = await client.post("/stores", json={"name": name},
                          headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 201, r.text
    return r.json()


class TestStoresNearYou:
    @pytest.mark.asyncio
    async def test_only_shops_within_25km_are_near(self, client):
        viewer = (-1.286, 36.817)  # Nairobi
        near = await _open_store(
            client,
            await _register_at(client, "0722000001", "Near Owner", *viewer),
            "Near Shop")
        far = await _open_store(
            client,
            await _register_at(client, "0722000002", "Far Owner", 1.0, 36.817),
            "Far Shop")

        nearby = (await client.get("/stores", params={
            "lat": viewer[0], "lng": viewer[1], "with_total": True,
            "max_distance_km": 25, "nearest_first": True,
        })).json()
        names = {s["name"] for s in nearby["items"]}
        assert names == {"Near Shop"}, names
        item = nearby["items"][0]
        assert item["id"] == near["id"]
        assert item["distance_km"] is not None and item["distance_km"] <= 25
        assert item["distance_label"].endswith("from you")

        everything = (await client.get("/stores", params={
            "lat": viewer[0], "lng": viewer[1], "with_total": True,
        })).json()
        by_name = {s["name"]: s for s in everything["items"]}
        assert by_name["Far Shop"]["distance_km"] > 25
        assert far["id"] == by_name["Far Shop"]["id"]
