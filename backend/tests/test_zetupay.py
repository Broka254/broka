"""ZetuPay: money users pay BROKA (api/core/zetupay.py, api/domains/payments/).

What must hold:
  * with ZETUPAY_ENABLED, listing fees, plans, boosts and badges are charged
    through ZetuPay, under a unique BROKA reference that identifies the
    user, the purpose, the amount and the record paid for - and Daraja is
    not asked;
  * ZetuPay's 202 "processing" buys nothing; only a verified successful
    webhook, or ZetuPay's own status answer, does;
  * the webhook is refused without the right x-zetupay-secret;
  * a payment is applied once, however often ZetuPay delivers its webhook
    or the status poll races it (waveTransactionId);
  * another amount, a second payment for a paid reference, and money for a
    reference BROKA never issued buy nothing and are flagged for a refund;
  * ZetuPay down or slow fails the payment cleanly, and a payment that
    arrives anyway is still applied;
  * deal money never comes near ZetuPay: E-Confirm keeps it.
"""
import dataclasses
import json
import uuid
from datetime import datetime, timedelta
from pathlib import Path

import httpx
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import func, select

from main import app
from api.core import config, mpesa_stk, zetupay
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Listing, SellerTier, User,
    VerificationPayment, init_db, reset_engine,
)
from api.domains.listings.paid import MONTH
from api.domains.payments import service
from api.models.listing_payment import ListingPayment
from api.models.subscription import Subscription, SubscriptionPayment
from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayTransaction
from api.security import create_access_token

WEBHOOK_SECRET = "zp-webhook-secret-for-tests"
MPESA_SECRET = "mpesa-callback-secret-for-tests"
BACKEND = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zetupay.db"
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


_SETTINGS_USERS = (
    "api.core.zetupay", "api.domains.payments.service",
    "api.domains.listings.service", "api.domains.pricing.payments",
    "api.domains.pricing.service", "api.domains.pricing.router",
    "api.domains.premium.entitlements", "api.domains.premium.payments",
    "api.domains.premium.router",
)


def _settings(monkeypatch, **changes):
    patched = dataclasses.replace(settings, **changes)
    for module in _SETTINGS_USERS:
        monkeypatch.setattr(f"{module}.settings", patched)
    return patched


@pytest.fixture
def zetupay_on(monkeypatch):
    return _settings(
        monkeypatch, zetupay_enabled=True, zetupay_secret_key="sk_test_unit",
        zetupay_webhook_secret=WEBHOOK_SECRET, mpesa_callback_secret=MPESA_SECRET,
    )


@pytest.fixture
def fees_on(monkeypatch, zetupay_on):
    return _settings(
        monkeypatch, zetupay_enabled=True, zetupay_secret_key="sk_test_unit",
        zetupay_webhook_secret=WEBHOOK_SECRET, mpesa_callback_secret=MPESA_SECRET,
        listing_fees_enabled=True,
    )


@pytest.fixture
def premium_on(monkeypatch, zetupay_on):
    return _settings(
        monkeypatch, zetupay_enabled=True, zetupay_secret_key="sk_test_unit",
        zetupay_webhook_secret=WEBHOOK_SECRET, mpesa_callback_secret=MPESA_SECRET,
        premium_enabled=True,
    )


class FakeZetuPay:
    """Stands in for ZetuPay's API: records prompts, answers status queries
    as told. Each prompt is accepted with a 202 - not a payment."""

    def __init__(self):
        self.prompts = []
        self.fail = None          # None | "down" | "timeout"
        self.status = {}          # reference -> what the status endpoint answers

    async def stk_push(self, phone, amount, reference, description):
        if self.fail == "down":
            raise zetupay.ZetuPayUnavailable("down")
        if self.fail == "timeout":
            raise zetupay.ZetuPayTimeout("slow")
        self.prompts.append({"phone": phone, "amount": amount, "reference": reference,
                             "description": description})
        return zetupay.Accepted(provider_id=f"zp_{uuid.uuid4().hex[:10]}")

    async def transaction_status(self, reference):
        body = self.status.get(reference)
        return zetupay.parse_event(body) if body is not None else None


