"""
Regression tests for the escrow audit (2026-09-14).

The headline bug: EscrowLedger.record_escrow_released() built its
escrow_holding debit from the caller's `amount` (deal.agreed_price)
regardless of what had actually been escrowed. Correct for the E-Confirm
flow, which escrows the full goods price. Wrong for the legacy M-Pesa
flow, where the STK push charges the COMMISSION ONLY (api/routers/mpesa.py:
`amount = max(1, int(round(deal.commission)))`) because the goods settle
off-platform. Every completed legacy deal credited escrow_holding ~1,500
and debited it ~50,000.

The reason it survived: trial_balance() only compared total debits to
total credits, and every ledger helper writes matched pairs, so that
equality holds by construction however wrong the amounts are. The books
could be arbitrarily broken and the only check that existed still reported
`balanced: true`.
"""
from decimal import Decimal

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine, async_sessionmaker

from api.core.ledger import EscrowLedger, LedgerError
from api.models.escrow_ledger import LedgerEntry, LedgerAccount, LedgerDirection


PRICE = 50_000.0
COMMISSION = 1_500.0


@pytest_asyncio.fixture
async def db_session():
    """Self-contained in-memory session.

    This suite has no shared DB fixture (tests/conftest.py only registers
    the asyncio plugin), and test_auctions.py's header records a previous
    draft breaking on an assumed `db_session` that did not exist - so this
    one is defined locally rather than assumed. Only the ledger table is
    created: these tests exercise ledger arithmetic, which needs no other
    schema, and pulling in the full metadata would couple them to every
    unrelated model in the app.
    """
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(LedgerEntry.metadata.create_all,
                            tables=[LedgerEntry.__table__])
    maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with maker() as session:
        yield session
    await engine.dispose()


async def _escrow_legs(db, deal_id):
    from sqlalchemy import select
    rows = (await db.execute(
        select(LedgerEntry).where(LedgerEntry.deal_id == deal_id))).scalars().all()
    return rows


