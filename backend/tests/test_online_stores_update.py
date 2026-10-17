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


class TestAreaPoints:
    def test_county_point_by_any_spelling(self):
        from api.domains.stores.area_points import county_point
        lat, lng = county_point("nairobi")
        assert abs(lat - -1.286) < 0.05 and abs(lng - 36.817) < 0.05
        assert county_point("Muranga") == county_point("Murang'a")
        assert county_point("Not A County") is None

    def test_subcounty_point_beats_county_point(self):
        from api.domains.stores.area_points import area_point
        lat, lng = area_point("Nairobi", "Westlands")
        assert abs(lat - -1.263) < 0.02 and abs(lng - 36.808) < 0.02

    def test_unknown_area_has_no_point(self):
        from api.domains.stores.area_points import area_point
        assert area_point(None, None) is None
        assert area_point("Nowhere", "Somewhere") is None


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


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

class TestPinlessStoresNearYou:
    @pytest.mark.asyncio
    async def test_area_fallback_finds_pinless_shop(self, client):
        # The owner registered far away (Mombasa) and never set a shop pin:
        # the shop's declared area is the only true shop location there is.
        token = await _register_at(client, "0722000011", "Coast Owner", -4.05, 39.67)
        created = await client.post("/stores", json={
            "name": "Kisumu Gadgets", "county": "Kisumu", "subcounty": "Kisumu Central",
        }, headers=_auth(token))
        assert created.status_code == 201, created.text
        store_id = created.json()["id"]

        nearby = (await client.get("/stores", params={
            "lat": -0.10, "lng": 34.76, "with_total": True,
            "max_distance_km": 25, "nearest_first": True, "limit": 100,
        })).json()
        row = next((s for s in nearby["items"] if s["id"] == store_id), None)
        assert row is not None, "pin-less shop in the viewer's area must be near"
        assert row["distance_approximate"] is True
        assert row["distance_label"].startswith("≈")
        assert row["has_location"] is True
        assert abs(row["approx_lat"] - -0.092) < 0.02

    @pytest.mark.asyncio
    async def test_raw_pin_distance_is_not_rounded_away(self, client):
        viewer = (0.515, 35.27)
        token = await _register_at(client, "0722000012", "Border Owner", *viewer)
        # 24.9 km due north raw; rounding the pin to 2 decimals (0.74)
        # would push it past 25 km and hide a shop that is in range.
        created = await client.post("/stores", json={
            "name": "Borderline Shop", "lat": 0.73894, "lng": 35.27,
        }, headers=_auth(token))
        assert created.status_code == 201, created.text
        store_id = created.json()["id"]

        nearby = (await client.get("/stores", params={
            "lat": viewer[0], "lng": viewer[1], "with_total": True,
            "max_distance_km": 25, "nearest_first": True, "limit": 100,
        })).json()
        row = next((s for s in nearby["items"] if s["id"] == store_id), None)
        assert row is not None, "24.9 km away must count as within 25 km"
        assert row["distance_km"] <= 25
        assert row["distance_approximate"] is False


class TestOnlineCategoryChoice:
    @pytest.mark.asyncio
    async def test_excluded_categories_are_refused_for_online_stores(self, client):
        token = await _register_at(client, "0722000013", "Choice Owner", -1.286, 36.817)
        for categories in (["Land"], ["Electronics", "Property"], ["Automobiles"]):
            r = await client.post("/stores", json={
                "name": "Wrong Shelf", "categories": categories,
            }, headers=_auth(token))
            assert r.status_code == 400, (categories, r.text)
            assert "online store" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_legacy_dealer_store_survives(self, client):
        token = await _register_at(client, "0722000014", "Dealer Owner", -1.286, 36.817)
        created = await client.post("/stores", json={
            "name": "Legacy Cars", "specialization": "Vehicles",
        }, headers=_auth(token))
        assert created.status_code == 201, created.text
        store = created.json()
        assert store["category"] == "Automobiles"
        # Keeping the category it already has is fine; adding another
        # excluded trade is not.
        kept = await client.patch(f"/stores/{store['id']}", json={
            "categories": ["Automobiles"]}, headers=_auth(token))
        assert kept.status_code == 200, kept.text
        added = await client.patch(f"/stores/{store['id']}", json={
            "categories": ["Automobiles", "Land"]}, headers=_auth(token))
        assert added.status_code == 400, added.text


