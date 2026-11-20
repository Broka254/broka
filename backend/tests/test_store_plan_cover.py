"""A store plan's places cover its owner's own listings (stores/plan_cover.py).

What must hold, with listing fees on:
  * a store owner pays no listing fee while their paid plan has a place to
    spare - for a listing in the store, as before, and for one of their own
    posted under "No Store" - and pays as anyone does once it is full;
  * only for what the store may hold: a shop's places never cover a car;
  * a lapsed plan covers nothing, and paying for it again brings its
    listings back with the store's own;
  * a listing posted before the plan had room goes up free on it, without
    an M-Pesa prompt, and is announced once;
  * the plan's listings follow its clock: a raise of their price shortens
    nothing, and the store's reminder is the only text about its deadline.

Regression: the exemption was the store association alone, so a shop that
had paid for 20 listings was charged a fee for its very first one posted
outside the store - the sell wizard's default.
"""
import dataclasses
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.core import mpesa_stk
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, SellerTier, User, init_db, reset_engine
from api.models.store import Store
from api.models.store_billing import StorePayment, StoreSubscription
from api.security import create_access_token

SECRET = "plan-cover-secret"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_plan_cover.db"
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


@pytest.fixture(autouse=True)
def fees_and_billing_on(monkeypatch):
    # Every module that reads a switch on these paths sees the same world.
    # The launch and founding offers are off: their interplay with paying
    # lives in test_launch_offers.py.
    patched = dataclasses.replace(
        settings, listing_fees_enabled=True, store_billing_enabled=True,
        mpesa_callback_secret=SECRET, free_listing_offer_limit=0,
        free_store_offer_limit=0, free_listings_per_seller=0, founding_seller_tiers=(),
    )
    for module in ("api.domains.listings.service", "api.domains.listings.paid",
                   "api.domains.listings.router", "api.domains.pricing.service",
                   "api.domains.pricing.payments", "api.domains.pricing.router",
                   "api.domains.pricing.launch_offers", "api.domains.stores.billing",
                   "api.domains.stores.router", "api.domains.stores.service"):
        monkeypatch.setattr(f"{module}.settings", patched)
    return patched


class FakeMpesa:
    def __init__(self):
        self.prompts = []

    async def stk_push(self, phone, amount, account_reference, description, callback_url):
        self.prompts.append({"phone": phone, "amount": amount, "reference": account_reference})
        return {"CheckoutRequestID": f"ws_CO_{uuid.uuid4().hex}", "MerchantRequestID": "m",
                "ResponseCode": "0"}

    async def stk_query(self, checkout_request_id):
        return {"errorCode": "500.001.1001"}


@pytest.fixture
def mpesa(monkeypatch):
    fake = FakeMpesa()
    monkeypatch.setattr(mpesa_stk, "stk_push", fake.stk_push)
    monkeypatch.setattr(mpesa_stk, "stk_query", fake.stk_query)
    return fake


@pytest.fixture
def announced(monkeypatch):
    """Listings announced to buyers (ListingCreated), from posting and from
    going up on the plan."""
    ids = []

    async def record(event):
        ids.append(event.listing_id)

    monkeypatch.setattr("api.domains.listings.service.publish", record)
    monkeypatch.setattr("api.domains.pricing.payments.publish", record)
    return ids


async def _user() -> tuple[str, dict]:
    u = User(name="Shop Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
             seller_tier=SellerTier.long_term)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _store_with_plan(owner_id, places=20, days=60, category="Electronics"):
    """A shop whose plan for `places` listings is paid `days` ahead (in the
    past when negative). Returns (store id, the plan's paid end)."""
    until = datetime.utcnow() + timedelta(days=days)
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner_id, name=f"Shop {uuid.uuid4().hex[:6]}",
                      slug=f"shop-{uuid.uuid4().hex[:10]}", category=category)
        db.add(store)
        await db.flush()
        db.add(StoreSubscription(store_id=store.id, plan_id="goods-20", listings=places,
                                 setup_fee_paid=True, paid_until=until))
        await db.commit()
        return store.id, until


