"""Payments that race each other.

Three paths can touch one deal's money state at nearly the same moment, and
each used to decide from a read that another could invalidate:

  * the AUCTION PAYMENT-LAPSE sweep cancelled any deal still `agreed` at the
    deadline - which is also the status of a deal whose STK prompt is on the
    buyer's phone. A buyer paying in the last minute ended up with money held
    against a cancelled deal and the item back on sale;
  * the E-CONFIRM FUND path read "no attempt yet" and only then sent the STK
    push, so two taps (or a tap and a lapse) could both act;
  * the legacy /mpesa/query set a deal `paid` directly, from any status,
    publishing nothing - so a query that beat the Safaricom callback left the
    deal paid with no ledger entry.

Service-level where the rule lives in a service (the sweep never goes near a
router), HTTP where the rule is the endpoint's.
"""
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuctionMeta, AuditLog, Deal, DealStatus, Listing,
    ListingStatus, ListingType, MpesaStatus, MpesaTransaction, User, init_db,
    reset_engine,
)
from api.domains.auctions import lifecycle
from api.domains.escrow.providers import EscrowProvider, EscrowProviderResult, FeeQuote
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.security import create_access_token
from main import app


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_payment_races.db"
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


# ── Fixtures ─────────────────────────────────────────────────────────────────

class FakeProvider(EscrowProvider):
    """E-Confirm stand-in. `status` is what get_status/fund report;
    `fund_error` makes fund_escrow raise; `fund_delay` holds fund_escrow open
    so a concurrent caller can race it."""

    def __init__(self, status: str = EConfirmEscrowStatus.PENDING):
        self.status = status
        self.fund_calls = 0
        self.status_calls = 0
        self.fund_error: Exception | None = None
        self.status_error: Exception | None = None
        self.fund_delay = 0.0

    async def get_fee_quote(self, amount):
        return FeeQuote(fee_amount=0.0)

    async def create_escrow(self, **kwargs):
        raise AssertionError("tests create escrow rows directly")

    async def fund_escrow(self, provider_transaction_id, payer_phone):
        self.fund_calls += 1
        if self.fund_delay:
            await asyncio.sleep(self.fund_delay)
        if self.fund_error is not None:
            raise self.fund_error
        return EscrowProviderResult(provider_transaction_id, self.status, self.status)

    async def get_status(self, provider_transaction_id):
        self.status_calls += 1
        if self.status_error is not None:
            raise self.status_error
        return EscrowProviderResult(provider_transaction_id, self.status, self.status)

    async def release_escrow(self, *a, **kw):
        raise AssertionError("not used")


@pytest.fixture
def provider(monkeypatch):
    fake = FakeProvider()
    monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: fake)
    monkeypatch.setattr("api.domains.escrow.providers.get_escrow_provider", lambda: fake)
    return fake


def _tag() -> str:
    return uuid.uuid4().hex[:10]


async def _user(name: str) -> User:
    u = User(name=name, phone=f"+2547{_tag()}", password_hash="x", email=f"{_tag()}@x.test")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


async def _won_auction(*, deadline_passed: bool = True):
    """A closed auction with a winner and an `agreed` deal, deadline passed."""
    seller, winner = await _user("Seller"), await _user("Winner")
    now = datetime.utcnow()
    listing = Listing(
        seller_id=seller.id, name=f"Item {_tag()}", category="Electronics", price=20000,
        lat=-1.29, lng=36.82, listing_type=ListingType.auction, status=ListingStatus.active,
    )
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
        db.add(AuctionMeta(
            listing_id=listing.id, status="live", min_bid_increment=500, starting_price=20000,
            starts_at=now - timedelta(hours=2), ends_at=now + timedelta(hours=1), bid_count=0,
        ))
        await db.commit()
    async with AsyncSessionLocal() as db:
        await lifecycle.place_bid(db, listing.id, winner.id, 25000)
    async with AsyncSessionLocal() as db:
        m = await lifecycle._locked_meta(db, listing.id)
        m.ends_at = datetime.utcnow() - timedelta(seconds=1)
        await db.commit()
    async with AsyncSessionLocal() as db:
        closed = await lifecycle.close_auction(db, listing.id)
    assert closed.deal_id
    if deadline_passed:
        await _set_deadline(listing.id, datetime.utcnow() - timedelta(seconds=1))
    return listing, closed.deal_id, winner


