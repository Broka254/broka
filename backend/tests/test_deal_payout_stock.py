"""A chat deal's payout and the shared stock count (listings/inventory.py,
DEAL MOVES).

Paying a deal out is the moment its units count as sold - and with in-app
payments off, the first moment they count at all (stock.deals_hold_stock).
Six paths pay a deal out, and every one of them used to commit the move
without the listing's lock, so an order accepted at the same moment counted
a unit the payout was taking; the buyer's own release took no lock at all,
not even the deal's, so two taps released the deal twice. Each now locks
the deal, then its listing, counts, moves the deal and settles the
listing's status in one transaction - and never refuses a payout for stock:
when the units were already promised, it says so (an audit row and a
reconciliation alert) and goes ahead.

The races themselves, against real store orders, are in
test_store_orders.py (TestCrossChannelStock); these pin each path and the
rules a payout must keep. Rows are made directly, as test_chat_settlement_
econfirm.py makes them: an accepted order's hold is Listing.stock_reserved.
"""
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

import api.core.workers as workers
import api.database as db_module
from api.core.config import settings
from api.database import (
    AsyncSessionLocal, AuditLog, Deal, DealStatus, Listing, ListingStatus, User,
    init_db, reset_engine,
)
from api.domains.listings import inventory, stock
from api.models.dispute import CaseState, DisputeCase
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.security import create_access_token
from main import app

PATHS = ("buyer_confirms", "legacy_escrow_route", "timer_sweep", "chat", "dispute", "econfirm")


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_deal_payout_stock.db"
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


@pytest.fixture(autouse=True)
def quiet(monkeypatch):
    """No event leaves the test and no M-Pesa call is made: the money paths
    here are under test for what they write, not what they announce."""
    async def nothing(*args, **kwargs):
        return {"success": True, "detail": "test"}
    monkeypatch.setattr("api.core.events.publish", nothing)
    monkeypatch.setattr("api.domains.escrow.service.publish", nothing)
    monkeypatch.setattr("api.routers.disputes._mpesa_b2c_refund", nothing)
    monkeypatch.setattr("api.domains.disputes.service._mpesa_b2c", nothing)


def _tag() -> str:
    return uuid.uuid4().hex[:10]


def _auth(user_id: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user_id})}"}


async def _people() -> tuple[str, str]:
    async with AsyncSessionLocal() as db:
        seller = User(name="Wanjiru Seller", phone=f"+2547{_tag()}", password_hash="x")
        buyer = User(name="Brian Buyer", phone=f"+2547{_tag()}", password_hash="x")
        db.add_all([seller, buyer])
        await db.commit()
        return seller.id, buyer.id


async def _listing(seller_id: str, *, quantity, tracked: bool = False, reserved: int = 0,
                   status: ListingStatus = ListingStatus.active) -> str:
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller_id, name=f"Phone {_tag()}", category="Electronics",
                          price=10000, lat=-1.29, lng=36.82, status=status, quantity=quantity,
                          stock_tracked=tracked, stock_reserved=reserved)
        db.add(listing)
        await db.commit()
        return listing.id


async def _deal(listing_id: str, seller_id: str, buyer_id: str, status: DealStatus, **extra) -> str:
    async with AsyncSessionLocal() as db:
        deal = Deal(listing_id=listing_id, seller_id=seller_id, buyer_id=buyer_id,
                    agreed_price=10000, commission=300, status=status, quantity=1, **extra)
        db.add(deal)
        await db.commit()
        return deal.id