@pytest.mark.asyncio
class TestReleaseDebitsWhatWasActuallyHeld:
    async def test_legacy_commission_only_deal_settles_to_zero(self, db_session):
        """The exact shape of the original bug."""
        ledger = EscrowLedger()
        # Legacy flow: only the commission ever reaches BROKA.
        await ledger.record_escrow_funded(
            db_session, "legacy-1", "buyer-1", COMMISSION, "RCT123")
        # Caller still passes agreed_price, as the event payload does.
        await ledger.record_escrow_released(
            db_session, "legacy-1", PRICE, COMMISSION)

        balance = await ledger.escrow_balance(db_session, "legacy-1")
        assert balance == Decimal("0"), (
            f"escrow_holding should settle to zero, got {balance} "
            "(the original bug left this at -48500)"
        )

    async def test_legacy_deal_records_no_phantom_seller_payout(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(
            db_session, "legacy-2", "buyer-1", COMMISSION, "RCT124")
        await ledger.record_escrow_released(
            db_session, "legacy-2", PRICE, COMMISSION)

        legs = await _escrow_legs(db_session, "legacy-2")
        seller_legs = [l for l in legs if l.account == LedgerAccount.seller_wallet]
        # BROKA never held the goods money on this flow, so crediting
        # seller_wallet for it would record a payout that never happened.
        assert not seller_legs

        broka = [l for l in legs if l.account == LedgerAccount.broka_revenue]
        assert len(broka) == 1
        assert broka[0].amount_kes == Decimal("1500.00")

    async def test_econfirm_full_price_deal_splits_correctly(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(
            db_session, "ec-1", "buyer-1", PRICE, "TXN-1")
        await ledger.record_escrow_released(
            db_session, "ec-1", PRICE, COMMISSION)

        assert await ledger.escrow_balance(db_session, "ec-1") == Decimal("0")
        legs = await _escrow_legs(db_session, "ec-1")
        seller = [l for l in legs if l.account == LedgerAccount.seller_wallet]
        assert len(seller) == 1
        assert seller[0].amount_kes == Decimal("48500.00")

    async def test_refund_also_returns_only_what_was_held(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(
            db_session, "ref-1", "buyer-1", COMMISSION, "RCT125")
        await ledger.record_escrow_refunded(
            db_session, "ref-1", PRICE, "dispute-1")
        assert await ledger.escrow_balance(db_session, "ref-1") == Decimal("0")


@pytest.mark.asyncio
class TestReplayedEventsDoNotDoubleTheBooks:
    """core/deal_hub_subscribers.py drives these writes off an at-least-once
    event bus, so redelivery is expected, not exceptional."""

    async def test_duplicate_funding_event_is_ignored(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(db_session, "rep-1", "b", PRICE, "T1")
        before = len(await _escrow_legs(db_session, "rep-1"))
        await ledger.record_escrow_funded(db_session, "rep-1", "b", PRICE, "T1")
        assert len(await _escrow_legs(db_session, "rep-1")) == before
        assert await ledger.escrow_balance(db_session, "rep-1") == Decimal(str(PRICE))

    async def test_duplicate_release_event_is_ignored(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(db_session, "rep-2", "b", PRICE, "T2")
        await ledger.record_escrow_released(db_session, "rep-2", PRICE, COMMISSION)
        before = len(await _escrow_legs(db_session, "rep-2"))
        await ledger.record_escrow_released(db_session, "rep-2", PRICE, COMMISSION)
        assert len(await _escrow_legs(db_session, "rep-2")) == before
        assert await ledger.escrow_balance(db_session, "rep-2") == Decimal("0")


@pytest.mark.asyncio
class TestMalformedAmountsAreRefused:
    async def test_negative_funding_is_refused(self, db_session):
        ledger = EscrowLedger()
        with pytest.raises(LedgerError):
            await ledger.record_escrow_funded(db_session, "bad-1", "b", -5000, "T")

    async def test_zero_funding_is_refused(self, db_session):
        ledger = EscrowLedger()
        with pytest.raises(LedgerError):
            await ledger.record_escrow_funded(db_session, "bad-2", "b", 0, "T")

    async def test_release_with_nothing_held_writes_nothing(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_released(db_session, "bad-3", PRICE, COMMISSION)
        assert not await _escrow_legs(db_session, "bad-3")


@pytest.mark.asyncio
class TestTrialBalanceCanActuallyFail:
    async def test_reports_integrity_ok_on_healthy_books(self, db_session):
        ledger = EscrowLedger()
        await ledger.record_escrow_funded(db_session, "ok-1", "b", PRICE, "T")
        await ledger.record_escrow_released(db_session, "ok-1", PRICE, COMMISSION)
        report = await ledger.trial_balance(db_session)
        assert report["escrow_integrity_ok"]
        assert report["negative_escrow_deals"] == []

    async def test_detects_a_deal_with_negative_escrow(self, db_session):
        """The condition the old trial_balance was structurally blind to."""
        ledger = EscrowLedger()
        db_session.add(LedgerEntry(
            deal_id="corrupt-1", account=LedgerAccount.escrow_holding,
            direction=LedgerDirection.debit, amount_kes=Decimal("999.00"),
            description="money out of a deal that never had any"))
        await db_session.flush()

        report = await ledger.trial_balance(db_session)
        assert not report["escrow_integrity_ok"]
        assert any(d["deal_id"] == "corrupt-1"
                   for d in report["negative_escrow_deals"])


class TestAgreedPriceValidation:
    """POST /deal/finalize took a bare `float` with no constraints on the
    endpoint that creates a money obligation."""

    def test_rejects_non_finite_values(self):
        from api.domains.escrow.service import validate_agreed_price
        from fastapi import HTTPException
        # json.loads parses the bare literals Infinity/NaN by default, so
        # these genuinely reach the handler from a raw request body.
        for bad in (float("inf"), float("-inf"), float("nan")):
            with pytest.raises(HTTPException):
                validate_agreed_price(bad)

    def test_rejects_zero_and_negative(self):
        from api.domains.escrow.service import validate_agreed_price
        from fastapi import HTTPException
        for bad in (0, -1, -50000.0):
            with pytest.raises(HTTPException):
                validate_agreed_price(bad)

    def test_rejects_absurd_values(self):
        from api.domains.escrow.service import validate_agreed_price
        from fastapi import HTTPException
        with pytest.raises(HTTPException):
            validate_agreed_price(1e15)

    def test_accepts_a_normal_price(self):
        from api.domains.escrow.service import validate_agreed_price
        assert validate_agreed_price(50000) == 50000.0
        assert validate_agreed_price("1200.456") == 1200.46
