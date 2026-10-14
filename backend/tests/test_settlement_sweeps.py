"""The two automatic settlement sweeps must move money once, only where
BROKA holds it, and tell the ledger.

  * DISPUTE timers (task_check_dispute_timers): a timed auto-refund called
    M-Pesa B2C itself AND then execute_fund_action, which pays the same 97%
    refund again - two refunds per case, the first made before any of
    execute_fund_action's guards ran.
  * DEAL timers (task_check_deal_timers): the automatic refund/release had
    no E-Confirm guard, so for an E-Confirm-funded deal a refund paid the
    buyer out of BROKA's own account while their money stayed in escrow,
    and a release marked the deal released with the seller never paid.
    Neither published the ledger event, and a release gave the seller an
    unearned +0.05 rating for the buyer's silence.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from sqlalchemy import select

import api.core.workers as workers
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Deal, DealStatus, Listing, ListingStatus, User,
    init_db, reset_engine,
)
from api.models.dispute import CaseState, DisputeCase, DisputeTimer, TimerKind
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_settlement_sweeps.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest.fixture
def payouts(monkeypatch):
    """Every M-Pesa B2C payout, from either code path."""
    sent = []

    async def fake_dispute_b2c(phone, amount, ref_id):
        sent.append(("dispute_b2c", phone, amount))
        return {"success": True, "detail": "test"}

    async def fake_router_b2c(phone, amount, ref_id):
        sent.append(("router_b2c", phone, amount))
        return {"success": True}

    monkeypatch.setattr("api.domains.disputes.service._mpesa_b2c", fake_dispute_b2c)
    monkeypatch.setattr("api.routers.disputes._mpesa_b2c_refund", fake_router_b2c)
    return sent


@pytest.fixture
def published(monkeypatch):
    seen = []

    async def fake_publish(event):
        seen.append(event)
    monkeypatch.setattr("api.core.events.publish", fake_publish)
    return seen


def _tag() -> str:
    return uuid.uuid4().hex[:10]


async def _paid_deal(*, econfirm: bool = False, timer_type: str | None = None) -> tuple[str, str, str]:
    async with AsyncSessionLocal() as db:
        seller = User(name="Seller S", phone=f"+2547{_tag()}", password_hash="x", rating=4.0)
        buyer = User(name="Buyer B", phone=f"+2547{_tag()}", password_hash="x")
        db.add_all([seller, buyer])
        await db.commit()
        listing = Listing(seller_id=seller.id, name=f"Item {_tag()}", category="Electronics",
                          price=10000, lat=0, lng=0, status=ListingStatus.pending)
        db.add(listing)
        await db.commit()
        deal = Deal(
            listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
            agreed_price=10000, commission=300, status=DealStatus.paid,
            timer_type=timer_type,
            timer_deadline=(datetime.utcnow() - timedelta(minutes=1)) if timer_type else None,
        )
        db.add(deal)
        await db.commit()
        if econfirm:
            db.add(ExternalEscrow(
                deal_id=deal.id, provider_transaction_id=f"tx-{_tag()}",
                status=EConfirmEscrowStatus.FUNDED, amount=10000,
                buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            ))
            await db.commit()
        return deal.id, buyer.id, seller.id


async def _deal(deal_id: str) -> Deal:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()


async def _audits(action: str, deal_id: str) -> list:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AuditLog).where(AuditLog.action == action, AuditLog.resource_id == deal_id)
        )).scalars().all()


# ── Dispute timers ───────────────────────────────────────────────────────────

class TestDisputeTimerRefundPaysOnce:
    @pytest.mark.asyncio
    async def test_a_timed_auto_refund_pays_the_buyer_exactly_once(self, payouts, published):
        deal_id, buyer_id, _ = await _paid_deal()
        async with AsyncSessionLocal() as db:
            case = DisputeCase(deal_id=deal_id, opener_id=buyer_id,
                               state=CaseState.waiting_seller_explanation)
            db.add(case)
            await db.commit()
            db.add(DisputeTimer(case_id=case.id, deal_id=deal_id,
                                timer_kind=TimerKind.auto_refund_buyer,
                                fires_at=datetime.utcnow() - timedelta(minutes=1)))
            await db.commit()
            case_id = case.id

        await workers.task_check_dispute_timers()

        assert len(payouts) == 1, f"expected one refund, got {payouts}"
        assert payouts[0][2] == 9700.0
        async with AsyncSessionLocal() as db:
            case = (await db.execute(select(DisputeCase).where(DisputeCase.id == case_id))).scalar_one()
        assert case.state == CaseState.closed_refunded
        assert (await _deal(deal_id)).status == DealStatus.refunded


# ── Deal timers ──────────────────────────────────────────────────────────────

class TestDealTimerSettlement:
    @pytest.mark.asyncio
    async def test_legacy_auto_refund_pays_once_and_tells_the_ledger(self, payouts, published):
        from api.core.events import EscrowRefunded

        deal_id, _, _ = await _paid_deal(timer_type="seller_silence_refund")
        await workers.task_check_deal_timers({})

        assert [p for p in payouts if p[0] == "router_b2c"] == [payouts[0]] and len(payouts) == 1
        assert (await _deal(deal_id)).status == DealStatus.refunded
        refunds = [e for e in published if isinstance(e, EscrowRefunded) and e.deal_id == deal_id]
        assert len(refunds) == 1 and refunds[0].amount == 9700.0

    @pytest.mark.asyncio
    async def test_legacy_auto_release_tells_the_ledger_and_awards_no_rating(self, payouts, published):
        from api.core.events import EscrowReleased

        deal_id, _, seller_id = await _paid_deal(timer_type="buyer_silence_release")
        await workers.task_check_deal_timers({})

        assert (await _deal(deal_id)).status == DealStatus.released
        assert [e for e in published if isinstance(e, EscrowReleased) and e.deal_id == deal_id]
        async with AsyncSessionLocal() as db:
            seller = (await db.execute(select(User).where(User.id == seller_id))).scalar_one()
        assert seller.rating == 4.0, "a buyer's silence is not a review"
        assert seller.completed_deals == 1

    @pytest.mark.asyncio
    @pytest.mark.parametrize("timer_type,action", [
        ("seller_silence_refund", "refund"),
        ("buyer_silence_release", "release"),
    ])
    async def test_an_econfirm_deal_is_never_settled_automatically(
        self, payouts, published, timer_type, action,
    ):
        deal_id, _, _ = await _paid_deal(econfirm=True, timer_type=timer_type)
        await workers.task_check_deal_timers({})

        assert payouts == [], "BROKA must not pay out money E-Confirm is holding"
        deal = await _deal(deal_id)
        assert deal.status == DealStatus.paid
        assert deal.timer_fired_at is not None  # consumed, not re-fired every tick
        assert await _audits(f"econfirm_auto_{action}_blocked", deal_id)
        assert not [e for e in published if getattr(e, "deal_id", None) == deal_id]
