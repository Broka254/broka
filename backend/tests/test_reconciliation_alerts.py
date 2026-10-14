"""Reconciliation alerts reach Sentry: once each, grouped per (kind, deal).

A real sentry_sdk client with an in-memory transport - and the logging
integration on, as in production - so these check what Sentry would
actually receive:

  * exactly ONE event per alert: the structured capture, not also the log
    line (that goes through a logger the logging integration ignores);
  * tags, context and a fingerprint that makes each deal its own issue, so a
    second deal needing a person is a new alert rather than a silent count
    on an issue someone already saw;
  * the real alert sites emit it (escrow, deal timers, legacy M-Pesa, chat
    intents, auction lapse);
  * ARQ worker processes initialise Sentry too.
"""
import logging
import uuid
from dataclasses import replace
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
import sentry_sdk
from sentry_sdk.integrations.logging import LoggingIntegration
from sentry_sdk.transport import Transport
from sqlalchemy import select

from api.core.config import settings
from api.core.reconciliation import alert_logger, report_reconciliation
from api.database import (
    AsyncSessionLocal, AuctionMeta, Deal, DealStatus, Listing, ListingStatus,
    ListingType, MpesaStatus, MpesaTransaction, User, init_db, reset_engine,
)
from api.domains.escrow.providers import EscrowProvider, EscrowProviderResult
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow


class _CapturingTransport(Transport):
    def __init__(self, sink):
        super().__init__()
        self.sink = sink

    def capture_envelope(self, envelope):
        for item in envelope.items:
            event = item.get_event()
            if event is not None:
                self.sink.append(event)


@pytest.fixture
def sentry_events():
    events: list = []
    sentry_sdk.init(
        dsn="https://public@o0.ingest.sentry.io/0",
        transport=_CapturingTransport(events),
        default_integrations=False,
        auto_enabling_integrations=False,
        integrations=[LoggingIntegration(level=logging.INFO, event_level=logging.ERROR)],
    )
    try:
        yield events
    finally:
        sentry_sdk.get_client().flush()
        sentry_sdk.init()  # back to a client with no DSN: capture is a no-op


@pytest.fixture(autouse=True)
def _fresh_cooldown(monkeypatch):
    """Each test starts with no (kind, deal) recently reported."""
    import api.core.reconciliation as recon
    monkeypatch.setattr(recon, "_last_sent", {})


def _recon(events: list) -> list:
    sentry_sdk.get_client().flush()
    return [e for e in events if e.get("tags", {}).get("alert") == "reconciliation"]


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_reconciliation_alerts.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


# ── The helper ───────────────────────────────────────────────────────────────

class TestReportReconciliation:
    def test_one_structured_event_per_alert(self, sentry_events):
        report_reconciliation(
            "econfirm_funded_on_inactive_deal", deal_id="deal-1",
            provider_transaction_id="tx-1", reason="money for a cancelled deal",
        )
        events = _recon(sentry_events)  # flushes first
        assert len(sentry_events) == 1, "the log line must not become a second event"
        (e,) = events
        assert e["level"] == "error"
        assert e["tags"]["reconciliation.kind"] == "econfirm_funded_on_inactive_deal"
        assert e["tags"]["deal_id"] == "deal-1"
        assert e["tags"]["provider_transaction_id"] == "tx-1"
        assert e["contexts"]["reconciliation"]["reason"] == "money for a cancelled deal"
        assert e["fingerprint"] == ["reconciliation", "econfirm_funded_on_inactive_deal", "deal-1"]

    def test_each_deal_is_its_own_issue(self, sentry_events):
        for deal in ("deal-a", "deal-b"):
            report_reconciliation("mpesa_payment_on_inactive_deal", deal_id=deal, reason="r")
        prints = {tuple(e["fingerprint"]) for e in _recon(sentry_events)}
        assert prints == {
            ("reconciliation", "mpesa_payment_on_inactive_deal", "deal-a"),
            ("reconciliation", "mpesa_payment_on_inactive_deal", "deal-b"),
        }

    def test_a_stuck_deal_is_not_resent_every_sweep(self, sentry_events, monkeypatch, caplog):
        """Re-detected every few minutes, sent at most once per cooldown."""
        import api.core.reconciliation as recon

        clock = [1000.0]
        monkeypatch.setattr(recon.time, "monotonic", lambda: clock[0])
        with caplog.at_level(logging.WARNING, logger=alert_logger.name):
            for _ in range(12):  # an hour of 5-minute sweeps
                report_reconciliation("econfirm_unrecognized_status", deal_id="stuck", reason="r")
                clock[0] += 299
        assert len(_recon(sentry_events)) == 1
        assert caplog.text.count("stuck") == 12, "every detection is still logged"

        clock[0] += recon.REPEAT_COOLDOWN_SECONDS  # the reminder
        report_reconciliation("econfirm_unrecognized_status", deal_id="stuck", reason="r")
        assert len(_recon(sentry_events)) == 2

    def test_a_different_kind_for_the_same_deal_is_not_suppressed(self, sentry_events):
        report_reconciliation("econfirm_fund_outcome_unknown", deal_id="d", reason="r", level="warning")
        report_reconciliation("econfirm_funded_on_inactive_deal", deal_id="d", reason="r")
        assert len(_recon(sentry_events)) == 2

    def test_self_healing_kinds_are_warnings(self, sentry_events):
        report_reconciliation("econfirm_fund_outcome_unknown", deal_id="d", reason="r", level="warning")
        assert _recon(sentry_events)[0]["level"] == "warning"

    def test_an_unknown_level_is_treated_as_error(self, sentry_events):
        report_reconciliation("k", deal_id="d", reason="r", level="shouting")
        assert _recon(sentry_events)[0]["level"] == "error"

    def test_the_log_line_is_still_written(self, sentry_events, caplog):
        with caplog.at_level(logging.ERROR, logger=alert_logger.name):
            report_reconciliation("k", deal_id="d-log", reason="visible in logs")
        assert "d-log" in caplog.text and "visible in logs" in caplog.text

    def test_a_sentry_failure_never_breaks_the_caller(self, sentry_events, monkeypatch):
        def boom(*a, **kw):
            raise RuntimeError("sentry down")
        monkeypatch.setattr(sentry_sdk, "capture_message", boom)
        report_reconciliation("k", deal_id="d", reason="r")  # must not raise

    def test_without_sentry_configured_it_is_a_quiet_no_op(self):
        sentry_sdk.init()  # no DSN
        report_reconciliation("k", deal_id="d", reason="r")  # must not raise


