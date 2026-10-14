"""Changing a listing's price, and listings that can't be delivered.

What must hold:
  * once buyers have seen a price, one change raises it by at most 25%
    (price_rules.MAX_RAISE_SHARE); a new listing's price can be corrected
    freely, and a cut is never limited;
  * a raise on a listing with paid time left shortens that time in
    proportion to the new monthly fee - after the seller has been told and
    agreed - so a listing can't pay the fee of a low price and then sell at
    a high one; a cut leaves the paid time alone;
  * land and property are never described as delivered: whatever the app
    sends about delivery is dropped, and Zeno is told it stays where it is.
"""
import dataclasses
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.domains.listings import price_rules
from api.domains.listings.handover import IN_PLACE_NOTE
from api.domains.zeno_assistant import listing_context
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_price_change.db"
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


@pytest.fixture
def fees_on(monkeypatch):
    patched = dataclasses.replace(settings, listing_fees_enabled=True)
    for module in ("api.domains.listings.service", "api.domains.listings.router",
                   "api.domains.pricing.service"):
        monkeypatch.setattr(f"{module}.settings", patched)


async def _seller() -> dict:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers, **extra) -> dict:
    body = {"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 20000, "lat": -1.28, "lng": 36.82, **extra}
    r = await client.post("/listings/", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _set(listing_id, **values) -> None:
    async with AsyncSessionLocal() as db:
        listing = await db.get(Listing, listing_id)
        for k, v in values.items():
            setattr(listing, k, v)
        await db.commit()


async def _get(listing_id) -> Listing:
    async with AsyncSessionLocal() as db:
        return await db.get(Listing, listing_id)


async def _shown_for_days(listing_id, days=3) -> None:
    """Posted `days` ago: buyers have seen its price."""
    await _set(listing_id, created_at=datetime.utcnow() - timedelta(days=days))


async def _price(client, headers, listing_id, price, **extra):
    return await client.patch(f"/listings/{listing_id}", headers=headers,
                              json={"price": price, **extra})


# ── How far one change may go ────────────────────────────────────────────────

class TestRaiseLimit:
    @pytest.mark.asyncio
    async def test_a_seen_price_cannot_jump_more_than_a_quarter(self, client):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])

        r = await _price(client, h, listing["id"], 26000)

        assert r.status_code == 422, r.text
        assert r.json()["detail"]["code"] == "PRICE_RAISE_TOO_LARGE"
        assert r.json()["detail"]["max_price"] == 25000
        assert (await _get(listing["id"])).price == 20000

    @pytest.mark.asyncio
    async def test_a_quarter_is_allowed(self, client):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])

        r = await _price(client, h, listing["id"], 25000)

        assert r.status_code == 200, r.text
        assert (await _get(listing["id"])).price == 25000

    @pytest.mark.asyncio
    async def test_a_new_listing_can_be_corrected(self, client):
        h = await _seller()
        listing = await _listing(client, h, price=1500)

        r = await _price(client, h, listing["id"], 15000)

        assert r.status_code == 200, r.text

    @pytest.mark.asyncio
    async def test_a_listing_buyers_cannot_see_yet_can_be_corrected(self, client, fees_on):
        h = await _seller()
        listing = await _listing(client, h, price=1500)
        await _shown_for_days(listing["id"])
        # Never paid: hidden from buyers.
        await _set(listing["id"], paid_until=datetime.utcnow() - timedelta(days=3))

        r = await _price(client, h, listing["id"], 15000)

        assert r.status_code == 200, r.text

    @pytest.mark.asyncio
    async def test_a_cut_is_never_limited(self, client):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])

        r = await _price(client, h, listing["id"], 2000)

        assert r.status_code == 200, r.text
        assert (await _get(listing["id"])).price == 2000


# ── A raise and the fee already paid ─────────────────────────────────────────

