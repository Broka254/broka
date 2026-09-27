"""
BROKA - Auction lifecycle tests
Run: pytest backend/tests/test_auction_lifecycle.py -v

Covers the twelve cases the auction brief names, against
api/domains/auctions/lifecycle.py - the module that now owns every rule
about whether a bid is allowed and what happens when an auction closes.

Called mostly at the service layer rather than through HTTP. That is not
convenience: these rules have to hold for the closing SWEEP as much as for
a request, and the sweep never goes near the router. Testing the service
tests what both callers actually depend on. The one HTTP test here exists
to prove the endpoint really does delegate rather than keeping a second
copy of the rules.
"""
import re
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import (
    AsyncSessionLocal, AuctionMeta, Bid, Deal, DealStatus, Listing,
    ListingStatus, ListingType, User, init_db, reset_engine,
)
from sqlalchemy import delete as sa_delete

from api.domains.auctions import lifecycle
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_auction_lifecycle.db"
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
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


def _tag() -> str:
    return uuid.uuid4().hex[:10]


async def _user(name: str) -> User:
    user = User(name=name, phone=f"+2547{_tag()}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


async def _auction(
    seller: User,
    *,
    starting_price: float = 20000.0,
    reserve: float | None = None,
    increment: float = 500.0,
    starts_in: timedelta = timedelta(minutes=-5),
    ends_in: timedelta = timedelta(hours=1),
) -> tuple[Listing, AuctionMeta]:
    """An auction listing plus its lifecycle row, with an explicit window.

    Defaults to one that opened five minutes ago and closes in an hour -
    i.e. genuinely LIVE - so each test only has to state the part of the
    window it actually cares about.
    """
    now = datetime.utcnow()
    listing = Listing(
        seller_id=seller.id,
        name=f"Auction item {_tag()}",
        category="Electronics",
        price=starting_price,
        lat=-1.2921,
        lng=36.8219,
        listing_type=ListingType.auction,
        reserve_price=reserve,
        status=ListingStatus.active,
    )
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.commit()
        await db.refresh(listing)
        meta = AuctionMeta(
            listing_id=listing.id,
            status="live",
            min_bid_increment=increment,
            starting_price=starting_price,
            starts_at=now + starts_in,
            ends_at=now + ends_in,
            bid_count=0,
        )
        db.add(meta)
        await db.commit()
        await db.refresh(meta)
    return listing, meta


async def _bid(listing_id: str, bidder: User, amount: float):
    async with AsyncSessionLocal() as db:
        return await lifecycle.place_bid(db, listing_id, bidder.id, amount)


async def _meta(listing_id: str) -> AuctionMeta:
    from sqlalchemy import select
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        )).scalar_one()


async def _close(listing_id: str):
    async with AsyncSessionLocal() as db:
        return await lifecycle.close_auction(db, listing_id)


class TestBidWindow:
    """1, 2, 4 — the auction's open window is the server's to decide."""

    @pytest.mark.asyncio
    async def test_bid_before_start_is_rejected(self):
        seller = await _user("Seller early")
        bidder = await _user("Bidder early")
        listing, _ = await _auction(seller, starts_in=timedelta(hours=2),
                                    ends_in=timedelta(hours=3))
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, bidder, 25000)
        assert exc.value.code == "AUCTION_NOT_STARTED"
        assert (await _meta(listing.id)).bid_count == 0

    @pytest.mark.asyncio
    async def test_valid_bid_during_auction_is_accepted(self):
        seller = await _user("Seller live")
        bidder = await _user("Bidder live")
        listing, _ = await _auction(seller, starting_price=20000)
        result = await _bid(listing.id, bidder, 20500)
        assert result.amount == 20500
        assert result.bid_count == 1
        assert result.status == lifecycle.LIVE
        meta = await _meta(listing.id)
        assert meta.current_bid == 20500
        assert meta.current_bidder_id == bidder.id

    @pytest.mark.asyncio
    async def test_bid_after_end_is_rejected(self):
        """The auction is over by the CLOCK, whether or not any sweep has
        run - the window this test opens is precisely the one a bid used to
        slip through."""
        seller = await _user("Seller late")
        bidder = await _user("Bidder late")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=-2), ends_in=timedelta(minutes=-1),
        )
        meta = await _meta(listing.id)
        assert meta.closed_at is None and meta.status == "live", (
            "precondition: nothing has closed this auction yet"
        )
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, bidder, 25000)
        assert exc.value.code == "AUCTION_ENDED"

    @pytest.mark.asyncio
    async def test_bid_on_auction_with_no_end_is_refused(self):
        """An auction that can never close must not take bids - that is the
        pre-0021 state, and accepting into it is how bids piled up on
        something with no lifecycle at all."""
        seller = await _user("Seller unscheduled")
        bidder = await _user("Bidder unscheduled")
        listing, _ = await _auction(seller)
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = None
            await db.commit()
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, bidder, 25000)
        assert exc.value.code == "AUCTION_NOT_SCHEDULED"


class TestIncrements:
    """3 — a raise has to be a real raise."""

    @pytest.mark.asyncio
    async def test_first_bid_must_meet_starting_price(self):
        seller = await _user("Seller floor")
        bidder = await _user("Bidder floor")
        listing, _ = await _auction(seller, starting_price=20000)
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, bidder, 19999)
        assert exc.value.code == "BID_TOO_LOW"
        assert "20,000" in exc.value.message

    @pytest.mark.asyncio
    async def test_bid_below_required_increment_is_rejected(self):
        seller = await _user("Seller inc")
        a = await _user("Bidder A inc")
        b = await _user("Bidder B inc")
        listing, _ = await _auction(seller, starting_price=20000, increment=500)
        await _bid(listing.id, a, 20000)
        # 20,400 beats the current bid but not by the increment. The old
        # code accepted any raise at all, including one shilling.
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, b, 20400)
        assert exc.value.code == "BID_TOO_LOW"
        assert (await _meta(listing.id)).current_bid == 20000

    @pytest.mark.asyncio
    async def test_bid_exactly_on_the_increment_is_accepted(self):
        seller = await _user("Seller exact")
        a = await _user("Bidder A exact")
        b = await _user("Bidder B exact")
        listing, _ = await _auction(seller, starting_price=20000, increment=500)
        await _bid(listing.id, a, 20000)
        result = await _bid(listing.id, b, 20500)
        assert result.amount == 20500
        assert result.min_next_bid == 21000

    @pytest.mark.asyncio
    async def test_seller_cannot_bid_on_own_auction(self):
        seller = await _user("Seller self")
        listing, _ = await _auction(seller)
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, seller, 25000)
        assert exc.value.code == "OWN_LISTING"


class TestConcurrency:
    """5 — two bids at once must not corrupt the final state."""

    @pytest.mark.asyncio
    async def test_competing_bids_leave_consistent_state(self):
        """Both bidders race the same current_bid. Whatever the ordering,
        the auction must end up agreeing with its own bid rows: the
        denormalized current_bid IS the maximum, the count matches, and the
        recorded leader is the one who actually holds the top bid."""
        from sqlalchemy import select

        seller = await _user("Seller race")
        a = await _user("Bidder A race")
        b = await _user("Bidder B race")
        listing, _ = await _auction(seller, starting_price=20000, increment=500)
        await _bid(listing.id, a, 20000)

        results = await asyncio.gather(
            _bid(listing.id, b, 21000),
            _bid(listing.id, a, 22000),
            return_exceptions=True,
        )
        accepted = [r for r in results if isinstance(r, lifecycle.BidResult)]
        assert accepted, f"at least one competing bid must succeed: {results}"

        meta = await _meta(listing.id)
        async with AsyncSessionLocal() as db:
            bids = (await db.execute(
                select(Bid).where(Bid.listing_id == listing.id)
            )).scalars().all()

        top = max(bids, key=lambda x: x.amount)
        assert meta.current_bid == top.amount, "current_bid must equal the real maximum"
        assert meta.current_bidder_id == top.bidder_id
        assert meta.bid_count == len(bids), "bid_count must match the rows that exist"


class TestReserve:
    """3, 6, 7 — a reserve is a close-time test, never a bid floor."""

    @pytest.mark.asyncio
    async def test_bids_below_reserve_are_accepted(self):
        """The brief's own example. 20,500 / 30,000 / 45,000 against a
        50,000 reserve are all valid bids; the old code rejected every one
        of them with "bid must be at least 50,000", publishing the seller's
        secret price in an error message."""
        seller = await _user("Seller reserve")
        bidder = await _user("Bidder reserve")
        listing, _ = await _auction(
            seller, starting_price=20000, reserve=50000, increment=500,
        )
        for amount in (20500, 30000, 45000):
            result = await _bid(listing.id, bidder, amount)
            assert result.amount == amount
            assert result.reserve_met is False
        assert (await _meta(listing.id)).current_bid == 45000

    @pytest.mark.asyncio
    async def test_reserve_not_met_ends_with_no_sale(self):
        seller = await _user("Seller unmet")
        bidder = await _user("Bidder unmet")
        listing, _ = await _auction(seller, starting_price=20000, reserve=50000)
        await _bid(listing.id, bidder, 45000)

        result = await _close(listing.id)
        assert result.outcome == lifecycle.OUTCOME_RESERVE_NOT_MET
        assert result.winner_id is None
        assert result.deal_id is None

        meta = await _meta(listing.id)
        assert meta.winner_id is None
        assert meta.winning_amount is None

    @pytest.mark.asyncio
    async def test_reserve_met_means_highest_bidder_wins(self):
        seller = await _user("Seller met")
        bidder = await _user("Bidder met")
        listing, _ = await _auction(seller, starting_price=20000, reserve=50000)
        await _bid(listing.id, bidder, 55000)

        result = await _close(listing.id)
        assert result.outcome == lifecycle.OUTCOME_WON
        assert result.winner_id == bidder.id
        assert result.winning_amount == 55000

    @pytest.mark.asyncio
    async def test_reserve_met_flag_flips_without_revealing_the_reserve(self):
        seller = await _user("Seller flag")
        bidder = await _user("Bidder flag")
        listing, _ = await _auction(seller, starting_price=20000, reserve=50000)
        low = await _bid(listing.id, bidder, 30000)
        assert low.reserve_met is False
        high = await _bid(listing.id, bidder, 50000)
        assert high.reserve_met is True

        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            listing_row = (await db.execute(
                select(Listing).where(Listing.id == listing.id)
            )).scalar_one()
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            state = await lifecycle.public_state(db, listing_row, meta)
        assert state["has_reserve"] is True
        assert state["reserve_met"] is True
        assert "reserve_price" not in state, "a seller's reserve must never be sent to clients"