@pytest.fixture
def zp(monkeypatch):
    fake = FakeZetuPay()
    monkeypatch.setattr(zetupay, "stk_push", fake.stk_push)
    monkeypatch.setattr(zetupay, "transaction_status", fake.transaction_status)

    async def no_daraja(*_a, **_k):
        raise AssertionError("Daraja must not be asked while ZetuPay is on")

    monkeypatch.setattr(mpesa_stk, "stk_push", no_daraja)
    monkeypatch.setattr(mpesa_stk, "stk_query", no_daraja)
    return fake


@pytest.fixture
def announced(monkeypatch):
    events = []

    async def record(event):
        events.append(event)

    monkeypatch.setattr("api.domains.listings.service.publish", record)
    monkeypatch.setattr("api.domains.pricing.payments.publish", record)
    return events


async def _user(tier=SellerTier.short_term) -> tuple[User, dict]:
    u = User(name="Payer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", seller_tier=tier)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers) -> dict:
    body = {"description": "Well kept, works perfectly - selling because I upgraded.",
            "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 20000, "lat": -1.28, "lng": 36.82}
    r = await client.post("/listings/", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _pay_fee(client, headers, listing_id, months=1):
    return await client.post("/pricing/listing-fee/pay", headers=headers, json={
        "listing_id": listing_id, "months": months, "phone_number": "0712345678"})


async def _charge(purpose, target_id) -> ZetuPayPayment:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(ZetuPayPayment).where(
            ZetuPayPayment.purpose == purpose, ZetuPayPayment.target_id == target_id,
        ))).scalar_one()


def _event(reference, amount, status="success", wave=None, receipt="UJ1ABC2DEF"):
    """A ZetuPay transaction webhook."""
    return {"event": "transaction.updated", "data": {
        "reference": reference, "amount": amount, "currency": "KES", "status": status,
        "waveTransactionId": wave or f"wave_{uuid.uuid4().hex[:12]}",
        "mpesaReceiptNumber": receipt if status == "success" else None,
    }}


async def _webhook(client, body, secret=WEBHOOK_SECRET):
    headers = {} if secret is None else {"x-zetupay-secret": secret}
    return await client.post("/payments/zetupay/webhook", json=body, headers=headers)


async def _in_feed(client, listing_id) -> bool:
    items = (await client.get("/listings/", params={"limit": 100, "sort": "recent"})).json()
    return any(i["id"] == listing_id for i in items)


async def _fee_status(client, headers, payment_id) -> dict:
    return (await client.get(f"/pricing/listing-fee/payments/{payment_id}", headers=headers)).json()


async def _audit(action, resource_id) -> list[AuditLog]:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(AuditLog).where(
            AuditLog.action == action, AuditLog.resource_id == resource_id))).scalars().all()


async def _age(charge_id, seconds=60):
    async with AsyncSessionLocal() as db:
        row = await db.get(ZetuPayPayment, charge_id)
        row.created_at = datetime.utcnow() - timedelta(seconds=seconds)
        await db.commit()


# ── The listing fee through ZetuPay ──────────────────────────────────────────