class TestRaiseAndPaidTime:
    @pytest.mark.asyncio
    async def test_the_seller_is_told_before_the_paid_time_shrinks(self, client, fees_on):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])
        paid_until = datetime.utcnow() + timedelta(days=20)
        await _set(listing["id"], paid_until=paid_until)

        r = await _price(client, h, listing["id"], 25000)

        assert r.status_code == 409, r.text
        detail = r.json()["detail"]
        assert detail["code"] == "PRICE_RAISE_SHORTENS_PAID_TIME"
        assert detail["monthly_fee_after"] > detail["monthly_fee_before"]
        assert detail["days_left_after"] < detail["days_left"]
        after = await _get(listing["id"])
        assert after.price == 20000 and after.paid_until == paid_until

    @pytest.mark.asyncio
    async def test_agreeing_shortens_it_in_proportion_to_the_fee(self, client, fees_on):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])
        await _set(listing["id"], paid_until=datetime.utcnow() + timedelta(days=20))
        asked = (await _price(client, h, listing["id"], 25000)).json()["detail"]

        r = await _price(client, h, listing["id"], 25000, accept_shorter_paid_time=True)

        assert r.status_code == 200, r.text
        after = await _get(listing["id"])
        assert after.price == 25000
        left = (after.paid_until - datetime.utcnow()).total_seconds() / 86400
        expected = 20 * asked["monthly_fee_before"] / asked["monthly_fee_after"]
        assert abs(left - expected) < 0.01
        assert r.json()["listing_fee"]["paid_until"] == after.paid_until.isoformat()

    @pytest.mark.asyncio
    async def test_a_cut_keeps_the_paid_time(self, client, fees_on):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])
        paid_until = datetime.utcnow() + timedelta(days=20)
        await _set(listing["id"], paid_until=paid_until)

        r = await _price(client, h, listing["id"], 15000)

        assert r.status_code == 200, r.text
        assert (await _get(listing["id"])).paid_until == paid_until

    @pytest.mark.asyncio
    async def test_with_fees_off_a_raise_costs_nothing(self, client):
        h = await _seller()
        listing = await _listing(client, h)
        await _shown_for_days(listing["id"])

        r = await _price(client, h, listing["id"], 25000)

        assert r.status_code == 200, r.text
        assert (await _get(listing["id"])).paid_until is None


class TestShortenedPaidUntil:
    def test_scales_the_time_left_by_the_fee_ratio(self):
        now = datetime(2026, 10, 1)
        until = price_rules.shortened_paid_until(now + timedelta(days=21), now, 100, 150)
        assert until == now + timedelta(days=14)

    def test_leaves_it_alone_when_the_fee_did_not_rise_or_nothing_is_paid(self):
        now = datetime(2026, 10, 1)
        assert price_rules.shortened_paid_until(now + timedelta(days=21), now, 150, 100) == now + timedelta(days=21)
        assert price_rules.shortened_paid_until(None, now, 100, 150) is None
        assert price_rules.shortened_paid_until(now - timedelta(days=1), now, 100, 150) == now - timedelta(days=1)


# ── Listings that can't be delivered ─────────────────────────────────────────

# Land must say how big it is (validation.clean_land_details).
LAND = {"attributes": {"land_size": "0.25", "land_size_unit": "acres"}}


class TestNotDeliverable:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("category", ["Land", "Property"])
    async def test_delivery_answers_are_dropped(self, client, category):
        h = await _seller()
        listing = await _listing(client, h, category=category, price=1_500_000,
                                 description="Quarter acre with a ready title deed, near the tarmac.",
                                 **LAND, delivery_available=True, delivery_note="Anywhere in Nairobi")

        assert listing["delivery_available"] is None
        assert listing["delivery_note"] is None
        assert listing["handover"] == "in_place"

    @pytest.mark.asyncio
    async def test_goods_keep_the_sellers_answer(self, client):
        h = await _seller()
        listing = await _listing(client, h, delivery_available=True, delivery_note="Within Nairobi")

        assert listing["delivery_available"] is True
        assert listing["delivery_note"] == "Within Nairobi"
        assert listing["handover"] == "delivery"

    @pytest.mark.asyncio
    async def test_zeno_is_told_it_stays_where_it_is(self, client):
        h = await _seller()
        listing = await _listing(client, h, category="Land", price=1_500_000,
                                 description="Quarter acre with a ready title deed, near the tarmac.",
                                 **LAND)
        # An older row, from before the app stopped asking.
        await _set(listing["id"], delivery_available=True, delivery_note="Anywhere")

        async with AsyncSessionLocal() as db:
            ctx = await listing_context.load(db, "someone-else", listing["id"])

        assert f"Delivery: {IN_PLACE_NOTE}" in ctx["facts"]
        assert "Anywhere" not in str(ctx)
