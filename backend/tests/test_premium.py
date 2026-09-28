"""Premium plans (PRICING.md section 4; api/domains/premium/).

What must hold:
  * with PREMIUM_ENABLED off nothing changes: every feature is free and no
    plan can be bought;
  * a plan is bought at the catalogue price, settled once, and a callback
    claiming another amount buys nothing;
  * renewing extends from the end of the paid time; upgrading turns the
    unused days into days of the dearer plan; a downgrade waits;
  * each premium feature spends its allowance before it costs money, is
    refused with a 402 the app can act on when there is none, and gets the
    allowance back when the costly thing did not happen.
"""
import dataclasses
import uuid
from datetime import datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.core import mpesa_stk
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, BuyAgentRequest, Interest, Listing, NegotiationMessage, User,
    init_db, reset_engine,
)
from api.domains.premium import entitlements
from api.domains.premium.entitlements import MONTH, Feature
from api.domains.pricing.plans import FREE_TRIAL, PREMIUM_BY_ID, period_prices
from api.models.subscription import FeatureUsage, Subscription, SubscriptionPayment
from api.security import create_access_token

SECRET = "premium-callback-secret"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_premium.db"
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
def premium_on(monkeypatch):
    patched = dataclasses.replace(settings, premium_enabled=True, mpesa_callback_secret=SECRET)
    for module in ("api.domains.premium.entitlements", "api.domains.premium.payments",
                   "api.domains.premium.router"):
        monkeypatch.setattr(f"{module}.settings", patched)


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


async def _user(plan=None, days_left=30, started_days_ago=0) -> tuple[User, dict]:
    u = User(name="Member", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.flush()
        if plan:
            now = datetime.utcnow()
            db.add(Subscription(user_id=u.id, plan_id=plan,
                                started_at=now - timedelta(days=started_days_ago),
                                paid_until=now + timedelta(days=days_left)))
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _subscribe(client, headers, plan="plus", months=1):
    return await client.post("/premium/subscribe", headers=headers, json={
        "plan_id": plan, "months": months, "phone_number": "0712345678"})


def _callback(checkout_id, amount, code=0):
    stk = {"CheckoutRequestID": checkout_id, "ResultCode": code, "ResultDesc": "done"}
    if code == 0:
        stk["CallbackMetadata"] = {"Item": [
            {"Name": "Amount", "Value": amount}, {"Name": "MpesaReceiptNumber", "Value": "SKP1"}]}
    return {"Body": {"stkCallback": stk}}


async def _pay(client, headers, plan="plus", months=1, amount=None):
    started = (await _subscribe(client, headers, plan, months)).json()
    async with AsyncSessionLocal() as db:
        checkout = (await db.get(SubscriptionPayment, started["payment_id"])).checkout_request_id
    await client.post(f"/premium/callback/{SECRET}",
                      json=_callback(checkout, started["amount"] if amount is None else amount))
    return started


async def _sub(user_id) -> Subscription:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Subscription).where(Subscription.user_id == user_id))).scalar_one()


# ── Off: nothing changes ─────────────────────────────────────────────────────

class TestPremiumOff:
    @pytest.mark.asyncio
    async def test_everything_is_free_and_nothing_is_sold(self, client, mpesa):
        _, h = await _user()
        assert (await client.get("/premium/me", headers=h)).json()["enabled"] is False
        assert (await _subscribe(client, h)).status_code == 409
        assert mpesa.prompts == []
        # The Buying Agent keeps its old cap of one watch.
        made = await client.post("/buy-agent-requests", headers=h, json={"category": "Electronics", "max_price": 20000})
        assert made.status_code == 200, made.text


# ── Buying a plan ────────────────────────────────────────────────────────────

