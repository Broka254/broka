"""BROKA without in-app payments (IN_APP_PAYMENTS_ENABLED off).

Buyers pay sellers directly for now. What must hold:
  * nothing can start moving a buyer's money - each route answers with a
    message an older app build can show;
  * the listing fee drops the discounts measured in escrow deals, which no
    longer happen;
  * the safe-paying advice and escrow providers are served, marked as
    independent;
  * Zeno is told payments happen outside BROKA.

Leak flags (test_completion_rate.py) and auction deadlines
(test_auction_lifecycle.py) are tested beside the code they pause.
"""
import uuid

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.pricing import engine, safe_payment
from api.domains.pricing.categories import CATEGORIES
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_payments_off.db"
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


async def _headers() -> dict:
    u = User(name="Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}",
            "X-Idempotency-Key": uuid.uuid4().hex}


PAYMENT_STARTS = [
    ("get", "/deal/pay-quote/some-listing", None),
    ("post", "/deal/pay", {"listing_id": "some-listing"}),
    ("get", "/deal/some-deal/fee-quote", None),
    ("post", "/deal/some-deal/fund", {"payer_phone": "0712345678"}),
    ("post", "/mpesa/stk-push", {"deal_id": "some-deal", "phone_number": "0712345678",
                                  "password": "x"}),
]


class TestNoPaymentCanStart:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("method, path, body", PAYMENT_STARTS, ids=[p for _, p, _ in PAYMENT_STARTS])
    async def test_refused_with_a_message_the_app_can_show(self, client, payments_off, method, path, body):
        h = await _headers()
        r = await (client.get(path, headers=h) if method == "get"
                   else client.post(path, headers=h, json=body))
        assert r.status_code == 409, r.text
        assert r.json()["detail"] == {"code": safe_payment.PAYMENTS_OFF_CODE,
                                      "message": safe_payment.PAYMENTS_OFF_MESSAGE}

    @pytest.mark.asyncio
    async def test_the_routes_still_work_when_payments_are_on(self, client):
        """The guard, not the routes, is what refuses: with payments on the
        same request reaches the escrow code (no such listing)."""
        r = await client.get("/deal/pay-quote/no-such-listing", headers=await _headers())
        assert r.status_code == 404


class TestListingFee:
    def test_no_escrow_discounts_without_escrow_deals(self):
        e = CATEGORIES["Electronics"]
        proven = engine.SellerRecord(completed_weight=100, completed_deals=100)
        off = engine.quote(e, 20_000, 1, proven, 0, discounts_apply=False)
        on = engine.quote(e, 20_000, 1, proven, 0, discounts_apply=True)
        assert off["monthly_fee"] == off["list_price"] == 100
        assert off["discount_percent"] == 0 and off["discounts"]["apply"] is False
        assert on["monthly_fee"] < off["monthly_fee"]

    @pytest.mark.asyncio
    async def test_the_quote_endpoint_follows_the_switch(self, client, payments_off):
        q = (await client.get("/pricing/listing-fee/quote", headers=await _headers(),
                              params={"category": "Electronics", "price": 180000, "quantity": 3})).json()
        assert q["listing_value"] == 540_000
        assert q["monthly_fee"] == q["list_price"] == 835


class TestSafePayment:
    @pytest.mark.asyncio
    async def test_advice_and_independent_providers_are_served(self, client, payments_off):
        r = await client.get("/pricing/safe-payment")
        assert r.status_code == 200
        body = r.json()
        assert body["in_app_payments"] is False
        assert body["advice"] and body["providers"]
        assert all(p["url"].startswith("https://") for p in body["providers"])
        assert "independent" in body["disclaimer"]

    def test_land_and_car_buyers_are_not_sent_to_m_pesa_escrow(self):
        """Regression: the advice sent land and car buyers to an escrow
        service, and listed one as M-Pesa escrow - which can't carry more than
        KES 250,000 in a payment, and proves nothing about who owns the land."""
        advice = " ".join(safe_payment.ADVICE)
        assert "Ardhisasa" in advice and "NTSA" in advice
        assert "250,000" in advice
        assert not any(line.startswith("For land, a car") for line in safe_payment.ADVICE)

    @pytest.mark.asyncio
    async def test_plans_say_no_commission_is_charged(self, client, payments_off):
        assert (await client.get("/pricing/plans")).json()["commission_charged"] is False


class TestZeno:
    def test_zeno_is_told_payments_happen_outside_broka(self, payments_off):
        policy = safe_payment.ai_payment_policy()
        assert "does not handle deal payments" in policy
        assert "4.49%" in policy  # named, so Zeno knows never to quote it

    def test_nothing_is_added_while_payments_are_on(self):
        assert safe_payment.ai_payment_policy() == ""