async def _ready_to_pay_out(path: str, listing_id: str, seller_id: str, buyer_id: str) -> str:
    """A deal on `listing_id` that `path` is about to pay out."""
    if path == "timer_sweep":
        # The buyer never confirmed: the sweep releases it.
        return await _deal(listing_id, seller_id, buyer_id, DealStatus.paid,
                           timer_type="buyer_silence_release",
                           timer_deadline=datetime.utcnow() - timedelta(minutes=1))
    if path == "chat":
        # "Yes, all good" after the condition check.
        return await _deal(listing_id, seller_id, buyer_id, DealStatus.awaiting_condition_check)
    if path == "dispute":
        deal_id = await _deal(listing_id, seller_id, buyer_id, DealStatus.disputed)
        async with AsyncSessionLocal() as db:
            db.add(DisputeCase(deal_id=deal_id, opener_id=buyer_id, state=CaseState.ready_for_release))
            await db.commit()
        return deal_id
    deal_id = await _deal(listing_id, seller_id, buyer_id, DealStatus.paid)
    if path == "econfirm":
        # E-Confirm has paid the payment out; the deal follows.
        async with AsyncSessionLocal() as db:
            db.add(ExternalEscrow(
                deal_id=deal_id, provider_transaction_id=f"tx-{_tag()}",
                status=EConfirmEscrowStatus.COMPLETED, amount=10000, merchant_commission_amount=300,
                buyer_email="b@x.test", seller_email="s@x.test", receiver_phone="+254700000000",
            ))
            await db.commit()
    return deal_id


async def _pay_out(path: str, client, deal_id: str, buyer_id: str) -> None:
    if path == "buyer_confirms":
        r = await client.post(f"/deal/{deal_id}/confirm-delivery", json={}, headers=_auth(buyer_id))
        assert r.status_code == 200, r.text
    elif path == "legacy_escrow_route":
        r = await client.post(f"/escrow/confirm-delivery/{deal_id}", headers=_auth(buyer_id))
        assert r.status_code == 200, r.text
    elif path == "timer_sweep":
        await workers.task_check_deal_timers({})
    elif path == "chat":
        async with AsyncSessionLocal() as db:
            listing_id = (await db.execute(select(Deal.listing_id).where(Deal.id == deal_id))).scalar_one()
        r = await client.post("/negotiate/message", json={
            "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer_id,
            "content": "(tap)", "intent": "buyer_confirms_goods_ok",
        }, headers=_auth(buyer_id))
        assert r.status_code == 200, r.text
    elif path == "dispute":
        from api.domains.disputes.service import DisputeEngineService
        async with AsyncSessionLocal() as db:
            case = (await db.execute(select(DisputeCase).where(DisputeCase.deal_id == deal_id))).scalar_one()
            await DisputeEngineService(db).execute_fund_action(case, buyer_id, "admin")
    elif path == "econfirm":
        from api.domains.escrow.service import EscrowService
        async with AsyncSessionLocal() as db:
            assert await EscrowService(db)._finish_release_if_complete(deal_id) is True
    else:
        raise AssertionError(path)


async def _status(model, row_id: str) -> str:
    async with AsyncSessionLocal() as db:
        value = (await db.execute(select(model.status).where(model.id == row_id))).scalar_one()
    return getattr(value, "value", value)


async def _shelf(listing_id: str) -> inventory.Inventory:
    async with AsyncSessionLocal() as db:
        return await inventory.count(db, await db.get(Listing, listing_id))


async def _audits(action: str, resource_id: str) -> list:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(AuditLog).where(
            AuditLog.action == action, AuditLog.resource_id == resource_id,
        ))).scalars().all()