class TestListingFee:
    @pytest.mark.asyncio
    async def test_the_prompt_goes_through_zetupay_under_a_broka_reference(self, client, fees_on, zp):
        seller, h = await _user()
        listing = await _listing(client, h)
        quote = (await client.get(f"/pricing/listing-fee/listings/{listing['id']}/quote", headers=h)).json()
        r = await _pay_fee(client, h, listing["id"], months=3)
        assert r.status_code == 200, r.text
        expected = next(o["total"] for o in quote["options"] if o["months"] == 3)
        assert r.json()["amount"] == expected

        charge = await _charge(Purpose.LISTING_FEE, r.json()["payment_id"])
        assert zp.prompts == [{"phone": "254712345678", "amount": expected,
                               "reference": charge.reference, "description": "BROKA listing 3mo"}]
        # The reference names the user, the purpose, the amount and the record.
        assert charge.reference.startswith("LF") and len(charge.reference) == 12
        assert (charge.user_id, charge.purpose, charge.amount, charge.related_id) == \
            (seller.id, "listing_fee", expected, listing["id"])
        async with AsyncSessionLocal() as db:
            row = await db.get(ListingPayment, r.json()["payment_id"])
        assert row.provider == "zetupay" and row.checkout_request_id is None

    @pytest.mark.asyncio
    async def test_processing_is_not_paid(self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        assert charge.status == "processing"
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"
        assert not await _in_feed(client, listing["id"])
        assert announced == []

    @pytest.mark.asyncio
    async def test_a_successful_payment_activates_the_listing(self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"], months=2)).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])

        r = await _webhook(client, _event(charge.reference, paid["amount"], wave="wave_ok_1",
                                          receipt="UJ9PAID001"))
        assert r.status_code == 200 and r.json()["outcome"] == "applied"

        assert await _in_feed(client, listing["id"])
        assert [e.listing_id for e in announced] == [listing["id"]]
        status = await _fee_status(client, h, paid["payment_id"])
        assert status["status"] == "success" and status["listing_fee"]["live"] is True
        until = datetime.fromisoformat(status["paid_until"])
        assert abs((until - datetime.utcnow()) - 2 * MONTH) < timedelta(minutes=1)
        settled = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        assert (settled.status, settled.wave_transaction_id, settled.mpesa_receipt) == \
            ("success", "wave_ok_1", "UJ9PAID001")
        assert await _audit("zetupay_payment_settled", settled.id)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("status", ["failed", "cancelled"])
    async def test_a_failed_or_cancelled_payment_leaves_it_unpaid(self, client, fees_on, zp, status):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        r = await _webhook(client, _event(charge.reference, paid["amount"], status=status))
        assert r.json()["outcome"] == "failed"
        fee = await _fee_status(client, h, paid["payment_id"])
        assert fee["status"] == "failed" and fee["listing_fee"]["status"] == "unpaid"
        assert not await _in_feed(client, listing["id"])
        # Not "already on your phone": a finished prompt allows the retry.
        assert (await _pay_fee(client, h, listing["id"])).status_code == 200

    @pytest.mark.asyncio
    async def test_a_duplicate_webhook_is_applied_once(self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        body = _event(charge.reference, paid["amount"], wave="wave_dup_1")

        first = await _webhook(client, body)
        before = await _fee_status(client, h, paid["payment_id"])
        second = await _webhook(client, body)
        after = await _fee_status(client, h, paid["payment_id"])

        assert first.json()["outcome"] == "applied"
        assert second.status_code == 200 and second.json()["outcome"] == "duplicate"
        assert after["paid_until"] == before["paid_until"]
        assert len(announced) == 1
        async with AsyncSessionLocal() as db:
            count = (await db.execute(select(func.count()).select_from(ZetuPayTransaction).where(
                ZetuPayTransaction.wave_transaction_id == "wave_dup_1"))).scalar()
        assert count == 1

    @pytest.mark.asyncio
    async def test_a_second_payment_for_a_paid_reference_is_flagged_not_applied(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _webhook(client, _event(charge.reference, paid["amount"], wave="wave_first"))
        before = await _fee_status(client, h, paid["payment_id"])

        r = await _webhook(client, _event(charge.reference, paid["amount"], wave="wave_second"))
        assert r.json()["outcome"] == "duplicate_payment"
        assert (await _fee_status(client, h, paid["payment_id"]))["paid_until"] == before["paid_until"]
        assert await _audit("zetupay_duplicate_payment", charge.id), "a person must refund it"

    @pytest.mark.asyncio
    async def test_the_wrong_amount_buys_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"], months=6)).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])

        r = await _webhook(client, _event(charge.reference, 1))
        assert r.status_code == 200 and r.json()["outcome"] == "amount_mismatch"
        fee = await _fee_status(client, h, paid["payment_id"])
        assert fee["status"] == "failed" and fee["failure_reason"] == "amount_mismatch"
        assert not await _in_feed(client, listing["id"])
        assert await _audit("zetupay_amount_mismatch", charge.id)

    @pytest.mark.asyncio
    async def test_another_currency_buys_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        body = _event(charge.reference, paid["amount"])
        body["data"]["currency"] = "USD"
        assert (await _webhook(client, body)).json()["outcome"] == "amount_mismatch"
        assert not await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_an_unknown_reference_is_recorded_and_flagged(self, client, fees_on, zp):
        r = await _webhook(client, _event("LFNOSUCHREF0", 500, wave="wave_stranger"))
        assert r.status_code == 200 and r.json()["outcome"] == "unknown_reference"
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(ZetuPayTransaction).where(
                ZetuPayTransaction.wave_transaction_id == "wave_stranger"))).scalar_one()
        assert row.payment_id is None and row.outcome == "unknown_reference"
        assert await _audit("zetupay_unknown_reference", "wave_stranger")

    @pytest.mark.asyncio
    @pytest.mark.parametrize("secret", ["wrong-secret", "", None])
    async def test_a_webhook_without_the_secret_is_refused(self, client, fees_on, zp, secret):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        wave = f"wave_forged_{uuid.uuid4().hex[:6]}"

        r = await _webhook(client, _event(charge.reference, paid["amount"], wave=wave), secret=secret)
        assert r.status_code == 401
        assert not await _in_feed(client, listing["id"])
        assert (await _charge(Purpose.LISTING_FEE, paid["payment_id"])).status == "processing"
        async with AsyncSessionLocal() as db:
            assert (await db.execute(select(ZetuPayTransaction).where(
                ZetuPayTransaction.wave_transaction_id == wave))).scalar_one_or_none() is None

    @pytest.mark.asyncio
    async def test_no_configured_secret_refuses_every_webhook(self, client, monkeypatch, zp):
        _settings(monkeypatch, zetupay_enabled=True, zetupay_webhook_secret="")
        r = await _webhook(client, _event("LFANYTHING00", 100), secret="")
        assert r.status_code == 401

    @pytest.mark.asyncio
    async def test_a_body_that_is_not_json_is_refused(self, client, fees_on, zp):
        r = await client.post("/payments/zetupay/webhook", content=b"not json",
                              headers={"x-zetupay-secret": WEBHOOK_SECRET,
                                       "content-type": "application/json"})
        assert r.status_code == 400

    @pytest.mark.asyncio
    async def test_a_processing_event_changes_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        r = await _webhook(client, _event(charge.reference, paid["amount"], status="processing",
                                          wave="wave_progress"))
        assert r.json()["outcome"] == "ignored"
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"
        # The same transaction then succeeding is not a duplicate of it.
        r = await _webhook(client, _event(charge.reference, paid["amount"], wave="wave_progress"))
        assert r.json()["outcome"] == "applied"


# ── ZetuPay down, slow or late ───────────────────────────────────────────────

class TestProviderFailure:
    @pytest.mark.asyncio
    async def test_zetupay_down_fails_the_payment_and_allows_a_retry(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        zp.fail = "down"
        r = await _pay_fee(client, h, listing["id"])
        assert r.status_code == 502 and "Couldn't reach M-Pesa" in r.json()["detail"]
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(ListingPayment).where(
                ListingPayment.listing_id == listing["id"]))).scalar_one()
        assert (row.status, row.failure_reason) == ("failed", "prompt_not_sent")
        assert (await _charge(Purpose.LISTING_FEE, row.id)).status == "failed"
        zp.fail = None
        assert (await _pay_fee(client, h, listing["id"])).status_code == 200

    @pytest.mark.asyncio
    async def test_a_timeout_is_failed_but_a_payment_that_arrives_anyway_lands(
            self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        zp.fail = "timeout"
        r = await _pay_fee(client, h, listing["id"])
        assert r.status_code == 502 and "slow" in r.json()["detail"]
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(ListingPayment).where(
                ListingPayment.listing_id == listing["id"]))).scalar_one()
        charge = await _charge(Purpose.LISTING_FEE, row.id)
        assert (charge.status, charge.failure_reason) == ("failed", "provider_timeout")

        # The prompt had gone out after all, and the seller paid it.
        r = await _webhook(client, _event(charge.reference, row.amount))
        assert r.json()["outcome"] == "applied"
        assert (await _fee_status(client, h, row.id))["status"] == "success"
        assert await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_the_status_poll_asks_zetupay_when_the_webhook_is_late(
            self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id)
        late = _event(charge.reference, paid["amount"], wave="wave_polled")
        zp.status[charge.reference] = late["data"]

        status = await _fee_status(client, h, paid["payment_id"])
        assert status["status"] == "success" and status["listing_fee"]["live"] is True
        # The webhook arriving afterwards changes nothing.
        r = await _webhook(client, late)
        assert r.json()["outcome"] == "duplicate"
        assert (await _fee_status(client, h, paid["payment_id"]))["paid_until"] == status["paid_until"]
        assert len([e for e in announced if e.listing_id == listing["id"]]) == 1

    @pytest.mark.asyncio
    async def test_a_prompt_still_open_stays_pending(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id, seconds=600)
        zp.status[charge.reference] = {"reference": charge.reference, "status": "processing"}
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"

    @pytest.mark.asyncio
    async def test_the_sweep_settles_a_payment_whose_webhook_never_came(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id, seconds=600)
        zp.status[charge.reference] = _event(charge.reference, paid["amount"])["data"]

        async with AsyncSessionLocal() as db:
            assert await service.reconcile_stale(db) >= 1
        assert (await _charge(Purpose.LISTING_FEE, paid["payment_id"])).status == "success"
        assert await _in_feed(client, listing["id"])


