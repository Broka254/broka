"""GET /auction/{listing_id}/leaderboard - the list the auction screen shows.

The route used to try a C++ ranking engine (`broka_engine`) that was never
built, then sort in Python. The ordering is SQL's now; these pin what the
app has always been shown.
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import AsyncSessionLocal, Bid, Listing, User, init_db, reset_engine
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_auction_leaderboard.db"
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


_seq = itertools.count()


async def _auction_with_bids(bids):
    """A listing and a bidder per (name, amount, minutes_ago)."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Seller", phone=f"0780{next(_seq):06d}", password_hash="x")
        db.add(seller)
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Sofa", category="furniture",
                          price=10_000.0, lat=-1.28, lng=36.82, listing_type="auction")
        db.add(listing)
        await db.flush()
        now = datetime.utcnow()
        for name, amount, minutes_ago in bids:
            bidder = User(name=name, phone=f"0781{next(_seq):06d}", password_hash="x")
            db.add(bidder)
            await db.flush()
            db.add(Bid(listing_id=listing.id, bidder_id=bidder.id, amount=amount,
                       created_at=now - timedelta(minutes=minutes_ago)))
        await db.commit()
        return listing.id


@pytest.mark.asyncio
async def test_highest_first_and_the_earlier_of_equal_bids_leads(client):
    listing_id = await _auction_with_bids([
        ("Amina", 12_000.0, 30),
        ("Baraka", 15_000.0, 5),
        ("Chebet", 15_000.0, 90),     # same amount as Baraka, placed earlier
        ("Daudi", 11_000.0, 0),
    ])
    resp = await client.get(f"/auction/{listing_id}/leaderboard")
    assert resp.status_code == 200
    board = resp.json()
    assert [(row["rank"], row["bidder_name"], row["amount"]) for row in board] == [
        (1, "Chebet", 15_000.0),
        (2, "Baraka", 15_000.0),
        (3, "Amina", 12_000.0),
        (4, "Daudi", 11_000.0),
    ]
    assert [row["time_ago"] for row in board] == ["1h ago", "5m ago", "30m ago", "just now"]


@pytest.mark.asyncio
async def test_no_bids_is_an_empty_board(client):
    listing_id = await _auction_with_bids([])
    resp = await client.get(f"/auction/{listing_id}/leaderboard")
    assert resp.status_code == 200
    assert resp.json() == []