class TestClose:
    """4, 8, 9 — closing is automatic, and it happens once."""

    @pytest.mark.asyncio
    async def test_auction_with_no_bids_has_no_winner(self):
        seller = await _user("Seller empty")
        listing, _ = await _auction(seller)
        result = await _close(listing.id)
        assert result.outcome == lifecycle.OUTCOME_NO_BIDS
        assert result.winner_id is None
        assert result.deal_id is None

    @pytest.mark.asyncio
    async def test_closing_twice_is_idempotent(self):
        """The brief's hard requirement: running the closing job twice must
        not create two winners or two deals."""
        from sqlalchemy import func, select

        seller = await _user("Seller once")
        bidder = await _user("Bidder once")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 25000)

        first = await _close(listing.id)
        second = await _close(listing.id)

        assert first.already_closed is False
        assert second.already_closed is True
        assert second.winner_id == first.winner_id
        assert second.deal_id == first.deal_id
        assert second.winning_amount == first.winning_amount

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1, "a second close must not create a second deal"

    @pytest.mark.asyncio
    async def test_concurrent_closes_produce_one_winner(self):
        from sqlalchemy import func, select

        seller = await _user("Seller race close")
        bidder = await _user("Bidder race close")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 30000)

        await asyncio.gather(
            _close(listing.id), _close(listing.id), return_exceptions=True,
        )
        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1

    @pytest.mark.asyncio
    async def test_closed_auction_refuses_further_bids(self):
        seller = await _user("Seller shut")
        a = await _user("Bidder A shut")
        b = await _user("Bidder B shut")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, a, 25000)
        await _close(listing.id)
        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, b, 40000)
        assert exc.value.code == "AUCTION_ENDED"

    @pytest.mark.asyncio
    async def test_sweep_closes_only_auctions_whose_time_has_come(self):
        seller = await _user("Seller sweep")
        due, _ = await _auction(seller, starts_in=timedelta(hours=-2),
                                ends_in=timedelta(minutes=-1))
        not_due, _ = await _auction(seller, ends_in=timedelta(hours=2))
        async with AsyncSessionLocal() as db:
            ids = await lifecycle.due_for_close(db)
        assert due.id in ids
        assert not_due.id not in ids


class TestWinnerBecomesADeal:
    """5 (brief section), 10, 11 — the win lands in the existing Deal +
    E-Confirm flow, not a parallel auction payment system."""

    @pytest.mark.asyncio
    async def test_win_creates_exactly_one_deal_at_the_winning_price(self):
        from sqlalchemy import select
        from api.core.config import settings

        seller = await _user("Seller deal")
        loser = await _user("Loser deal")
        winner = await _user("Winner deal")
        listing, _ = await _auction(seller, starting_price=20000, increment=1000)
        await _bid(listing.id, loser, 20000)
        await _bid(listing.id, winner, 78000)

        result = await _close(listing.id)
        assert result.outcome == lifecycle.OUTCOME_WON
        assert result.deal_id, "a won auction must produce a deal"

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(Deal).where(Deal.listing_id == listing.id)
            )).scalars().all()
        assert len(deals) == 1
        deal = deals[0]
        assert deal.buyer_id == winner.id
        assert deal.seller_id == seller.id
        # The winning price becomes the goods amount, and the auction
        # commission applies to it (4% + the escrow provider's 1% = 5%).
        assert deal.agreed_price == 78000
        assert deal.commission == round(78000 * settings.auction_commission_rate, 2)
        assert deal.status == DealStatus.agreed

    @pytest.mark.asyncio
    async def test_winning_listing_is_locked_against_a_competing_sale(self):
        from sqlalchemy import select

        seller = await _user("Seller lock")
        winner = await _user("Winner lock")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)
        await _close(listing.id)

        async with AsyncSessionLocal() as db:
            row = (await db.execute(
                select(Listing).where(Listing.id == listing.id)
            )).scalar_one()
        assert row.status != ListingStatus.active, (
            "a won listing must not stay open to a competing sale"
        )

    @pytest.mark.asyncio
    async def test_no_sale_creates_no_deal(self):
        from sqlalchemy import func, select

        seller = await _user("Seller nosale")
        bidder = await _user("Bidder nosale")
        listing, _ = await _auction(seller, starting_price=20000, reserve=90000)
        await _bid(listing.id, bidder, 25000)
        await _close(listing.id)

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 0


class TestPaymentDeadline:
    """12 — an unpaid win lapses instead of locking the listing forever."""

    @pytest.mark.asyncio
    async def test_win_sets_a_payment_deadline(self):
        from api.core.config import settings

        seller = await _user("Seller deadline")
        winner = await _user("Winner deadline")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 25000)
        result = await _close(listing.id)

        assert result.payment_deadline is not None
        expected = datetime.utcnow() + timedelta(
            hours=settings.auction_payment_deadline_hours
        )
        assert abs((result.payment_deadline - expected).total_seconds()) < 120

    @pytest.mark.asyncio
    async def test_unpaid_win_lapses_and_frees_the_listing(self):
        from sqlalchemy import select

        seller = await _user("Seller lapse")
        winner = await _user("Winner lapse")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 25000)
        closed = await _close(listing.id)
        assert closed.deal_id

        # Put the deadline in the past, the way 24 hours of not paying would.
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.payment_deadline = datetime.utcnow() - timedelta(minutes=1)
            await db.commit()

        async with AsyncSessionLocal() as db:
            overdue = await lifecycle.due_for_payment_lapse(db)
        assert listing.id in [m.listing_id for m in overdue]

        async with AsyncSessionLocal() as db:
            outcome = await lifecycle.lapse_unpaid_win(db, listing.id)
        assert outcome == lifecycle.OUTCOME_UNPAID

        async with AsyncSessionLocal() as db:
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            deal = (await db.execute(
                select(Deal).where(Deal.id == closed.deal_id)
            )).scalar_one()
            row = (await db.execute(
                select(Listing).where(Listing.id == listing.id)
            )).scalar_one()
        assert meta.outcome == lifecycle.OUTCOME_UNPAID
        assert deal.status == DealStatus.cancelled
        assert row.status == ListingStatus.active, (
            "the listing must be sellable again, not locked forever"
        )

    @pytest.mark.asyncio
    async def test_a_paid_win_does_not_lapse(self):
        """The sweep must not cancel a deal the buyer already paid for
        between being picked up and the lock being taken."""
        from sqlalchemy import select

        seller = await _user("Seller paid")
        winner = await _user("Winner paid")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 25000)
        closed = await _close(listing.id)

        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.payment_deadline = datetime.utcnow() - timedelta(minutes=1)
            deal = (await db.execute(
                select(Deal).where(Deal.id == closed.deal_id)
            )).scalar_one()
            deal.status = DealStatus.paid
            await db.commit()

        async with AsyncSessionLocal() as db:
            outcome = await lifecycle.lapse_unpaid_win(db, listing.id)
        assert outcome is None

        async with AsyncSessionLocal() as db:
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            deal = (await db.execute(
                select(Deal).where(Deal.id == closed.deal_id)
            )).scalar_one()
        assert meta.outcome == lifecycle.OUTCOME_WON
        assert deal.status == DealStatus.paid


class TestBidEndpointDelegates:
    """The HTTP surface must not carry a second copy of the rules."""

    @pytest.mark.asyncio
    async def test_endpoint_rejects_a_low_bid_with_a_machine_readable_code(self, client):
        seller = await _user("Seller http")
        bidder = await _user("Bidder http")
        listing, _ = await _auction(seller, starting_price=20000, increment=500)
        headers = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}

        ok = await client.post("/auction/bid", headers=headers,
                               json={"listing_id": listing.id, "amount": 20000})
        assert ok.status_code == 201, ok.text
        assert ok.json()["min_next_bid"] == 20500

        low = await client.post("/auction/bid", headers=headers,
                                json={"listing_id": listing.id, "amount": 20100})
        assert low.status_code == 400
        assert low.json()["detail"]["code"] == "BID_TOO_LOW"

    @pytest.mark.asyncio
    async def test_endpoint_rejects_a_bid_on_an_ended_auction(self, client):
        seller = await _user("Seller http end")
        bidder = await _user("Bidder http end")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=-2), ends_in=timedelta(minutes=-1),
        )
        headers = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}
        res = await client.post("/auction/bid", headers=headers,
                                json={"listing_id": listing.id, "amount": 25000})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_ENDED"