class TestSubscribing:
    @pytest.mark.asyncio
    async def test_a_plan_is_bought_at_its_price_and_starts_now(self, client, premium_on, mpesa):
        user, h = await _user()
        started = await _pay(client, h, "pro", 3)
        pro = PREMIUM_BY_ID["pro"].monthly_price
        assert started["amount"] == next(p["total"] for p in period_prices(pro) if p["months"] == 3)
        assert mpesa.prompts[0]["amount"] == started["amount"]
        assert mpesa.prompts[0]["callback_url"].endswith(f"/premium/callback/{SECRET}")
        me = (await client.get("/premium/me", headers=h)).json()
        assert me["plan"]["id"] == "pro"
        until = datetime.fromisoformat(me["paid_until"])
        assert abs((until - datetime.utcnow()) - 3 * MONTH) < timedelta(minutes=1)
        assert me["usage"]["ai_covers"] == {"allowance": 20, "used": 0, "left": 20}

    @pytest.mark.asyncio
    async def test_a_replayed_callback_buys_nothing_more(self, client, premium_on, mpesa):
        user, h = await _user()
        started = await _pay(client, h, "plus", 1)
        first = (await _sub(user.id)).paid_until
        async with AsyncSessionLocal() as db:
            checkout = (await db.get(SubscriptionPayment, started["payment_id"])).checkout_request_id
        await client.post(f"/premium/callback/{SECRET}", json=_callback(checkout, started["amount"]))
        assert (await _sub(user.id)).paid_until == first

    @pytest.mark.asyncio
    async def test_a_callback_claiming_another_amount_buys_nothing(self, client, premium_on, mpesa):
        _, h = await _user()
        started = await _pay(client, h, "elite", 12, amount=1)
        status = (await client.get(f"/premium/payments/{started['payment_id']}", headers=h)).json()
        assert status["status"] == "failed" and status["failure_reason"] == "amount_mismatch"
        assert (await client.get("/premium/me", headers=h)).json()["plan"] is None

    @pytest.mark.asyncio
    async def test_the_unprotected_callback_is_closed_once_there_is_a_secret(self, client, premium_on, mpesa):
        _, h = await _user()
        started = (await _subscribe(client, h)).json()
        async with AsyncSessionLocal() as db:
            checkout = (await db.get(SubscriptionPayment, started["payment_id"])).checkout_request_id
        assert (await client.post("/premium/callback", json=_callback(checkout, started["amount"]))).status_code == 404
        assert (await client.get("/premium/me", headers=h)).json()["plan"] is None

    @pytest.mark.asyncio
    async def test_renewing_extends_from_the_end(self, client, premium_on, mpesa):
        user, h = await _user("plus", days_left=10)
        before = (await _sub(user.id)).paid_until
        await _pay(client, h, "plus", 1)
        assert (await _sub(user.id)).paid_until - before == MONTH

    @pytest.mark.asyncio
    async def test_upgrading_turns_unused_days_into_days_of_the_new_plan(self, client, premium_on, mpesa):
        user, h = await _user("plus", days_left=30, started_days_ago=0)
        await _pay(client, h, "pro", 1)
        sub = await _sub(user.id)
        assert sub.plan_id == "pro"
        credit = sub.paid_until - datetime.utcnow() - MONTH
        ratio = PREMIUM_BY_ID["plus"].monthly_price / PREMIUM_BY_ID["pro"].monthly_price
        assert abs(credit - timedelta(days=30) * ratio) < timedelta(minutes=1)

    @pytest.mark.asyncio
    async def test_a_downgrade_waits_for_the_dearer_plan_to_end(self, client, premium_on, mpesa):
        _, h = await _user("elite")
        r = await _subscribe(client, h, "plus")
        assert r.status_code == 409 and "when it ends" in r.json()["detail"]
        assert mpesa.prompts == []

    @pytest.mark.asyncio
    async def test_no_more_than_a_year_ahead(self, client, premium_on, mpesa):
        _, h = await _user("pro", days_left=200)
        r = await _subscribe(client, h, "pro", 12)
        assert r.status_code == 409 and "a year ahead" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_the_status_poll_settles_a_payment_safaricom_confirms(self, client, premium_on, mpesa):
        _, h = await _user()
        started = (await _subscribe(client, h)).json()
        async with AsyncSessionLocal() as db:
            p = await db.get(SubscriptionPayment, started["payment_id"])
            p.created_at = datetime.utcnow() - timedelta(minutes=1)
            await db.commit()
        pending = (await client.get(f"/premium/payments/{started['payment_id']}", headers=h)).json()
        assert pending["status"] == "pending"
        mpesa.query_answer = {"ResultCode": "0"}
        paid = (await client.get(f"/premium/payments/{started['payment_id']}", headers=h)).json()
        assert paid["status"] == "success"
        assert (await client.get("/premium/me", headers=h)).json()["plan"]["id"] == "plus"

    @pytest.mark.asyncio
    async def test_someone_elses_payment_is_not_found(self, client, premium_on, mpesa):
        _, h = await _user()
        _, other = await _user()
        started = (await _subscribe(client, h)).json()
        assert (await client.get(f"/premium/payments/{started['payment_id']}", headers=other)).status_code == 404

    @pytest.mark.asyncio
    @pytest.mark.parametrize("body, status", [
        ({"plan_id": "gold", "months": 1}, 422),
        ({"plan_id": "plus", "months": 2}, 400),
        ({"plan_id": "plus", "months": 1, "phone_number": "12345"}, 400),
    ])
    async def test_refuses_nonsense(self, client, premium_on, mpesa, body, status):
        _, h = await _user()
        r = await client.post("/premium/subscribe", headers=h, json={"phone_number": "0712345678", **body})
        assert r.status_code == status
        assert mpesa.prompts == []