async def _listing(client, headers, **extra) -> dict:
    body = {"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 20000, "lat": -1.28, "lng": 36.82, **extra}
    r = await client.post("/listings/", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _draft_quote(client, headers, **params) -> dict:
    r = await client.get("/pricing/listing-fee/quote", headers=headers,
                         params={"category": "Electronics", "price": 20000, **params})
    assert r.status_code == 200, r.text
    return r.json()


async def _quote(client, headers, listing_id) -> dict:
    r = await client.get(f"/pricing/listing-fee/listings/{listing_id}/quote", headers=headers)
    assert r.status_code == 200, r.text
    return r.json()


async def _paid_until(listing_id) -> datetime:
    async with AsyncSessionLocal() as db:
        return (await db.get(Listing, listing_id)).paid_until


async def _sub(store_id) -> StoreSubscription:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(StoreSubscription).where(
            StoreSubscription.store_id == store_id))).scalar_one()


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


def _callback(checkout_id, amount):
    return {"Body": {"stkCallback": {
        "CheckoutRequestID": checkout_id, "ResultCode": 0, "ResultDesc": "done",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": amount},
            {"Name": "MpesaReceiptNumber", "Value": f"SKC{uuid.uuid4().hex[:10].upper()}"},
        ]},
    }}}


async def _pay_store(client, headers, store_id):
    """Two more months of the 20-listing plan, through M-Pesa's callback."""
    r = await client.post(f"/stores/{store_id}/billing/pay", headers=headers, json={
        "listings": 20, "months": 2, "phone_number": "0712345678"})
    assert r.status_code == 200, r.text
    started = r.json()
    async with AsyncSessionLocal() as db:
        checkout = (await db.get(StorePayment, started["payment_id"])).checkout_request_id
    sent = await client.post(f"/stores/billing/callback/{SECRET}",
                             json=_callback(checkout, started["amount"]))
    assert sent.status_code == 200


class TestPostingOnThePlan:
    @pytest.mark.asyncio
    async def test_no_fee_until_the_plan_is_full(self, client, announced):
        owner, h = await _user()
        store_id, until = await _store_with_plan(owner, places=2)
        in_store = await _listing(client, h, store_id=store_id)

        q = await _draft_quote(client, h)
        assert q["store_covered"] is True and q["fees_enabled"] is False
        assert q["store_plan"]["places"] == 2 and q["store_plan"]["free"] == 1
        assert q["launch_offer"]["eligible"] is False

        own = await _listing(client, h)          # under "No Store": its second place
        assert own["listing_fee"]["status"] == "live"
        assert own["listing_fee"]["needs_payment"] is False
        assert await _paid_until(own["id"]) == until, "it runs on the plan's clock"
        assert await _in_feed(client, own["id"])
        assert announced == [in_store["id"], own["id"]]
        covered = await _quote(client, h, own["id"])
        assert covered["store_plan"]["covered"] is True and covered["fees_enabled"] is False

        # Both places are taken: the next one pays, as anyone's does.
        full = await _draft_quote(client, h)
        assert full["store_covered"] is False and full["fees_enabled"] is True
        assert "store_plan" not in full
        third = await _listing(client, h)
        assert third["listing_fee"]["status"] == "unpaid"
        assert not await _in_feed(client, third["id"])
        assert (await _quote(client, h, third["id"]))["fees_enabled"] is True

    @pytest.mark.asyncio
    async def test_a_shops_places_never_cover_a_car(self, client):
        owner, h = await _user()
        await _store_with_plan(owner)
        q = await _draft_quote(client, h, category="Automobiles", price=800_000)
        assert q["store_covered"] is False and q["fees_enabled"] is True
        car = await _listing(client, h, category="Automobiles", price=800_000)
        assert car["listing_fee"]["status"] == "unpaid"

    @pytest.mark.asyncio
    async def test_a_lapsed_plan_covers_nothing(self, client):
        owner, h = await _user()
        await _store_with_plan(owner, days=-1)
        assert (await _draft_quote(client, h))["fees_enabled"] is True
        assert (await _listing(client, h))["listing_fee"]["status"] == "unpaid"


