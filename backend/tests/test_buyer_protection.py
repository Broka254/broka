"""Partial payments, buyer release, the delivery claim's automatic release,
and refund requests (ESCROW_AUDIT.md, "Partial payments" and "Release,
reminders and refund requests").

HTTP through the real /deal endpoints where the rule is an endpoint's; the
five-minute sweep (task_check_deal_timers) is driven directly, with the
deal's clocks moved back instead of waiting. E-Confirm is a fake that keeps
each transaction's state separately - a deal paid in parts has several.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Deal, DealStatus, Listing, ListingStatus,
    NegotiationMessage, User, init_db, reset_engine,
)
from api.domains.escrow.providers import EConfirmProvider, EscrowProvider, EscrowProviderResult, FeeQuote
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.security import create_access_token
from main import app


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_buyer_protection.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


class FakeEConfirm(EscrowProvider):
    """Each transaction has its own status. `funds_on_push` makes an STK
    push fund the transaction, as if the buyer entered their PIN."""

    def __init__(self):
        self.tx: dict[str, str] = {}
        self.created: list[dict] = []
        self.released: list[str] = []
        self.release_status = "Completed"
        self.funds_on_push = True

    async def get_fee_quote(self, amount):
        return FeeQuote(fee_amount=round(amount * 0.01, 2))

    async def create_escrow(self, **kw):
        tx = f"ec_{uuid.uuid4().hex[:12]}"
        self.tx[tx] = "pending"
        self.created.append({**kw, "tx": tx})
        return EscrowProviderResult(tx, EConfirmEscrowStatus.PENDING, "pending", confirmation_code=f"code-{tx}")

    async def fund_escrow(self, tx, payer_phone):
        if self.funds_on_push:
            self.tx[tx] = "Escrow Funded"
        return EscrowProviderResult(tx, EConfirmProvider.map_status("pending"), "pending")

    async def get_status(self, tx):
        raw = self.tx[tx]
        return EscrowProviderResult(tx, EConfirmProvider.map_status(raw), raw)

    async def release_escrow(self, tx, confirmation_code, notes=None):
        assert confirmation_code == f"code-{tx}"
        self.released.append(tx)
        self.tx[tx] = self.release_status
        return EscrowProviderResult(tx, EConfirmProvider.map_status(self.release_status), self.release_status)




@pytest.fixture
def econfirm(monkeypatch):
    fake = FakeEConfirm()
    monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: fake)
    monkeypatch.setattr("api.domains.escrow.providers.get_escrow_provider", lambda: fake)
    return fake


@pytest.fixture
def texts(monkeypatch):
    """Every SMS sent, as (phone, text); never quiet hours."""
    sent = []

    class _SMS:
        async def send(self, phone, message):
            sent.append((phone, message))
            return True

    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: _SMS())
    monkeypatch.setattr("api.domains.escrow.protection._quiet_hours", lambda: False)
    return sent


def _tag() -> str:
    return uuid.uuid4().hex[:10]


async def _user(name: str) -> User:
    u = User(name=name, phone=f"+2547{_tag()}", password_hash="x", email=f"{_tag()}@x.test")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _auth(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _deal(client, price: float = 100000, category: str = "Electronics"):
    """An agreed deal between a fresh seller and buyer."""
    seller, buyer = await _user("Seller Sam"), await _user("Buyer Bea")
    listing = Listing(seller_id=seller.id, name=f"Item {_tag()}", category=category, price=price,
                      lat=-1.29, lng=36.82, status=ListingStatus.active)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    r = await client.post("/deal/finalize", json={
        "listing_id": listing.id, "buyer_id": buyer.id, "agreed_price": price,
    }, headers=_auth(seller))
    assert r.status_code == 201, r.text
    return r.json()["deal_id"], seller, buyer


async def _pay(client, deal_id, buyer, amount=None):
    """Pay, then poll the payment status as the app's payment screen does -
    which is what reconciles the payment with E-Confirm."""
    body = {"payer_phone": "+254700000001"}
    if amount is not None:
        body["amount"] = amount
    r = await client.post(f"/deal/{deal_id}/fund", json=body, headers=_auth(buyer))
    if r.status_code == 200:
        await client.get(f"/deal/{deal_id}/payment-status", headers=_auth(buyer))
    return r


async def _status(client, deal_id, user):
    r = await client.get(f"/deal/{deal_id}/payment-status", headers=_auth(user))
    assert r.status_code == 200, r.text
    return r.json()


async def _get(client, deal_id, user):
    r = await client.get(f"/deal/{deal_id}", headers=_auth(user))
    assert r.status_code == 200, r.text
    return r.json()


async def _row(deal_id) -> Deal:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()


async def _shift(deal_id, **columns_back):
    """Move the deal's clocks back: _shift(id, seller_claimed_delivery_at=25)
    makes that claim 25 hours old."""
    async with AsyncSessionLocal() as db:
        deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        for col, hours in columns_back.items():
            setattr(deal, col, getattr(deal, col) - timedelta(hours=hours))
        await db.commit()


async def _sweep():
    from api.core.workers import task_check_deal_timers
    await task_check_deal_timers({})


async def _messages(deal: Deal, to: str) -> list[str]:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(NegotiationMessage.content).where(
                NegotiationMessage.listing_id == deal.listing_id,
                NegotiationMessage.buyer_id == deal.buyer_id,
                NegotiationMessage.role == "broker",
                NegotiationMessage.recipient_role == to,
            ).order_by(NegotiationMessage.created_at)
        )).scalars().all()
    return list(rows)


async def _audit(action, deal_id):
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AuditLog).where(AuditLog.action == action, AuditLog.resource_id == deal_id)
        )).scalars().all()


async def _paid_in_full(client, econfirm):
    deal_id, seller, buyer = await _deal(client)
    assert (await _pay(client, deal_id, buyer)).status_code == 200
    assert (await _status(client, deal_id, buyer))["deal_status"] == "paid"
    return deal_id, seller, buyer


# ── Partial payments ───────────────────────────────────────────────────────

class TestPartialPayments:
    @pytest.mark.asyncio
    async def test_a_part_payment_secures_part_and_a_top_up_clears_the_balance(self, client, econfirm):
        deal_id, seller, buyer = await _deal(client, price=100000)

        r = await _pay(client, deal_id, buyer, amount=40000)
        assert r.status_code == 200, r.text
        s = await _status(client, deal_id, buyer)
        assert s["deal_status"] == "paid"
        assert s["amount_paid"] == 40000
        assert s["balance"] == 60000
        assert s["can_add_payment"] is True

        r = await _pay(client, deal_id, buyer, amount=60000)
        assert r.status_code == 200, r.text
        s = await _status(client, deal_id, buyer)
        assert s["amount_paid"] == 100000
        assert s["balance"] == 0
        assert s["can_add_payment"] is False
        assert [p["payment_no"] for p in s["payments"]] == [0, 1]

        # Two E-Confirm transactions, whose commissions add up to the deal's.
        assert [c["amount"] for c in econfirm.created] == [40000, 60000]
        deal = await _row(deal_id)
        assert sum(c["commission_amount"] for c in econfirm.created) == pytest.approx(deal.commission)

        # The seller is told about the top-up.
        assert any("added KES 60,000" in m for m in await _messages(deal, "seller"))

    @pytest.mark.asyncio
    async def test_paying_more_than_the_balance_is_refused(self, client, econfirm):
        deal_id, _, buyer = await _deal(client, price=50000)
        r = await _pay(client, deal_id, buyer, amount=50001)
        assert r.status_code == 422
        assert econfirm.created == []

    @pytest.mark.asyncio
    async def test_a_token_part_payment_is_refused(self, client, econfirm):
        deal_id, _, buyer = await _deal(client, price=50000)
        r = await _pay(client, deal_id, buyer, amount=10)
        assert r.status_code == 422
        assert econfirm.created == []

    @pytest.mark.asyncio
    async def test_a_second_tap_while_a_prompt_is_open_does_not_open_another_payment(self, client, econfirm):
        econfirm.funds_on_push = False  # the prompt sits on the buyer's phone
        deal_id, _, buyer = await _deal(client, price=50000)
        assert (await _pay(client, deal_id, buyer, amount=20000)).status_code == 200
        assert (await _pay(client, deal_id, buyer, amount=30000)).status_code == 200
        assert len(econfirm.created) == 1

    @pytest.mark.asyncio
    async def test_paying_a_fully_paid_deal_again_opens_nothing(self, client, econfirm):
        deal_id, _, buyer = await _paid_in_full(client, econfirm)
        assert (await _pay(client, deal_id, buyer)).status_code == 200
        assert len(econfirm.created) == 1

    @pytest.mark.asyncio
    async def test_the_seller_states_the_price_and_the_buyer_pays_the_balance(self, client, econfirm):
        deal_id, seller, buyer = await _deal(client, price=80000)
        assert (await _pay(client, deal_id, buyer)).status_code == 200  # pays the 80,000 the deal said

        # The seller says they agreed 90,000: a balance of 10,000 appears.
        r = await client.post(f"/deal/{deal_id}/price", json={"agreed_price": 90000}, headers=_auth(seller))
        assert r.status_code == 200, r.text
        assert r.json()["balance"] == 10000
        deal = await _row(deal_id)
        assert any("agreed price is KES 90,000" in m for m in await _messages(deal, "buyer"))

        assert (await _pay(client, deal_id, buyer)).status_code == 200
        assert (await _status(client, deal_id, buyer))["balance"] == 0
        assert [c["amount"] for c in econfirm.created] == [80000, 10000]

    @pytest.mark.asyncio
    async def test_the_price_cannot_go_below_what_was_paid(self, client, econfirm):
        deal_id, seller, buyer = await _deal(client, price=80000)
        assert (await _pay(client, deal_id, buyer, amount=50000)).status_code == 200
        r = await client.post(f"/deal/{deal_id}/price", json={"agreed_price": 40000}, headers=_auth(seller))
        assert r.status_code == 422
        # ...but the seller can accept what was paid as the price.
        r = await client.post(f"/deal/{deal_id}/price", json={"agreed_price": 50000}, headers=_auth(seller))
        assert r.status_code == 200
        assert r.json()["balance"] == 0

    @pytest.mark.asyncio
    async def test_only_the_seller_states_the_price(self, client, econfirm):
        deal_id, _, buyer = await _deal(client, price=80000)
        r = await client.post(f"/deal/{deal_id}/price", json={"agreed_price": 1000}, headers=_auth(buyer))
        assert r.status_code == 403


class TestLedgerPerPayment:
    @pytest.mark.asyncio
    async def test_a_release_reaches_the_ledger(self, client, econfirm):
        """The release subscriber began its transaction twice and lost
        every release entry; the deal's escrow account stayed full."""
        from api.core.ledger import ledger
        deal_id, _, buyer = await _deal(client, price=100000)
        await _pay(client, deal_id, buyer, amount=30000)
        await _pay(client, deal_id, buyer, amount=70000)
        async with AsyncSessionLocal() as db:
            assert await ledger.escrow_balance(db, deal_id) == 100000
        r = await client.post(f"/deal/{deal_id}/confirm-delivery", headers=_auth(buyer))
        assert r.json()["status"] == "released"
        async with AsyncSessionLocal() as db:
            assert await ledger.escrow_balance(db, deal_id) == 0

    @pytest.mark.asyncio
    async def test_each_payment_is_credited_once(self):
        from api.core.ledger import ledger
        deal_id = f"deal-{_tag()}"
        async with AsyncSessionLocal() as db:
            async with db.begin():
                await ledger.record_escrow_funded(db, deal_id, "b", 40000, "tx-1")
                await ledger.record_escrow_funded(db, deal_id, "b", 60000, "tx-2")
                await ledger.record_escrow_funded(db, deal_id, "b", 60000, "tx-2")  # a redelivery
            assert await ledger.escrow_balance(db, deal_id) == 100000