# ── Allowances ───────────────────────────────────────────────────────────────

class TestAllowances:
    @pytest.mark.asyncio
    async def test_a_plan_month_allows_exactly_its_allowance(self, premium_on):
        user, _ = await _user("pro")
        async with AsyncSessionLocal() as db:
            for _ in range(PREMIUM_BY_ID["pro"].auctions_hosted):
                await entitlements.consume(db, user.id, Feature.AUCTION)
            with pytest.raises(Exception) as exc:
                await entitlements.consume(db, user.id, Feature.AUCTION)
        assert exc.value.status_code == 402 and exc.value.detail["code"] == "ALLOWANCE_USED"
        assert exc.value.detail["upgrade_to"] == "elite"

    @pytest.mark.asyncio
    async def test_allowances_renew_each_plan_month(self, premium_on):
        user, h = await _user("pro", days_left=60, started_days_ago=31)
        async with AsyncSessionLocal() as db:
            sub = await entitlements.active_subscription(db, user.id)
            old_key = f"{sub.started_at:%Y%m%dT%H%M%S}:0"
            db.add(FeatureUsage(user_id=user.id, feature=Feature.AI_COVER, period_key=old_key, used=20))
            await db.commit()
            await entitlements.consume(db, user.id, Feature.AI_COVER)  # a new month

    @pytest.mark.asyncio
    async def test_released_allowance_can_be_spent_again(self, premium_on):
        user, _ = await _user()
        async with AsyncSessionLocal() as db:
            for _ in range(FREE_TRIAL["ai_covers"]):
                await entitlements.consume(db, user.id, Feature.AI_COVER)
            await entitlements.release(db, user.id, Feature.AI_COVER)
            await entitlements.consume(db, user.id, Feature.AI_COVER)

    @pytest.mark.asyncio
    async def test_me_without_a_plan_shows_the_free_tries(self, client, premium_on):
        _, h = await _user()
        me = (await client.get("/premium/me", headers=h)).json()
        assert me["plan"] is None and me["trial"] == {"ai_covers": 2}
        assert me["usage"]["voice_requests"]["allowance"] == 0


# ── The gates ────────────────────────────────────────────────────────────────

class TestVoiceMode:
    @pytest.mark.asyncio
    async def test_needs_a_plan_and_typing_does_not(self, client, premium_on, monkeypatch):
        monkeypatch.setattr("api.domains.zeno_assistant.service.assistant_turn",
                            AsyncMock(return_value={"reply": "Sawa", "action": None}))
        _, free = await _user()
        _, plus = await _user("plus")
        voice = {"message": "open my inbox", "mode": "voice"}
        refused = await client.post("/zeno/assistant/turn", headers=free, json=voice)
        assert refused.status_code == 402 and refused.json()["detail"]["code"] == "PREMIUM_REQUIRED"
        typed = await client.post("/zeno/assistant/turn", headers=free, json={"message": "open my inbox"})
        assert typed.status_code == 200
        assert (await client.post("/zeno/assistant/turn", headers=plus, json=voice)).status_code == 200
        me = (await client.get("/premium/me", headers=plus)).json()
        assert me["usage"]["voice_requests"]["used"] == 1