# ── The real alert sites ─────────────────────────────────────────────────────

def _tag() -> str:
    return uuid.uuid4().hex[:10]


class _FundedProvider(EscrowProvider):
    async def get_fee_quote(self, amount): ...
    async def create_escrow(self, **kw): ...
    async def fund_escrow(self, *a): ...
    async def release_escrow(self, *a, **kw): ...

    async def get_status(self, tx):
        return EscrowProviderResult(tx, EConfirmEscrowStatus.FUNDED, "Escrow Funded")


async def _deal(status: DealStatus, *, econfirm: bool, escrow_status=EConfirmEscrowStatus.PENDING,
                timer_type=None, listing_type=ListingType.direct):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{_tag()}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{_tag()}", password_hash="x")
        db.add_all([seller, buyer])
        await db.commit()
        listing = Listing(seller_id=seller.id, name=f"Item {_tag()}", category="Electronics",
                          price=10000, lat=0, lng=0, status=ListingStatus.pending,
                          listing_type=listing_type)
        db.add(listing)
        await db.commit()
        deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                    agreed_price=10000, commission=300, status=status, timer_type=timer_type,
                    timer_deadline=(datetime.utcnow() - timedelta(minutes=1)) if timer_type else None)
        db.add(deal)
        await db.commit()
        tx = None
        if econfirm:
            tx = f"tx-{_tag()}"
            db.add(ExternalEscrow(
                deal_id=deal.id, provider_transaction_id=tx, status=escrow_status, amount=10000,
                buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
                funding_initiated_at=datetime.utcnow() - timedelta(hours=1),
            ))
            await db.commit()
        return deal.id, listing.id, buyer.id, tx


def _kinds(events) -> dict:
    return {e["tags"]["reconciliation.kind"]: e for e in _recon(events)}


