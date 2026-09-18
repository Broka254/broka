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
        # The winning price becomes the goods amount, and the existing
        # commission model applies to it unchanged.
        assert deal.agreed_price == 78000
        assert deal.commission == round(78000 * settings.commission_rate, 2)
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
