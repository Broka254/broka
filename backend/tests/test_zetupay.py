"""ZetuPay: money users pay BROKA (api/core/zetupay.py, api/domains/payments/).

Written to ZetuPay's documented contract (pay.zetupay.co.ke/docs: stk-push,
payment-status, callbacks, errors): POST /payment/stk-push with
{amount, phoneNumber, reference} and an Idempotency-Key; a 202 carrying
paymentKey and waveTransactionId; GET /payment/stk-push/{paymentKey}; webhooks
for successful payments only, as the bare transaction, signed in
x-zetupay-signature with the live Secret Key.

What must hold:
  * with ZETUPAY_ENABLED, listing fees, plans, boosts and badges are charged
    through ZetuPay, under a unique BROKA reference that identifies the
    user, the purpose, the amount and the record paid for - and Daraja is
    not asked;
  * ZetuPay's 202 "processing" buys nothing; only a signed success webhook,
    or ZetuPay's own status answer, does;
  * a webhook without a valid, fresh signature is refused - including one
    carrying only the older x-zetupay-secret header;
  * a payment is applied once, however often ZetuPay delivers its webhook
    or the status poll races it (waveTransactionId);
  * a failed or cancelled prompt, which sends no webhook, is learnt of by
    asking ZetuPay with the paymentKey;
  * another amount, a second payment for a paid reference, and money for a
    reference BROKA never issued buy nothing and are flagged for a refund;
  * ZetuPay down or slow fails the payment cleanly, and a payment that
    arrives anyway is still applied;
  * deal money never comes near ZetuPay: E-Confirm keeps it.
"""
import asyncio
import dataclasses
import hashlib
import hmac
import json
import time
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
    AsyncSessionLocal, AuditLog, Deal, DealStatus, Listing, ListingStatus, MpesaTransaction,
    SellerTier, User, VerificationPayment, init_db, reset_engine,
)
from api.domains.listings.paid import MONTH
from api.domains.payments import service
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.models.listing_payment import ListingPayment
from api.models.subscription import Subscription, SubscriptionPayment
from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayTransaction
from api.security import create_access_token

KEY = "sk_live_unit_test_key_0123456789"
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


_ON = dict(zetupay_enabled=True, zetupay_secret_key=KEY, mpesa_callback_secret=MPESA_SECRET)


@pytest.fixture
def zetupay_on(monkeypatch):
    return _settings(monkeypatch, **_ON)


@pytest.fixture
def fees_on(monkeypatch):
    return _settings(monkeypatch, **_ON, listing_fees_enabled=True)


@pytest.fixture
def premium_on(monkeypatch):
    return _settings(monkeypatch, **_ON, premium_enabled=True)


class FakeZetuPay:
    """Stands in for ZetuPay's API at the client boundary: records prompts,
    answers each with a 202's paymentKey and waveTransactionId, and answers
    status queries as told (by paymentKey, as ZetuPay does)."""

    def __init__(self):
        self.prompts = []
        self.fail = None          # None | "down" | "timeout"
        self.answers = {}         # paymentKey -> the status endpoint's JSON
        self.asked = []           # paymentKeys asked about

    async def stk_push(self, phone, amount, reference):
        if self.fail == "down":
            raise zetupay.ZetuPayUnavailable("down")
        if self.fail == "timeout":
            raise zetupay.ZetuPayTimeout("slow")
        accepted = zetupay.Accepted(payment_key=f"pk_{uuid.uuid4().hex}",
                                    wave_transaction_id=f"WP-{uuid.uuid4().hex[:12].upper()}")
        self.prompts.append({"phone": phone, "amount": amount, "reference": reference,
                             "payment_key": accepted.payment_key, "wave": accepted.wave_transaction_id})
        return accepted

    async def transaction_status(self, payment_key, reference):
        self.asked.append(payment_key)
        answer = self.answers.get(payment_key)
        if answer is None:
            return None
        event = zetupay.parse_event(answer)
        if event.reference != reference:
            raise zetupay.ZetuPayUnavailable("status query answered for another reference")
        return event

    def prompt_for(self, reference) -> dict:
        return next(p for p in self.prompts if p["reference"] == reference)


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


async def _user(tier=SellerTier.short_term, admin=False) -> tuple[User, dict]:
    u = User(name="Payer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
             seller_tier=tier, is_admin=admin)
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


