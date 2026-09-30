"""
BROKA - Listing stock, sold-out listings, and deleting a listing
Run: pytest backend/tests/test_listing_stock.py -v

Stock (api/domains/listings/stock.py). Agreeing any deal used to hide the
listing, whatever its quantity - a seller of 100 bags vanished when the first
buyer agreed to one - nothing brought it back when that deal was refunded,
and nothing stopped a second buyer agreeing to an item that was already
taken. Now a deal takes Deal.quantity units; the listing stays on sale while
units are left, is hidden when none are, and comes back if a deal gives its
units back.

Deleting (DELETE /listings/{id}). There was no way to: the dashboard had no
delete, and no endpoint did it.

Also here: two reviews of one deal sent together, and the seller's deal time
on the public listing (the web storefront's product page).
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import (
    init_db, reset_engine, AsyncSessionLocal, User, Listing, ListingStatus,
    ListingType, Deal, DealStatus, Review, Bid,
)
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_stock.db"
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


_seq = itertools.count()


async def _user(name: str = "Test User") -> tuple[str, dict]:
    async with AsyncSessionLocal() as db:
        u = User(name=name, phone=f"07{next(_seq):08d}", password_hash="x", phone_verified=True)
        db.add(u)
        await db.commit()
        return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(seller_id: str, quantity=None, listing_type=ListingType.direct,
                   status=ListingStatus.active) -> str:
    async with AsyncSessionLocal() as db:
        l = Listing(seller_id=seller_id, name=f"Maize bags {next(_seq)}", category="Agriculture",
                    price=3500.0, lat=-1.28, lng=36.82, quantity=quantity,
                    listing_type=listing_type, status=status)
        db.add(l)
        await db.commit()
        return l.id


async def _status(listing_id: str) -> str:
    async with AsyncSessionLocal() as db:
        l = await db.get(Listing, listing_id)
        await db.refresh(l)
        return l.status.value


async def _finalize(client, listing_id, buyer_id, headers, quantity=None, price=7000):
    body = {"listing_id": listing_id, "buyer_id": buyer_id, "agreed_price": price}
    if quantity is not None:
        body["quantity"] = quantity
    return await client.post("/deal/finalize", json=body, headers=headers)


async def _on_sale(client, seller_id: str) -> set[str]:
    res = await client.get("/listings/", params={"seller_id": seller_id})
    return {l["id"] for l in res.json()}


async def _set_deal(deal_id: str, status: DealStatus):
    async with AsyncSessionLocal() as db:
        d = await db.get(Deal, deal_id)
        d.status = status
        if status == DealStatus.released:
            d.released_at = datetime.utcnow()
        await db.commit()


async def _sweep() -> int:
    from api.core.workers import task_sync_listing_stock
    return await task_sync_listing_stock()


# ── Stock ────────────────────────────────────────────────────────────────────

class TestStock:
    @pytest.mark.asyncio
    async def test_a_listing_with_units_left_stays_on_sale(self, client):
        seller_id, _ = await _user("Grace")
        listing_id = await _listing(seller_id, quantity=3)
        amina, as_amina = await _user("Amina")
        brian, as_brian = await _user("Brian")

        res = await _finalize(client, listing_id, amina, as_amina, quantity=2)
        assert res.status_code == 201, res.text
        # The first agreement used to hide it. One bag is left.
        assert await _status(listing_id) == "active"
        assert listing_id in await _on_sale(client, seller_id)
        body = (await client.get(f"/listings/{listing_id}")).json()
        assert (body["units_left"], body["sold_out"], body["available"]) == (1, False, True)

        # More than is left is refused, saying how many there are.
        res = await _finalize(client, listing_id, brian, as_brian, quantity=2)
        assert res.status_code == 409
        assert "Only 1 left" in res.json()["detail"]

        # The last one: sold out, and gone from what buyers browse.
        res = await _finalize(client, listing_id, brian, as_brian, quantity=1)
        assert res.status_code == 201, res.text
        assert await _status(listing_id) == "pending"
        assert listing_id not in await _on_sale(client, seller_id)
        body = (await client.get(f"/listings/{listing_id}")).json()
        assert (body["units_left"], body["sold_out"], body["available"]) == (0, True, False)

        async with AsyncSessionLocal() as db:
            units = sorted((await db.execute(
                select(Deal.quantity).where(Deal.listing_id == listing_id))).scalars())
        assert units == [1, 2]

    @pytest.mark.asyncio
    async def test_a_sold_out_listing_cannot_be_bought_again(self, client):
        # No quantity stated reads as one.
        seller_id, _ = await _user("Otieno")
        listing_id = await _listing(seller_id)
        amina, as_amina = await _user("Amina")
        kevin, as_kevin = await _user("Kevin")
        assert (await _finalize(client, listing_id, amina, as_amina)).status_code == 201

        res = await _finalize(client, listing_id, kevin, as_kevin)
        assert res.status_code == 409
        assert res.json()["detail"] == "This listing is sold out."
        # Interest in it would text the seller about something they can't sell.
        res = await client.post(f"/listings/{listing_id}/interest", json={}, headers=as_kevin)
        assert res.status_code == 409

        # The buyer who has the deal still reaches it.
        res = await _finalize(client, listing_id, amina, as_amina)
        assert res.status_code == 201 and res.json()["existed"] is True

    @pytest.mark.asyncio
    async def test_a_refund_puts_the_listing_back_on_sale(self, client):
        seller_id, _ = await _user("Wanjiru")
        listing_id = await _listing(seller_id, quantity=1)
        amina, as_amina = await _user("Amina")
        deal_id = (await _finalize(client, listing_id, amina, as_amina)).json()["deal_id"]
        assert await _status(listing_id) == "pending"

        await _set_deal(deal_id, DealStatus.refunded)
        assert await _sweep() >= 1
        assert await _status(listing_id) == "active"
        assert listing_id in await _on_sale(client, seller_id)

    @pytest.mark.asyncio
    async def test_every_unit_paid_out_is_sold(self, client):
        seller_id, _ = await _user("Mutua")
        listing_id = await _listing(seller_id, quantity=2)
        amina, as_amina = await _user("Amina")
        brian, as_brian = await _user("Brian")
        d1 = (await _finalize(client, listing_id, amina, as_amina)).json()["deal_id"]
        d2 = (await _finalize(client, listing_id, brian, as_brian)).json()["deal_id"]
        await _set_deal(d1, DealStatus.released)
        await _sweep()
        # One sold, one still in a deal: hidden, not yet sold.
        assert await _status(listing_id) == "pending"
        await _set_deal(d2, DealStatus.released)
        await _sweep()
        assert await _status(listing_id) == "completed"

    @pytest.mark.asyncio
    async def test_a_listing_hidden_by_the_old_rule_comes_back(self, client):
        # Hidden on its first agreement, with 9 of 10 bags still unsold.
        seller_id, _ = await _user("Njeri")
        amina, _ = await _user("Amina")
        listing_id = await _listing(seller_id, quantity=10, status=ListingStatus.pending)
        async with AsyncSessionLocal() as db:
            db.add(Deal(listing_id=listing_id, seller_id=seller_id, buyer_id=amina,
                        agreed_price=3500.0, commission=122.0, status=DealStatus.paid))
            await db.commit()
        await _sweep()
        assert await _status(listing_id) == "active"

    @pytest.mark.asyncio
    async def test_the_sweep_leaves_deleted_listings_and_auctions_alone(self):
        seller_id, _ = await _user("Kamau")
        deleted = await _listing(seller_id, status=ListingStatus.cancelled)
        auction = await _listing(seller_id, listing_type=ListingType.auction,
                                 status=ListingStatus.pending)
        await _sweep()
        assert await _status(deleted) == "cancelled"
        assert await _status(auction) == "pending"


# ── Deleting ─────────────────────────────────────────────────────────────────

class TestDelete:
    @pytest.mark.asyncio
    async def test_the_seller_deletes_it_and_buyers_stop_seeing_it(self, client):
        seller_id, as_seller = await _user("Grace")
        listing_id = await _listing(seller_id, quantity=5)
        assert listing_id in await _on_sale(client, seller_id)

        res = await client.delete(f"/listings/{listing_id}", headers=as_seller)
        assert res.status_code == 200
        assert res.json() == {"deleted": True, "listing_id": listing_id}
        assert await _status(listing_id) == "cancelled"
        assert listing_id not in await _on_sale(client, seller_id)
        # A link to it (a chat, an old notification) says it's gone.
        body = (await client.get(f"/listings/{listing_id}")).json()
        assert body["status"] == "cancelled" and body["available"] is False
        # And nobody can buy it.
        buyer, as_buyer = await _user("Amina")
        res = await _finalize(client, listing_id, buyer, as_buyer)
        assert res.status_code == 409
        assert "removed" in res.json()["detail"]
        # Deleting again is not an error.
        assert (await client.delete(f"/listings/{listing_id}", headers=as_seller)).status_code == 200

    @pytest.mark.asyncio
    async def test_only_the_seller(self, client):
        seller_id, _ = await _user("Grace")
        _, as_other = await _user("Someone")
        listing_id = await _listing(seller_id)
        assert (await client.delete(f"/listings/{listing_id}", headers=as_other)).status_code == 403
        assert (await client.delete(f"/listings/{listing_id}")).status_code in (401, 403)
        assert await _status(listing_id) == "active"

    @pytest.mark.asyncio
    async def test_not_while_a_buyers_deal_is_under_way(self, client):
        seller_id, as_seller = await _user("Grace")
        listing_id = await _listing(seller_id, quantity=4)
        buyer, as_buyer = await _user("Amina")
        deal_id = (await _finalize(client, listing_id, buyer, as_buyer)).json()["deal_id"]
        for live in (DealStatus.agreed, DealStatus.paid, DealStatus.disputed):
            await _set_deal(deal_id, live)
            res = await client.delete(f"/listings/{listing_id}", headers=as_seller)
            assert res.status_code == 409, live
            assert "deal in progress" in res.json()["detail"]
        # Finished deals don't stop it.
        await _set_deal(deal_id, DealStatus.released)
        assert (await client.delete(f"/listings/{listing_id}", headers=as_seller)).status_code == 200

    @pytest.mark.asyncio
    async def test_not_an_auction_with_bids(self, client):
        seller_id, as_seller = await _user("Grace")
        bidder, _ = await _user("Bidder")
        listing_id = await _listing(seller_id, listing_type=ListingType.auction)
        async with AsyncSessionLocal() as db:
            db.add(Bid(listing_id=listing_id, bidder_id=bidder, amount=5000.0))
            await db.commit()
        res = await client.delete(f"/listings/{listing_id}", headers=as_seller)
        assert res.status_code == 409
        assert await _status(listing_id) == "active"


# ── Reviews: two at once ─────────────────────────────────────────────────────

class TestReviewRace:
    @pytest.mark.asyncio
    async def test_the_second_of_two_simultaneous_reviews_is_refused(self, client, monkeypatch):
        seller_id, _ = await _user("Grace")
        buyer, as_buyer = await _user("Amina")
        listing_id = await _listing(seller_id)
        deal_id = (await _finalize(client, listing_id, buyer, as_buyer)).json()["deal_id"]
        await _set_deal(deal_id, DealStatus.released)

        # Both requests pass the service's own check before either commits.
        from api.domains.reviews.service import ReviewService

        async def never(self, deal_id, reviewer_id):
            return False
        monkeypatch.setattr(ReviewService, "_already_reviewed", never)

        first = await client.post("/reviews/", json={"deal_id": deal_id, "rating": 5}, headers=as_buyer)
        second = await client.post("/reviews/", json={"deal_id": deal_id, "rating": 5}, headers=as_buyer)
        assert first.status_code == 201
        assert second.status_code == 409
        async with AsyncSessionLocal() as db:
            n = len((await db.execute(select(Review).where(Review.deal_id == deal_id))).all())
        assert n == 1


# ── Deal time on the public listing ──────────────────────────────────────────

class TestListingDealTime:
    @pytest.mark.asyncio
    async def test_the_public_listing_carries_the_sellers_deal_time(self, client):
        seller_id, _ = await _user("Grace")
        buyer, _ = await _user("Amina")
        listing_id = await _listing(seller_id, quantity=5)
        agreed = datetime.utcnow() - timedelta(days=3)
        async with AsyncSessionLocal() as db:
            db.add(Deal(listing_id=listing_id, seller_id=seller_id, buyer_id=buyer,
                        agreed_price=3500.0, commission=122.0, status=DealStatus.released,
                        created_at=agreed, released_at=agreed + timedelta(hours=30)))
            (await db.get(User, seller_id)).completed_deals = 1
            await db.commit()
        body = (await client.get(f"/listings/{listing_id}")).json()
        assert body["seller_avg_deal_time_minutes"] == 30 * 60
        assert body["seller_timed_deals"] == 1

    @pytest.mark.asyncio
    async def test_not_before_the_first_sale(self, client):
        seller_id, _ = await _user("New Seller")
        listing_id = await _listing(seller_id)
        body = (await client.get(f"/listings/{listing_id}")).json()
        assert "seller_avg_deal_time_minutes" not in body