# ── Release ────────────────────────────────────────────────────────────────

class TestRelease:
    @pytest.mark.asyncio
    async def test_the_buyer_releases_every_payment(self, client, econfirm):
        deal_id, seller, buyer = await _deal(client, price=100000)
        await _pay(client, deal_id, buyer, amount=30000)
        await _pay(client, deal_id, buyer, amount=70000)

        r = await client.post(f"/deal/{deal_id}/confirm-delivery",
                              json={"item_received": True}, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        assert r.json()["status"] == "released"
        assert len(econfirm.released) == 2
        assert (await _row(deal_id)).status == DealStatus.released

    @pytest.mark.asyncio
    async def test_releasing_before_delivery_is_recorded_not_refused(self, client, econfirm):
        deal_id, _, buyer = await _paid_in_full(client, econfirm)
        r = await client.post(f"/deal/{deal_id}/confirm-delivery",
                              json={"item_received": False, "ownership_transferred": False},
                              headers=_auth(buyer))
        assert r.status_code == 200
        rows = await _audit("econfirm_release_requested", deal_id)
        assert "item_received=no" in rows[0].detail
        assert "ownership_transferred=no" in rows[0].detail

    @pytest.mark.asyncio
    async def test_a_payout_still_in_flight_keeps_the_deal_paid_until_reconciled(self, client, econfirm):
        deal_id, _, buyer = await _deal(client, price=100000)
        await _pay(client, deal_id, buyer, amount=30000)
        await _pay(client, deal_id, buyer, amount=70000)
        econfirm.release_status = "payout_initiated"

        r = await client.post(f"/deal/{deal_id}/confirm-delivery", headers=_auth(buyer))
        assert r.json()["status"] == "release_pending"
        assert (await _row(deal_id)).status == DealStatus.paid

        # E-Confirm finishes ONE payout: still not released.
        first = econfirm.released[0]
        econfirm.tx[first] = "Completed"
        await _status(client, deal_id, buyer)
        assert (await _row(deal_id)).status == DealStatus.paid
        # ...and then the other.
        for tx in econfirm.released:
            econfirm.tx[tx] = "Completed"
        await _status(client, deal_id, buyer)
        assert (await _row(deal_id)).status == DealStatus.released

    @pytest.mark.asyncio
    async def test_land_asks_about_the_ownership_documents(self, client, econfirm):
        deal_id, _, buyer = await _deal(client, category="Land")
        assert (await _get(client, deal_id, buyer))["requires_ownership_transfer"] is True
        deal_id, _, buyer = await _deal(client, category="Electronics")
        assert (await _get(client, deal_id, buyer))["requires_ownership_transfer"] is False


# ── Delivery claim → 72 hours → release ────────────────────────────────────

class TestDeliveryClaim:
    @pytest.mark.asyncio
    async def test_the_buyer_is_reminded_every_12_hours_texted_on_days_2_and_3_then_paid_out(
            self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        r = await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))
        assert r.status_code == 200, r.text
        assert r.json()["outcome"] == "started"
        assert r.json()["auto_release_at"]
        deal = await _row(deal_id)
        claim_msgs = len(await _messages(deal, "buyer"))

        await _sweep()  # straight after the claim: nothing due yet
        assert len(await _messages(deal, "buyer")) == claim_msgs
        assert texts == []

        await _shift(deal_id, seller_claimed_delivery_at=13)
        await _sweep()
        assert len(await _messages(deal, "buyer")) == claim_msgs + 1
        assert texts == []

        await _shift(deal_id, seller_claimed_delivery_at=12)  # 25 hours: day 2
        await _sweep()
        assert len(await _messages(deal, "buyer")) == claim_msgs + 2
        assert len(texts) == 1
        assert texts[0][0] == buyer.phone

        await _shift(deal_id, seller_claimed_delivery_at=24)  # 49 hours: day 3
        await _sweep()
        assert len(texts) == 2
        assert econfirm.released == []

        await _shift(deal_id, seller_claimed_delivery_at=24)  # 73 hours
        await _sweep()
        assert len(econfirm.released) == 1
        assert (await _row(deal_id)).status == DealStatus.released

    @pytest.mark.asyncio
    async def test_the_buyer_releasing_first_ends_the_countdown(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))
        await client.post(f"/deal/{deal_id}/confirm-delivery", headers=_auth(buyer))
        await _shift(deal_id, seller_claimed_delivery_at=80)
        await _sweep()
        assert len(econfirm.released) == 1  # the buyer's, not a second one

    @pytest.mark.asyncio
    async def test_only_the_seller_marks_a_deal_delivered(self, client, econfirm):
        deal_id, _, buyer = await _paid_in_full(client, econfirm)
        r = await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(buyer))
        assert r.status_code == 403

    @pytest.mark.asyncio
    async def test_a_second_claim_does_not_restart_the_clock(self, client, econfirm):
        deal_id, seller, _ = await _paid_in_full(client, econfirm)
        first = (await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))).json()
        await _shift(deal_id, seller_claimed_delivery_at=10)
        again = (await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))).json()
        assert again["outcome"] == "running"
        assert again["auto_release_at"] < first["auto_release_at"]