def _txn(reference, amount, wave, status="success", receipt="RHS98JJK3") -> dict:
    """A payment webhook as ZetuPay documents it: the bare transaction."""
    return {
        "_id": uuid.uuid4().hex[:24], "application": uuid.uuid4().hex[:24],
        "amount": amount, "gross": amount, "fee": round(amount * 0.015, 2),
        "net": round(amount * 0.985, 2), "phoneNumber": "254712345678",
        "receiptNumber": receipt, "status": status, "paymentMethod": "M-Pesa STK",
        "waveTransactionId": wave, "checkoutRequestId": "ws_CO_12072026151037_10948",
        "merchantRequestId": "10492-2947-194", "mpesaResultCode": 0,
        "reference": reference, "firstName": "John", "lastName": "Doe",
        "transactionDate": "2026-10-01T15:12:01.000Z", "mode": "production", "real": True,
    }


def _sign(raw: bytes, key=KEY, at=None) -> str:
    stamp = str(int(time.time() if at is None else at))
    digest = hmac.new(key.encode(), stamp.encode() + b"." + raw, hashlib.sha256).hexdigest()
    return f"t={stamp},v1={digest}"


async def _webhook(client, body, *, signature=..., extra_headers=None):
    raw = json.dumps(body).encode()
    headers = {"content-type": "application/json", **(extra_headers or {})}
    if signature is ...:
        headers["x-zetupay-signature"] = _sign(raw)
    elif signature is not None:
        headers["x-zetupay-signature"] = signature
    return await client.post("/payments/zetupay/webhook", content=raw, headers=headers)


async def _paid_webhook(client, zp, charge, amount=None, **kw):
    """ZetuPay's success webhook for the payment its 202 announced."""
    prompt = zp.prompt_for(charge.reference)
    return await _webhook(client, _txn(charge.reference, charge.amount if amount is None else amount,
                                       prompt["wave"], **kw))


def _status_answer(charge, status, amount=None, wave=None, result="") -> dict:
    """GET /payment/stk-push/{paymentKey}, as ZetuPay documents it."""
    return {"success": True, "data": {
        "paymentKey": charge.provider_payment_id, "waveTransactionId": wave or charge.wave_transaction_id,
        "reference": charge.reference, "amount": charge.amount if amount is None else amount,
        "currency": "KES", "phoneNumber": "254712345678", "status": status,
        "checkoutRequestId": "ws_CO_1", "resultCode": 0 if status == "success" else 1032,
        "resultDesc": result or ("The service request is processed successfully."
                                 if status == "success" else "Request cancelled by user"),
        "receiptNumber": "RHS98JJK3" if status == "success" else None,
    }}


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


