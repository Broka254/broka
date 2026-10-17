"""Online store plans (PRICING.md §5; api/domains/stores/billing.py).

What must hold:
  * with STORE_BILLING_ENABLED off nothing changes: the billing screens are
    closed, no store's visibility depends on a plan, and the M-Pesa callback
    route is unreachable without the secret;
  * an unpaid store is dark to buyers - out of the directory, its catalogue
    empty, its listings out of the feeds - while its owner keeps every
    screen and sees what is owed;
  * a plan is bought at the rate card's price for its size every 2 months
    (20 listings minimum, KES 40 a listing per two months, cheaper per
    listing as it grows); online stores carry no opening fee, dealer/agent
    cards keep theirs (waived from 6 months), and a callback claiming
    another amount buys nothing;
  * renewing extends from the end, upgrading turns unused days into days of
    the dearer plan, a downgrade and an over-a-year payment wait;
  * a car yard pays only once it holds its card's stock of live listings;
  * a store that predates billing gets grace time when it switches on - but
    not a free opening, and never a store created after billing was on;
  * store plans settle through ZetuPay the same way when it is enabled.

Same fixture shape as test_premium.py.
"""
import dataclasses
import itertools
import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.core import mpesa_stk
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Listing, init_db, reset_engine,
)
from api.domains.payments import service as zetupay_service
from api.domains.stores import billing as store_billing
from api.models.store_billing import StoreBillingMeta, StorePayment, StoreSubscription
from api.models.zetupay import Purpose

SECRET = "store-callback-secret"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_billing.db"
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


def _patch_billing(monkeypatch, **overrides):
    patched = dataclasses.replace(
        settings, store_billing_enabled=True, mpesa_callback_secret=SECRET, **overrides)
    for module in ("api.domains.stores.billing", "api.domains.stores.router",
                   "api.domains.stores.service", "api.domains.listings.paid",
                   "api.domains.listings.service"):
        monkeypatch.setattr(f"{module}.settings", patched)
    return patched


@pytest.fixture
def billing_on(monkeypatch):
    return _patch_billing(monkeypatch)


@pytest.fixture
def quiet_stk(monkeypatch):
    """Attempts that are refused still spend the caller's prompt budget;
    tests that deliberately make many attempts take the limiter out."""
    async def _ok(identifier):
        return None
    monkeypatch.setattr("api.domains.stores.router.stk_limiter.check_and_record", _ok)


class FakeMpesa:
    def __init__(self):
        self.prompts = []
        self.query_answer = {"errorCode": "500.001.1001"}

    async def stk_push(self, phone, amount, account_reference, description, callback_url):
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


_n = itertools.count(1)


async def _register(client, business_category="Electronics"):
    n = next(_n)
    phone = f"0746{n:06d}"
    code = (await client.post("/auth/otp/request", json={"phone": phone})).json()["debug_code"]
    token = (await client.post("/auth/otp/verify", json={"phone": phone, "code": code})).json()[
        "phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": token, "name": f"Store Owner {n}", "password": "Passw0rd!x",
        "lat": -1.286, "lng": 36.817, "account_type": "buyer_seller",
        "seller_tier": "long_term", "business_name": f"Biz {n}",
        "business_category": business_category, "business_location": "Nairobi",
    })
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], {"Authorization": f"Bearer {reg.json()['access_token']}"}