# ── Refund requests ────────────────────────────────────────────────────────

class TestRefundRequest:
    @pytest.mark.asyncio
    async def test_a_silent_seller_is_reminded_then_the_buyer_is_refunded(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        r = await client.post(f"/deal/{deal_id}/refund-request",
                              json={"reason": "The seller stopped answering"}, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        assert r.json()["refund_request"]["respond_by"]
        deal = await _row(deal_id)
        # Told at once: in the chat, and by SMS.
        assert any("asked for a refund" in m for m in await _messages(deal, "seller"))
        assert [t[0] for t in texts] == [seller.phone]

        await _sweep()
        assert len(texts) == 1  # the first text is not sent twice

        await _shift(deal_id, refund_requested_at=25)
        await _sweep()
        assert len(texts) == 2
        assert (await _row(deal_id)).status == DealStatus.paid

        await _shift(deal_id, refund_requested_at=24)  # 49 hours
        await _sweep()
        deal = await _row(deal_id)
        # E-Confirm holds the money: frozen, and the team is asked to return it.
        assert deal.refund_outcome == "seller_silent"
        assert deal.status == DealStatus.disputed
        assert await _audit("econfirm_refund_required", deal_id)
        assert econfirm.released == []

    @pytest.mark.asyncio
    async def test_the_team_closes_the_refund_once_returned(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        await client.post(f"/deal/{deal_id}/refund-response", json={"accept": True}, headers=_auth(seller))

        admin = await _user("Admin")
        async with AsyncSessionLocal() as db:
            (await db.execute(select(User).where(User.id == admin.id))).scalar_one().is_admin = True
            await db.commit()
        r = await client.post(f"/admin/deals/{deal_id}/econfirm-refunded", headers=_auth(admin))
        assert r.status_code == 200, r.text
        assert (await _row(deal_id)).status == DealStatus.refunded

    @pytest.mark.asyncio
    async def test_the_seller_accepting_refunds_without_waiting(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        r = await client.post(f"/deal/{deal_id}/refund-response", json={"accept": True}, headers=_auth(seller))
        assert r.status_code == 200, r.text
        assert r.json()["outcome"] == "refund_pending"
        assert (await _row(deal_id)).refund_outcome == "seller_accepted"

    @pytest.mark.asyncio
    async def test_the_seller_contesting_opens_a_dispute(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        r = await client.post(f"/deal/{deal_id}/refund-response",
                              json={"accept": False, "note": "Delivered on Monday"}, headers=_auth(seller))
        assert r.status_code == 200
        deal = await _row(deal_id)
        assert deal.status == DealStatus.disputed
        assert deal.refund_outcome == "seller_contested"
        # Nothing is refunded when the deadline would have passed.
        await _shift(deal_id, refund_requested_at=60)
        await _sweep()
        assert (await _row(deal_id)).refund_outcome == "seller_contested"

    @pytest.mark.asyncio
    async def test_after_a_delivery_claim_a_refund_request_is_a_dispute(self, client, econfirm, texts):
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))
        r = await client.post(f"/deal/{deal_id}/refund-request",
                              json={"reason": "It never came"}, headers=_auth(buyer))
        assert r.json()["outcome"] == "disputed"
        deal = await _row(deal_id)
        assert deal.status == DealStatus.disputed
        # ...and the release countdown is off.
        await _shift(deal_id, seller_claimed_delivery_at=80)
        await _sweep()
        assert econfirm.released == []

    @pytest.mark.asyncio
    async def test_claiming_delivery_on_an_open_refund_request_disputes_it(self, client, econfirm, texts):
        """A seller cannot dodge a refund request by tapping "delivered":
        that would otherwise start the 72-hour countdown to their payout."""
        deal_id, seller, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        r = await client.post(f"/deal/{deal_id}/mark-delivered", headers=_auth(seller))
        assert r.json()["outcome"] == "disputed"
        deal = await _row(deal_id)
        assert deal.status == DealStatus.disputed
        assert deal.timer_type == "refund_request"

        await _shift(deal_id, refund_requested_at=80)
        await _sweep()
        deal = await _row(deal_id)
        assert econfirm.released == []
        assert deal.refund_outcome == "seller_contested"

    @pytest.mark.asyncio
    async def test_the_buyer_can_withdraw_and_no_refund_follows(self, client, econfirm, texts):
        deal_id, _, buyer = await _paid_in_full(client, econfirm)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        r = await client.delete(f"/deal/{deal_id}/refund-request", headers=_auth(buyer))
        assert r.status_code == 200
        await _shift(deal_id, refund_requested_at=60)
        await _sweep()
        deal = await _row(deal_id)
        assert deal.refund_outcome == "withdrawn"
        assert deal.status == DealStatus.paid

    @pytest.mark.asyncio
    async def test_no_top_up_while_a_refund_is_requested(self, client, econfirm, texts):
        deal_id, seller, buyer = await _deal(client, price=100000)
        await _pay(client, deal_id, buyer, amount=40000)
        await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        assert (await _pay(client, deal_id, buyer, amount=60000)).status_code == 409

    @pytest.mark.asyncio
    async def test_nothing_paid_means_nothing_to_refund(self, client, econfirm):
        deal_id, _, buyer = await _deal(client)
        r = await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(buyer))
        assert r.status_code == 400

    @pytest.mark.asyncio
    async def test_the_seller_cannot_request_the_refund(self, client, econfirm):
        deal_id, seller, _ = await _paid_in_full(client, econfirm)
        r = await client.post(f"/deal/{deal_id}/refund-request", json={"reason": ""}, headers=_auth(seller))
        assert r.status_code == 403


class TestChatDealStatus:
    @pytest.mark.asyncio
    async def test_the_chat_sees_what_was_paid_and_strangers_see_nothing(self, client, econfirm):
        deal_id, seller, buyer = await _deal(client, price=100000)
        await _pay(client, deal_id, buyer, amount=25000)
        listing_id = (await _row(deal_id)).listing_id

        r = await client.get(f"/negotiate/deal-status/{listing_id}", headers=_auth(buyer))
        body = r.json()
        assert body["has_deal"] is True
        assert body["amount_paid"] == 25000
        assert body["balance"] == 75000
        assert body["can_add_payment"] is True

        # The seller reads the buyer's thread by naming the buyer.
        r = await client.get(f"/negotiate/deal-status/{listing_id}",
                             params={"buyer_id": buyer.id}, headers=_auth(seller))
        assert r.json()["amount_paid"] == 25000

        # Anyone else naming the buyer gets nothing - it carries money now.
        stranger = await _user("Stranger")
        r = await client.get(f"/negotiate/deal-status/{listing_id}",
                             params={"buyer_id": buyer.id}, headers=_auth(stranger))
        assert r.json() == {"has_deal": False}


# ── Paying from the chat in one step (no finalize) ─────────────────────────

async def _listing(price: float = 50000, *, seller_email: bool = True):
    seller = await _user("Seller Sue")
    if not seller_email:
        async with AsyncSessionLocal() as db:
            (await db.execute(select(User).where(User.id == seller.id))).scalar_one().email = None
            await db.commit()
    listing = Listing(seller_id=seller.id, name=f"Item {_tag()}", category="Electronics", price=price,
                      lat=-1.29, lng=36.82, status=ListingStatus.active)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
    return listing, seller


async def _phone_buyer(email: bool = True) -> User:
    """A buyer as signup makes them: a real Kenyan number, maybe no email."""
    u = User(name="Buyer Ben", phone=f"+2547{uuid.uuid4().int % 10**8:08d}", password_hash="x",
             email=f"{_tag()}@x.test" if email else None)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


class TestPayInOneStep:
    @pytest.mark.asyncio
    async def test_paying_opens_the_deal_and_sends_the_prompt(self, client, econfirm):
        listing, _ = await _listing(50000)
        buyer = await _phone_buyer()
        r = await client.post("/deal/pay", json={"listing_id": listing.id}, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        deal_id = r.json()["deal_id"]
        # No finalize call: the deal exists, at the listing's price, and the
        # whole of it went to E-Confirm, prompting the buyer's own number.
        deal = await _row(deal_id)
        assert deal.agreed_price == 50000
        assert econfirm.created[0]["amount"] == 50000
        assert (await _status(client, deal_id, buyer))["deal_status"] == "paid"

    @pytest.mark.asyncio
    async def test_the_agreed_offer_is_the_price_and_a_part_can_be_paid(self, client, econfirm):
        listing, _ = await _listing(50000)
        buyer = await _phone_buyer()
        r = await client.post("/deal/pay", json={
            "listing_id": listing.id, "agreed_price": 45000, "amount": 20000,
            "payer_phone": "0712 345 678",
        }, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        deal_id = r.json()["deal_id"]
        await _status(client, deal_id, buyer)
        # The rest through the same button: the existing deal is topped up.
        r = await client.post("/deal/pay", json={"listing_id": listing.id}, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        assert r.json()["deal_id"] == deal_id
        s = await _status(client, deal_id, buyer)
        assert s["amount_paid"] == 45000 and s["balance"] == 0
        assert [c["amount"] for c in econfirm.created] == [20000, 25000]

    @pytest.mark.asyncio
    async def test_people_without_an_email_can_still_pay(self, client, econfirm):
        listing, seller = await _listing(30000, seller_email=False)
        buyer = await _phone_buyer(email=False)
        r = await client.post("/deal/pay", json={"listing_id": listing.id}, headers=_auth(buyer))
        assert r.status_code == 200, r.text
        assert econfirm.created[0]["buyer_email"] == f"user-{buyer.id}@broka.co.ke"
        assert econfirm.created[0]["seller_email"] == f"user-{seller.id}@broka.co.ke"

    @pytest.mark.asyncio
    async def test_a_fee_quote_e_confirm_cannot_give_does_not_stop_payment(self, client, econfirm):
        from api.core.econfirm_client import EConfirmAPIError

        async def refuses(amount):
            raise EConfirmAPIError(404, "Not Found")
        econfirm.get_fee_quote = refuses
        listing, _ = await _listing(40000)
        buyer = await _phone_buyer()
        r = await client.get(f"/deal/pay-quote/{listing.id}", headers=_auth(buyer))
        assert r.status_code == 200, r.text
        q = r.json()
        assert q["fee_estimated"] is True
        assert q["provider_fee"] == 400  # the published 1%
        assert q["total_to_pay"] == pytest.approx(40000 + q["merchant_commission"] + 400)
        assert (await client.post("/deal/pay", json={"listing_id": listing.id},
                                  headers=_auth(buyer))).status_code == 200

    @pytest.mark.asyncio
    async def test_e_confirm_s_reason_reaches_the_buyer(self, client, econfirm):
        from api.core.econfirm_client import EConfirmAPIError

        async def refuses(**kw):
            raise EConfirmAPIError(422, "receiver_phone is not a valid M-Pesa number")
        econfirm.create_escrow = refuses
        listing, _ = await _listing(40000)
        buyer = await _phone_buyer()
        r = await client.post("/deal/pay", json={"listing_id": listing.id}, headers=_auth(buyer))
        assert r.status_code == 422
        assert "receiver_phone is not a valid M-Pesa number" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_a_number_that_is_not_m_pesa_is_refused_before_any_prompt(self, client, econfirm):
        listing, _ = await _listing(40000)
        buyer = await _phone_buyer()
        r = await client.post("/deal/pay", json={"listing_id": listing.id, "payer_phone": "12345"},
                              headers=_auth(buyer))
        assert r.status_code == 422
        assert econfirm.created == []
        async with AsyncSessionLocal() as db:
            opened = (await db.execute(select(Deal).where(Deal.listing_id == listing.id))).scalars().all()
        assert opened == []

    @pytest.mark.asyncio
    async def test_a_seller_cannot_pay_for_their_own_listing(self, client, econfirm):
        listing, seller = await _listing(40000)
        r = await client.post("/deal/pay", json={"listing_id": listing.id}, headers=_auth(seller))
        assert r.status_code == 400