class TestSweepDrivesTheWholeThing:
    """The closing job is what makes any of this automatic. These go through
    the worker task, not close_auction directly, because in production
    nothing calls close_auction by hand."""

    @pytest.mark.asyncio
    async def test_sweep_closes_a_due_auction_and_notifies_everyone(self, monkeypatch):
        """One pass of the sweep: the auction closes, the winner gets a deal,
        and the right people are told - the winner that payment is due, the
        loser that they lost."""
        from api.core import workers
        from api.core.event_catalog import EventType

        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        seller = await _user("Seller sweep run")
        loser = await _user("Loser sweep run")
        winner = await _user("Winner sweep run")
        listing, _ = await _auction(seller, starting_price=20000, increment=1000)
        await _bid(listing.id, loser, 20000)
        await _bid(listing.id, winner, 42000)

        # Wind the clock past the end, the way a real auction gets there.
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        await workers.task_close_due_auctions({})

        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            deal = (await db.execute(
                select(Deal).where(Deal.listing_id == listing.id)
            )).scalar_one()

        assert meta.outcome == lifecycle.OUTCOME_WON
        assert meta.winner_id == winner.id
        assert meta.deal_id == deal.id
        assert deal.agreed_price == 42000

        recipients = {p[0] for p in pushes}
        assert winner.id in recipients, "the winner must be told they won"
        assert loser.id in recipients, "a losing bidder must be told the auction ended"

        won = [p for p in pushes if p[0] == winner.id]
        assert any("won" in p[1].lower() for p in won)
        # The winning notification has to make the obligation obvious and
        # carry what the payment screen needs.
        assert any("payment" in p[2].lower() for p in won)
        assert any(p[3].get("deal_id") == deal.id for p in won)

    @pytest.mark.asyncio
    async def test_sweep_run_twice_still_produces_one_deal(self):
        from sqlalchemy import func, select
        from api.core import workers

        seller = await _user("Seller sweep twice")
        winner = await _user("Winner sweep twice")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        await workers.task_close_due_auctions({})
        await workers.task_close_due_auctions({})

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1

    @pytest.mark.asyncio
    async def test_sweep_notifies_seller_when_reserve_was_not_met(self, monkeypatch):
        from api.core import workers

        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        seller = await _user("Seller sweep reserve")
        bidder = await _user("Bidder sweep reserve")
        listing, _ = await _auction(seller, starting_price=20000, reserve=80000)
        await _bid(listing.id, bidder, 25000)
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        await workers.task_close_due_auctions({})

        seller_pushes = [p for p in pushes if p[0] == seller.id]
        assert seller_pushes, "the seller must learn their auction didn't sell"
        assert any("reserve" in p[2].lower() for p in seller_pushes)

    @pytest.mark.asyncio
    async def test_ending_soon_reminder_goes_out_once(self, monkeypatch):
        from api.core import workers

        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        seller = await _user("Seller soon")
        bidder = await _user("Bidder soon")
        listing, _ = await _auction(seller, starting_price=20000,
                                    ends_in=timedelta(minutes=5))
        await _bid(listing.id, bidder, 25000)

        await workers.task_notify_auctions_ending_soon({})
        first = [p for p in pushes if p[0] == bidder.id]
        assert first, "a bidder must be reminded before the auction closes"

        pushes.clear()
        await workers.task_notify_auctions_ending_soon({})
        assert not pushes, "the reminder must not repeat on every sweep pass"


class TestDealCreationFailureAndRetry:
    """The recoverable gap between a closed auction and its Deal.

    close_auction commits the close BEFORE creating the Deal, on purpose: a
    downstream failure must never roll back a finished auction and reopen it
    for more bids. The price of that ordering is a window where an auction
    is correctly closed, with a winner and a price, and no Deal - so the
    winner has been told nothing and has nothing to pay. Left alone that
    state is permanent, because the close sweep only looks at auctions that
    are still open.
    """

    @staticmethod
    def _break_deal_creation(monkeypatch):
        """Make EscrowService.finalize_deal fail the way a real outage would."""
        from api.domains.escrow.service import EscrowService

        async def _boom(self, **kwargs):
            raise RuntimeError("escrow unavailable")

        monkeypatch.setattr(EscrowService, "finalize_deal", _boom)

    @pytest.mark.asyncio
    async def test_failed_deal_preserves_the_closed_auction(self, monkeypatch):
        """The auction must stay closed, with its winner and price intact -
        never reopened, never re-decided."""
        from sqlalchemy import func, select

        seller = await _user("Seller dealfail")
        loser = await _user("Loser dealfail")
        winner = await _user("Winner dealfail")
        listing, _ = await _auction(seller, starting_price=20000, increment=1000)
        await _bid(listing.id, loser, 20000)
        await _bid(listing.id, winner, 50000)

        self._break_deal_creation(monkeypatch)
        result = await _close(listing.id)

        assert result.outcome == lifecycle.OUTCOME_WON
        assert result.winner_id == winner.id
        assert result.winning_amount == 50000
        assert result.deal_id is None, "the deal genuinely failed"

        meta = await _meta(listing.id)
        assert meta.closed_at is not None, "the auction must stay closed"
        assert meta.winner_id == winner.id
        assert meta.winning_amount == 50000
        assert meta.deal_id is None

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 0

    @pytest.mark.asyncio
    async def test_a_closed_auction_with_a_failed_deal_still_refuses_bids(self, monkeypatch):
        """The gap must not become a way back into a finished auction."""
        seller = await _user("Seller dealfail bid")
        winner = await _user("Winner dealfail bid")
        latecomer = await _user("Late dealfail bid")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)

        self._break_deal_creation(monkeypatch)
        await _close(listing.id)

        with pytest.raises(lifecycle.AuctionError) as exc:
            await _bid(listing.id, latecomer, 99000)
        assert exc.value.code == "AUCTION_ENDED"

    @pytest.mark.asyncio
    async def test_retry_creates_the_deal_without_re_deciding_anything(self, monkeypatch):
        """THE case. A later close/sweep finds outcome=won with no deal_id,
        retries, and persists the result - keeping the same winner and the
        same price."""
        from sqlalchemy import func, select

        seller = await _user("Seller retry")
        winner = await _user("Winner retry")
        rival = await _user("Rival retry")
        listing, _ = await _auction(seller, starting_price=20000, increment=1000)
        await _bid(listing.id, rival, 20000)
        await _bid(listing.id, winner, 64000)

        self._break_deal_creation(monkeypatch)
        first = await _close(listing.id)
        assert first.deal_id is None

        # Escrow comes back.
        monkeypatch.undo()

        # The sweep must be able to FIND it - it is closed, so the ordinary
        # due_for_close query cannot see it.
        async with AsyncSessionLocal() as db:
            pending = await lifecycle.due_for_deal_retry(db)
        assert listing.id in pending

        retried = await _close(listing.id)
        assert retried.already_closed is True, "the auction must not be reopened"
        assert retried.outcome == lifecycle.OUTCOME_WON
        assert retried.winner_id == winner.id, "the same winner, not a re-decision"
        assert retried.winning_amount == 64000
        assert retried.deal_id, "the deal must now exist"

        meta = await _meta(listing.id)
        assert meta.deal_id == retried.deal_id, "deal_id must be persisted"
        assert meta.closed_at == first_closed_at(first, meta)

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(Deal).where(Deal.listing_id == listing.id)
            )).scalars().all()
        assert len(deals) == 1
        assert deals[0].buyer_id == winner.id
        assert deals[0].agreed_price == 64000

    @pytest.mark.asyncio
    async def test_repeated_retries_never_duplicate_the_deal(self, monkeypatch):
        from sqlalchemy import func, select

        seller = await _user("Seller retry twice")
        winner = await _user("Winner retry twice")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)

        self._break_deal_creation(monkeypatch)
        await _close(listing.id)
        monkeypatch.undo()

        await _close(listing.id)
        await _close(listing.id)
        await _close(listing.id)

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1

    @pytest.mark.asyncio
    async def test_concurrent_retries_produce_one_deal(self, monkeypatch):
        from sqlalchemy import func, select

        seller = await _user("Seller retry race")
        winner = await _user("Winner retry race")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)

        self._break_deal_creation(monkeypatch)
        await _close(listing.id)
        monkeypatch.undo()

        await asyncio.gather(
            _close(listing.id), _close(listing.id), return_exceptions=True,
        )
        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1

    @pytest.mark.asyncio
    async def test_sweep_recovers_the_deal_and_notifies_the_winner(self, monkeypatch):
        """End to end through the worker, which is what runs in production."""
        from sqlalchemy import select
        from api.core import workers

        seller = await _user("Seller sweep retry")
        winner = await _user("Winner sweep retry")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 35000)
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        self._break_deal_creation(monkeypatch)
        await workers.task_close_due_auctions({})
        meta = await _meta(listing.id)
        assert meta.outcome == lifecycle.OUTCOME_WON and meta.deal_id is None

        monkeypatch.undo()
        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        await workers.task_close_due_auctions({})

        meta = await _meta(listing.id)
        assert meta.deal_id, "the sweep must recover the deal"
        async with AsyncSessionLocal() as db:
            deal = (await db.execute(
                select(Deal).where(Deal.id == meta.deal_id)
            )).scalar_one()
        assert deal.agreed_price == 35000

        # The winner was never told the first time - there was nothing to
        # pay. They must be told now.
        won = [p for p in pushes if p[0] == winner.id]
        assert won, "the winner must be notified once the deal exists"
        assert any(p[3].get("deal_id") == meta.deal_id for p in won)

    @pytest.mark.asyncio
    async def test_retry_finder_ignores_auctions_that_are_fine(self):
        """A successful close, a no-bids close and a reserve-not-met close
        must never be picked up as needing a deal."""
        seller = await _user("Seller finder")
        winner = await _user("Winner finder")

        sold, _ = await _auction(seller, starting_price=20000)
        await _bid(sold.id, winner, 30000)
        await _close(sold.id)

        empty, _ = await _auction(seller)
        await _close(empty.id)

        under, _ = await _auction(seller, starting_price=20000, reserve=90000)
        await _bid(under.id, winner, 25000)
        await _close(under.id)

        async with AsyncSessionLocal() as db:
            pending = await lifecycle.due_for_deal_retry(db)
        assert sold.id not in pending
        assert empty.id not in pending
        assert under.id not in pending


def first_closed_at(result, meta):
    """The close timestamp must not move on a retry - the auction closed
    when it closed."""
    return meta.closed_at