# ── Plans: bought and renewed through ZetuPay ────────────────────────────────

async def _subscribe(client, headers, plan="plus", months=1):
    r = await client.post("/premium/subscribe", headers=headers, json={
        "plan_id": plan, "months": months, "phone_number": "0712345678"})
    assert r.status_code == 200, r.text
    return r.json()


async def _paid_until(user_id) -> datetime:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Subscription.paid_until).where(
            Subscription.user_id == user_id))).scalar_one()


class TestSubscription:
    @pytest.mark.asyncio
    async def test_a_plan_is_bought_then_renewed_from_where_it_ends(self, client, premium_on, zp):
        user, h = await _user()
        first = await _subscribe(client, h)
        charge = await _charge(Purpose.SUBSCRIPTION, first["payment_id"])
        assert charge.reference.startswith("PL") and charge.related_id == "plus"
        assert (await _webhook(client, _event(charge.reference, first["amount"]))).json()["outcome"] == "applied"
        ends = await _paid_until(user.id)
        assert abs((ends - datetime.utcnow()) - MONTH) < timedelta(minutes=1)
        assert (await client.get("/premium/me", headers=h)).json()["plan"]["id"] == "plus"

        # Renewal: another payment for the same plan, extending it.
        second = await _subscribe(client, h)
        renewal = await _charge(Purpose.SUBSCRIPTION, second["payment_id"])
        assert renewal.reference != charge.reference
        body = _event(renewal.reference, second["amount"], wave="wave_renewal")
        assert (await _webhook(client, body)).json()["outcome"] == "applied"
        assert await _paid_until(user.id) - ends == MONTH
        # ...once, however often ZetuPay says so.
        assert (await _webhook(client, body)).json()["outcome"] == "duplicate"
        assert await _paid_until(user.id) - ends == MONTH
        status = (await client.get(f"/premium/payments/{second['payment_id']}", headers=h)).json()
        assert status["status"] == "success"

    @pytest.mark.asyncio
    async def test_the_wrong_amount_buys_no_plan_time(self, client, premium_on, zp):
        user, h = await _user()
        started = await _subscribe(client, h, plan="pro")
        charge = await _charge(Purpose.SUBSCRIPTION, started["payment_id"])
        r = await _webhook(client, _event(charge.reference, started["amount"] - 1))
        assert r.json()["outcome"] == "amount_mismatch"
        async with AsyncSessionLocal() as db:
            assert (await db.execute(select(Subscription).where(
                Subscription.user_id == user.id))).scalar_one_or_none() is None
            row = await db.get(SubscriptionPayment, started["payment_id"])
        assert (row.status, row.failure_reason, row.provider) == ("failed", "amount_mismatch", "zetupay")


