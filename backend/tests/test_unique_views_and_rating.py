"""Unique views, composite /10 ratings, and store insight series.

* A signed-in account viewing a listing twice counts once — for store
  listings and personal listings alike (one code path serves both).
* Buyer reviews only CONTRIBUTE to the /10 overall rating (seller and
  store): one 5-star review must not produce a perfect / headline 5-star
  score, and reply speed / time on BROKA still move the number.
* The store insights payload carries distinct daily series for rating,
  reviews and response time, not only visits/views/chats.
"""
import itertools
from datetime import date

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.domains.trust.seller_rating import SellerSignals, overall_rating
from tests.legal_payload import legal_payload


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_unique_views.db"
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


_n = itertools.count(1)


def _auth(token):
    return {"Authorization": f"Bearer {token}"}


async def _register(client):
    n = next(_n)
    phone = f"0755{n:06d}"
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    token = verify.json()["phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": token, "name": f"User {n}", "email": f"u{n}@test.ke",
        "password": "Passw0rd!23", "lat": -1.286, "lng": 36.817,
        "account_type": "buyer_seller", "seller_tier": "long_term",
        "business_name": f"Business {n}", "business_category": "Electronics",
        "business_location": "Nairobi",
        "legal_acceptance": legal_payload(),
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "Passw0rd!23"})
    return reg.json()["user_id"], _auth(login.json()["access_token"])


async def _listing(client, headers, name, store_id=None):
    body = {
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": name, "category": "Electronics", "price": 1000,
        "lat": -1.0, "lng": 36.0,
    }
    if store_id:
        body["store_id"] = store_id
    r = await client.post("/listings/", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()["id"]


class TestUniqueViews:
    @pytest.mark.asyncio
    async def test_same_account_counts_once_for_personal_listing(self, client):
        _, seller = await _register(client)
        _, buyer = await _register(client)
        _, other = await _register(client)
        lid = await _listing(client, seller, "Personal item")

        first = (await client.get(f"/listings/{lid}", headers=buyer)).json()
        second = (await client.get(f"/listings/{lid}", headers=buyer)).json()
        third = (await client.get(f"/listings/{lid}", headers=other)).json()
        assert first["views"] == 1
        assert second["views"] == 1, "same account viewing twice must count once"
        assert third["views"] == 2, "a different account is a new view"

    @pytest.mark.asyncio
    async def test_same_account_counts_once_for_store_listing(self, client):
        _, seller = await _register(client)
        _, buyer = await _register(client)
        store = (await client.post("/stores", json={"name": f"Shop {next(_n)}"},
                                   headers=seller)).json()
        lid = await _listing(client, seller, "Store item", store_id=store["id"])
        await client.get(f"/listings/{lid}", headers=buyer)
        again = (await client.get(f"/listings/{lid}", headers=buyer)).json()
        assert again["views"] == 1
        # The headline ratings on a listing are composites out of 10, for
        # the seller and for the store — never a raw review average.
        assert again["seller_overall_rating"] is not None
        assert 0 <= again["seller_overall_rating"] <= 10
        assert again["store_rating"] is not None
        assert 0 <= again["store_rating"] <= 10

    @pytest.mark.asyncio
    async def test_seller_own_views_never_count(self, client):
        seller_id, seller = await _register(client)
        lid = await _listing(client, seller, "Own item")
        body = (await client.get(f"/listings/{lid}", headers=seller)).json()
        assert body["views"] == 0


class TestSellerRatingIncludesReviews:
    def test_one_five_star_review_is_not_a_perfect_rating(self):
        base = dict(dcr_percent=90, median_response_minutes=30,
                    completed_deals=30, pending_deals=2, days_on_broka=300,
                    unique_counterparties=25)
        loved = overall_rating(SellerSignals(
            review_average=5.0, review_count=1, **base)).rating
        hated = overall_rating(SellerSignals(
            review_average=1.0, review_count=20, **base)).rating
        assert loved < 10.0
        assert loved > hated, "reviews must move the /10 rating"

    def test_reviews_do_not_override_reply_speed_and_tenure(self):
        slow_new = overall_rating(SellerSignals(
            review_average=5.0, review_count=20, median_response_minutes=2880,
            completed_deals=30, pending_deals=2, days_on_broka=7,
            unique_counterparties=25)).rating
        fast_old = overall_rating(SellerSignals(
            review_average=5.0, review_count=20, median_response_minutes=5,
            completed_deals=30, pending_deals=2, days_on_broka=365,
            unique_counterparties=25)).rating
        assert fast_old > slow_new

    def test_no_reviews_keeps_neutral_anchor(self):
        assert overall_rating(SellerSignals(days_on_broka=1)).rating == pytest.approx(6.5, abs=0.15)


class TestStoreInsightSeries:
    @pytest.mark.asyncio
    async def test_insights_carry_rating_review_and_response_series(self, client):
        _, seller = await _register(client)
        store = (await client.post("/stores", json={"name": f"Shop {next(_n)}"},
                                   headers=seller)).json()
        r = await client.get(f"/stores/{store['id']}/insights?days=7", headers=seller)
        assert r.status_code == 200, r.text
        series = r.json()["series"]
        for key in ("rating", "reviews", "response_minutes"):
            assert key in series, f"missing distinct series: {key}"
            assert isinstance(series[key], list)
            assert all("date" in p for p in series[key])
        # Today is always present so the chart can plot the current value.
        today = date.today().isoformat()
        assert any(p["date"] == today for p in series["rating"])
