"""Auctions switched off for launch (AUCTIONS_ENABLED; auctions/paused.py).

A winning bid is paid through BROKA's own escrow, which is paused, so
auctions are hidden rather than deleted. What must hold while they're off:
  * nothing can create, change or bid on one - each refusal carries a
    message an older app build (which still offers them) can show;
  * no list a buyer browses shows one - and the filter that hides them
    must not hide anything else, listings saved with no type included;
  * an auction someone already has open by its link still reads, so a
    winner can see what they won;
  * the Auction House is empty, the plans stop selling auctions, no
    "ending soon" reminder goes out, and Zeno doesn't offer them.
With AUCTIONS_ENABLED on (the rest of the suite), all of it is as before.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import (
    AsyncSessionLocal, AuctionMeta, Listing, ListingType, User, init_db, reset_engine,
)
from api.domains.auctions import paused
from api.domains.pricing import safe_payment
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_auctions_off.db"
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


async def _user(name: str = "Seller") -> User:
    u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u


def _auth(u: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(seller: User, name: str, listing_type, *, with_meta: bool = False) -> Listing:
    listing = Listing(seller_id=seller.id, name=name, category="Collectibles", price=5000.0,
                      lat=-1.29, lng=36.82, listing_type=listing_type)
    async with AsyncSessionLocal() as db:
        db.add(listing)
        await db.flush()
        if with_meta:
            now = datetime.utcnow()
            db.add(AuctionMeta(listing_id=listing.id, starting_price=5000.0, min_bid_increment=100.0,
                               status="live", starts_at=now - timedelta(hours=1),
                               ends_at=now + timedelta(days=1)))
        if listing_type is None:
            # Set in SQL: the ORM would fill in the column's default
            # ("direct"), and a NULL row is what a legacy listing is.
            from sqlalchemy import update
            await db.execute(update(Listing).where(Listing.id == listing.id).values(listing_type=None))
        await db.commit()
        await db.refresh(listing)
    return listing


_NEW_AUCTION = {
    "name": "Vintage Watch", "category": "Collectibles", "price": 10000,
    "description": "Well kept, works perfectly - selling because I upgraded.",
    "lat": -1.286, "lng": 36.817, "listing_type": "auction",
}

_REFUSED = {"code": paused.AUCTIONS_OFF_CODE, "message": paused.AUCTIONS_OFF_MESSAGE}


class TestNothingCanStartOne:
    @pytest.mark.asyncio
    async def test_an_auction_listing_is_refused_and_nothing_is_saved(self, client, auctions_off):
        seller = await _user()
        r = await client.post("/listings/", json=_NEW_AUCTION, headers=_auth(seller))
        assert r.status_code == 409, r.text
        assert r.json()["detail"] == _REFUSED
        async with AsyncSessionLocal() as db:
            from sqlalchemy import select
            saved = (await db.execute(select(Listing).where(Listing.seller_id == seller.id))).scalars().all()
        assert saved == []

    @pytest.mark.asyncio
    async def test_a_direct_sale_still_lists(self, client, auctions_off):
        r = await client.post("/listings/", json={**_NEW_AUCTION, "listing_type": "direct"},
                              headers=_auth(await _user()))
        assert r.status_code == 201, r.text

    @pytest.mark.asyncio
    async def test_a_bid_is_refused(self, client, auctions_off):
        seller = await _user()
        live = await _listing(seller, "Old Clock", ListingType.auction, with_meta=True)
        r = await client.post("/auction/bid", json={"listing_id": live.id, "amount": 6000},
                              headers=_auth(await _user("Bidder")))
        assert r.status_code == 409 and r.json()["detail"] == _REFUSED

    @pytest.mark.asyncio
    async def test_its_terms_cannot_be_changed(self, client, auctions_off):
        seller = await _user()
        live = await _listing(seller, "Old Lamp", ListingType.auction, with_meta=True)
        r = await client.patch(f"/auctions/{live.id}/terms", json={"min_bid_increment": 200},
                               headers=_auth(seller))
        assert r.status_code == 409 and r.json()["detail"] == _REFUSED

    @pytest.mark.asyncio
    async def test_with_auctions_on_the_same_bid_reaches_the_auction(self, client):
        """The guard, not the route, is what refuses."""
        seller = await _user()
        live = await _listing(seller, "Old Radio", ListingType.auction, with_meta=True)
        r = await client.post("/auction/bid", json={"listing_id": live.id, "amount": 6000},
                              headers=_auth(await _user("Bidder")))
        assert r.status_code == 201, r.text


class TestBuyersSeeNone:
    @pytest.mark.asyncio
    async def test_feeds_leave_out_auctions_and_nothing_else(self, client, auctions_off):
        seller = await _user()
        auction = await _listing(seller, "Hidden Auction", ListingType.auction, with_meta=True)
        direct = await _listing(seller, "Plain Sale", ListingType.direct)
        # Regression guard: NULL != 'auction' is NULL in SQL, so a bare
        # "not an auction" filter would hide every listing saved untyped.
        untyped = await _listing(seller, "Untyped Sale", None)
        ids = {l["id"] for l in (await client.get("/listings/", params={"seller_id": seller.id})).json()}
        assert direct.id in ids and untyped.id in ids
        assert auction.id not in ids
        typed = (await client.get("/listings/", params={"listing_type": "auction"})).json()
        assert typed == []

    @pytest.mark.asyncio
    async def test_with_auctions_on_feeds_show_them(self, client):
        seller = await _user()
        auction = await _listing(seller, "Shown Auction", ListingType.auction, with_meta=True)
        ids = {l["id"] for l in (await client.get("/listings/", params={"seller_id": seller.id})).json()}
        assert auction.id in ids

    @pytest.mark.asyncio
    async def test_the_auction_house_is_empty(self, client, auctions_off):
        await _listing(await _user(), "Another Auction", ListingType.auction, with_meta=True)
        r = await client.get("/auctions")
        assert r.status_code == 200 and r.json() == []

    @pytest.mark.asyncio
    async def test_one_opened_by_its_link_still_reads(self, client, auctions_off):
        auction = await _listing(await _user(), "Won Auction", ListingType.auction, with_meta=True)
        assert (await client.get(f"/listings/{auction.id}")).status_code == 200
        assert (await client.get(f"/auctions/{auction.id}")).status_code == 200


class TestNothingSellsThem:
    @pytest.mark.asyncio
    async def test_plans_offer_no_auctions(self, client, auctions_off):
        plans = (await client.get("/pricing/plans")).json()["premium"]
        assert all(p["allowances"]["auctions_hosted"] == 0 for p in plans)
        assert not any("auction" in p["pitch"].lower() for p in plans)

    @pytest.mark.asyncio
    async def test_with_auctions_on_the_plans_sell_them(self, client):
        plans = {p["id"]: p for p in (await client.get("/pricing/plans")).json()["premium"]}
        assert plans["pro"]["allowances"]["auctions_hosted"] == 2
        assert "auctions" in plans["pro"]["pitch"]

    @pytest.mark.asyncio
    async def test_a_subscriber_is_not_shown_auctions_left(self, client, auctions_off):
        from api.core.config import settings
        # A frozen dataclass field, flipped the way conftest's fixtures do.
        before = settings.premium_enabled
        object.__setattr__(settings, "premium_enabled", True)
        try:
            await self._pro_subscriber_sees_no_auctions(client)
        finally:
            object.__setattr__(settings, "premium_enabled", before)

    async def _pro_subscriber_sees_no_auctions(self, client):
        from api.models.subscription import Subscription
        u = await _user("Pro Subscriber")
        async with AsyncSessionLocal() as db:
            now = datetime.utcnow()
            db.add(Subscription(user_id=u.id, plan_id="pro", started_at=now - timedelta(days=1),
                                paid_until=now + timedelta(days=29)))
            await db.commit()
        me = (await client.get("/premium/me", headers=_auth(u))).json()
        assert me["plan"]["id"] == "pro"
        assert me["usage"]["auctions_hosted"]["allowance"] == 0
        assert me["usage"]["ai_covers"]["allowance"] == 20

    @pytest.mark.asyncio
    async def test_no_ending_soon_reminder(self, monkeypatch, auctions_off):
        from api.core import workers
        from api.domains.auctions import lifecycle

        async def must_not_run(db):
            raise AssertionError("looked for auctions to remind about")

        monkeypatch.setattr(lifecycle, "due_for_ending_soon", must_not_run)
        await workers.task_notify_auctions_ending_soon({})

    def test_zeno_is_told_there_are_none(self, auctions_off):
        assert "no auctions" in safe_payment.ai_payment_policy()

    def test_and_with_payments_off_too(self, auctions_off, payments_off):
        policy = safe_payment.ai_payment_policy()
        assert "no auctions" in policy and "does not handle deal payments" in policy