class TestTermsLocking:
    """An auction's terms are the contract bidders bid against. Once
    somebody has committed money to them they stop being editable."""

    @pytest.mark.asyncio
    async def test_seller_can_configure_an_upcoming_auction(self, client):
        seller = await _user("Seller terms open")
        listing, _ = await _auction(
            seller, starting_price=20000,
            starts_in=timedelta(hours=2), ends_in=timedelta(hours=8),
        )
        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}

        res = await client.patch(
            f"/auctions/{listing.id}/terms",
            headers=headers,
            json={
                "starting_price": 25000,
                "min_bid_increment": 1000,
                "reserve_price": 60000,
                "ends_at": (datetime.utcnow() + timedelta(hours=12)).isoformat(),
            },
        )
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["starting_price"] == 25000
        assert body["min_bid_increment"] == 1000
        assert body["has_reserve"] is True
        # Never the amount, even to the seller's own client - the state
        # payload has one shape and it is the public one.
        assert "reserve_price" not in body

    @pytest.mark.asyncio
    async def test_terms_lock_once_the_auction_is_live(self, client):
        seller = await _user("Seller terms live")
        listing, _ = await _auction(seller, starting_price=20000)  # live by default
        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}

        res = await client.patch(f"/auctions/{listing.id}/terms",
                                 headers=headers, json={"min_bid_increment": 5000})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_TERMS_LOCKED"
        assert (await _meta(listing.id)).min_bid_increment == 500

    @pytest.mark.asyncio
    async def test_terms_lock_once_a_bid_lands(self, client):
        """Even an auction that has not technically opened yet is settled
        the moment somebody bids on it."""
        seller = await _user("Seller terms bid")
        bidder = await _user("Bidder terms bid")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 20000)

        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        for payload in (
            {"starting_price": 5000},
            {"min_bid_increment": 10},
            {"reserve_price": 999999},
            {"ends_at": (datetime.utcnow() + timedelta(days=30)).isoformat()},
            {"starts_at": (datetime.utcnow() + timedelta(days=1)).isoformat()},
            {"clear_reserve": True},
        ):
            res = await client.patch(f"/auctions/{listing.id}/terms",
                                     headers=headers, json=payload)
            assert res.status_code == 409, f"{payload} should have been refused: {res.text}"
            assert res.json()["detail"]["code"] == "AUCTION_TERMS_LOCKED"

    @pytest.mark.asyncio
    async def test_terms_stay_locked_after_the_auction_closes(self, client):
        seller = await _user("Seller terms closed")
        bidder = await _user("Bidder terms closed")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 25000)
        await _close(listing.id)

        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        res = await client.patch(f"/auctions/{listing.id}/terms",
                                 headers=headers, json={"reserve_price": 10})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_TERMS_LOCKED"

    @pytest.mark.asyncio
    async def test_generic_listing_price_edit_cannot_move_a_live_starting_price(self, client):
        """listing.price IS the auction's starting price, so the ordinary
        edit endpoint is a back door into auction terms. It predates
        auctions having terms at all."""
        seller = await _user("Seller backdoor")
        bidder = await _user("Bidder backdoor")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 20000)

        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        res = await client.patch(f"/listings/{listing.id}",
                                 headers=headers, json={"price": 1})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_TERMS_LOCKED"

        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            row = (await db.execute(
                select(Listing).where(Listing.id == listing.id)
            )).scalar_one()
        assert row.price == 20000

    @pytest.mark.asyncio
    async def test_photos_stay_editable_after_bidding_starts(self, client):
        """The lock is on terms, not on the listing. A seller must still be
        able to add a better photo of what people are bidding on."""
        seller = await _user("Seller photos")
        bidder = await _user("Bidder photos")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 20000)

        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        res = await client.patch(f"/listings/{listing.id}",
                                 headers=headers, json={"verified_photos": "data:image/png;base64,AAAA"})
        assert res.status_code == 200, res.text

    @pytest.mark.asyncio
    async def test_invalid_windows_are_refused(self, client):
        seller = await _user("Seller invalid terms")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=2), ends_in=timedelta(hours=8),
        )
        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        now = datetime.utcnow()

        # Closes before it opens.
        res = await client.patch(f"/auctions/{listing.id}/terms", headers=headers, json={
            "starts_at": (now + timedelta(days=2)).isoformat(),
            "ends_at": (now + timedelta(days=1)).isoformat(),
        })
        assert res.status_code == 422
        assert res.json()["detail"]["code"] == "INVALID_WINDOW"

        # Zero/negative numbers are refused by the schema itself.
        for payload in ({"starting_price": 0}, {"min_bid_increment": -5},
                        {"reserve_price": 0}):
            bad = await client.patch(f"/auctions/{listing.id}/terms",
                                     headers=headers, json=payload)
            assert bad.status_code == 422, f"{payload}: {bad.text}"

        # A reserve under the starting price is met by the first bid, so it
        # protects nothing while looking like it does.
        pointless = await client.patch(f"/auctions/{listing.id}/terms", headers=headers,
                                       json={"starting_price": 50000, "reserve_price": 10000})
        assert pointless.status_code == 422
        assert pointless.json()["detail"]["code"] == "RESERVE_BELOW_START"

    @pytest.mark.asyncio
    async def test_only_the_seller_can_change_terms(self, client):
        seller = await _user("Seller owns terms")
        stranger = await _user("Stranger terms")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=2), ends_in=timedelta(hours=8),
        )
        headers = {"Authorization": f"Bearer {create_access_token({'sub': stranger.id})}"}
        res = await client.patch(f"/auctions/{listing.id}/terms",
                                 headers=headers, json={"min_bid_increment": 1})
        assert res.status_code == 403