async def _store(client, headers, **fields) -> dict:
    r = await client.post("/stores", json={"name": f"Shop {next(_n)}", **fields}, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _listing(client, headers, store_id, name, category="Electronics") -> dict:
    r = await client.post("/listings/", json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": name, "category": category, "price": 1000, "lat": -1.0, "lng": 36.0,
        "store_id": store_id,
    }, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


def _callback(checkout_id, amount, code=0):
    stk = {"CheckoutRequestID": checkout_id, "ResultCode": code, "ResultDesc": "done"}
    if code == 0:
        stk["CallbackMetadata"] = {"Item": [
            {"Name": "Amount", "Value": amount}, {"Name": "MpesaReceiptNumber", "Value": "SKP1"}]}
    return {"Body": {"stkCallback": stk}}


async def _pay(client, headers, store_id, listings=30, months=2, amount=None):
    r = await client.post(f"/stores/{store_id}/billing/pay", headers=headers, json={
        "listings": listings, "months": months, "phone_number": "0712345678"})
    assert r.status_code == 200, r.text
    started = r.json()
    async with AsyncSessionLocal() as db:
        checkout = (await db.get(StorePayment, started["payment_id"])).checkout_request_id
    sent = await client.post(f"/stores/billing/callback/{SECRET}",
                             json=_callback(checkout, started["amount"] if amount is None else amount))
    assert sent.status_code == 200
    return started


async def _sub(store_id) -> StoreSubscription | None:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(StoreSubscription).where(
            StoreSubscription.store_id == store_id))).scalar_one_or_none()


async def _forget_grace_round():
    """Clear the one-time marker, as a deployment that has never started
    would: lets a test run ensure_grace_subscriptions again."""
    async with AsyncSessionLocal() as db:
        marker = await db.get(StoreBillingMeta, store_billing.GRACE_MARKER_ID)
        if marker is not None:
            await db.delete(marker)
            await db.commit()


async def _listing_row(listing_id) -> Listing:
    async with AsyncSessionLocal() as db:
        return await db.get(Listing, listing_id)


async def _audit(action, resource_id) -> list[AuditLog]:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(AuditLog).where(
            AuditLog.action == action, AuditLog.resource_id == resource_id))).scalars().all()


async def _age(payment_id, seconds=60):
    async with AsyncSessionLocal() as db:
        row = await db.get(StorePayment, payment_id)
        row.created_at = datetime.utcnow() - timedelta(seconds=seconds)
        await db.commit()


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


async def _in_directory(client, store_id) -> bool:
    stores = (await client.get("/stores", params={"limit": 100})).json()
    return any(s["id"] == store_id for s in stores)


# ── Off: nothing changes ─────────────────────────────────────────────────────

class TestBillingOff:
    @pytest.mark.asyncio
    async def test_the_screens_are_closed_and_no_store_is_gated(self, client):
        _, h = await _register(client)
        store = await _store(client, h)
        sid = store["id"]
        assert store["billing"] is None
        assert store["is_active"] is True
        assert (await client.get(f"/stores/{sid}/billing", headers=h)).status_code == 409
        assert (await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})).status_code == 409
        # Off, a store is visible exactly as before: no plan exists to gate it.
        assert (await client.get(f"/stores/{sid}")).json()["is_active"] is True
        assert await _in_directory(client, sid)

    @pytest.mark.asyncio
    async def test_the_callback_route_needs_the_secret(self, client, monkeypatch):
        monkeypatch.setattr("api.domains.stores.router.settings",
                            dataclasses.replace(settings, mpesa_callback_secret=SECRET))
        assert (await client.post("/stores/billing/callback", json={})).status_code == 404
        assert (await client.post("/stores/billing/callback/wrong", json={})).status_code == 404
        # Right secret, unknown checkout: accepted and ignored.
        ok = await client.post(f"/stores/billing/callback/{SECRET}", json={})
        assert ok.status_code == 200 and ok.json()["ResultCode"] == 0


# ── Unpaid: the owner sees everything, buyers nothing ────────────────────────