class TestEveryPayoutPath:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("path", PATHS)
    async def test_each_payout_settles_the_listing_in_its_own_transaction(self, client, path):
        # One unit, stated (not counted), its one deal under way: hidden as
        # pending. Paid out, it is sold at once - not in the next five-minute
        # sweep - because the payout counted it under the listing's lock.
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=1, status=ListingStatus.pending)
        deal_id = await _ready_to_pay_out(path, lid, seller_id, buyer_id)

        await _pay_out(path, client, deal_id, buyer_id)

        assert await _status(Deal, deal_id) == "released"
        assert await _status(Listing, lid) == "completed"
        shelf = await _shelf(lid)
        assert (shelf.sold_in_deals, shelf.available) == (1, 0)
        assert await _audits("deal_stock_over_allocated", lid) == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("path", PATHS)
    async def test_with_payments_off_a_payout_counts_and_records_units_already_promised(
            self, client, payments_off, path):
        # With payments off a paid deal holds nothing until its payout, so an
        # accepted order may hold the one unit (stock_reserved) the deal is
        # for. Every path counts that under the lock, pays out anyway - the
        # buyer has paid and has the goods - and writes the conflict down
        # for a person to settle with the store.
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=1, reserved=1, status=ListingStatus.pending)
        deal_id = await _ready_to_pay_out(path, lid, seller_id, buyer_id)
        assert (await _shelf(lid)).available == 0

        await _pay_out(path, client, deal_id, buyer_id)

        assert await _status(Deal, deal_id) == "released"
        conflicts = await _audits("deal_stock_over_allocated", lid)
        assert len(conflicts) == 1
        assert f"deal={deal_id}" in conflicts[0].detail and "took 1 unit(s) with 0 left" in conflicts[0].detail
        shelf = await _shelf(lid)
        assert (shelf.reserved, shelf.in_deals, shelf.available) == (1, 1, 0)
        assert await _status(Listing, lid) == "completed"

    @pytest.mark.asyncio
    @pytest.mark.parametrize("payments", ["on", "off"])
    async def test_a_payout_with_units_to_spare_records_no_conflict(self, client, request, payments):
        if payments == "off":
            request.getfixturevalue("payments_off")
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=3, tracked=True, reserved=1)
        deal_id = await _ready_to_pay_out("buyer_confirms", lid, seller_id, buyer_id)

        await _pay_out("buyer_confirms", client, deal_id, buyer_id)

        shelf = await _shelf(lid)
        assert (shelf.total, shelf.reserved, shelf.sold_in_deals, shelf.available) == (3, 1, 1, 1)
        # Counted stock stays listed whatever is left (stock.status_for).
        assert await _status(Listing, lid) == "active"
        assert await _audits("deal_stock_over_allocated", lid) == []