# ── Boosts and badges ────────────────────────────────────────────────────────

class TestBoostAndBadge:
    @pytest.mark.asyncio
    async def test_a_boost_is_paid_through_zetupay(self, client, zetupay_on, zp):
        _, h = await _user(SellerTier.short_term)
        listing = await _listing(client, h)
        r = await client.post("/featured/boost", headers=h, json={
            "listing_id": listing["id"], "plan": "week", "phone_number": "0712345678"})
        assert r.status_code == 200, r.text
        reference = r.json()["checkout_request_id"]
        assert reference.startswith("BS") and zp.prompts[-1]["amount"] == 99

        async with AsyncSessionLocal() as db:
            assert not (await db.get(Listing, listing["id"])).is_featured, "a 202 features nothing"
        assert (await _webhook(client, _event(reference, 99))).json()["outcome"] == "applied"
        status = (await client.get(f"/featured/status/{listing['id']}", headers=h)).json()
        assert status["payment_status"] == "success" and status["is_featured"] is True
        until = datetime.fromisoformat(status["featured_until"])
        assert until > datetime.utcnow() + timedelta(days=6)

    @pytest.mark.asyncio
    async def test_the_daraja_callback_cannot_settle_a_zetupay_boost(self, client, zetupay_on, zp, monkeypatch):
        monkeypatch.setattr("api.routers.featured.CALLBACK_SECRET", MPESA_SECRET)
        _, h = await _user(SellerTier.short_term)
        listing = await _listing(client, h)
        reference = (await client.post("/featured/boost", headers=h, json={
            "listing_id": listing["id"], "plan": "week", "phone_number": "0712345678"})).json()["checkout_request_id"]
        forged = {"Body": {"stkCallback": {"CheckoutRequestID": reference, "ResultCode": 0,
                                           "CallbackMetadata": {"Item": [
                                               {"Name": "MpesaReceiptNumber", "Value": "X"}]}}}}
        await client.post(f"/featured/callback/{MPESA_SECRET}", json=forged)
        async with AsyncSessionLocal() as db:
            assert not (await db.get(Listing, listing["id"])).is_featured

    @pytest.mark.asyncio
    async def test_a_badge_is_paid_through_zetupay(self, client, zetupay_on, zp):
        _, h = await _user()
        r = await client.post("/verify/purchase", headers=h, json={
            "tier": "basic", "phone_number": "0712345678"})
        assert r.status_code == 200, r.text
        reference = r.json()["checkout_request_id"]
        assert reference.startswith("VB") and zp.prompts[-1]["amount"] == 299
        assert (await client.get("/verify/status", headers=h)).json()["is_verified"] is False

        assert (await _webhook(client, _event(reference, 299))).json()["outcome"] == "applied"
        status = (await client.get("/verify/status", headers=h)).json()
        assert status["is_verified"] is True and status["payment_status"] == "success"
        async with AsyncSessionLocal() as db:
            row = (await db.execute(select(VerificationPayment).where(
                VerificationPayment.checkout_request_id == reference))).scalar_one()
        assert row.provider == "zetupay"

    @pytest.mark.asyncio
    async def test_a_number_that_is_not_kenyan_is_refused_before_any_prompt(self, client, zetupay_on, zp):
        _, h = await _user()
        r = await client.post("/verify/purchase", headers=h, json={
            "tier": "basic", "phone_number": "+44 7700 900123"})
        assert r.status_code == 400
        assert zp.prompts == []