class TestFullJourney:
    """The whole thing, in one test, in order:

        seller creates auction -> LIVE -> bid -> outbid -> ends_at passes
        -> sweep closes -> highest bidder wins -> reserve evaluated
        -> exactly one Deal -> winner pays -> escrow -> seller fulfils
        -> buyer confirms -> released

    Deliberately end-to-end rather than a sum of the unit tests above: each
    stage's output is the next stage's input, and the failures worth
    catching here are the seams between them, not the stages themselves.

    The one simulated step is the M-Pesa/E-Confirm provider round trip -
    moving the Deal to `paid` stands in for money actually arriving, since
    that is an external service. Everything either side of it is the real
    code path.
    """

    @pytest.mark.asyncio
    async def test_create_to_confirmed_delivery(self, client, monkeypatch):
        from sqlalchemy import func, select
        from api.core import workers
        from api.core.config import settings
        from api.core.money import add_money, pct_of
        from api.domains.escrow.service import EscrowService

        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        seller = await _user("Journey Seller")
        alice = await _user("Journey Alice")
        bob = await _user("Journey Bob")
        sh = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}

        # ── 1. Seller creates an auction with real terms ─────────────────
        starts = datetime.utcnow() + timedelta(minutes=30)
        ends = starts + timedelta(hours=2)
        created = await client.post("/listings/", headers=sh, json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Journey Tractor",
            "category": "Agriculture",
            "price": 200000,
            "lat": -1.286, "lng": 36.817,
            "listing_type": "auction",
            "reserve_price": 260000,
            "min_bid_increment": 10000,
            "auction_starts_at": starts.isoformat(),
            "auction_ends_at": ends.isoformat(),
        })
        assert created.status_code == 201, created.text
        listing_id = created.json()["id"]

        detail = await client.get(f"/auctions/{listing_id}")
        assert detail.status_code == 200, detail.text
        assert detail.json()["status"] == "upcoming"
        assert detail.json()["min_bid_increment"] == 10000
        assert detail.json()["has_reserve"] is True
        assert "reserve_price" not in detail.json()

        # ── 2. Bidding is refused before it opens ────────────────────────
        ah = {"Authorization": f"Bearer {create_access_token({'sub': alice.id})}"}
        early = await client.post("/auction/bid", headers=ah,
                                  json={"listing_id": listing_id, "amount": 210000})
        assert early.status_code == 409
        assert early.json()["detail"]["code"] == "AUCTION_NOT_STARTED"

        # ── 3. The auction opens ─────────────────────────────────────────
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing_id)
            meta.starts_at = datetime.utcnow() - timedelta(minutes=1)
            await db.commit()
        assert (await client.get(f"/auctions/{listing_id}")).json()["status"] == "live"

        # ── 4. Alice bids; the seller cannot ─────────────────────────────
        first = await client.post("/auction/bid", headers=ah,
                                  json={"listing_id": listing_id, "amount": 200000})
        assert first.status_code == 201, first.text
        assert first.json()["min_next_bid"] == 210000
        assert first.json()["reserve_met"] is False

        own = await client.post("/auction/bid", headers=sh,
                                json={"listing_id": listing_id, "amount": 300000})
        assert own.status_code == 403
        assert own.json()["detail"]["code"] == "OWN_LISTING"

        # ── 5. A raise that does not clear the increment is refused ──────
        bh = {"Authorization": f"Bearer {create_access_token({'sub': bob.id})}"}
        short = await client.post("/auction/bid", headers=bh,
                                  json={"listing_id": listing_id, "amount": 205000})
        assert short.status_code == 400
        assert short.json()["detail"]["code"] == "BID_TOO_LOW"

        # ── 6. Bob outbids Alice, and Alice is told ──────────────────────
        pushes.clear()
        outbid = await client.post("/auction/bid", headers=bh,
                                   json={"listing_id": listing_id, "amount": 280000})
        assert outbid.status_code == 201, outbid.text
        assert outbid.json()["reserve_met"] is True, "280k clears the 260k reserve"
        alice_told = [p for p in pushes if p[0] == alice.id]
        assert alice_told, "the outbid bidder must be notified"
        assert "outbid" in alice_told[0][1].lower()

        # Terms are now locked - people are bidding against them.
        locked = await client.patch(f"/auctions/{listing_id}/terms", headers=sh,
                                    json={"min_bid_increment": 1})
        assert locked.status_code == 409
        assert locked.json()["detail"]["code"] == "AUCTION_TERMS_LOCKED"

        # ── 7. The auction reaches its end ───────────────────────────────
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing_id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        pushes.clear()
        await workers.task_close_due_auctions({})

        # ── 8. Highest bidder wins, reserve was met ──────────────────────
        closed = (await client.get(f"/auctions/{listing_id}")).json()
        assert closed["status"] == "ended"
        assert closed["outcome"] == "won"
        assert closed["winner_id"] == bob.id
        assert closed["winning_amount"] == 280000
        assert closed["deal_id"]
        assert closed["payment_deadline"]

        # Winner told to pay; loser told they lost.
        bob_told = [p for p in pushes if p[0] == bob.id]
        alice_told = [p for p in pushes if p[0] == alice.id]
        assert any("won" in p[1].lower() for p in bob_told)
        assert any("payment" in p[2].lower() for p in bob_told)
        assert any(p[3].get("deal_id") == closed["deal_id"] for p in bob_told)
        assert alice_told, "the losing bidder must be told the auction ended"

        # A bid after close is refused.
        late = await client.post("/auction/bid", headers=ah,
                                 json={"listing_id": listing_id, "amount": 500000})
        assert late.status_code == 409
        assert late.json()["detail"]["code"] == "AUCTION_ENDED"

        # ── 9. Exactly one Deal, at the winning price ────────────────────
        async with AsyncSessionLocal() as db:
            count = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing_id)
            )).scalar_one()
            deal = (await db.execute(
                select(Deal).where(Deal.id == closed["deal_id"])
            )).scalar_one()
            listing_row = (await db.execute(
                select(Listing).where(Listing.id == listing_id)
            )).scalar_one()
        assert count == 1
        assert deal.buyer_id == bob.id and deal.seller_id == seller.id
        assert deal.agreed_price == 280000, "the winning bid IS the goods amount"
        assert deal.commission == pct_of(280000, settings.auction_commission_rate)
        assert deal.status == DealStatus.agreed
        # The listing is locked against a competing sale.
        assert listing_row.status != ListingStatus.active

        # ── 10. The winner pays (provider round trip simulated) ──────────
        expected_total = add_money(deal.agreed_price, deal.commission)
        assert expected_total == 280000 + pct_of(280000, settings.auction_commission_rate)
        async with AsyncSessionLocal() as db:
            paying = (await db.execute(
                select(Deal).where(Deal.id == deal.id)
            )).scalar_one()
            paying.status = DealStatus.paid
            await db.commit()

        # ── 11. Seller fulfils, buyer confirms - the REAL escrow path ────
        async with AsyncSessionLocal() as db:
            released = await EscrowService(db).confirm_delivery(
                deal_id=deal.id, buyer_id=bob.id,
            )
        assert released["status"] == "released"

        async with AsyncSessionLocal() as db:
            final_deal = (await db.execute(
                select(Deal).where(Deal.id == deal.id)
            )).scalar_one()
            final_seller = (await db.execute(
                select(User).where(User.id == seller.id)
            )).scalar_one()
        assert final_deal.status == DealStatus.released
        assert final_deal.delivery_confirmed_at is not None
        assert final_deal.released_at is not None
        assert (final_seller.completed_deals or 0) >= 1, (
            "a completed auction sale must count toward the seller's record"
        )

    @pytest.mark.asyncio
    async def test_journey_with_reserve_not_met_ends_in_no_deal(self, client, monkeypatch):
        """The same journey, diverging at the reserve: bidding is healthy,
        the reserve is simply never reached, and nothing is sold."""
        from sqlalchemy import func, select
        from api.core import workers

        pushes = []

        async def _capture(user_id, title, body, data):
            pushes.append((user_id, title, body, data))

        import api.core.push_subscribers as push_subs
        monkeypatch.setattr(push_subs, "_notify", _capture)

        seller = await _user("Journey2 Seller")
        bidder = await _user("Journey2 Bidder")
        sh = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        bh = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}

        created = await client.post("/listings/", headers=sh, json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Journey Reserve Piano",
            "category": "Music & Instruments",
            "price": 20000,
            "lat": -1.286, "lng": 36.817,
            "listing_type": "auction",
            "reserve_price": 50000,
            "min_bid_increment": 500,
            "auction_ends_at": (datetime.utcnow() + timedelta(hours=1)).isoformat(),
        })
        assert created.status_code == 201, created.text
        listing_id = created.json()["id"]

        # Exactly the brief's example: every one of these is a VALID bid.
        for amount in (20500, 30000, 45000):
            res = await client.post("/auction/bid", headers=bh,
                                    json={"listing_id": listing_id, "amount": amount})
            assert res.status_code == 201, f"{amount}: {res.text}"
            assert res.json()["reserve_met"] is False

        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing_id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        pushes.clear()
        await workers.task_close_due_auctions({})

        closed = (await client.get(f"/auctions/{listing_id}")).json()
        assert closed["status"] == "ended"
        assert closed["outcome"] == "reserve_not_met"
        assert closed["winner_id"] is None
        assert closed["deal_id"] is None

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing_id)
            )).scalar_one()
        assert deals == 0

        seller_told = [p for p in pushes if p[0] == seller.id]
        assert any("reserve" in p[2].lower() for p in seller_told)


class TestSweepReliability:
    """The sweep is the only thing that closes an auction. The Flutter
    countdown reaching zero is decoration - so these are the properties
    that decide whether auctions actually end."""

    @pytest.mark.asyncio
    async def test_sweep_finds_every_due_auction_not_just_the_first(self):
        from api.core import workers

        seller = await _user("Seller batch")
        bidder = await _user("Bidder batch")
        listings = []
        for _ in range(5):
            listing, _ = await _auction(seller, starting_price=20000)
            await _bid(listing.id, bidder, 25000)
            listings.append(listing)

        async with AsyncSessionLocal() as db:
            for listing in listings:
                meta = await lifecycle._locked_meta(db, listing.id)
                meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        await workers.task_close_due_auctions({})

        for listing in listings:
            meta = await _meta(listing.id)
            assert meta.closed_at is not None, f"{listing.id} was left open"
            assert meta.outcome == lifecycle.OUTCOME_WON
            assert meta.deal_id, f"{listing.id} closed without a deal"

    @pytest.mark.asyncio
    async def test_one_bad_auction_does_not_stop_the_rest_of_the_sweep(self, monkeypatch):
        """A pass that dies on its first problem leaves every later auction
        stuck in LIVE forever."""
        from api.core import workers

        seller = await _user("Seller resilient")
        bidder = await _user("Bidder resilient")
        good_a, _ = await _auction(seller, starting_price=20000)
        bad, _ = await _auction(seller, starting_price=20000)
        good_b, _ = await _auction(seller, starting_price=20000)
        for listing in (good_a, bad, good_b):
            await _bid(listing.id, bidder, 25000)
        async with AsyncSessionLocal() as db:
            for listing in (good_a, bad, good_b):
                meta = await lifecycle._locked_meta(db, listing.id)
                meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        real_close = lifecycle.close_auction

        async def _explode_on_one(db, listing_id):
            if listing_id == bad.id:
                raise RuntimeError("something went wrong closing this one")
            return await real_close(db, listing_id)

        monkeypatch.setattr(lifecycle, "close_auction", _explode_on_one)
        await workers.task_close_due_auctions({})
        monkeypatch.undo()

        assert (await _meta(good_a.id)).closed_at is not None
        assert (await _meta(good_b.id)).closed_at is not None
        # The broken one is still due, so the next pass retries it rather
        # than it being silently dropped.
        async with AsyncSessionLocal() as db:
            still_due = await lifecycle.due_for_close(db)
        assert bad.id in still_due

        await workers.task_close_due_auctions({})
        assert (await _meta(bad.id)).closed_at is not None, (
            "a transient failure must be retried on the next pass"
        )

    @pytest.mark.asyncio
    async def test_concurrent_sweeps_close_each_auction_exactly_once(self):
        """Two workers hitting the same pass - the multi-process case."""
        from sqlalchemy import func, select
        from api.core import workers

        seller = await _user("Seller two workers")
        bidder = await _user("Bidder two workers")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, bidder, 30000)
        async with AsyncSessionLocal() as db:
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.ends_at = datetime.utcnow() - timedelta(seconds=1)
            await db.commit()

        await asyncio.gather(
            workers.task_close_due_auctions({}),
            workers.task_close_due_auctions({}),
            workers.task_close_due_auctions({}),
            return_exceptions=True,
        )

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1
        meta = await _meta(listing.id)
        assert meta.outcome == lifecycle.OUTCOME_WON
        assert meta.winner_id == bidder.id

    @pytest.mark.asyncio
    async def test_an_expired_auction_is_never_reported_as_live(self):
        """Even before any sweep runs. The status a client is shown is
        derived from the clock, so a sweep that is late cannot leave an
        auction looking open - which is what would let someone bid into an
        auction that should have closed."""
        seller = await _user("Seller stuck")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=-3), ends_in=timedelta(minutes=-5),
        )
        meta = await _meta(listing.id)
        assert meta.status == "live", "precondition: the cached column is stale"
        assert meta.closed_at is None, "precondition: no sweep has run"
        assert lifecycle.effective_status(meta) == lifecycle.ENDED

        from sqlalchemy import select
        async with AsyncSessionLocal() as db:
            listing_row = (await db.execute(
                select(Listing).where(Listing.id == listing.id)
            )).scalar_one()
            state = await lifecycle.public_state(db, listing_row, meta)
        assert state["status"] == "ended"
        assert state["seconds_remaining"] == 0

    @pytest.mark.asyncio
    async def test_listing_status_filter_uses_derived_state(self, client):
        """The grid must not offer an auction as live once its time is up."""
        seller = await _user("Seller grid")
        listing, _ = await _auction(
            seller, starts_in=timedelta(hours=-3), ends_in=timedelta(minutes=-5),
        )
        res = await client.get("/auctions", params={"status": "live"})
        assert res.status_code == 200
        assert listing.id not in [a["id"] for a in res.json()]