async def _set_deadline(listing_id: str, when):
    async with AsyncSessionLocal() as db:
        m = await lifecycle._locked_meta(db, listing_id)
        m.payment_deadline = when
        await db.commit()


async def _add_escrow(deal_id: str, *, status=EConfirmEscrowStatus.PENDING, funding_at=None) -> str:
    tx = f"tx-{_tag()}"
    async with AsyncSessionLocal() as db:
        db.add(ExternalEscrow(
            deal_id=deal_id, provider_transaction_id=tx, status=status, amount=25000,
            buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            funding_initiated_at=funding_at,
        ))
        await db.commit()
    return tx


async def _state(listing_id: str, deal_id: str):
    async with AsyncSessionLocal() as db:
        meta = (await db.execute(select(AuctionMeta).where(AuctionMeta.listing_id == listing_id))).scalar_one()
        deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        listing = (await db.execute(select(Listing).where(Listing.id == listing_id))).scalar_one()
    return meta, deal, listing


async def _lapse(listing_id: str):
    async with AsyncSessionLocal() as db:
        return await lifecycle.lapse_unpaid_win(db, listing_id)


async def _audit(action: str, deal_id: str) -> list:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AuditLog).where(AuditLog.action == action, AuditLog.resource_id == deal_id)
        )).scalars().all()


SETTLE = timedelta(minutes=settings.auction_funding_settle_minutes)


# ── The payment lapse ────────────────────────────────────────────────────────