# ── Deal money stays with E-Confirm ──────────────────────────────────────────

class TestSeparation:
    def test_no_deal_money_path_knows_zetupay(self):
        deal_paths = [
            *sorted((BACKEND / "api/domains/escrow").glob("*.py")),
            *sorted((BACKEND / "api/domains/disputes").glob("*.py")),
            BACKEND / "api/core/econfirm_client.py",
            BACKEND / "api/routers/mpesa.py",
            BACKEND / "api/routers/escrow.py",
            BACKEND / "api/routers/deal.py",
        ]
        for path in deal_paths:
            assert "zetupay" not in path.read_text().lower(), path

    @pytest.mark.asyncio
    async def test_zetupay_takes_only_broka_charges(self, zetupay_on, zp):
        user, _ = await _user()
        async with AsyncSessionLocal() as db:
            with pytest.raises(ValueError):
                await service.start(db, user_id=user.id, purpose="deal_funding", amount=5000,
                                    phone="254712345678", target_id="deal-1", related_id=None,
                                    description="deal")
            assert (await db.execute(select(ZetuPayPayment).where(
                ZetuPayPayment.target_id == "deal-1"))).scalar_one_or_none() is None
        assert zp.prompts == []
        assert set(Purpose.ALL) == {"listing_fee", "subscription", "boost", "verification"}


# ── The ZetuPay client itself ────────────────────────────────────────────────