class TestPutOnThePlan:
    @pytest.mark.asyncio
    async def test_a_listing_from_before_the_plan_goes_up_free(self, client, mpesa, announced):
        owner, h = await _user()
        waiting = await _listing(client, h)      # no store yet: waits for its fee
        assert waiting["listing_fee"]["status"] == "unpaid"
        _, until = await _store_with_plan(owner)

        q = await _quote(client, h, waiting["id"])
        assert q["fees_enabled"] is False, "the plan covers it: nothing to pay"
        assert q["store_plan"]["covered"] is False and q["store_plan"]["free"] == 20

        r = await client.post("/pricing/listing-fee/renew-free", headers=h,
                              json={"listing_id": waiting["id"]})
        assert r.status_code == 200, r.text
        assert r.json()["listing_fee"]["live"] is True
        assert await _paid_until(waiting["id"]) == until
        assert await _in_feed(client, waiting["id"])
        assert announced == [waiting["id"]], "announced when buyers can first see it"
        assert mpesa.prompts == []

        on_plan = (await _quote(client, h, waiting["id"]))["store_plan"]
        assert on_plan["covered"] is True and on_plan["in_use"] == 1
        again = await client.post("/pricing/listing-fee/renew-free", headers=h,
                                  json={"listing_id": waiting["id"]})
        assert again.status_code == 409

    @pytest.mark.asyncio
    async def test_without_a_place_it_still_renews_through_a_payment(self, client):
        _, h = await _user()
        waiting = await _listing(client, h)
        r = await client.post("/pricing/listing-fee/renew-free", headers=h,
                              json={"listing_id": waiting["id"]})
        assert r.status_code == 409
        assert (await _paid_until(waiting["id"])) <= datetime.utcnow()


class TestThePlansClock:
    @pytest.mark.asyncio
    async def test_paying_for_the_plan_carries_its_listings_forward(self, client, mpesa):
        owner, h = await _user()
        store_id, until = await _store_with_plan(owner)
        own = await _listing(client, h)
        await _pay_store(client, h, store_id)

        renewed = (await _sub(store_id)).paid_until
        assert renewed > until
        assert await _paid_until(own["id"]) == renewed

    @pytest.mark.asyncio
    async def test_a_lapsed_plan_paid_again_brings_them_back(self, client, mpesa):
        owner, h = await _user()
        store_id, _ = await _store_with_plan(owner)
        own = await _listing(client, h)
        lapsed = datetime.utcnow() - timedelta(days=1)
        async with AsyncSessionLocal() as db:
            (await db.execute(select(StoreSubscription).where(
                StoreSubscription.store_id == store_id))).scalar_one().paid_until = lapsed
            (await db.get(Listing, own["id"])).paid_until = lapsed
            await db.commit()
        assert not await _in_feed(client, own["id"])

        await _pay_store(client, h, store_id)
        assert await _paid_until(own["id"]) == (await _sub(store_id)).paid_until
        assert await _in_feed(client, own["id"])

    @pytest.mark.asyncio
    async def test_a_price_raise_takes_no_time_off_it(self, client):
        owner, h = await _user()
        _, until = await _store_with_plan(owner)
        own = await _listing(client, h, price=20000)
        r = await client.patch(f"/listings/{own['id']}", headers=h, json={"price": 22000})
        assert r.status_code == 200, r.text
        assert await _paid_until(own["id"]) == until

    @pytest.mark.asyncio
    async def test_the_store_text_is_the_only_one_about_its_deadline(self, client, monkeypatch):
        from api.domains.pricing import expiry_alerts

        sent_texts = []

        class _SMS:
            async def send(self, phone, message):
                sent_texts.append(message)
                return True

        monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: _SMS())
        owner, h = await _user()
        store_id, _ = await _store_with_plan(owner)
        own = await _listing(client, h)
        now = datetime.utcnow().replace(hour=9, minute=0, second=0, microsecond=0)
        soon = now + timedelta(days=1)
        async with AsyncSessionLocal() as db:
            (await db.execute(select(StoreSubscription).where(
                StoreSubscription.store_id == store_id))).scalar_one().paid_until = soon
            (await db.get(Listing, own["id"])).paid_until = soon
            await db.commit()
            sent = await expiry_alerts.send_due_expiry_alerts(db, now)
        assert sent["listings"] == 0 and sent["stores"] >= 1
        assert not any(own["name"][:20] in text for text in sent_texts)