async def _ledger(wave) -> list[ZetuPayTransaction]:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(ZetuPayTransaction).where(
            ZetuPayTransaction.wave_transaction_id == wave))).scalars().all()


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
        prompt = zp.prompts[-1]
        assert (prompt["phone"], prompt["amount"], prompt["reference"]) == \
            ("254712345678", expected, charge.reference)
        # The reference names the user, the purpose, the amount and the record.
        assert charge.reference.startswith("LF") and len(charge.reference) == 12
        assert (charge.user_id, charge.purpose, charge.amount, charge.related_id) == \
            (seller.id, "listing_fee", expected, listing["id"])
        # ZetuPay's 202 identifiers are kept: the paymentKey is how we ask.
        assert (charge.provider_payment_id, charge.wave_transaction_id) == \
            (prompt["payment_key"], prompt["wave"])
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

        r = await _paid_webhook(client, zp, charge, receipt="UJ9PAID001")
        assert r.status_code == 200 and r.json()["outcome"] == "applied"

        assert await _in_feed(client, listing["id"])
        assert [e.listing_id for e in announced] == [listing["id"]]
        status = await _fee_status(client, h, paid["payment_id"])
        assert status["status"] == "success" and status["listing_fee"]["live"] is True
        until = datetime.fromisoformat(status["paid_until"])
        assert abs((until - datetime.utcnow()) - 2 * MONTH) < timedelta(minutes=1)
        settled = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        assert (settled.status, settled.mpesa_receipt) == ("success", "UJ9PAID001")
        assert await _audit("zetupay_payment_settled", settled.id)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("status", ["failed", "cancelled", "expired"])
    async def test_a_failed_or_cancelled_prompt_is_learnt_by_asking(self, client, fees_on, zp, status):
        """No webhook comes for these: the status poll asks ZetuPay."""
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id)
        zp.answers[charge.provider_payment_id] = _status_answer(charge, status)

        fee = await _fee_status(client, h, paid["payment_id"])
        assert zp.asked == [charge.provider_payment_id]
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

        first = await _paid_webhook(client, zp, charge)
        before = await _fee_status(client, h, paid["payment_id"])
        # ZetuPay's retry: the same transaction, re-signed.
        second = await _paid_webhook(client, zp, charge)
        after = await _fee_status(client, h, paid["payment_id"])

        assert first.json()["outcome"] == "applied"
        assert second.status_code == 200 and second.json()["outcome"] == "duplicate"
        assert after["paid_until"] == before["paid_until"]
        assert len(announced) == 1
        assert len(await _ledger(charge.wave_transaction_id)) == 1

    @pytest.mark.asyncio
    async def test_a_second_payment_for_a_paid_reference_is_flagged_not_applied(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _paid_webhook(client, zp, charge)
        before = await _fee_status(client, h, paid["payment_id"])

        r = await _webhook(client, _txn(charge.reference, charge.amount, "WP-SECOND-PAYMENT"))
        assert r.json()["outcome"] == "duplicate_payment"
        assert (await _fee_status(client, h, paid["payment_id"]))["paid_until"] == before["paid_until"]
        assert await _audit("zetupay_duplicate_payment", charge.id), "a person must refund it"

    @pytest.mark.asyncio
    async def test_the_wrong_amount_buys_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"], months=6)).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])

        r = await _paid_webhook(client, zp, charge, amount=1)
        assert r.status_code == 200 and r.json()["outcome"] == "amount_mismatch"
        fee = await _fee_status(client, h, paid["payment_id"])
        assert fee["status"] == "failed" and fee["failure_reason"] == "amount_mismatch"
        assert not await _in_feed(client, listing["id"])
        assert await _audit("zetupay_amount_mismatch", charge.id)

    @pytest.mark.asyncio
    async def test_an_unknown_reference_is_recorded_and_flagged(self, client, fees_on, zp):
        r = await _webhook(client, _txn("LFNOSUCHREF0", 500, "WP-STRANGER"))
        assert r.status_code == 200 and r.json()["outcome"] == "unknown_reference"
        [row] = await _ledger("WP-STRANGER")
        assert row.payment_id is None and row.outcome == "unknown_reference"
        assert await _audit("zetupay_unknown_reference", "WP-STRANGER")

    @pytest.mark.asyncio
    async def test_a_processing_event_changes_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        r = await _paid_webhook(client, zp, charge, status="processing")
        assert r.json()["outcome"] == "ignored"
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"
        # The same transaction then succeeding is not a duplicate of it.
        assert (await _paid_webhook(client, zp, charge)).json()["outcome"] == "applied"

    @pytest.mark.asyncio
    async def test_a_subscription_event_is_never_read_as_a_payment(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        event = {"event": "subscription.charge.success", "data": {
            "subscription_code": "SUB_1", "amount": charge.amount, "status": "active",
            "reference": charge.reference, "transaction_reference": "RHS98JJK3"}}
        r = await _webhook(client, event)
        assert r.status_code == 200 and r.json()["outcome"] == "ignored_event"
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"


# ── The webhook's signature ──────────────────────────────────────────────────

class TestWebhookSignature:
    async def _pending_charge(self, client, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        return listing, await _charge(Purpose.LISTING_FEE, paid["payment_id"])

    @pytest.mark.asyncio
    @pytest.mark.parametrize("case", ["missing", "other_key", "stale", "garbage"])
    async def test_a_webhook_without_a_valid_fresh_signature_is_refused(self, client, fees_on, zp, case):
        listing, charge = await self._pending_charge(client, zp)
        body = _txn(charge.reference, charge.amount, zp.prompt_for(charge.reference)["wave"])
        raw = json.dumps(body).encode()
        signature = {
            "missing": None,
            "other_key": _sign(raw, key="sk_live_someone_else"),
            "stale": _sign(raw, at=time.time() - 301),
            "garbage": "t=abc,v1=zz",
        }[case]
        r = await _webhook(client, body, signature=signature)
        assert r.status_code == 401
        assert not await _in_feed(client, listing["id"])
        assert (await _charge(Purpose.LISTING_FEE, charge.target_id)).status == "processing"
        assert await _ledger(body["waveTransactionId"]) == []

    @pytest.mark.asyncio
    async def test_a_body_altered_after_signing_is_refused(self, client, fees_on, zp):
        listing, charge = await self._pending_charge(client, zp)
        body = _txn(charge.reference, 1, zp.prompt_for(charge.reference)["wave"])
        signature = _sign(json.dumps(body).encode())
        body["amount"] = charge.amount          # signed for KES 1, claims the full amount
        assert (await _webhook(client, body, signature=signature)).status_code == 401
        assert not await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_the_old_secret_header_alone_is_not_enough(self, client, fees_on, zp):
        """x-zetupay-secret carries the key itself: anyone who saw one
        request could forge any other, so only the signature counts."""
        listing, charge = await self._pending_charge(client, zp)
        body = _txn(charge.reference, charge.amount, zp.prompt_for(charge.reference)["wave"])
        r = await _webhook(client, body, signature=None, extra_headers={"x-zetupay-secret": KEY})
        assert r.status_code == 401
        assert not await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_no_configured_key_refuses_every_webhook(self, client, monkeypatch, zp):
        _settings(monkeypatch, zetupay_enabled=True, zetupay_secret_key="")
        raw = json.dumps(_txn("LFANYTHING00", 100, "WP-X")).encode()
        r = await client.post("/payments/zetupay/webhook", content=raw, headers={
            "content-type": "application/json", "x-zetupay-signature": _sign(raw, key="")})
        assert r.status_code == 401

    @pytest.mark.asyncio
    async def test_a_signed_body_that_is_not_json_is_refused(self, client, fees_on, zp):
        raw = b"not json"
        r = await client.post("/payments/zetupay/webhook", content=raw, headers={
            "content-type": "application/json", "x-zetupay-signature": _sign(raw)})
        assert r.status_code == 400

    def test_signature_check_matches_zetupays_recipe(self, monkeypatch):
        """hex HMAC-SHA256 of "<t>.<raw body>" with the Secret Key."""
        _settings(monkeypatch, zetupay_secret_key=KEY)
        raw = b'{"status":"success","amount":10}'
        t = 1783869123
        v1 = hmac.new(KEY.encode(), f"{t}.".encode() + raw, hashlib.sha256).hexdigest()
        assert zetupay.signature_ok(raw, f"t={t},v1={v1}", now=t + 10)
        assert not zetupay.signature_ok(raw, f"t={t},v1={v1}", now=t + 301)
        assert not zetupay.signature_ok(raw + b" ", f"t={t},v1={v1}", now=t)
        assert not zetupay.signature_ok(raw, f"t={t + 1},v1={v1}", now=t)


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
        assert charge.provider_payment_id is None, "no 202, so nothing to ask ZetuPay about"

        # The prompt had gone out after all, and the seller paid it.
        r = await _webhook(client, _txn(charge.reference, row.amount, "WP-LATE-PAID"))
        assert r.json()["outcome"] == "applied"
        assert (await _fee_status(client, h, row.id))["status"] == "success"
        assert await _in_feed(client, listing["id"])

    @pytest.mark.asyncio
    async def test_the_status_poll_applies_a_payment_whose_webhook_is_late(
            self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id)
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "success")

        status = await _fee_status(client, h, paid["payment_id"])
        assert status["status"] == "success" and status["listing_fee"]["live"] is True
        # The webhook arriving afterwards changes nothing.
        r = await _paid_webhook(client, zp, charge)
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
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "processing")
        assert (await _fee_status(client, h, paid["payment_id"]))["status"] == "pending"

    @pytest.mark.asyncio
    async def test_a_status_answer_for_another_amount_buys_nothing(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id)
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "success", amount=1)
        fee = await _fee_status(client, h, paid["payment_id"])
        assert fee["status"] == "failed" and fee["failure_reason"] == "amount_mismatch"

    @pytest.mark.asyncio
    async def test_the_sweep_settles_a_payment_whose_webhook_never_came(self, client, fees_on, zp):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id, seconds=600)
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "success")

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
        assert (await _paid_webhook(client, zp, charge)).json()["outcome"] == "applied"
        ends = await _paid_until(user.id)
        assert abs((ends - datetime.utcnow()) - MONTH) < timedelta(minutes=1)
        assert (await client.get("/premium/me", headers=h)).json()["plan"]["id"] == "plus"

        # Renewal: another payment for the same plan, extending it.
        second = await _subscribe(client, h)
        renewal = await _charge(Purpose.SUBSCRIPTION, second["payment_id"])
        assert renewal.reference != charge.reference
        assert (await _paid_webhook(client, zp, renewal)).json()["outcome"] == "applied"
        assert await _paid_until(user.id) - ends == MONTH
        # ...once, however often ZetuPay says so.
        assert (await _paid_webhook(client, zp, renewal)).json()["outcome"] == "duplicate"
        assert await _paid_until(user.id) - ends == MONTH
        status = (await client.get(f"/premium/payments/{second['payment_id']}", headers=h)).json()
        assert status["status"] == "success"

    @pytest.mark.asyncio
    async def test_the_wrong_amount_buys_no_plan_time(self, client, premium_on, zp):
        user, h = await _user()
        started = await _subscribe(client, h, plan="pro")
        charge = await _charge(Purpose.SUBSCRIPTION, started["payment_id"])
        r = await _paid_webhook(client, zp, charge, amount=started["amount"] - 1)
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
        wave = zp.prompt_for(reference)["wave"]
        assert (await _webhook(client, _txn(reference, 99, wave))).json()["outcome"] == "applied"
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

        wave = zp.prompt_for(reference)["wave"]
        assert (await _webhook(client, _txn(reference, 299, wave))).json()["outcome"] == "applied"
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


