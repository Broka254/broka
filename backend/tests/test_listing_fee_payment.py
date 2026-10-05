"""Paying the listing fee (PRICING.md; api/domains/pricing/payments.py).

What must hold:
  * with fees on, a new listing is hidden from buyers until paid, and the
    Buying Agent hears of it only then;
  * the amount is the server's quote, and a callback claiming another
    amount buys nothing;
  * a payment is applied once, however many times Safaricom calls back or
    the app polls;
  * renewing extends from the end of the paid time, never past six months;
  * with fees off, nothing changes for anyone.
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
from api.database import (
    AsyncSessionLocal, AuditLog, Listing, ListingStatus, SellerTier, User, init_db, reset_engine,
)
from api.domains.listings.paid import MONTH
from api.models.listing_payment import ListingPayment
from api.security import create_access_token

SECRET = "test-callback-secret"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_fee_payment.db"
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


def _settings(monkeypatch, **changes):
    patched = dataclasses.replace(settings, **changes)
    for module in ("api.domains.listings.service", "api.domains.pricing.payments",
                   "api.domains.pricing.service", "api.domains.pricing.router"):
        monkeypatch.setattr(f"{module}.settings", patched)


@pytest.fixture
def fees_on(monkeypatch):
    _settings(monkeypatch, listing_fees_enabled=True, mpesa_callback_secret=SECRET)


class FakeMpesa:
    """Stands in for Daraja: records prompts, answers queries as told."""

    def __init__(self):
        self.prompts = []
        self.query_answer = {"errorCode": "500.001.1001", "errorMessage": "The transaction is being processed"}
        self.fail = False

    async def stk_push(self, phone, amount, account_reference, description, callback_url):
        if self.fail:
            raise mpesa_stk.MpesaUnavailable("down")
        self.prompts.append({"phone": phone, "amount": amount, "callback_url": callback_url})
        return {"CheckoutRequestID": f"ws_CO_{uuid.uuid4().hex}", "MerchantRequestID": "m", "ResponseCode": "0"}

    async def stk_query(self, checkout_request_id):
        return self.query_answer


@pytest.fixture
def mpesa(monkeypatch):
    fake = FakeMpesa()
    monkeypatch.setattr(mpesa_stk, "stk_push", fake.stk_push)
    monkeypatch.setattr(mpesa_stk, "stk_query", fake.stk_query)
    return fake


@pytest.fixture
def announced(monkeypatch):
    """ListingCreated events, from creation and from payment."""
    events = []

    async def record(event):
        events.append(event)

    monkeypatch.setattr("api.domains.listings.service.publish", record)
    monkeypatch.setattr("api.domains.pricing.payments.publish", record)
    return events


async def _user(tier=SellerTier.short_term) -> tuple[User, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", seller_tier=tier)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers, **extra) -> dict:
    body = {"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 20000, "lat": -1.28, "lng": 36.82, **extra}
    r = await client.post("/listings/", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _pay(client, headers, listing_id, months=1, **extra):
    return await client.post("/pricing/listing-fee/pay", headers=headers, json={
        "listing_id": listing_id, "months": months, "phone_number": "0712345678", **extra})


def _callback(checkout_id, amount, code=0, receipt="SKA1B2C3D4"):
    stk = {"CheckoutRequestID": checkout_id, "ResultCode": code, "ResultDesc": "done"}
    if code == 0:
        stk["CallbackMetadata"] = {"Item": [
            {"Name": "Amount", "Value": amount}, {"Name": "MpesaReceiptNumber", "Value": receipt}]}
    return {"Body": {"stkCallback": stk}}


async def _checkout_id(payment_id) -> str:
    async with AsyncSessionLocal() as db:
        return (await db.get(ListingPayment, payment_id)).checkout_request_id


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


async def _paid_listing(client, headers, months=1):
    listing = await _listing(client, headers)
    paid = (await _pay(client, headers, listing["id"], months)).json()
    await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                      json=_callback(await _checkout_id(paid["payment_id"]), paid["amount"]))
    return listing, paid


# ── Fees off: nothing changes ────────────────────────────────────────────────

class TestFeesOff:
    @pytest.mark.asyncio
    async def test_a_listing_goes_live_as_it_always_has(self, client, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        assert listing["listing_fee"]["status"] == "free"
        assert await _in_feed(client, listing["id"])
        assert [e.listing_id for e in announced] == [listing["id"]]

    @pytest.mark.asyncio
    async def test_there_is_nothing_to_pay(self, client, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        r = await _pay(client, h, listing["id"])
        assert r.status_code == 409
        assert mpesa.prompts == []


# ── Free listings: a seller's first ones pay nothing ────────────────────────

@pytest.fixture
def two_free(monkeypatch):
    _settings(monkeypatch, listing_fees_enabled=True, mpesa_callback_secret=SECRET,
              free_listings_per_seller=2)


class TestFreeListings:
    @pytest.mark.asyncio
    async def test_the_first_two_go_live_free_and_the_third_waits_for_its_fee(self, client, two_free):
        _, h = await _user()
        quote = (await client.get("/pricing/listing-fee/quote", headers=h,
                                  params={"category": "Electronics", "price": 20000})).json()
        assert quote["free_listing"] is True
        # An app build that predates free listings reads this and skips the fee step.
        assert quote["fees_enabled"] is False

        first, second = await _listing(client, h), await _listing(client, h)
        assert first["listing_fee"]["status"] == second["listing_fee"]["status"] == "free"
        assert await _in_feed(client, first["id"]) and await _in_feed(client, second["id"])

        quote = (await client.get("/pricing/listing-fee/quote", headers=h,
                                  params={"category": "Electronics", "price": 20000})).json()
        assert quote["free_listing"] is False and quote["fees_enabled"] is True
        third = await _listing(client, h)
        assert third["listing_fee"]["status"] == "unpaid"
        assert not await _in_feed(client, third["id"])

    @pytest.mark.asyncio
    async def test_a_free_place_comes_back_when_a_free_listing_is_sold(self, client, two_free):
        seller, h = await _user()
        first, _ = await _listing(client, h), await _listing(client, h)
        async with AsyncSessionLocal() as db:
            (await db.get(Listing, first["id"])).status = ListingStatus.completed
            await db.commit()
        assert (await _listing(client, h))["listing_fee"]["status"] == "free"

    @pytest.mark.asyncio
    async def test_each_seller_has_their_own_free_places(self, client, two_free):
        _, a = await _user()
        _, b = await _user()
        await _listing(client, a)
        await _listing(client, a)
        assert (await _listing(client, a))["listing_fee"]["status"] == "unpaid"
        assert (await _listing(client, b))["listing_fee"]["status"] == "free"


# ── Fees on: hidden until paid ───────────────────────────────────────────────

class TestUnpaidIsHidden:
    @pytest.mark.asyncio
    async def test_buyers_cannot_find_or_reach_it(self, client, fees_on, announced):
        seller, h = await _user()
        _, buyer_h = await _user()
        listing = await _listing(client, h)
        assert listing["listing_fee"] == {"status": "unpaid", "live": False,
                                          "paid_until": listing["listing_fee"]["paid_until"],
                                          "needs_payment": True}
        assert not await _in_feed(client, listing["id"])
        assert (await client.get(f"/listings/{listing['id']}")).status_code == 404
        r = await client.post(f"/listings/{listing['id']}/interest", headers=buyer_h, json={})
        assert r.status_code == 404
        assert announced == [], "the Buying Agent must not tell buyers about it yet"
        # ...but its seller still has it.
        own = await client.get(f"/listings/{listing['id']}/private", headers=h)
        assert own.status_code == 200 and own.json()["listing_fee"]["status"] == "unpaid"
        mine = (await client.get("/pricing/listing-fee/mine", headers=h)).json()["listings"]
        assert [m["id"] for m in mine] == [listing["id"]]

    @pytest.mark.asyncio
    async def test_auctions_pay_no_listing_fee(self, client, fees_on):
        _, h = await _user()
        listing = await _listing(client, h, listing_type="auction", price=50000)
        assert listing["listing_fee"]["status"] == "free"

    @pytest.mark.asyncio
    async def test_a_listing_whose_time_ran_out_is_hidden_again(self, client, fees_on):
        _, h = await _user()
        listing = await _listing(client, h)
        async with AsyncSessionLocal() as db:
            row = await db.get(Listing, listing["id"])
            # Paid for a month, 40 days ago.
            row.created_at = datetime.utcnow() - timedelta(days=40)
            row.paid_until = row.created_at + timedelta(days=30)
            await db.commit()
        assert not await _in_feed(client, listing["id"])
        own = (await client.get(f"/listings/{listing['id']}/private", headers=h)).json()
        assert own["listing_fee"]["status"] == "expired"

    @pytest.mark.asyncio
    async def test_store_counts_and_trending_skip_it(self, client, fees_on):
        _, h = await _user()
        listing = await _listing(client, h)
        trending = (await client.get("/trending", params={"limit": 100})).json()
        items = trending if isinstance(trending, list) else trending.get("items", [])
        assert listing["id"] not in {i["id"] for i in items}


# ── Paying ───────────────────────────────────────────────────────────────────

class TestPaying:
    @pytest.mark.asyncio
    async def test_the_quote_for_a_listing_offers_six_months(self, client, fees_on):
        _, h = await _user()
        listing = await _listing(client, h)
        q = (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote", headers=h)).json()
        assert q["months_available"] == 6
        assert [o["months"] for o in q["options"]] == [1, 2, 3, 4, 5, 6]
        assert q["listing_fee"]["status"] == "unpaid" and q["fees_enabled"] is True

    @pytest.mark.asyncio
    async def test_the_prompt_asks_for_the_quoted_amount(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        q = (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote", headers=h)).json()
        r = await _pay(client, h, listing["id"], months=3)
        assert r.status_code == 200, r.text
        expected = next(o["total"] for o in q["options"] if o["months"] == 3)
        assert r.json()["amount"] == expected == mpesa.prompts[0]["amount"]
        assert mpesa.prompts[0]["phone"] == "254712345678"
        assert mpesa.prompts[0]["callback_url"].endswith(f"/pricing/listing-fee/callback/{SECRET}")

    @pytest.mark.asyncio
    async def test_paying_publishes_it_and_announces_it_once(self, client, fees_on, mpesa, announced):
        _, h = await _user()
        listing, paid = await _paid_listing(client, h, months=2)
        assert await _in_feed(client, listing["id"])
        assert (await client.get(f"/listings/{listing['id']}")).status_code == 200
        assert [e.listing_id for e in announced] == [listing["id"]]

        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "success"
        until = datetime.fromisoformat(status["paid_until"])
        assert abs((until - datetime.utcnow()) - 2 * MONTH) < timedelta(minutes=1)

        # Safaricom calls back again: nothing more happens.
        checkout = await _checkout_id(paid["payment_id"])
        await client.post(f"/pricing/listing-fee/callback/{SECRET}", json=_callback(checkout, paid["amount"]))
        again = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert again["paid_until"] == status["paid_until"]
        assert len(announced) == 1

    @pytest.mark.asyncio
    async def test_a_callback_claiming_another_amount_buys_nothing(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"], months=6)).json()
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(paid["payment_id"]), 1))
        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "failed" and status["failure_reason"] == "amount_mismatch"
        assert not await _in_feed(client, listing["id"])
        async with AsyncSessionLocal() as db:
            audit = (await db.execute(select(AuditLog).where(
                AuditLog.action == "listing_fee_amount_mismatch",
                AuditLog.resource_id == listing["id"]))).scalar_one_or_none()
        assert audit is not None

    @pytest.mark.asyncio
    async def test_the_unprotected_callback_is_closed_once_there_is_a_secret(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        body = _callback(await _checkout_id(paid["payment_id"]), paid["amount"])
        assert (await client.post("/pricing/listing-fee/callback", json=body)).status_code == 404
        assert (await client.post("/pricing/listing-fee/callback/wrong", json=body)).status_code == 404
        assert not await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_a_cancelled_prompt_leaves_it_unpaid(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(paid["payment_id"]), paid["amount"], code=1032))
        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "failed"
        assert status["listing_fee"]["status"] == "unpaid"

    @pytest.mark.asyncio
    async def test_one_prompt_at_a_time(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        assert (await _pay(client, h, listing["id"])).status_code == 200
        second = await _pay(client, h, listing["id"])
        assert second.status_code == 409 and "already on your phone" in second.json()["detail"]
        assert len(mpesa.prompts) == 1

    @pytest.mark.asyncio
    async def test_no_prompt_is_not_a_pending_payment(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        mpesa.fail = True
        assert (await _pay(client, h, listing["id"])).status_code == 502
        mpesa.fail = False
        assert (await _pay(client, h, listing["id"])).status_code == 200, \
            "a prompt that never went out must not block the retry"

    @pytest.mark.asyncio
    @pytest.mark.parametrize("phone", ["12345", "0812345678", "+44 7700 900123", ""])
    async def test_refuses_a_number_that_is_not_a_kenyan_mobile(self, client, fees_on, mpesa, phone):
        _, h = await _user()
        listing = await _listing(client, h)
        r = await client.post("/pricing/listing-fee/pay", headers=h, json={
            "listing_id": listing["id"], "months": 1, "phone_number": phone})
        assert r.status_code == 400
        assert mpesa.prompts == []

    @pytest.mark.asyncio
    async def test_someone_elses_listing_or_payment_is_not_found(self, client, fees_on, mpesa):
        _, h = await _user()
        _, other = await _user()
        listing = await _listing(client, h)
        assert (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote",
                                 headers=other)).status_code == 404
        assert (await _pay(client, other, listing["id"])).status_code == 404
        paid = (await _pay(client, h, listing["id"])).json()
        assert (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}",
                                 headers=other)).status_code == 404


# ── Renewing ─────────────────────────────────────────────────────────────────

class TestRenewing:
    @pytest.mark.asyncio
    async def test_extends_from_the_end_of_the_paid_time_up_to_six_months(self, client, fees_on, mpesa):
        _, h = await _user()
        listing, first = await _paid_listing(client, h, months=5)
        q = (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote", headers=h)).json()
        assert q["months_available"] == 1
        assert [o["months"] for o in q["options"]] == [1]

        too_many = await _pay(client, h, listing["id"], months=2)
        assert too_many.status_code == 409 and "6 months" in too_many.json()["detail"]

        second = (await _pay(client, h, listing["id"], months=1)).json()
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(second["payment_id"]), second["amount"]))
        until = {}
        for name, p in (("first", first), ("second", second)):
            status = (await client.get(f"/pricing/listing-fee/payments/{p['payment_id']}", headers=h)).json()
            until[name] = datetime.fromisoformat(status["paid_until"])
        assert until["second"] - until["first"] == MONTH

    @pytest.mark.asyncio
    async def test_a_listing_ending_soon_asks_for_renewal(self, client, fees_on, mpesa):
        _, h = await _user()
        listing, _ = await _paid_listing(client, h, months=1)
        async with AsyncSessionLocal() as db:
            row = await db.get(Listing, listing["id"])
            row.paid_until = datetime.utcnow() + timedelta(days=3)
            await db.commit()
        mine = (await client.get("/pricing/listing-fee/mine", headers=h)).json()["listings"]
        assert [(m["id"], m["listing_fee"]["status"]) for m in mine] == [(listing["id"], "ending")]
        assert await _in_feed(client, listing["id"]), "ending soon is still live"


# ── The status poll asks Safaricom when the callback is late ─────────────────

async def _age(payment_id, seconds=60):
    async with AsyncSessionLocal() as db:
        p = await db.get(ListingPayment, payment_id)
        p.created_at = datetime.utcnow() - timedelta(seconds=seconds)
        await db.commit()


class TestStatusPoll:
    @pytest.mark.asyncio
    async def test_a_confirmed_payment_is_applied_without_a_callback(self, client, fees_on, mpesa, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        await _age(paid["payment_id"])
        mpesa.query_answer = {"ResultCode": "0", "ResultDesc": "The service request is processed successfully."}
        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "success" and status["listing_fee"]["live"] is True
        # The callback arriving afterwards changes nothing.
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(paid["payment_id"]), paid["amount"]))
        again = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert again["paid_until"] == status["paid_until"]
        assert len([e for e in announced if e.listing_id == listing["id"]]) == 1

    @pytest.mark.asyncio
    async def test_a_prompt_still_open_stays_pending(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        await _age(paid["payment_id"], seconds=600)
        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "pending", "a late callback must still be able to land"

    @pytest.mark.asyncio
    async def test_a_cancelled_prompt_is_marked_failed(self, client, fees_on, mpesa):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        await _age(paid["payment_id"])
        mpesa.query_answer = {"ResultCode": "1032", "ResultDesc": "Request cancelled by user"}
        status = (await client.get(f"/pricing/listing-fee/payments/{paid['payment_id']}", headers=h)).json()
        assert status["status"] == "failed"


# ── Featured with the listing ────────────────────────────────────────────────

class TestFeaturedAddOn:
    @pytest.mark.asyncio
    async def test_a_short_term_seller_can_add_it_to_the_same_payment(self, client, fees_on, mpesa):
        _, h = await _user(SellerTier.short_term)
        listing = await _listing(client, h)
        alone = (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote", headers=h)).json()
        paid = (await _pay(client, h, listing["id"], featured_plan="week")).json()
        assert paid["amount"] == alone["options"][0]["total"] + 99
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(paid["payment_id"]), paid["amount"]))
        async with AsyncSessionLocal() as db:
            row = await db.get(Listing, listing["id"])
            assert row.is_featured and row.featured_until > datetime.utcnow() + timedelta(days=6)

    @pytest.mark.asyncio
    async def test_a_long_term_seller_cannot(self, client, fees_on, mpesa):
        _, h = await _user(SellerTier.long_term)
        listing = await _listing(client, h)
        r = await _pay(client, h, listing["id"], featured_plan="week")
        assert r.status_code == 403
        assert mpesa.prompts == []


# ── Money for a listing that is no longer for sale ───────────────────────────

class TestSoldWhilePaying:
    @pytest.mark.asyncio
    async def test_is_recorded_and_flagged_for_a_refund(self, client, fees_on, mpesa, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay(client, h, listing["id"])).json()
        async with AsyncSessionLocal() as db:
            row = await db.get(Listing, listing["id"])
            row.status = ListingStatus.cancelled
            await db.commit()
        await client.post(f"/pricing/listing-fee/callback/{SECRET}",
                          json=_callback(await _checkout_id(paid["payment_id"]), paid["amount"]))
        async with AsyncSessionLocal() as db:
            payment = await db.get(ListingPayment, paid["payment_id"])
            audit = (await db.execute(select(AuditLog).where(
                AuditLog.action == "listing_fee_on_inactive_listing",
                AuditLog.resource_id == listing["id"]))).scalar_one_or_none()
        assert payment.status == "success"
        assert audit is not None
        assert announced == [], "a withdrawn listing is not announced to buyers"


# ── A boost for a listing buyers can't see ───────────────────────────────────

class TestBoostNeedsALiveListing:
    @pytest.mark.asyncio
    async def test_is_refused_before_any_prompt(self, client, fees_on, monkeypatch):
        from api.routers import featured

        async def must_not_run(*_a, **_k):
            raise AssertionError("the M-Pesa prompt must not be sent")

        monkeypatch.setattr(featured, "_get_token", must_not_run)
        _, h = await _user(SellerTier.short_term)
        listing = await _listing(client, h)
        r = await client.post("/featured/boost", headers=h, json={
            "listing_id": listing["id"], "plan": "week", "phone_number": "0712345678"})
        assert r.status_code == 409
        assert "fee first" in r.json()["detail"]