class TestBuyingAgent:
    @pytest.mark.asyncio
    async def test_watches_follow_the_plan(self, client, premium_on):
        _, free = await _user()
        _, pro = await _user("pro")
        watch = {"category": "Electronics", "max_price": 20000}
        refused = await client.post("/buy-agent-requests", headers=free, json=watch)
        assert refused.status_code == 402 and refused.json()["detail"]["upgrade_to"] == "plus"
        for _ in range(PREMIUM_BY_ID["pro"].agent_watches):
            assert (await client.post("/buy-agent-requests", headers=pro, json=watch)).status_code == 200
        full = await client.post("/buy-agent-requests", headers=pro, json=watch)
        assert full.status_code == 409 and "3 active" in full.json()["detail"]

    @pytest.mark.asyncio
    async def test_asking_zeno_for_a_watch_without_a_plan_says_so_in_words(self, client, premium_on):
        # The Zeno tab sets watches through an action, which answers in its
        # FAILED shape. The plan refusal used to arrive there as the repr of
        # the 402's detail dict, printed to the buyer as is.
        _, free = await _user()
        ask = {"action": "CREATE_BUYING_REQUEST",
               "parameters": {"category": "Electronics", "max_price": 20000}}
        answer = (await client.post("/buy-agent-requests/action", headers=free, json=ask)).json()
        assert answer["status"] == "FAILED" and answer["error_code"] == "PREMIUM_REQUIRED"
        assert answer["message"].startswith("The Buying Agent is part of BROKA Plus")

    @pytest.mark.asyncio
    async def test_zeno_negotiates_on_a_plan_that_includes_it_once_per_thread(self, client, premium_on):
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Laptop", category="Electronics",
                              price=40000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            listing_id = listing.id
        ask = {"action": "START_NEGOTIATION", "parameters": {"listing_id": listing_id}}
        _, plus = await _user("plus")
        refused = await client.post("/buy-agent-requests/action", headers=plus, json=ask)
        assert refused.status_code == 402 and refused.json()["detail"]["upgrade_to"] == "pro"

        _, pro = await _user("pro")
        assert (await client.post("/buy-agent-requests/action", headers=pro, json=ask)).json()["status"] == "SUCCESS"
        again = (await client.post("/buy-agent-requests/action", headers=pro, json=ask)).json()
        assert again["already_open"] is True
        me = (await client.get("/premium/me", headers=pro)).json()
        assert me["usage"]["auto_negotiations"]["used"] == 1, "a repeat tap opens nothing and costs nothing"

    @pytest.mark.asyncio
    async def test_the_automatic_opener_needs_a_negotiation_left(self, premium_on):
        from api.core.buy_agent_subscribers import on_listing_created_match_buy_agents
        seller, _ = await _user()
        plus_buyer, _ = await _user("plus")
        pro_buyer, _ = await _user("pro")
        async with AsyncSessionLocal() as db:
            for buyer in (plus_buyer, pro_buyer):
                db.add(BuyAgentRequest(
                    id=str(uuid.uuid4()), buyer_id=buyer.id, category="Gaming", max_price=90000,
                    must_have_features="[]", status="active", negotiation_authorized=True,
                    match_count=0, created_at=datetime.utcnow(), updated_at=datetime.utcnow(),
                    expires_at=datetime.utcnow() + timedelta(days=30)))
            listing = Listing(seller_id=seller.id, name="PS5", category="Gaming",
                              price=60000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            listing_id = listing.id
        with patch("api.core.buy_agent_subscribers._push_in_background"):
            await on_listing_created_match_buy_agents(SimpleNamespace(
                payload={"listing_id": listing_id, "category": "Gaming", "price": 60000},
                aggregate_id=listing_id))
        async with AsyncSessionLocal() as db:
            openers = (await db.execute(select(NegotiationMessage.buyer_id).where(
                NegotiationMessage.listing_id == listing_id,
                NegotiationMessage.is_agent_initiated.is_(True)))).scalars().all()
            matched = (await db.execute(select(BuyAgentRequest.buyer_id).where(
                BuyAgentRequest.status == "matched",
                BuyAgentRequest.buyer_id.in_([plus_buyer.id, pro_buyer.id])))).scalars().all()
        assert openers == [pro_buyer.id]
        assert set(matched) == {plus_buyer.id, pro_buyer.id}, "both are still told about the match"


class TestAuctions:
    @pytest.mark.asyncio
    async def test_hosting_needs_a_plan_that_includes_it(self, client, premium_on):
        body = {"description": "Well kept, works perfectly - selling because I upgraded.",
                "name": "Camera", "category": "Electronics", "price": 30000,
                "lat": -1.28, "lng": 36.82}
        _, plus = await _user("plus")
        refused = await client.post("/listings/", headers=plus, json={**body, "listing_type": "auction"})
        assert refused.status_code == 402 and "Bidding stays free" in refused.json()["detail"]["message"]
        assert (await client.post("/listings/", headers=plus, json=body)).status_code == 201
        _, pro = await _user("pro")
        assert (await client.post("/listings/", headers=pro, json={**body, "listing_type": "auction"})).status_code == 201
        me = (await client.get("/premium/me", headers=pro)).json()
        assert me["usage"]["auctions_hosted"]["used"] == 1


class TestSmsAlerts:
    async def _due_interest(self, seller: User) -> str:
        buyer, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Fridge", category="Home & Furniture",
                              price=25000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.flush()
            interest = Interest(listing_id=listing.id, buyer_id=buyer.id,
                                nudge_deadline=datetime.utcnow() - timedelta(seconds=1))
            db.add(interest)
            await db.commit()
            return interest.id

    async def _sweep(self, send: AsyncMock):
        from api.core.nudge_templates import EAT
        from api.core.workers import task_check_interest_nudges
        with patch("api.core.sms.get_sms_provider", return_value=SimpleNamespace(send=send)), \
             patch("api.core.nudge_templates.now_eat", return_value=datetime(2026, 9, 15, 14, 0, tzinfo=EAT)):
            await task_check_interest_nudges({})

    async def _interest(self, interest_id) -> Interest:
        async with AsyncSessionLocal() as db:
            return await db.get(Interest, interest_id)

    @pytest.mark.asyncio
    async def test_a_seller_without_a_plan_is_not_texted(self, premium_on):
        seller, _ = await _user()
        interest_id = await self._due_interest(seller)
        send = AsyncMock(return_value=True)
        await self._sweep(send)
        send.assert_not_called()
        assert (await self._interest(interest_id)).nudge_cancelled_at is not None

    @pytest.mark.asyncio
    async def test_a_seller_on_plus_is_texted_and_it_counts(self, client, premium_on):
        seller, h = await _user("plus")
        interest_id = await self._due_interest(seller)
        send = AsyncMock(return_value=True)
        await self._sweep(send)
        send.assert_called_once()
        assert (await self._interest(interest_id)).nudge_sent_at is not None
        assert (await client.get("/premium/me", headers=h)).json()["usage"]["sms_alerts"]["used"] == 1

    @pytest.mark.asyncio
    async def test_a_text_that_does_not_go_is_not_spent(self, client, premium_on):
        seller, h = await _user("plus")
        interest_id = await self._due_interest(seller)
        await self._sweep(AsyncMock(return_value=False))
        assert (await self._interest(interest_id)).nudge_sent_at is None
        assert (await client.get("/premium/me", headers=h)).json()["usage"]["sms_alerts"]["used"] == 0

    @pytest.mark.asyncio
    async def test_a_text_zeno_sends_from_a_negotiation_needs_a_plan(self, client, premium_on):
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Sofa", category="Home & Furniture",
                              price=18000, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            listing_id = listing.id
        ask = {"listing_id": listing_id, "text": "Still available?", "send": True}

        async def buyer(plan=None):
            # Only someone in a conversation on the listing may text about it.
            u, h = await _user(plan)
            async with AsyncSessionLocal() as db:
                db.add(NegotiationMessage(listing_id=listing_id, sender_id=u.id, role="buyer",
                                          recipient_role="seller", buyer_id=u.id, content="Hi"))
                await db.commit()
            return h

        send = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=SimpleNamespace(send=send)):
            free = await buyer()
            refused = await client.post("/negotiate/zeno-action/draft-sms", headers=free, json=ask)
            assert refused.status_code == 402 and refused.json()["detail"]["upgrade_to"] == "plus"
            send.assert_not_called()

            plus = await buyer("plus")
            assert (await client.post("/negotiate/zeno-action/draft-sms", headers=plus, json=ask)).status_code == 200
            assert (await client.get("/premium/me", headers=plus)).json()["usage"]["sms_alerts"]["used"] == 1

            send.return_value = False
            other = await buyer("plus")
            failed = await client.post("/negotiate/zeno-action/draft-sms", headers=other, json=ask)
            assert failed.status_code == 502
            assert (await client.get("/premium/me", headers=other)).json()["usage"]["sms_alerts"]["used"] == 0, \
                "a text that did not go is not spent"