class TestAPayoutHappensOnce:
    """Phase 2, test C: releasing, refunding and repeating."""

    @pytest.mark.asyncio
    async def test_a_second_release_changes_nothing(self, client):
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=2)
        deal_id = await _ready_to_pay_out("buyer_confirms", lid, seller_id, buyer_id)

        await _pay_out("buyer_confirms", client, deal_id, buyer_id)
        again = await client.post(f"/deal/{deal_id}/confirm-delivery", json={}, headers=_auth(buyer_id))
        assert again.status_code == 400 and "released" in again.json()["detail"]
        # The stock sweep reads the released deal the same way, every time.
        for _ in range(2):
            await workers.task_sync_listing_stock()
            shelf = await _shelf(lid)
            assert (shelf.in_deals, shelf.sold_in_deals, shelf.available) == (1, 1, 1)
        async with AsyncSessionLocal() as db:
            seller = await db.get(User, seller_id)
        assert seller.completed_deals == 1
        assert len(await _audits("delivery_confirmed", deal_id)) == 1

    @pytest.mark.asyncio
    async def test_two_releases_at_once_release_once(self, client, monkeypatch):
        # The buyer's release used to read `paid` without any lock and write
        # `released` straight after: two taps both released the deal - two
        # completed deals, two audit rows. Now the second waits on the
        # deal's lock and finds it released.
        if db_module.engine.dialect.name != "postgresql":
            pytest.skip("needs PostgreSQL's concurrent writers; SQLite serialises them outright")
        from api.core.ledger import ledger

        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=2)
        deal_id = await _ready_to_pay_out("buyer_confirms", lid, seller_id, buyer_id)
        in_first = asyncio.Event()
        go_on = asyncio.Event()
        real = ledger.record_escrow_released

        async def held_once(db, released_deal_id, *args, **kwargs):
            if released_deal_id == deal_id and not in_first.is_set():
                in_first.set()
                await asyncio.wait_for(go_on.wait(), 30)
            return await real(db, released_deal_id, *args, **kwargs)

        monkeypatch.setattr(ledger, "record_escrow_released", held_once)

        async def tap():
            return await client.post(f"/deal/{deal_id}/confirm-delivery", json={}, headers=_auth(buyer_id))

        first = asyncio.create_task(tap())
        await asyncio.wait_for(in_first.wait(), 30)
        second = asyncio.create_task(tap())
        await asyncio.sleep(0.5)
        assert not second.done(), (await second).text
        go_on.set()
        answers = await asyncio.wait_for(asyncio.gather(first, second), 30)

        assert sorted(r.status_code for r in answers) == [200, 400], [r.text for r in answers]
        async with AsyncSessionLocal() as db:
            seller = await db.get(User, seller_id)
        assert seller.completed_deals == 1
        assert len(await _audits("delivery_confirmed", deal_id)) == 1
        shelf = await _shelf(lid)
        assert (shelf.sold_in_deals, shelf.available) == (1, 1)

    @pytest.mark.asyncio
    async def test_a_refund_gives_the_units_back_and_takes_none(self, client):
        # The timer sweep refunds a paid deal whose seller went silent: its
        # unit is on sale again (the chat rule), and a refund never counts
        # as a sale.
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=1, status=ListingStatus.pending)
        deal_id = await _deal(lid, seller_id, buyer_id, DealStatus.paid,
                              timer_type="seller_silence_refund",
                              timer_deadline=datetime.utcnow() - timedelta(minutes=1))
        assert (await _shelf(lid)).available == 0

        await workers.task_check_deal_timers({})
        await workers.task_sync_listing_stock()

        assert await _status(Deal, deal_id) == "refunded"
        shelf = await _shelf(lid)
        assert (shelf.in_deals, shelf.sold_in_deals, shelf.available) == (0, 0, 1)
        assert await _status(Listing, lid) == "active"
        assert await _audits("deal_stock_over_allocated", lid) == []

    @pytest.mark.asyncio
    @pytest.mark.parametrize("payments", ["on", "off"])
    async def test_moves_among_the_statuses_that_hold_units_lock_nothing(self, request, payments):
        # Paid to disputed, a dispute's own steps: the count doesn't change,
        # so no listing is locked for them.
        if payments == "off":
            request.getfixturevalue("payments_off")
        seller_id, buyer_id = await _people()
        lid = await _listing(seller_id, quantity=1)
        deal_id = await _deal(lid, seller_id, buyer_id, DealStatus.paid)
        async with AsyncSessionLocal() as db:
            deal = await db.get(Deal, deal_id)
            for target in (DealStatus.disputed, DealStatus.awaiting_resolution,
                           DealStatus.goods_not_arrived, DealStatus.awaiting_condition_check):
                assert await inventory.lock_for_deal_move(db, deal, target) is None
            assert (await inventory.lock_for_deal_move(db, deal, DealStatus.released)) is not None


class TestTheRuleAndTheCountAgree:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("payments", ["on", "off"])
    async def test_holds_units_is_the_counts_own_rule(self, request, payments):
        # lock_for_deal_move decides from stock.holds_units whether a move
        # changes the count; the count is stock._holding_deal() in SQL. A
        # status the two read differently would move units without the lock.
        if payments == "off":
            request.getfixturevalue("payments_off")
        seller_id, buyer_id = await _people()
        for status in DealStatus:
            lid = await _listing(seller_id, quantity=5)
            await _deal(lid, seller_id, buyer_id, status)
            async with AsyncSessionLocal() as db:
                held, sold = await stock.units_taken(db, lid)
            assert held == (1 if stock.holds_units(status) else 0), status
            assert sold == (1 if status == DealStatus.released else 0), status