class TestUnpaidStoreIsDark:
    @pytest.mark.asyncio
    async def test_owner_sees_what_is_owed_but_buyers_see_nothing(self, client, billing_on):
        _, h = await _register(client)
        store = await _store(client, h)
        sid = store["id"]
        listing = await _listing(client, h, sid, "Phone A")

        assert store["billing"]["active"] is False
        assert store["is_active"] is True  # owner's own payload keeps the truth
        mine = (await client.get("/stores/mine", headers=h)).json()
        assert mine["id"] == sid and mine["billing"] == store["billing"]

        quote = (await client.get(f"/stores/{sid}/billing", headers=h)).json()
        assert quote["rate_card"]["id"] == "goods"
        assert quote["setup_fee"] == 0, "online stores carry no opening fee"
        assert quote["current"]["active"] is False
        assert quote["live_listings"] == 1

        public = (await client.get(f"/stores/{sid}")).json()
        assert public["is_active"] is False
        assert public["billing"] is None
        assert not await _in_directory(client, sid)
        assert (await client.get(f"/stores/{sid}/listings")).json() == []
        assert (await client.get(f"/stores/{sid}/categories")).json() == []
        assert not await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_the_billing_screen_is_the_owners_only(self, client, billing_on):
        _, h = await _register(client)
        _, other = await _register(client)
        sid = (await _store(client, h))["id"]
        assert (await client.get(f"/stores/{sid}/billing", headers=other)).status_code == 403

    @pytest.mark.asyncio
    async def test_the_door_can_be_closed_but_not_reopened_until_paid(self, client, billing_on):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        paused = await client.post(f"/stores/{sid}/status", json={"is_active": False}, headers=h)
        assert paused.status_code == 200 and paused.json()["is_active"] is False
        reopened = await client.post(f"/stores/{sid}/status", json={"is_active": True}, headers=h)
        assert reopened.status_code == 409
        assert "Pay" in reopened.json()["detail"]

    @pytest.mark.asyncio
    async def test_the_owners_list_reads_hidden_not_live(self, client, billing_on):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        await _listing(client, h, sid, "Phone B")
        body = (await client.get(f"/stores/{sid}/manage/listings", headers=h)).json()
        assert body["counts"]["live"] == 0 and body["counts"]["hidden"] == 1
        assert body["items"][0]["store_state"] == "hidden"


# ── Paying ───────────────────────────────────────────────────────────────────