class TestClient:
    @pytest.fixture
    def api(self, monkeypatch):
        _settings(monkeypatch, zetupay_secret_key="sk_live_never_logged",
                  zetupay_base_url="https://pay.zetupay.test/api/v1")
        calls = {"requests": [], "respond": lambda request: httpx.Response(202, json={
            "status": "processing", "transactionId": "zp_123"})}

        def handler(request):
            calls["requests"].append(request)
            return calls["respond"](request)

        def client():
            return httpx.AsyncClient(transport=httpx.MockTransport(handler),
                                     base_url="https://pay.zetupay.test/api/v1")

        monkeypatch.setattr(zetupay, "_client", client)
        return calls

    @pytest.mark.asyncio
    async def test_a_202_is_accepted_and_nothing_more(self, api):
        accepted = await zetupay.stk_push("254712345678", 199, "PL0123456789", "BROKA Plus 1mo")
        assert accepted == zetupay.Accepted(provider_id="zp_123")
        request = api["requests"][0]
        assert request.url.path == "/api/v1" + zetupay.STK_PUSH_PATH
        assert request.headers["authorization"] == "Bearer sk_live_never_logged"
        assert json.loads(request.content) == {"phone": "254712345678", "amount": 199,
                                               "reference": "PL0123456789",
                                               "description": "BROKA Plus 1mo"}

    @pytest.mark.asyncio
    async def test_a_refusal_is_unavailable(self, api):
        api["respond"] = lambda request: httpx.Response(400, json={"message": "bad phone"})
        with pytest.raises(zetupay.ZetuPayUnavailable) as exc:
            await zetupay.stk_push("254712345678", 199, "PL0123456789", "x")
        assert not isinstance(exc.value, zetupay.ZetuPayTimeout)

    @pytest.mark.asyncio
    async def test_a_202_saying_failed_is_unavailable(self, api):
        api["respond"] = lambda request: httpx.Response(202, json={"status": "failed"})
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.stk_push("254712345678", 199, "PL0123456789", "x")

    @pytest.mark.asyncio
    async def test_a_timeout_is_its_own_kind(self, api, caplog):
        def slow(request):
            raise httpx.ReadTimeout("slow", request=request)

        api["respond"] = slow
        with pytest.raises(zetupay.ZetuPayTimeout):
            await zetupay.stk_push("254712345678", 199, "PL0123456789", "x")
        assert "sk_live_never_logged" not in caplog.text

    @pytest.mark.asyncio
    async def test_no_key_means_no_request(self, api, monkeypatch):
        _settings(monkeypatch, zetupay_secret_key="")
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.stk_push("254712345678", 199, "PL0123456789", "x")
        assert api["requests"] == []

    @pytest.mark.asyncio
    async def test_status_answers(self, api):
        api["respond"] = lambda request: httpx.Response(404)
        assert await zetupay.transaction_status("PL0123456789") is None

        api["respond"] = lambda request: httpx.Response(200, json={"data": {
            "status": "completed", "amount": "199.00", "waveTransactionId": "w1"}})
        event = await zetupay.transaction_status("PL0123456789")
        assert (event.reference, event.status, event.amount, event.wave_transaction_id) == \
            ("PL0123456789", "success", 199.0, "w1")

        api["respond"] = lambda request: httpx.Response(200, json={
            "reference": "PLSOMEONEELS", "status": "success"})
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.transaction_status("PL0123456789")

    def test_an_unknown_status_never_reads_as_paid(self):
        assert zetupay.normalize_status("weird") == zetupay.PENDING
        assert zetupay.normalize_status(None) == zetupay.PENDING
        assert zetupay.normalize_status("Completed") == zetupay.SUCCESS
        assert zetupay.normalize_status("CANCELLED") == zetupay.FAILED
        assert zetupay.parse_event({"amount": "NaN", "status": "success"}).amount is None

    def test_references_are_unique_and_fit_mpesa(self):
        refs = {service.new_reference(Purpose.LISTING_FEE) for _ in range(2000)}
        assert len(refs) == 2000
        assert all(len(r) == 12 and r.isalnum() and r.isupper() for r in refs)


# ── Settings ─────────────────────────────────────────────────────────────────

class TestSettings:
    def test_the_secrets_stay_out_of_the_settings_repr(self):
        s = dataclasses.replace(settings, zetupay_secret_key="sk_live_hidden",
                                zetupay_webhook_secret="whsec_hidden")
        assert "sk_live_hidden" not in repr(s) and "whsec_hidden" not in repr(s)

    def test_production_refuses_zetupay_without_its_secrets(self, monkeypatch):
        prod = dataclasses.replace(
            settings, env="production", secret_key="x" * 40, zac_secret="zac-" + "y" * 40,
            mpesa_callback_secret="m" * 32, econfirm_api_key="ek",
            zetupay_enabled=True, zetupay_secret_key="sk_live_x", zetupay_webhook_secret="",
        )
        monkeypatch.setattr(config, "settings", prod)
        with pytest.raises(RuntimeError, match="ZETUPAY_WEBHOOK_SECRET"):
            config.validate_startup()