class TestLapseRespectsPaymentsInFlight:
    @pytest.mark.asyncio
    async def test_no_payment_attempt_still_lapses(self, provider):
        listing, deal_id, _ = await _won_auction()
        assert await _lapse(listing.id) == lifecycle.OUTCOME_UNPAID
        meta, deal, row = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.cancelled
        assert row.status == ListingStatus.active
        assert provider.status_calls == 0  # nothing to ask about

    @pytest.mark.asyncio
    async def test_a_recent_stk_prompt_defers_the_lapse(self, provider):
        """The original bug: buyer tapped Pay a minute before the deadline."""
        listing, deal_id, _ = await _won_auction()
        started = datetime.utcnow() - timedelta(minutes=1)
        await _add_escrow(deal_id, funding_at=started)

        assert await _lapse(listing.id) is None
        meta, deal, row = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed
        assert row.status != ListingStatus.active, "the item must not go back on sale"
        assert meta.outcome == lifecycle.OUTCOME_WON
        assert abs((meta.payment_deadline - (started + SETTLE)).total_seconds()) < 1
        assert provider.status_calls == 0  # too early to ask

    @pytest.mark.asyncio
    async def test_the_payment_landing_after_a_deferral_completes_the_deal(self, provider):
        from api.domains.escrow.service import EscrowService

        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - timedelta(minutes=1))
        assert await _lapse(listing.id) is None

        provider.status = EConfirmEscrowStatus.FUNDED
        async with AsyncSessionLocal() as db:
            await EscrowService(db).reconcile_econfirm_escrow(deal_id)
        _, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.paid

        # And the next sweep simply retires the deadline.
        await _set_deadline(listing.id, datetime.utcnow() - timedelta(seconds=1))
        assert await _lapse(listing.id) is None
        meta, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.paid
        assert meta.payment_deadline is None

    @pytest.mark.asyncio
    async def test_an_old_attempt_the_provider_confirms_unfunded_lapses(self, provider):
        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - SETTLE - timedelta(minutes=5))
        provider.status = EConfirmEscrowStatus.PENDING

        assert await _lapse(listing.id) == lifecycle.OUTCOME_UNPAID
        _, deal, row = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.cancelled
        assert row.status == ListingStatus.active
        assert provider.status_calls == 1

    @pytest.mark.asyncio
    async def test_an_old_attempt_the_provider_says_funded_is_applied_not_lapsed(self, provider):
        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - SETTLE - timedelta(minutes=5))
        provider.status = EConfirmEscrowStatus.FUNDED

        assert await _lapse(listing.id) is None
        meta, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.paid
        assert meta.outcome == lifecycle.OUTCOME_WON
        assert meta.payment_deadline is None

    @pytest.mark.asyncio
    async def test_an_unreachable_provider_defers_rather_than_guesses(self, provider):
        from api.core.econfirm_client import EConfirmConnectionError

        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - SETTLE - timedelta(minutes=5))
        provider.status_error = EConfirmConnectionError("down")

        assert await _lapse(listing.id) is None
        meta, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed
        assert meta.payment_deadline > datetime.utcnow()

    @pytest.mark.asyncio
    async def test_money_moved_but_deal_agreed_raises_an_alert_and_never_lapses(self, provider):
        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, status=EConfirmEscrowStatus.FUNDED,
                          funding_at=datetime.utcnow() - timedelta(hours=2))

        assert await _lapse(listing.id) is None
        meta, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed
        assert meta.payment_deadline is None  # the sweep stops; a human takes over
        assert await _audit("auction_payment_reconciliation_required", deal_id)

    @pytest.mark.asyncio
    async def test_a_recent_legacy_stk_push_defers_and_an_old_one_does_not(self, provider):
        listing, deal_id, winner = await _won_auction()
        async with AsyncSessionLocal() as db:
            txn = MpesaTransaction(
                deal_id=deal_id, buyer_id=winner.id, phone="+254711111111", amount=750,
                checkout_request_id=f"ws_{_tag()}", status=MpesaStatus.pending,
                created_at=datetime.utcnow() - timedelta(minutes=1),
            )
            db.add(txn)
            await db.commit()
            txn_id = txn.id

        assert await _lapse(listing.id) is None
        _, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed

        # The same prompt, long dead.
        async with AsyncSessionLocal() as db:
            t = (await db.execute(select(MpesaTransaction).where(MpesaTransaction.id == txn_id))).scalar_one()
            t.created_at = datetime.utcnow() - SETTLE - timedelta(minutes=5)
            await db.commit()
        await _set_deadline(listing.id, datetime.utcnow() - timedelta(seconds=1))
        assert await _lapse(listing.id) == lifecycle.OUTCOME_UNPAID

    @pytest.mark.asyncio
    async def test_a_legacy_success_with_an_agreed_deal_alerts(self, provider):
        listing, deal_id, winner = await _won_auction()
        async with AsyncSessionLocal() as db:
            db.add(MpesaTransaction(
                deal_id=deal_id, buyer_id=winner.id, phone="+254711111111", amount=750,
                checkout_request_id=f"ws_{_tag()}", status=MpesaStatus.success,
                callback_processed=True,
            ))
            await db.commit()
        assert await _lapse(listing.id) is None
        _, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed
        assert await _audit("auction_payment_reconciliation_required", deal_id)


# ── E-Confirm FUNDED against a dead deal ─────────────────────────────────────

class TestFundedOnInactiveDealAlerts:
    @pytest.mark.asyncio
    async def test_funded_on_a_cancelled_deal_is_recorded_for_reconciliation(self, provider):
        from api.domains.escrow.service import EscrowService

        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - timedelta(hours=1))
        async with AsyncSessionLocal() as db:
            d = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
            d.status = DealStatus.cancelled
            await db.commit()

        provider.status = EConfirmEscrowStatus.FUNDED
        async with AsyncSessionLocal() as db:
            await EscrowService(db).reconcile_econfirm_escrow(deal_id)

        _, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.cancelled, "never silently revived"
        assert await _audit("econfirm_funded_on_inactive_deal", deal_id)

    @pytest.mark.asyncio
    async def test_funded_on_an_already_paid_deal_is_benign(self, provider):
        from api.domains.escrow.service import EscrowService

        listing, deal_id, _ = await _won_auction()
        await _add_escrow(deal_id, funding_at=datetime.utcnow() - timedelta(hours=1))
        async with AsyncSessionLocal() as db:
            d = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
            d.status = DealStatus.paid  # a concurrent poller got there first
            await db.commit()

        provider.status = EConfirmEscrowStatus.FUNDED
        async with AsyncSessionLocal() as db:
            await EscrowService(db).reconcile_econfirm_escrow(deal_id)
        assert not await _audit("econfirm_funded_on_inactive_deal", deal_id)