class TestPaying:
    @pytest.mark.asyncio
    async def test_the_quote_is_the_cards_price(self, client, billing_on):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        quote = (await client.get(f"/stores/{sid}/billing",
                                  params={"listings": 30}, headers=h)).json()
        assert quote["current"]["setup_fee_paid"] is False
        assert quote["setup_fee"] == 0
        amounts = {p["months"]: p["amount"] for p in quote["plan"]["periods"]}
        assert amounts == {2: 1_099, 4: 2_069, 6: 2_899, 12: 5_409}
        # Below the online minimum and past the card's most: a person prices
        # that, not the app.
        assert (await client.get(f"/stores/{sid}/billing",
                                 params={"listings": 10}, headers=h)).status_code == 422
        assert (await client.get(f"/stores/{sid}/billing",
                                 params={"listings": 2000}, headers=h)).status_code == 422

    @pytest.mark.asyncio
    async def test_two_months_opens_the_store_and_is_receipted(self, client, billing_on, mpesa):
        uid, h = await _register(client)
        sid = (await _store(client, h))["id"]
        listing = await _listing(client, h, sid, "Phone C")
        started = await _pay(client, h, sid, months=2)
        assert started["amount"] == 1_099 and started["setup_fee"] == 0
        assert mpesa.prompts[-1]["amount"] == 1_099
        assert mpesa.prompts[-1]["phone"] == "254712345678"

        sub = await _sub(sid)
        assert sub.setup_fee_paid is True
        assert timedelta(days=59) < sub.paid_until - datetime.utcnow() <= timedelta(days=60)

        assert (await client.get(f"/stores/{sid}")).json()["is_active"] is True
        assert await _in_directory(client, sid)
        assert [i["id"] for i in (await client.get(f"/stores/{sid}/listings")).json()] == [listing["id"]]
        assert await _in_feed(client, listing["id"])
        owner_list = (await client.get(f"/stores/{sid}/manage/listings", headers=h)).json()
        assert owner_list["items"][0]["store_state"] == "live"

        receipt = next(c for c in (await client.get(
            f"/listings/seller/{uid}/receipts", headers=h)).json()["charges"] if c["kind"] == "store")
        assert receipt["amount"] == 1_099 and "opening fee" not in receipt["detail"]

        # Pause and reopen: only now can the door come back open.
        await client.post(f"/stores/{sid}/status", json={"is_active": False}, headers=h)
        reopen = await client.post(f"/stores/{sid}/status", json={"is_active": True}, headers=h)
        assert reopen.status_code == 200 and reopen.json()["is_active"] is True

    @pytest.mark.asyncio
    async def test_six_months_has_no_opening_fee_on_online_stores(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        started = await _pay(client, h, sid, months=6)
        assert started["amount"] == 2_899 and started["setup_fee"] == 0
        assert mpesa.prompts[-1]["amount"] == 2_899
        sub = await _sub(sid)
        assert sub.setup_fee_paid is True
        assert timedelta(days=179) < sub.paid_until - datetime.utcnow() <= timedelta(days=180)

    @pytest.mark.asyncio
    async def test_renewing_extends_and_never_repeats_the_opening_fee(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        await _pay(client, h, sid, months=2)
        first_end = (await _sub(sid)).paid_until
        await _pay(client, h, sid, months=2)
        assert (await _sub(sid)).paid_until - first_end == timedelta(days=60)
        assert mpesa.prompts[-1]["amount"] == 1_099, "renewal is the plan price alone"

    @pytest.mark.asyncio
    async def test_a_callback_claiming_another_amount_is_refused(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        started = await _pay(client, h, sid, months=2, amount=1)
        sub = await _sub(sid)  # the row a billing-on store opens with
        assert sub is not None and sub.paid_until is None, "a forged amount must buy nothing"
        assert (await client.get(f"/stores/{sid}")).json()["is_active"] is False
        status = (await client.get(
            f"/stores/{sid}/billing/payments/{started['payment_id']}", headers=h)).json()
        assert status["status"] == "failed" and status["failure_reason"] == "amount_mismatch"
        assert len(await _audit("store_amount_mismatch", sid)) == 1

    @pytest.mark.asyncio
    async def test_a_repeated_callback_changes_nothing(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        started = await _pay(client, h, sid, months=2)
        settled_end = (await _sub(sid)).paid_until
        async with AsyncSessionLocal() as db:
            checkout = (await db.get(StorePayment, started["payment_id"])).checkout_request_id
        await client.post(f"/stores/billing/callback/{SECRET}",
                          json=_callback(checkout, started["amount"]))
        assert (await _sub(sid)).paid_until == settled_end
        status = (await client.get(
            f"/stores/{sid}/billing/payments/{started['payment_id']}", headers=h)).json()
        assert status["status"] == "success"

    @pytest.mark.asyncio
    async def test_a_cancelled_prompt_can_be_retried_at_once(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        first = (await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})).json()
        async with AsyncSessionLocal() as db:
            checkout = (await db.get(StorePayment, first["payment_id"])).checkout_request_id
        await client.post(f"/stores/billing/callback/{SECRET}",
                          json=_callback(checkout, 0, code=1032))
        status = (await client.get(
            f"/stores/{sid}/billing/payments/{first['payment_id']}", headers=h)).json()
        assert status["status"] == "failed"
        await _pay(client, h, sid, months=2)
        assert (await _sub(sid)).setup_fee_paid is True

    @pytest.mark.asyncio
    async def test_an_unfinished_prompt_blocks_another(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        first = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})
        assert first.status_code == 200
        again = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})
        assert again.status_code == 409 and "two minutes" in again.json()["detail"]
        await _age(first.json()["payment_id"], seconds=180)
        third = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})
        assert third.status_code == 200

    @pytest.mark.asyncio
    async def test_the_status_poll_settles_a_late_callback(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        started = (await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})).json()
        mpesa.query_answer = {"ResultCode": 0, "ResultDesc": "ok"}
        await _age(started["payment_id"])
        status = (await client.get(
            f"/stores/{sid}/billing/payments/{started['payment_id']}", headers=h)).json()
        assert status["status"] == "success"
        assert (await _sub(sid)).setup_fee_paid is True