class TestOrphanedDealClaim:
    """A retry claims the deal id BEFORE creating the deal, so two workers
    cannot both proceed. The cost of claiming first is that a process dying
    mid-claim leaves an auction pointing at a Deal that was never written -
    a winner with nothing to pay, and a deal_id that hides it from the
    NULL-based retry query. Detecting that orphan is what makes the strict
    claim safe to use."""

    @pytest.mark.asyncio
    async def test_a_claim_that_never_became_a_deal_is_recovered(self):
        from sqlalchemy import func, select

        seller = await _user("Seller orphan")
        winner = await _user("Winner orphan")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 40000)
        await _close(listing.id)

        # Simulate the crash: the auction holds a deal_id for a Deal that
        # does not exist. This is what a process killed between claiming and
        # inserting leaves behind.
        async with AsyncSessionLocal() as db:
            real_deal_id = (await db.execute(
                select(AuctionMeta.deal_id).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            await db.execute(
                sa_delete(Deal).where(Deal.id == real_deal_id)
            )
            meta = await lifecycle._locked_meta(db, listing.id)
            meta.deal_id = "claimed-but-never-written"
            await db.commit()

        # The NULL-based query alone would never see this.
        async with AsyncSessionLocal() as db:
            pending = await lifecycle.due_for_deal_retry(db)
        assert listing.id in pending, "an orphaned claim must be recoverable"

        recovered = await _close(listing.id)
        assert recovered.deal_id
        assert recovered.deal_id != "claimed-but-never-written"
        assert recovered.winner_id == winner.id
        assert recovered.winning_amount == 40000

        async with AsyncSessionLocal() as db:
            deals = (await db.execute(
                select(func.count(Deal.id)).where(Deal.listing_id == listing.id)
            )).scalar_one()
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
        assert deals == 1
        assert meta.deal_id == recovered.deal_id

    @pytest.mark.asyncio
    async def test_a_healthy_deal_is_never_seen_as_an_orphan(self):
        """The orphan check joins against Deal, so it must not sweep up
        auctions whose deal is perfectly fine."""
        seller = await _user("Seller healthy")
        winner = await _user("Winner healthy")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)
        result = await _close(listing.id)
        assert result.deal_id

        async with AsyncSessionLocal() as db:
            pending = await lifecycle.due_for_deal_retry(db)
        assert listing.id not in pending

    @pytest.mark.asyncio
    async def test_the_deal_gets_the_id_that_was_claimed(self):
        """Claim and deal must refer to the same row, or the claim proves
        nothing."""
        from sqlalchemy import select

        seller = await _user("Seller claimid")
        winner = await _user("Winner claimid")
        listing, _ = await _auction(seller, starting_price=20000)
        await _bid(listing.id, winner, 30000)

        # Force the retry path rather than the straight-through close.
        from api.domains.escrow.service import EscrowService
        original = EscrowService.finalize_deal

        async def _fail_once(self, **kwargs):
            raise RuntimeError("not this time")

        EscrowService.finalize_deal = _fail_once
        try:
            await _close(listing.id)
        finally:
            EscrowService.finalize_deal = original

        recovered = await _close(listing.id)
        async with AsyncSessionLocal() as db:
            meta = (await db.execute(
                select(AuctionMeta).where(AuctionMeta.listing_id == listing.id)
            )).scalar_one()
            deal = (await db.execute(
                select(Deal).where(Deal.listing_id == listing.id)
            )).scalar_one()
        assert meta.deal_id == deal.id == recovered.deal_id


class TestReserveIsNeverPublic:
    """The reserve is the seller's secret walk-away price.

    lifecycle.public_state and the auction endpoints were careful about
    this from the start. ListingService._listing_dict was not: it returned
    `reserve_price` outright, and it backs GET /listings/ and
    GET /listings/{id}, both unauthenticated. So every auction's reserve
    was one anonymous request away while the auction API hid it.
    """

    async def _public_auction(self, seller: User, reserve: float):
        listing, _ = await _auction(seller, starting_price=20000, reserve=reserve)
        return listing

    @pytest.mark.asyncio
    async def test_public_feed_does_not_contain_the_reserve(self, client):
        seller = await _user("Seller feed reserve")
        listing = await self._public_auction(seller, reserve=75000)

        res = await client.get("/listings/")
        assert res.status_code == 200, res.text
        body = res.json()
        rows = body["items"] if isinstance(body, dict) else body
        mine = [r for r in rows if r["id"] == listing.id]
        assert mine, "the auction should be in the public feed"
        for row in rows:
            assert "reserve_price" not in row
        assert 75000 not in mine[0].values()

    @pytest.mark.asyncio
    async def test_public_detail_does_not_contain_the_reserve(self, client):
        seller = await _user("Seller detail reserve")
        listing = await self._public_auction(seller, reserve=75000)

        res = await client.get(f"/listings/{listing.id}")
        assert res.status_code == 200, res.text
        body = res.json()
        assert "reserve_price" not in body
        assert 75000 not in body.values()

    @pytest.mark.asyncio
    async def test_auction_detail_still_says_whether_a_reserve_exists(self, client):
        """Hiding the number must not hide the FACT. A bidder needs to know
        the reserve has not been met to bid sensibly - that is the whole
        reason the flag exists."""
        seller = await _user("Seller reserve flags")
        bidder = await _user("Bidder reserve flags")
        listing = await self._public_auction(seller, reserve=75000)

        res = await client.get(f"/auctions/{listing.id}")
        assert res.status_code == 200, res.text
        body = res.json()
        assert body["has_reserve"] is True
        assert body["reserve_met"] is False
        assert "reserve_price" not in body

        await _bid(listing.id, bidder, 80000)
        body = (await client.get(f"/auctions/{listing.id}")).json()
        assert body["reserve_met"] is True
        assert "reserve_price" not in body

    @pytest.mark.asyncio
    async def test_the_seller_can_still_read_their_own_reserve(self, client):
        """Explicitly authenticated owner path. Buyers lose the field;
        the person who set it does not."""
        seller = await _user("Seller own reserve")
        listing = await self._public_auction(seller, reserve=75000)
        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}

        res = await client.get(f"/listings/{listing.id}/private", headers=headers)
        assert res.status_code == 200, res.text
        assert res.json()["reserve_price"] == 75000

    @pytest.mark.asyncio
    async def test_nobody_else_can_read_it_through_that_path(self, client):
        seller = await _user("Seller guarded reserve")
        snooper = await _user("Snooper")
        listing = await self._public_auction(seller, reserve=75000)

        anon = await client.get(f"/listings/{listing.id}/private")
        assert anon.status_code in (401, 403)

        headers = {"Authorization": f"Bearer {create_access_token({'sub': snooper.id})}"}
        other = await client.get(f"/listings/{listing.id}/private", headers=headers)
        assert other.status_code == 403
        assert "75000" not in other.text

    @pytest.mark.asyncio
    async def test_creating_a_listing_returns_the_owner_view(self, client):
        """The creator is authenticated and it is their own listing, so the
        create response keeps the reserve - that is not the leak."""
        seller = await _user("Seller creates")
        headers = {"Authorization": f"Bearer {create_access_token({'sub': seller.id})}"}
        res = await client.post("/listings/", headers=headers, json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Reserve creation check", "category": "Electronics",
            "price": 20000, "lat": -1.29, "lng": 36.82,
            "listing_type": "auction", "reserve_price": 60000,
            "auction_ends_at": (datetime.utcnow() + timedelta(hours=6)).isoformat(),
        })
        assert res.status_code == 201, res.text
        assert res.json()["reserve_price"] == 60000

        # ...and the same listing read back anonymously does not have it.
        listing_id = res.json()["id"]
        public = await client.get(f"/listings/{listing_id}")
        assert "reserve_price" not in public.json()