# ── The funding claim ────────────────────────────────────────────────────────

async def _fundable_deal():
    listing, deal_id, winner = await _won_auction(deadline_passed=False)
    await _add_escrow(deal_id)  # PENDING, created, no attempt yet
    return listing, deal_id, winner


async def _fund(deal_id: str, buyer_id: str):
    from api.domains.escrow.service import EscrowService
    async with AsyncSessionLocal() as db:
        return await EscrowService(db).fund_deal_escrow(deal_id, buyer_id, "+254711111111")


async def _escrow(deal_id: str) -> ExternalEscrow:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id))).scalar_one()


class TestFundingClaim:
    @pytest.mark.asyncio
    async def test_two_simultaneous_fund_calls_send_one_stk_prompt(self, provider):
        _, deal_id, winner = await _fundable_deal()
        provider.fund_delay = 0.2
        results = await asyncio.gather(
            _fund(deal_id, winner.id), _fund(deal_id, winner.id), return_exceptions=True,
        )
        assert not [r for r in results if isinstance(r, Exception)], results
        assert provider.fund_calls == 1

    @pytest.mark.asyncio
    async def test_no_prompt_is_sent_for_a_deal_that_lapsed(self, provider):
        listing, deal_id, winner = await _fundable_deal()
        async with AsyncSessionLocal() as db:
            d = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
            d.status = DealStatus.cancelled
            await db.commit()
        result = await _fund(deal_id, winner.id)
        assert provider.fund_calls == 0
        assert result["deal_status"] == "cancelled"

    @pytest.mark.asyncio
    async def test_a_confirmed_rejection_releases_the_claim_for_a_corrected_retry(self, provider):
        from fastapi import HTTPException
        from api.core.econfirm_client import EConfirmAPIError

        _, deal_id, winner = await _fundable_deal()
        provider.fund_error = EConfirmAPIError(400, "bad phone", {})
        with pytest.raises(HTTPException) as exc:
            await _fund(deal_id, winner.id)
        assert exc.value.status_code == 422
        assert (await _escrow(deal_id)).funding_initiated_at is None

        provider.fund_error = None
        await _fund(deal_id, winner.id)
        assert provider.fund_calls == 2
        assert (await _escrow(deal_id)).funding_initiated_at is not None

    @pytest.mark.asyncio
    async def test_an_ambiguous_failure_keeps_the_claim_and_never_resends(self, provider):
        from fastapi import HTTPException
        from api.core.econfirm_client import EConfirmConnectionError

        _, deal_id, winner = await _fundable_deal()
        provider.fund_error = EConfirmConnectionError("timeout")
        with pytest.raises(HTTPException) as exc:
            await _fund(deal_id, winner.id)
        assert exc.value.status_code == 503
        assert (await _escrow(deal_id)).funding_initiated_at is not None

        provider.fund_error = None
        await _fund(deal_id, winner.id)
        assert provider.fund_calls == 1, "a possibly-sent prompt must not be re-sent"

    @pytest.mark.asyncio
    async def test_a_lapse_after_the_claim_sees_the_attempt(self, provider):
        """The ordering the claim exists for: Pay wins, lapse defers."""
        listing, deal_id, winner = await _fundable_deal()
        await _fund(deal_id, winner.id)
        await _set_deadline(listing.id, datetime.utcnow() - timedelta(seconds=1))
        assert await _lapse(listing.id) is None
        _, deal, _ = await _state(listing.id, deal_id)
        assert deal.status == DealStatus.agreed


# ── Legacy Daraja: one guarded settlement for callback and query ─────────────

async def _legacy_deal():
    seller, buyer = await _user("LSeller"), await _user("LBuyer")
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller.id, name=f"Legacy {_tag()}", category="Electronics",
                          price=25000, lat=-1.29, lng=36.82, status=ListingStatus.pending)
        db.add(listing)
        await db.commit()
        deal = Deal(listing_id=listing.id, buyer_id=buyer.id, seller_id=seller.id,
                    agreed_price=25000, commission=750, status=DealStatus.agreed)
        db.add(deal)
        await db.commit()
        txn = MpesaTransaction(deal_id=deal.id, buyer_id=buyer.id, phone="+254711111111",
                               amount=750, checkout_request_id=f"ws_CO_{_tag()}",
                               status=MpesaStatus.pending)
        db.add(txn)
        await db.commit()
        return deal.id, txn.checkout_request_id, buyer, seller