# ── Changing plans ───────────────────────────────────────────────────────────

class TestChangingPlans:
    @pytest.mark.asyncio
    async def test_upgrading_credits_the_unused_days(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        await _pay(client, h, sid, listings=30, months=2)
        started = await _pay(client, h, sid, listings=50, months=2)
        assert started["amount"] == 1_659 and started["setup_fee"] == 0
        sub = await _sub(sid)
        assert sub.plan_id == "goods-50" and sub.listings == 50
        # ~60 days of 550 become ~39.8 days of 830, plus the 2 months bought.
        left = sub.paid_until - datetime.utcnow()
        assert timedelta(days=90) < left < timedelta(days=112)

    @pytest.mark.asyncio
    async def test_a_downgrade_and_an_over_a_year_payment_wait(self, client, billing_on, mpesa):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        await _pay(client, h, sid, listings=50, months=2)
        down = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})
        assert down.status_code == 409 and "move down" in down.json()["detail"]
        ahead = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 50, "months": 12, "phone_number": "0712345678"})
        assert ahead.status_code == 409 and "year ahead" in ahead.json()["detail"]


# ── Stock floors ─────────────────────────────────────────────────────────────

class TestStockFloors:
    @pytest.mark.asyncio
    async def test_a_car_yard_pays_only_with_five_live_listings(
            self, client, billing_on, mpesa, quiet_stk):
        _, h = await _register(client, business_category="Automobiles")
        sid = (await _store(client, h))["id"]
        quote = (await client.get(f"/stores/{sid}/billing",
                                  params={"listings": 10}, headers=h)).json()
        assert quote["rate_card"]["id"] == "vehicles" and quote["min_listings"] == 5
        assert {p["months"]: p["amount"] for p in quote["plan"]["periods"]}[2] == 6_298

        refused = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 10, "months": 2, "phone_number": "0712345678"})
        assert refused.status_code == 409 and "at least 5 live listings" in refused.json()["detail"]

        for i in range(4):
            await _listing(client, h, sid, f"Car {i}", category="Automobiles")
        refused = await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 10, "months": 2, "phone_number": "0712345678"})
        assert refused.status_code == 409 and "add 1 more" in refused.json()["detail"]

        fifth = await _listing(client, h, sid, "Car 5", category="Automobiles")
        started = await _pay(client, h, sid, listings=10, months=2)
        assert started["amount"] == 6_298 and started["setup_fee"] == 299
        assert await _in_feed(client, fifth["id"])


# ── Grace ────────────────────────────────────────────────────────────────────

class TestGrace:
    @pytest.mark.asyncio
    async def test_stores_that_predate_billing_get_grace_but_owe_the_opening(
            self, client, monkeypatch, mpesa):
        await _forget_grace_round()
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]  # created while billing was off

        _patch_billing(monkeypatch)
        created = await store_billing.ensure_grace_subscriptions()
        assert created >= 1
        sub = await _sub(sid)
        assert sub is not None and sub.plan_id is None
        assert sub.setup_fee_paid is False, "grace must not waive the opening fee"
        assert timedelta(days=29) < sub.paid_until - datetime.utcnow() <= timedelta(days=30)
        assert await _in_directory(client, sid)

        # Idempotent: a second worker's pass creates nothing.
        assert await store_billing.ensure_grace_subscriptions() == 0

        quote = (await client.get(f"/stores/{sid}/billing",
                                  params={"listings": 30}, headers=h)).json()
        assert quote["setup_fee"] == 0, "online stores carry no opening fee"
        started = await _pay(client, h, sid, months=2)
        assert started["amount"] == 1_099

    @pytest.mark.asyncio
    async def test_a_store_created_while_billing_is_on_gets_no_grace(
            self, client, billing_on, mpesa):
        # The bug this pins down: a store created while billing was on used
        # to have no subscription row, so the next startup's grace round
        # read it as a pre-billing store and gave a shop that never paid a
        # free month in the directory.
        await _forget_grace_round()
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]

        sub = await _sub(sid)
        assert sub is not None, "a store created while billing is on opens with its own row"
        assert sub.plan_id is None and sub.paid_until is None
        assert sub.setup_fee_paid is False

        # A fresh round - marker cleared, as if billing had just been
        # switched on - must not reach it: it is not rowless.
        await store_billing.ensure_grace_subscriptions()
        still = await _sub(sid)
        assert still.paid_until is None, "grace reached a store created after billing was on"
        assert not await _in_directory(client, sid)
        assert (await client.get(f"/stores/{sid}")).json()["is_active"] is False

        await _pay(client, h, sid, months=2)
        assert await _in_directory(client, sid)