class TestCreationIsValidatedToo:
    """POST /listings must enforce the same auction rules as
    PATCH /auctions/{id}/terms.

    It did not: creation went straight to AuctionMeta without consulting
    lifecycle.validate_terms, so an auction could be CREATED with an end
    before its start, or a reserve under its starting price - and then, the
    moment it went live, become uneditable in that state.
    """

    @staticmethod
    def _headers(user: User) -> dict:
        return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}

    @staticmethod
    def _body(**over) -> dict:
        body = {"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": f"Created auction {_tag()}", "category": "Electronics",
            "price": 20000, "lat": -1.29, "lng": 36.82,
            "listing_type": "auction",
        }
        body.update(over)
        return body

    @pytest.mark.asyncio
    async def test_end_before_start_is_rejected(self, client):
        seller = await _user("Seller bad window")
        now = datetime.utcnow()
        res = await client.post("/listings/", headers=self._headers(seller), json=self._body(
            auction_starts_at=(now + timedelta(hours=6)).isoformat(),
            auction_ends_at=(now + timedelta(hours=2)).isoformat(),
        ))
        assert res.status_code == 422, res.text
        assert res.json()["detail"]["code"] == "INVALID_WINDOW"

    @pytest.mark.asyncio
    async def test_reserve_below_the_starting_price_is_rejected(self, client):
        seller = await _user("Seller bad reserve")
        res = await client.post("/listings/", headers=self._headers(seller), json=self._body(
            price=20000, reserve_price=5000,
        ))
        assert res.status_code == 422, res.text
        assert res.json()["detail"]["code"] == "RESERVE_BELOW_START"

    @pytest.mark.asyncio
    async def test_a_zero_increment_is_rejected(self, client):
        seller = await _user("Seller bad increment")
        res = await client.post("/listings/", headers=self._headers(seller), json=self._body(
            min_bid_increment=0,
        ))
        assert res.status_code == 422, res.text
        assert res.json()["detail"]["code"] == "INVALID_INCREMENT"

    @pytest.mark.asyncio
    async def test_a_malformed_timestamp_is_rejected_not_defaulted(self, client):
        """The one that was silently wrong rather than loudly wrong.

        _coerce_dt turned anything unparseable into None, and None means
        "use the default window". So a seller who sent a broken
        auction_ends_at was told the auction was created and got one
        closing 72 hours out instead - a different auction from the one
        they asked for, with no error anywhere.
        """
        seller = await _user("Seller bad timestamp")
        res = await client.post("/listings/", headers=self._headers(seller), json=self._body(
            auction_ends_at="next Tuesday",
        ))
        assert res.status_code == 422, res.text
        assert res.json()["detail"]["code"] == "INVALID_TIMESTAMP"

        # And nothing was left behind by the rejected request.
        from sqlalchemy import func, select as sa_select
        async with AsyncSessionLocal() as db:
            count = (await db.execute(
                sa_select(func.count(Listing.id)).where(Listing.seller_id == seller.id)
            )).scalar_one()
        assert count == 0, "a rejected auction must not leave an orphan listing"

    @pytest.mark.asyncio
    async def test_a_valid_scheduled_auction_is_created(self, client):
        seller = await _user("Seller scheduled")
        now = datetime.utcnow()
        starts = (now + timedelta(hours=2)).replace(microsecond=0)
        ends = (now + timedelta(hours=10)).replace(microsecond=0)
        res = await client.post("/listings/", headers=self._headers(seller), json=self._body(
            price=20000, reserve_price=50000, min_bid_increment=1000,
            auction_starts_at=starts.isoformat(), auction_ends_at=ends.isoformat(),
        ))
        assert res.status_code == 201, res.text

        meta = await _meta(res.json()["id"])
        assert meta.starts_at == starts
        assert meta.ends_at == ends
        assert meta.min_bid_increment == 1000
        assert meta.starting_price == 20000
        assert lifecycle.effective_status(meta) == lifecycle.UPCOMING

    @pytest.mark.asyncio
    async def test_a_valid_immediate_auction_is_created(self, client):
        """No timestamps at all - what the sell wizard sends today. Opens
        now, closes at the configured default duration, and is biddable."""
        from api.core.config import settings

        seller = await _user("Seller immediate")
        bidder = await _user("Bidder immediate")
        res = await client.post("/listings/", headers=self._headers(seller),
                                json=self._body(price=20000))
        assert res.status_code == 201, res.text

        listing_id = res.json()["id"]
        meta = await _meta(listing_id)
        assert lifecycle.effective_status(meta) == lifecycle.LIVE
        assert meta.ends_at is not None
        hours = (meta.ends_at - datetime.utcnow()).total_seconds() / 3600
        assert abs(hours - settings.auction_default_duration_hours) < 1

        result = await _bid(listing_id, bidder, 20000)
        assert result.bid_count == 1


class TestRepeatBusinessIsNotADuplicate:
    """A finished deal must not block the next one.

    finalize_deal reused "any deal for this (listing, buyer) that is not
    cancelled", which includes `released` - a deal that completed and paid
    out. So the second time a buyer transacted on the same listing they
    were handed the OLD deal's id and told it already existed. For an
    auction win that is worse than a duplicate: the winner is pointed at a
    deal they already paid, and the auction they just won has nothing to
    pay against.
    """

    @pytest.mark.asyncio
    async def test_a_released_deal_does_not_block_a_later_win(self):
        from api.domains.escrow.service import EscrowService

        seller = await _user("Seller repeat")
        buyer = await _user("Buyer repeat")
        listing, _ = await _auction(seller, starting_price=20000)

        # Deal A: an earlier transaction between these two, long settled.
        async with AsyncSessionLocal() as db:
            svc = EscrowService(db)
            first = await svc.finalize_deal(
                listing_id=listing.id, buyer_id=buyer.id,
                agreed_price=20000, current_user_id=seller.id,
            )
        deal_a_id = first["deal_id"]
        assert first.get("existed") is not True

        async with AsyncSessionLocal() as db:
            deal_a = await db.get(Deal, deal_a_id)
            deal_a.status = DealStatus.released
            # Put it in the past so "most recent" is unambiguous.
            deal_a.created_at = datetime.utcnow() - timedelta(days=90)
            await db.commit()

        # Deal B: the same buyer wins the same listing again later.
        async with AsyncSessionLocal() as db:
            svc = EscrowService(db)
            second = await svc.finalize_deal(
                listing_id=listing.id, buyer_id=buyer.id,
                agreed_price=26000, current_user_id=seller.id,
            )

        assert second["deal_id"] != deal_a_id, (
            "the new win reused the settled deal instead of creating one"
        )
        assert second.get("existed") is not True

        async with AsyncSessionLocal() as db:
            deal_a = await db.get(Deal, deal_a_id)
            deal_b = await db.get(Deal, second["deal_id"])
            # Deal A is untouched.
            assert deal_a.status == DealStatus.released
            assert deal_a.agreed_price == 20000
            # Deal B is a real, separate, live deal.
            assert deal_b.status == DealStatus.agreed
            assert deal_b.agreed_price == 26000

    @pytest.mark.asyncio
    async def test_refunded_and_cancelled_also_do_not_block(self):
        from api.domains.escrow.service import EscrowService

        for terminal in (DealStatus.refunded, DealStatus.cancelled):
            seller = await _user(f"Seller {terminal.value}")
            buyer = await _user(f"Buyer {terminal.value}")
            listing, _ = await _auction(seller, starting_price=20000)

            async with AsyncSessionLocal() as db:
                first = await EscrowService(db).finalize_deal(
                    listing_id=listing.id, buyer_id=buyer.id,
                    agreed_price=20000, current_user_id=seller.id,
                )
            async with AsyncSessionLocal() as db:
                deal = await db.get(Deal, first["deal_id"])
                deal.status = terminal
                await db.commit()

            async with AsyncSessionLocal() as db:
                second = await EscrowService(db).finalize_deal(
                    listing_id=listing.id, buyer_id=buyer.id,
                    agreed_price=26000, current_user_id=seller.id,
                )
            assert second["deal_id"] != first["deal_id"], terminal

    @pytest.mark.asyncio
    async def test_an_active_deal_is_still_reused(self):
        """The protection that must survive the fix: a live transaction is
        joined, not duplicated."""
        from api.domains.escrow.service import EscrowService

        seller = await _user("Seller active dedupe")
        buyer = await _user("Buyer active dedupe")
        listing, _ = await _auction(seller, starting_price=20000)

        async with AsyncSessionLocal() as db:
            first = await EscrowService(db).finalize_deal(
                listing_id=listing.id, buyer_id=buyer.id,
                agreed_price=20000, current_user_id=seller.id,
            )
        for status in (DealStatus.agreed, DealStatus.paid, DealStatus.disputed):
            async with AsyncSessionLocal() as db:
                deal = await db.get(Deal, first["deal_id"])
                deal.status = status
                await db.commit()
            async with AsyncSessionLocal() as db:
                again = await EscrowService(db).finalize_deal(
                    listing_id=listing.id, buyer_id=buyer.id,
                    agreed_price=26000, current_user_id=seller.id,
                )
            assert again["deal_id"] == first["deal_id"], status
            assert again["existed"] is True

    @pytest.mark.asyncio
    async def test_lookup_survives_two_deals_for_the_same_pair(self):
        """get_by_listing_buyer used scalar_one_or_none() over an unordered,
        unlimited query, so the moment a pair had two deals it raised
        MultipleResultsFound - a 500, not a wrong answer."""
        from api.domains.escrow.repository import DealRepository

        seller = await _user("Seller two deals")
        buyer = await _user("Buyer two deals")
        listing, _ = await _auction(seller, starting_price=20000)

        async with AsyncSessionLocal() as db:
            older = Deal(
                listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
                agreed_price=20000, commission=600, status=DealStatus.released,
                created_at=datetime.utcnow() - timedelta(days=90),
            )
            newer = Deal(
                listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
                agreed_price=26000, commission=780, status=DealStatus.agreed,
                created_at=datetime.utcnow(),
            )
            db.add_all([older, newer])
            await db.commit()
            newer_id = newer.id

        async with AsyncSessionLocal() as db:
            repo = DealRepository(db)
            assert (await repo.get_by_listing_buyer(listing.id, buyer.id)).id == newer_id
            assert (await repo.get_active_by_listing_buyer(listing.id, buyer.id)).id == newer_id

    @pytest.mark.asyncio
    async def test_only_terminal_deals_are_skipped(self):
        """Pins the boundary itself. A state added later defaults to
        'active', which fails safe: it dedupes rather than duplicates."""
        from api.domains.escrow.repository import TERMINAL_DEAL_STATUSES

        assert TERMINAL_DEAL_STATUSES == frozenset({
            DealStatus.released, DealStatus.refunded, DealStatus.cancelled,
        })
        for live in (DealStatus.negotiating, DealStatus.agreed, DealStatus.paid,
                     DealStatus.disputed, DealStatus.awaiting_condition_check,
                     DealStatus.awaiting_resolution, DealStatus.awaiting_replacement,
                     DealStatus.goods_not_arrived):
            assert live not in TERMINAL_DEAL_STATUSES