def _callback(checkout_id: str, *, amount: float = 750, result_code: int = 0) -> dict:
    return {"Body": {"stkCallback": {
        "CheckoutRequestID": checkout_id, "ResultCode": result_code, "ResultDesc": "ok",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": amount},
            {"Name": "MpesaReceiptNumber", "Value": "QJL82TEST"},
        ]},
    }}}


class _SafaricomSaysPaid:
    """Stands in for httpx.AsyncClient inside /mpesa/query."""

    def __init__(self, *a, **kw):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, *a, **kw):
        class _Resp:
            status_code = 200

            @staticmethod
            def json():
                return {"ResultCode": "0", "ResultDesc": "The service request is processed successfully."}
        return _Resp()


@pytest.fixture
def funded_events(monkeypatch):
    seen = []

    async def _publish(event):
        seen.append(event)
    monkeypatch.setattr("api.routers.mpesa.publish", _publish)
    return seen


@pytest.fixture
def safaricom(monkeypatch):
    async def _token():
        return "tok"
    monkeypatch.setattr("api.routers.mpesa._get_access_token", _token)
    monkeypatch.setattr("api.routers.mpesa.httpx.AsyncClient", _SafaricomSaysPaid)


class TestLegacyMpesaSettlement:
    @pytest.mark.asyncio
    async def test_query_is_buyer_only(self, client, safaricom):
        _, checkout, _, seller = await _legacy_deal()
        tok = create_access_token({"sub": seller.id})
        r = await client.post("/mpesa/query", json={"checkout_request_id": checkout},
                              headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_query_settles_once_with_a_ledger_event_and_the_callback_is_a_no_op(
        self, client, safaricom, funded_events,
    ):
        from api.core.events import EscrowFunded

        deal_id, checkout, buyer, _ = await _legacy_deal()
        tok = create_access_token({"sub": buyer.id})
        r = await client.post("/mpesa/query", json={"checkout_request_id": checkout},
                              headers={"Authorization": f"Bearer {tok}"})
        assert r.status_code == 200
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        assert deal.status == DealStatus.paid
        assert [e for e in funded_events if isinstance(e, EscrowFunded)], \
            "the ledger event must be published by whichever path settles first"

        r = await client.post("/mpesa/callback", json=_callback(checkout))
        assert r.status_code == 200
        assert len([e for e in funded_events if isinstance(e, EscrowFunded)]) == 1

    @pytest.mark.asyncio
    async def test_query_cannot_revive_a_cancelled_deal(self, client, safaricom, funded_events):
        deal_id, checkout, buyer, _ = await _legacy_deal()
        async with AsyncSessionLocal() as db:
            d = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
            d.status = DealStatus.cancelled
            await db.commit()
        tok = create_access_token({"sub": buyer.id})
        await client.post("/mpesa/query", json={"checkout_request_id": checkout},
                          headers={"Authorization": f"Bearer {tok}"})
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        assert deal.status == DealStatus.cancelled
        assert await _audit("mpesa_payment_on_inactive_deal", deal_id)

    @pytest.mark.asyncio
    async def test_callback_settles_an_agreed_deal(self, client, funded_events):
        from api.core.events import EscrowFunded

        deal_id, checkout, _, _ = await _legacy_deal()
        r = await client.post("/mpesa/callback", json=_callback(checkout))
        assert r.status_code == 200
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        assert deal.status == DealStatus.paid
        assert len([e for e in funded_events if isinstance(e, EscrowFunded)]) == 1

    @pytest.mark.asyncio
    async def test_callback_with_the_wrong_amount_settles_nothing(self, client, funded_events):
        deal_id, checkout, _, _ = await _legacy_deal()
        await client.post("/mpesa/callback", json=_callback(checkout, amount=1))
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(select(Deal).where(Deal.id == deal_id))).scalar_one()
        assert deal.status == DealStatus.agreed
        assert funded_events == []