# ── The KES 10 test charge ───────────────────────────────────────────────────

class TestTestCharge:
    @pytest.mark.asyncio
    async def test_admins_only(self, client, zetupay_on, zp):
        _, h = await _user()
        r = await client.post("/payments/zetupay/test-charge", headers=h, json={"phone_number": "0712345678"})
        assert r.status_code == 403 and zp.prompts == []

    @pytest.mark.asyncio
    async def test_ten_shillings_end_to_end(self, client, zetupay_on, zp):
        admin, h = await _user(admin=True)
        r = await client.post("/payments/zetupay/test-charge", headers=h, json={"phone_number": "0712 345 678"})
        assert r.status_code == 200, r.text
        started = r.json()
        assert (started["amount"], started["status"], started["purpose"]) == (10, "processing", "test")
        assert started["reference"].startswith("TS")
        assert zp.prompts[-1]["amount"] == 10 and zp.prompts[-1]["phone"] == "254712345678"

        wave = zp.prompt_for(started["reference"])["wave"]
        r = await _webhook(client, _txn(started["reference"], 10, wave, receipt="TST10RCPT"))
        assert r.json()["outcome"] == "applied"
        status = (await client.get(f"/payments/zetupay/payments/{started['reference']}", headers=h)).json()
        assert (status["status"], status["mpesa_receipt"], status["wave_transaction_id"]) == \
            ("success", "TST10RCPT", wave)

    @pytest.mark.asyncio
    async def test_the_lookup_asks_zetupay_about_a_cancelled_one(self, client, zetupay_on, zp):
        _, h = await _user(admin=True)
        started = (await client.post("/payments/zetupay/test-charge", headers=h,
                                     json={"phone_number": "0712345678"})).json()
        async with AsyncSessionLocal() as db:
            charge = (await db.execute(select(ZetuPayPayment).where(
                ZetuPayPayment.reference == started["reference"]))).scalar_one()
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "cancelled")
        status = (await client.get(f"/payments/zetupay/payments/{started['reference']}", headers=h)).json()
        assert status["status"] == "failed" and status["failure_reason"] == "Request cancelled by user"

    @pytest.mark.asyncio
    async def test_refused_while_zetupay_is_off(self, client, monkeypatch, zp):
        _settings(monkeypatch, zetupay_enabled=False, zetupay_secret_key=KEY)
        _, h = await _user(admin=True)
        r = await client.post("/payments/zetupay/test-charge", headers=h, json={"phone_number": "0712345678"})
        assert r.status_code == 409 and zp.prompts == []


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
        assert set(Purpose.ALL) == {"listing_fee", "subscription", "boost", "verification", "test"}