# ── ZetuPay ──────────────────────────────────────────────────────────────────

class TestZetuPay:
    @pytest.mark.asyncio
    async def test_a_store_plan_runs_through_zetupay_when_it_is_on(
            self, client, billing_on, monkeypatch):
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        monkeypatch.setattr(zetupay_service, "enabled", lambda: True)

        async def _start(db, **kwargs):
            # The real service commits the domain row it was handed
            # (payments/service.py), so the mock must too.
            await db.commit()

        start = AsyncMock(side_effect=_start)
        monkeypatch.setattr(zetupay_service, "start", start)

        started = (await client.post(f"/stores/{sid}/billing/pay", headers=h, json={
            "listings": 30, "months": 2, "phone_number": "0712345678"})).json()
        assert start.await_count == 1
        assert start.await_args.kwargs["purpose"] == Purpose.STORE
        assert start.await_args.kwargs["target_id"] == started["payment_id"]

        async with AsyncSessionLocal() as db:
            payment = await db.get(StorePayment, started["payment_id"])
            assert payment.provider == zetupay_service.PROVIDER

        async with AsyncSessionLocal() as db:
            await store_billing.zetupay_settled(db, started["payment_id"], "ZPR123")
        sub = await _sub(sid)
        assert sub is not None and sub.setup_fee_paid is True
        async with AsyncSessionLocal() as db:
            payment = await db.get(StorePayment, started["payment_id"])
            assert payment.status == "success" and payment.mpesa_receipt == "ZPR123"

    @pytest.mark.asyncio
    async def test_zetupay_can_report_a_prompt_failed(self, client, billing_on):
        uid, h = await _register(client)
        sid = (await _store(client, h))["id"]
        async with AsyncSessionLocal() as db:
            payment = StorePayment(
                store_id=sid, user_id=uid, plan_id="goods-30", listings=30, months=2,
                amount=1_099, setup_fee=0, phone="254712345678", status="pending",
                provider="zetupay",
            )
            db.add(payment)
            await db.commit()
            await db.refresh(payment)
            await store_billing.zetupay_failed(db, payment.id, "cancelled on the phone")
        async with AsyncSessionLocal() as db:
            payment = await db.get(StorePayment, payment.id)
            assert payment.status == "failed" and payment.processed is True


# ── Fee exemption ────────────────────────────────────────────────────────────

class TestListingFeeExemption:
    @pytest.mark.asyncio
    async def test_store_listings_pay_no_listing_fee_and_follow_the_plan(
            self, client, monkeypatch, mpesa):
        _patch_billing(monkeypatch, listing_fees_enabled=True)
        _, h = await _register(client)
        sid = (await _store(client, h))["id"]
        listing = await _listing(client, h, sid, "Phone D")
        row = await _listing_row(listing["id"])
        assert row.paid_until is None, "a store listing must not wait on a listing fee"
        assert not await _in_feed(client, listing["id"]), "and still hidden while the store is unpaid"
        await _pay(client, h, sid, months=2)
        assert await _in_feed(client, listing["id"])