# ── E-Confirm release: the re-check under the lock must read the real row ────

class ReleaseCountingProvider(FakeProvider):
    """Counts release_escrow calls. Answers `payout_initiated`, the response
    that leaves Deal.status at `paid` and so leaves a second request a way
    past the deal lock."""

    def __init__(self):
        super().__init__(status=EConfirmEscrowStatus.RELEASE_PENDING)
        self.release_calls = 0

    async def release_escrow(self, provider_transaction_id, confirmation_code, notes=None):
        self.release_calls += 1
        return EscrowProviderResult(
            provider_transaction_id, EConfirmEscrowStatus.RELEASE_PENDING, "payout_initiated",
        )


@pytest.fixture
def release_provider(monkeypatch):
    fake = ReleaseCountingProvider()
    monkeypatch.setattr("api.domains.escrow.service.get_escrow_provider", lambda: fake)
    monkeypatch.setattr("api.domains.escrow.providers.get_escrow_provider", lambda: fake)
    return fake


async def _funded_econfirm_deal():
    """A paid deal whose E-Confirm escrow is funded and holds a release code."""
    from api.core.secrets_crypto import encrypt_secret

    seller, buyer = await _user("Seller"), await _user("Buyer")
    async with AsyncSessionLocal() as db:
        listing = Listing(
            seller_id=seller.id, name=f"Item {_tag()}", category="Electronics", price=25000,
            lat=-1.29, lng=36.82, status=ListingStatus.pending,
        )
        db.add(listing)
        await db.flush()
        deal = Deal(
            listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
            agreed_price=25000, commission=750, status=DealStatus.paid,
        )
        db.add(deal)
        await db.flush()
        db.add(ExternalEscrow(
            deal_id=deal.id, provider_transaction_id=f"tx-{_tag()}",
            status=EConfirmEscrowStatus.FUNDED, amount=25000,
            buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            confirmation_code_encrypted=encrypt_secret("RELEASE-CODE"),
        ))
        await db.commit()
        return deal.id, buyer


class TestReleaseRace:
    """Two "confirm delivery" requests for one E-Confirm deal.

    Request B reads the escrow (funded) and passes the cheap early check.
    Request A then marks it release_pending and commits - the deal stays
    `paid`, because a release answered with payout_initiated does not
    complete the deal. B takes the deal lock and re-reads the escrow. That
    re-read is the only thing between B and a second payout request, so it
    has to see A's commit, not B's own earlier copy of the row.
    """

    @pytest.mark.asyncio
    async def test_a_release_committed_by_another_request_stops_the_second_one(self, release_provider):
        from api.domains.escrow.service import EscrowService

        deal_id, buyer = await _funded_econfirm_deal()

        async with AsyncSessionLocal() as db_b:
            svc_b = EscrowService(db_b)
            deal_b = await svc_b.deals.get_by_id(deal_id)
            escrow_b = await svc_b.external_escrows.get_by_deal_id(deal_id)
            assert escrow_b.status == EConfirmEscrowStatus.FUNDED

            # Request A wins the race and commits its intent to release.
            async with AsyncSessionLocal() as db_a:
                row = (await db_a.execute(
                    select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
                )).scalar_one()
                row.status = EConfirmEscrowStatus.RELEASE_PENDING
                row.release_initiated_at = datetime.utcnow()
                await db_a.commit()

            await svc_b._confirm_delivery_econfirm(deal_b, escrow_b, buyer.id, None)

        assert release_provider.release_calls == 0, (
            "the re-check under the deal lock read a stale `funded` escrow and "
            "asked E-Confirm to release the same transaction a second time"
        )

    @pytest.mark.asyncio
    async def test_a_single_release_still_goes_through(self, release_provider):
        from api.domains.escrow.service import EscrowService

        deal_id, buyer = await _funded_econfirm_deal()
        async with AsyncSessionLocal() as db:
            await EscrowService(db).confirm_delivery(deal_id, buyer.id)
        assert release_provider.release_calls == 1
        async with AsyncSessionLocal() as db:
            escrow = (await db.execute(
                select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
            )).scalar_one()
        assert escrow.status == EConfirmEscrowStatus.RELEASE_PENDING