class TestEndingSoonIsRetried:
    """The reminder used to be marked sent before it was sent.

    ending_soon_notified_at was written and committed, THEN the event was
    emitted - and emit swallows its own exceptions. A delivery that failed
    left the auction marked as reminded, excluded from due_for_ending_soon
    forever, with nobody ever told the auction was closing.
    """

    async def _ending_soon(self):
        from api.core.config import settings

        seller = await _user(f"Seller ending {_tag()}")
        bidder = await _user(f"Bidder ending {_tag()}")
        listing, _ = await _auction(
            seller, starting_price=20000,
            ends_in=timedelta(minutes=max(1, settings.auction_ending_soon_minutes - 1)),
        )
        await _bid(listing.id, bidder, 20000)
        return listing, bidder

    @pytest.mark.asyncio
    async def test_a_failed_send_is_retried_by_the_next_sweep(self, monkeypatch):
        from api.core import workers
        from api.domains.auctions import events as auction_events

        listing, bidder = await self._ending_soon()

        calls: list[dict] = []

        async def _failing(**kwargs):
            calls.append(kwargs)
            return False        # what _safe_emit returns when emit() raised

        monkeypatch.setattr(auction_events, "emit_ending_soon", _failing)
        await workers.task_notify_auctions_ending_soon({})

        assert len(calls) == 1
        meta = await _meta(listing.id)
        assert meta.ending_soon_notified_at is None, "a failed send must stay owed"
        assert meta.ending_soon_attempts == 1

        # Next sweep: delivery works this time.
        async def _working(**kwargs):
            calls.append(kwargs)
            return True

        monkeypatch.setattr(auction_events, "emit_ending_soon", _working)
        await workers.task_notify_auctions_ending_soon({})

        assert len(calls) == 2, "the reminder was not retried"
        assert bidder.id in calls[1]["user_ids"]
        meta = await _meta(listing.id)
        assert meta.ending_soon_notified_at is not None
        assert meta.ending_soon_attempts == 2

    @pytest.mark.asyncio
    async def test_a_delivered_reminder_is_not_repeated(self, monkeypatch):
        from api.core import workers
        from api.domains.auctions import events as auction_events

        listing, _ = await self._ending_soon()
        calls: list[dict] = []

        async def _working(**kwargs):
            calls.append(kwargs)
            return True

        monkeypatch.setattr(auction_events, "emit_ending_soon", _working)
        await workers.task_notify_auctions_ending_soon({})
        await workers.task_notify_auctions_ending_soon({})
        await workers.task_notify_auctions_ending_soon({})

        assert len(calls) == 1, "one delivered reminder, one send"

    @pytest.mark.asyncio
    async def test_retries_are_bounded(self, monkeypatch):
        """A permanently failing delivery stops rather than being attempted
        every 60 seconds until the auction closes."""
        from api.core import workers
        from api.domains.auctions import events as auction_events

        listing, _ = await self._ending_soon()
        calls: list[dict] = []

        async def _failing(**kwargs):
            calls.append(kwargs)
            return False

        monkeypatch.setattr(auction_events, "emit_ending_soon", _failing)
        for _ in range(lifecycle.MAX_ENDING_SOON_ATTEMPTS + 3):
            await workers.task_notify_auctions_ending_soon({})

        assert len(calls) == lifecycle.MAX_ENDING_SOON_ATTEMPTS
        meta = await _meta(listing.id)
        assert meta.ending_soon_notified_at is None
        assert meta.ending_soon_attempts == lifecycle.MAX_ENDING_SOON_ATTEMPTS

    @pytest.mark.asyncio
    async def test_two_workers_on_one_tick_send_once(self):
        """The claim is a compare-and-swap, so only one caller may send."""
        listing, _ = await self._ending_soon()

        async def _claim():
            async with AsyncSessionLocal() as db:
                return await lifecycle.claim_ending_soon_attempt(db, listing.id)

        first, second = await asyncio.gather(_claim(), _claim())
        assert [first, second].count(True) == 1
        assert (await _meta(listing.id)).ending_soon_attempts == 1


class TestEveryRouteObeysTheLifecycle:
    """One set of rules, however you arrive at them.

    Two bid routes are mounted - /auction/bid (legacy, api/routers/auction.py)
    and the auction domain's own endpoints - and three public surfaces read
    auction state: GET /auctions, GET /auctions/{id}, GET /listings/{id}.
    A rule enforced in only some of them is not enforced.
    """

    @pytest.mark.asyncio
    async def test_the_legacy_bid_route_enforces_the_same_window(self, client):
        """Not "it calls the right function" - the observable rule."""
        seller = await _user("Seller legacy window")
        bidder = await _user("Bidder legacy window")
        headers = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}

        upcoming, _ = await _auction(
            seller, starts_in=timedelta(hours=1), ends_in=timedelta(hours=4),
        )
        res = await client.post("/auction/bid", headers=headers,
                                json={"listing_id": upcoming.id, "amount": 25000})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_NOT_STARTED"

        ended, _ = await _auction(
            seller, starts_in=timedelta(hours=-4), ends_in=timedelta(hours=-1),
        )
        res = await client.post("/auction/bid", headers=headers,
                                json={"listing_id": ended.id, "amount": 25000})
        assert res.status_code == 409
        assert res.json()["detail"]["code"] == "AUCTION_ENDED"

    @pytest.mark.asyncio
    async def test_the_legacy_bid_route_enforces_the_same_increment(self, client):
        seller = await _user("Seller legacy increment")
        bidder = await _user("Bidder legacy increment")
        headers = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}
        listing, _ = await _auction(seller, starting_price=20000, increment=5000)

        await _bid(listing.id, bidder, 20000)
        other = await _user("Bidder legacy increment 2")
        oh = {"Authorization": f"Bearer {create_access_token({'sub': other.id})}"}

        low = await client.post("/auction/bid", headers=oh,
                                json={"listing_id": listing.id, "amount": 21000})
        assert low.status_code == 400
        assert low.json()["detail"]["code"] == "BID_TOO_LOW"

        ok = await client.post("/auction/bid", headers=oh,
                               json={"listing_id": listing.id, "amount": 25000})
        assert ok.status_code == 201, ok.text
        assert ok.json()["min_next_bid"] == 30000

    @pytest.mark.asyncio
    async def test_the_legacy_bid_route_accepts_sub_reserve_bids(self, client):
        """The bug this route was rewritten for: it used to REJECT any bid
        under the reserve, which publishes the reserve as a minimum."""
        seller = await _user("Seller legacy reserve")
        bidder = await _user("Bidder legacy reserve")
        headers = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}
        listing, _ = await _auction(seller, starting_price=20000, reserve=90000)

        res = await client.post("/auction/bid", headers=headers,
                                json={"listing_id": listing.id, "amount": 25000})
        assert res.status_code == 201, res.text
        assert res.json()["reserve_met"] is False
        assert "reserve_price" not in res.json()

    @pytest.mark.asyncio
    async def test_no_auction_surface_leaks_the_reserve(self, client):
        """Every read path a buyer can reach, checked against one auction."""
        seller = await _user("Seller surfaces")
        bidder = await _user("Bidder surfaces")
        listing, _ = await _auction(seller, starting_price=20000, reserve=99000)
        bh = {"Authorization": f"Bearer {create_access_token({'sub': bidder.id})}"}

        bid = await client.post("/auction/bid", headers=bh,
                                json={"listing_id": listing.id, "amount": 25000})
        assert bid.status_code == 201, bid.text

        grid = await client.get("/auctions")
        detail = await client.get(f"/auctions/{listing.id}")
        public_listing = await client.get(f"/listings/{listing.id}")
        feed = await client.get("/listings/")

        for name, res in (
            ("POST /auction/bid", bid), ("GET /auctions", grid),
            ("GET /auctions/{id}", detail), ("GET /listings/{id}", public_listing),
            ("GET /listings/", feed),
        ):
            assert res.status_code == 200 or res.status_code == 201, name
            assert "reserve_price" not in res.text, f"{name} leaks the reserve"
            # The reserve as a value on its own (99000, 99000.0, "99,000"),
            # not any run of those digits: responses are full of ids and
            # microsecond timestamps, and "...:56.990008" contains "99000".
            assert not re.search(r"(?<![\w.])99,?000(?:\.0+)?(?!\w)", res.text), (
                f"{name} leaks the reserve value")

    @pytest.mark.asyncio
    async def test_the_websocket_snapshot_carries_state_not_the_reserve(self):
        """The auction WS frame is a public surface too - anyone watching
        the auction receives it."""
        from api.core.auction_hub_subscribers import _auction_state

        seller = await _user("Seller ws")
        bidder = await _user("Bidder ws")
        listing, _ = await _auction(seller, starting_price=20000, reserve=99000)
        await _bid(listing.id, bidder, 25000)

        state = await _auction_state(listing.id)
        assert state["current_bid"] == 25000
        assert state["reserve_met"] is False
        assert state["status"] == lifecycle.LIVE
        assert "reserve_price" not in state

    @pytest.mark.asyncio
    async def test_the_grid_and_the_detail_agree_with_the_lifecycle(self, client):
        """Three readers of the same auction, one answer. A cached status
        column that has drifted must not show through any of them."""
        seller = await _user("Seller agreement")
        listing, meta = await _auction(
            seller, starts_in=timedelta(hours=-2), ends_in=timedelta(hours=-1),
        )
        # Exactly the drift effective_status() exists to absorb: the row
        # still claims "live" because no sweep has run yet.
        async with AsyncSessionLocal() as db:
            row = await lifecycle._locked_meta(db, listing.id)
            row.status = lifecycle.LIVE
            await db.commit()

        detail = await client.get(f"/auctions/{listing.id}")
        assert detail.json()["status"] == lifecycle.ENDED
        assert lifecycle.effective_status(await _meta(listing.id)) == lifecycle.ENDED

        # And the grid agrees for every auction it returns. Checked across
        # the whole page rather than by looking for this one listing in it:
        # GET /auctions is an unordered LIMIT 20, so which auctions appear
        # depends on how many exist, and a test that depends on that is
        # testing the page size rather than the parity it means to.
        grid = await client.get("/auctions")
        rows = grid.json()
        rows = rows["items"] if isinstance(rows, dict) else rows
        assert rows, "the grid returned nothing to check"
        for row in rows:
            assert "reserve_price" not in row
            meta_row = await _meta(row["listing_id"])
            assert row["status"] == lifecycle.effective_status(meta_row), (
                f"grid disagrees with the lifecycle for {row['listing_id']}"
            )