class TestAlertSites:
    @pytest.mark.asyncio
    async def test_escrow_funded_on_a_cancelled_deal(self, sentry_events, monkeypatch):
        from api.domains.escrow.service import EscrowService

        monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: _FundedProvider())
        deal_id, _, _, tx = await _deal(DealStatus.cancelled, econfirm=True)
        async with AsyncSessionLocal() as db:
            await EscrowService(db).reconcile_econfirm_escrow(deal_id)
        e = _kinds(sentry_events)["econfirm_funded_on_inactive_deal"]
        assert e["tags"]["deal_id"] == deal_id and e["tags"]["provider_transaction_id"] == tx

    @pytest.mark.asyncio
    async def test_deal_timer_blocked_on_an_econfirm_deal(self, sentry_events):
        import api.core.workers as workers

        deal_id, _, _, _ = await _deal(DealStatus.paid, econfirm=True,
                                       escrow_status=EConfirmEscrowStatus.FUNDED,
                                       timer_type="seller_silence_refund")
        await workers.task_check_deal_timers({})
        assert _kinds(sentry_events)["econfirm_auto_refund_blocked"]["tags"]["deal_id"] == deal_id

    @pytest.mark.asyncio
    async def test_legacy_mpesa_payment_on_a_cancelled_deal(self, sentry_events, monkeypatch):
        from api.routers.mpesa import _settle_successful_stk

        async def _no_publish(event):
            pass
        monkeypatch.setattr("api.routers.mpesa.publish", _no_publish)
        deal_id, _, buyer_id, _ = await _deal(DealStatus.cancelled, econfirm=False)
        async with AsyncSessionLocal() as db:
            txn = MpesaTransaction(deal_id=deal_id, buyer_id=buyer_id, phone="+254711111111",
                                   amount=300, checkout_request_id=f"ws_{_tag()}",
                                   status=MpesaStatus.pending)
            db.add(txn)
            await db.commit()
            await _settle_successful_stk(db, txn)
        e = _kinds(sentry_events)["mpesa_payment_on_inactive_deal"]
        assert e["tags"]["deal_id"] == deal_id
        assert "+254711111111" not in str(e), "no phone numbers in Sentry"

    @pytest.mark.asyncio
    async def test_chat_release_blocked_on_an_econfirm_deal(self, sentry_events):
        from api.routers.negotiate import _econfirm_holds_funds

        deal_id, _, _, _ = await _deal(DealStatus.awaiting_condition_check, econfirm=True)
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
            assert await _econfirm_holds_funds(db, deal, "release") is True
        assert _kinds(sentry_events)["econfirm_chat_release_blocked"]["tags"]["deal_id"] == deal_id

    @pytest.mark.asyncio
    async def test_auction_lapse_with_money_moved(self, sentry_events):
        from api.domains.auctions import lifecycle

        deal_id, listing_id, buyer_id, _ = await _deal(
            DealStatus.agreed, econfirm=True, escrow_status=EConfirmEscrowStatus.FUNDED,
            listing_type=ListingType.auction,
        )
        async with AsyncSessionLocal() as db:
            db.add(AuctionMeta(
                listing_id=listing_id, status="ended", starting_price=10000, bid_count=1,
                closed_at=datetime.utcnow() - timedelta(days=2), outcome=lifecycle.OUTCOME_WON,
                winner_id=buyer_id, winning_amount=10000, deal_id=deal_id,
                payment_deadline=datetime.utcnow() - timedelta(minutes=1),
            ))
            await db.commit()
        async with AsyncSessionLocal() as db:
            assert await lifecycle.lapse_unpaid_win(db, listing_id) is None
        e = _kinds(sentry_events)["auction_payment_reconciliation_required"]
        assert e["tags"]["deal_id"] == deal_id
        assert e["contexts"]["reconciliation"]["listing_id"] == listing_id

    @pytest.mark.asyncio
    async def test_an_ambiguous_fund_attempt_is_a_warning(self, sentry_events, monkeypatch):
        from fastapi import HTTPException
        from api.core.econfirm_client import EConfirmConnectionError
        from api.domains.escrow.service import EscrowService

        class _TimeoutProvider(_FundedProvider):
            async def fund_escrow(self, tx, phone):
                raise EConfirmConnectionError("timeout")
        monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: _TimeoutProvider())

        deal_id, _, buyer_id, _ = await _deal(DealStatus.agreed, econfirm=True)
        async with AsyncSessionLocal() as db:
            esc = (await db.execute(select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id))).scalar_one()
            esc.funding_initiated_at = None
            await db.commit()
        async with AsyncSessionLocal() as db:
            with pytest.raises(HTTPException):
                await EscrowService(db).fund_deal_escrow(deal_id, buyer_id, "+254711111111")
        assert _kinds(sentry_events)["econfirm_fund_outcome_unknown"]["level"] == "warning"


# ── ARQ workers ──────────────────────────────────────────────────────────────

class TestArqWorkerStartup:
    @pytest.mark.asyncio
    async def test_a_worker_initialises_sentry_when_configured(self, monkeypatch):
        import api.core.config as config
        import api.core.observability as observability
        import api.core.workers as workers

        seen = []
        monkeypatch.setattr(observability, "_init_sentry", lambda dsn, env: seen.append((dsn, env)))
        monkeypatch.setattr(config, "settings", replace(settings, sentry_dsn="https://k@o0.ingest.sentry.io/1"))
        await workers._arq_on_startup({})
        assert seen == [("https://k@o0.ingest.sentry.io/1", settings.env)]
        assert workers.WorkerSettings.on_startup is workers._arq_on_startup

    @pytest.mark.asyncio
    async def test_a_worker_without_a_dsn_skips_it(self, monkeypatch):
        import api.core.config as config
        import api.core.observability as observability
        import api.core.workers as workers

        seen = []
        monkeypatch.setattr(observability, "_init_sentry", lambda dsn, env: seen.append(dsn))
        monkeypatch.setattr(config, "settings", replace(settings, sentry_dsn=""))
        await workers._arq_on_startup({})
        assert seen == []