def _row(obj) -> dict:
    return {c.key: getattr(obj, c.key) for c in obj.__table__.columns}


class TestEConfirmDealsAreUntouched:
    @pytest.mark.asyncio
    async def test_no_zetupay_success_can_fund_or_move_a_deal(self, client, fees_on, zp):
        seller, _ = await _user()
        buyer, buyer_h = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name=f"Phone {uuid.uuid4().hex[:6]}",
                              category="Electronics", price=10000, lat=-1.29, lng=36.82,
                              status=ListingStatus.pending)
            db.add(listing)
            await db.commit()
            # Agreed and waiting for the buyer's money: the state a stray
            # "payment succeeded" would do the most damage in.
            deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                        agreed_price=10000, commission=449, status=DealStatus.agreed)
            db.add(deal)
            await db.commit()
            escrow = ExternalEscrow(
                deal_id=deal.id, provider_transaction_id=f"ec-{uuid.uuid4().hex[:10]}",
                status=EConfirmEscrowStatus.PENDING, amount=10449,
                buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            )
            db.add(escrow)
            await db.commit()
            before = (_row(deal), _row(escrow))
            deal_id, escrow_tx = deal.id, escrow.provider_transaction_id

        # Signed successes naming the deal, E-Confirm's transaction, or no
        # reference at all: none is a BROKA charge.
        for reference in (deal_id, escrow_tx, None):
            body = _txn(reference, 10449, f"WP-{uuid.uuid4().hex[:8]}")
            if reference is None:
                del body["reference"]
            outcome = (await _webhook(client, body)).json()["outcome"]
            assert outcome in ("unknown_reference", "ignored"), (reference, outcome)
        # And a genuine BROKA charge by the same buyer, paid.
        own = await _listing(client, buyer_h)
        paid = (await _pay_fee(client, buyer_h, own["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        assert (await _paid_webhook(client, zp, charge)).json()["outcome"] == "applied"

        async with AsyncSessionLocal() as db:
            deal = await db.get(Deal, deal_id)
            escrow = (await db.execute(select(ExternalEscrow).where(
                ExternalEscrow.deal_id == deal_id))).scalar_one()
            mpesa_rows = (await db.execute(select(func.count()).select_from(MpesaTransaction).where(
                MpesaTransaction.deal_id == deal_id))).scalar()
            charges_for_deal = (await db.execute(select(func.count()).select_from(ZetuPayPayment).where(
                (ZetuPayPayment.target_id == deal_id) | (ZetuPayPayment.related_id == deal_id)))).scalar()
        assert (_row(deal), _row(escrow)) == before
        assert mpesa_rows == 0 and charges_for_deal == 0


# ── Two copies of one webhook at the same instant ────────────────────────────

class TestConcurrentDelivery:
    @pytest.mark.asyncio
    async def test_two_identical_webhooks_at_once_apply_once(self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"], months=2)).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])

        first, second = await asyncio.gather(_paid_webhook(client, zp, charge),
                                             _paid_webhook(client, zp, charge))
        assert {first.status_code, second.status_code} == {200}
        assert sorted([first.json()["outcome"], second.json()["outcome"]]) == ["applied", "duplicate"]

        status = await _fee_status(client, h, paid["payment_id"])
        until = datetime.fromisoformat(status["paid_until"])
        assert abs((until - datetime.utcnow()) - 2 * MONTH) < timedelta(minutes=1), "two months, not four"
        assert len(announced) == 1

    @pytest.mark.asyncio
    async def test_a_webhook_racing_the_status_poll_applies_once(self, client, fees_on, zp, announced):
        _, h = await _user()
        listing = await _listing(client, h)
        paid = (await _pay_fee(client, h, listing["id"])).json()
        charge = await _charge(Purpose.LISTING_FEE, paid["payment_id"])
        await _age(charge.id)
        zp.answers[charge.provider_payment_id] = _status_answer(charge, "success")

        hook, poll = await asyncio.gather(_paid_webhook(client, zp, charge),
                                          _fee_status(client, h, paid["payment_id"]))
        assert hook.status_code == 200 and poll["status"] in ("pending", "success")
        status = await _fee_status(client, h, paid["payment_id"])
        until = datetime.fromisoformat(status["paid_until"])
        assert abs((until - datetime.utcnow()) - MONTH) < timedelta(minutes=1)
        assert len(announced) == 1
        assert [r.outcome for r in await _ledger(charge.wave_transaction_id)] == ["applied"]


# ── The ZetuPay client against the documented contract ───────────────────────

class TestClient:
    @pytest.fixture
    def api(self, monkeypatch):
        _settings(monkeypatch, zetupay_secret_key=KEY, zetupay_base_url="https://pay.zetupay.co.ke/api/v1")
        calls = {"requests": [], "respond": None}

        def handler(request):
            calls["requests"].append(request)
            return calls["respond"](request)

        def client():
            return httpx.AsyncClient(transport=httpx.MockTransport(handler),
                                     base_url="https://pay.zetupay.co.ke/api/v1")

        monkeypatch.setattr(zetupay, "_client", client)
        return calls

    # The 202 from ZetuPay's STK Push page, verbatim.
    ACCEPTED = {"success": True, "data": {
        "paymentKey": "pk_idem_3f9a1c07b2d84e6f9a51c2d7e8b0a4c1", "waveTransactionId": "WP-48213-9F2A61C4",
        "reference": "ORDER-9874", "identifier": "cust_92047", "amount": 1500, "currency": "KES",
        "phoneNumber": "254712345678", "status": "processing", "environment": "production",
        "checkoutRequestId": "ws_CO_12072026151037_10948", "resultCode": None, "resultDesc": None,
        "receiptNumber": None, "paidAt": None, "createdAt": "2026-07-12T15:10:37.000Z",
        "updatedAt": "2026-07-12T15:10:38.000Z"},
        "message": "Payment prompt sent to the customer's phone"}

    @pytest.mark.asyncio
    async def test_the_push_request_is_exactly_the_documented_one(self, api):
        api["respond"] = lambda request: httpx.Response(202, json=self.ACCEPTED)
        accepted = await zetupay.stk_push("254712345678", 1500, "ORDER-9874")
        assert accepted == zetupay.Accepted(payment_key="pk_idem_3f9a1c07b2d84e6f9a51c2d7e8b0a4c1",
                                            wave_transaction_id="WP-48213-9F2A61C4")
        [request] = api["requests"]
        assert (request.method, str(request.url)) == ("POST", "https://pay.zetupay.co.ke/api/v1/payment/stk-push")
        assert request.headers["authorization"] == f"Bearer {KEY}"
        assert request.headers["idempotency-key"] == "ORDER-9874"
        assert request.headers["content-type"] == "application/json"
        assert json.loads(request.content) == {"amount": 1500, "phoneNumber": "254712345678",
                                               "reference": "ORDER-9874"}

    @pytest.mark.asyncio
    @pytest.mark.parametrize("code,error", [
        (400, "Validation failed"), (401, "Authentication failed"), (402, "Payment Required"),
        (403, "Forbidden"), (409, "Idempotency conflict"), (422, "Wallet not ready for M-Pesa"),
        (429, "Too many requests"), (500, "Server error"), (502, "M-Pesa error"),
    ])
    async def test_every_documented_error_means_no_prompt(self, api, code, error):
        api["respond"] = lambda request: httpx.Response(code, json={
            "success": False, "error": error, "message": "details"})
        with pytest.raises(zetupay.ZetuPayUnavailable) as exc:
            await zetupay.stk_push("254712345678", 10, "TS0123456789")
        assert not isinstance(exc.value, zetupay.ZetuPayTimeout)

    @pytest.mark.asyncio
    async def test_a_2xx_that_is_not_success_is_no_prompt(self, api):
        api["respond"] = lambda request: httpx.Response(202, json={"success": False, "message": "x"})
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.stk_push("254712345678", 10, "TS0123456789")

    @pytest.mark.asyncio
    async def test_a_timeout_is_its_own_kind_and_never_logs_the_key(self, api, caplog):
        def slow(request):
            raise httpx.ReadTimeout("slow", request=request)

        api["respond"] = slow
        with pytest.raises(zetupay.ZetuPayTimeout):
            await zetupay.stk_push("254712345678", 10, "TS0123456789")
        assert KEY not in caplog.text

    @pytest.mark.asyncio
    async def test_no_key_means_no_request(self, api, monkeypatch):
        _settings(monkeypatch, zetupay_secret_key="")
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.stk_push("254712345678", 10, "TS0123456789")
        assert api["requests"] == []

    @pytest.mark.asyncio
    async def test_status_is_asked_by_payment_key_and_read_as_documented(self, api):
        # The 200 from ZetuPay's STK Push page ("Check a payment"), verbatim.
        api["respond"] = lambda request: httpx.Response(200, json={"success": True, "data": {
            "paymentKey": "pk_idem_3f9a1c07b2d84e6f9a51c2d7e8b0a4c1", "waveTransactionId": "WP-48213-9F2A61C4",
            "reference": "ORDER-9874", "amount": 1500, "currency": "KES", "phoneNumber": "254712345678",
            "status": "success", "checkoutRequestId": "ws_CO_12072026151037_10948", "resultCode": 0,
            "resultDesc": "The service request is processed successfully.", "receiptNumber": "RHS98JJK3",
            "paidAt": "2026-07-12T15:12:03.000Z"}})
        event = await zetupay.transaction_status("pk_idem_3f9a1c07b2d84e6f9a51c2d7e8b0a4c1", "ORDER-9874")
        [request] = api["requests"]
        assert (request.method, str(request.url)) == (
            "GET", "https://pay.zetupay.co.ke/api/v1/payment/stk-push/pk_idem_3f9a1c07b2d84e6f9a51c2d7e8b0a4c1")
        assert request.headers["authorization"] == f"Bearer {KEY}"
        assert (event.reference, event.status, event.amount, event.wave_transaction_id, event.receipt) == \
            ("ORDER-9874", "success", 1500.0, "WP-48213-9F2A61C4", "RHS98JJK3")

    @pytest.mark.asyncio
    async def test_status_unknown_expired_or_about_another_payment(self, api):
        for code in (404, 410):
            api["respond"] = lambda request, code=code: httpx.Response(code, json={
                "success": False, "error": "Payment request not found or expired"})
            assert await zetupay.transaction_status("pk_x", "TS0123456789") is None
        api["respond"] = lambda request: httpx.Response(200, json={"success": True, "data": {
            "reference": "TSSOMEONEELS", "status": "success", "amount": 10}})
        with pytest.raises(zetupay.ZetuPayUnavailable):
            await zetupay.transaction_status("pk_x", "TS0123456789")

    def test_only_documented_statuses_count(self):
        assert zetupay.normalize_status("success") == zetupay.SUCCESS
        for s in ("failed", "cancelled", "expired"):
            assert zetupay.normalize_status(s) == zetupay.FAILED
        for s in ("pending", "processing", "completed", "paid", "", None):
            assert zetupay.normalize_status(s) == zetupay.PENDING, s
        assert zetupay.parse_event({"amount": "NaN", "status": "success"}).amount is None

    def test_references_are_unique_and_fit_zetupay(self):
        refs = {service.new_reference(Purpose.LISTING_FEE) for _ in range(2000)}
        assert len(refs) == 2000
        # <= 100 characters, and never one of ZetuPay's reserved top-up forms.
        assert all(len(r) == 12 and r.isalnum() and r.isupper() and not r.lower().startswith("top_")
                   for r in refs)


# ── Settings ─────────────────────────────────────────────────────────────────

def _production(**changes):
    return dataclasses.replace(
        settings, env="production", secret_key="x" * 40, zac_secret="zac-" + "y" * 40,
        mpesa_callback_secret="m" * 32, econfirm_api_key="ek", **changes,
    )


class TestSettings:
    def test_the_key_stays_out_of_the_settings_repr(self):
        assert "sk_live_hidden" not in repr(dataclasses.replace(settings, zetupay_secret_key="sk_live_hidden"))

    def test_there_is_no_second_webhook_secret(self):
        assert not hasattr(settings, "zetupay_webhook_secret")

    def test_production_refuses_zetupay_without_its_key(self, monkeypatch):
        monkeypatch.setattr(config, "settings", _production(zetupay_enabled=True, zetupay_secret_key=""))
        with pytest.raises(RuntimeError, match="ZETUPAY_SECRET_KEY"):
            config.validate_startup()

    def test_a_key_that_is_not_live_is_reported(self, monkeypatch, caplog):
        monkeypatch.setattr(config, "settings", _production(zetupay_enabled=True,
                                                            zetupay_secret_key="sk_test_x"))
        try:
            config.validate_startup()
        except RuntimeError as exc:
            assert "ZETUPAY" not in str(exc), exc
        assert "signatures will not verify" in caplog.text

    def test_an_unverified_contract_never_stops_production_from_starting(self, monkeypatch):
        monkeypatch.setattr(zetupay, "CONTRACT_VERIFIED", False)
        monkeypatch.setattr(config, "settings", _production(zetupay_enabled=True, zetupay_secret_key=""))
        try:
            config.validate_startup()
        except RuntimeError as exc:
            assert "ZETUPAY" not in str(exc), exc


# ── The contract guard ───────────────────────────────────────────────────────

class TestContractGuard:
    @pytest.mark.asyncio
    async def test_unverified_keeps_charges_on_daraja(self, client, monkeypatch):
        monkeypatch.setattr(zetupay, "CONTRACT_VERIFIED", False)
        _settings(monkeypatch, **_ON, listing_fees_enabled=True)
        daraja = []

        async def daraja_push(phone, amount, account_reference, description, callback_url):
            daraja.append(amount)
            return {"CheckoutRequestID": f"ws_CO_{uuid.uuid4().hex}", "ResponseCode": "0"}

        async def no_zetupay(*_a, **_k):
            raise AssertionError("ZetuPay must not be asked while its contract is unverified")

        monkeypatch.setattr(mpesa_stk, "stk_push", daraja_push)
        monkeypatch.setattr(zetupay, "stk_push", no_zetupay)

        _, h = await _user()
        listing = await _listing(client, h)
        r = await _pay_fee(client, h, listing["id"])
        assert r.status_code == 200, r.text
        assert daraja == [r.json()["amount"]]
        async with AsyncSessionLocal() as db:
            row = await db.get(ListingPayment, r.json()["payment_id"])
        assert row.provider == "daraja" and row.checkout_request_id

    def test_the_contract_is_marked_verified(self):
        assert zetupay.CONTRACT_VERIFIED is True, \
            "checked against pay.zetupay.co.ke/docs - see core/zetupay.py's docstring"
