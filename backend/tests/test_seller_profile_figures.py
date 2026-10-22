"""
BROKA - The figures a seller's profile shows, and who may review them
Run: pytest backend/tests/test_seller_profile_figures.py -v

Two things the profile screen, a listing's seller block and the seller
dashboard read that did not exist:

  * The average deal completion time. The profile read an
    `avg_deal_time_minutes` GET /auth/user/{id} never returned, so every
    seller showed "N/A". It is now measured from the seller's released deals,
    agreement to payout (trust/deal_time.py).
  * Reviews. The app called /reviews/summary/{id} and /reviews/my-deals,
    routes of a router that is not mounted, so every profile said "No reviews
    yet" and no buyer could ever pick a deal to review. Only a buyer whose
    deal with the seller completed may review, once per deal.
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import (
    init_db, reset_engine, AsyncSessionLocal, User, Listing, Deal, DealStatus, Review,
)
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    # With REDIS_URL set, ReviewSubmitted would go to a stream nothing here reads.
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_seller_profile_figures.db"
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


_phone_seq = itertools.count()


async def _user(name: str) -> tuple[str, dict]:
    async with AsyncSessionLocal() as db:
        u = User(name=name, phone=f"07{next(_phone_seq):08d}", password_hash="x",
                 phone_verified=True)
        db.add(u)
        await db.commit()
        return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _deal(seller_id: str, buyer_id: str, status: DealStatus,
                agreed: datetime | None = None, took: timedelta | None = None,
                listing_name: str = "Samsung A54") -> str:
    """A deal agreed at [agreed] and, if [took] is given, paid out that long
    after - the way every release path stamps released_at."""
    agreed = agreed or datetime.utcnow() - timedelta(days=10)
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller_id, name=listing_name, category="electronics",
                          price=20_000.0, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        deal = Deal(listing_id=listing.id, seller_id=seller_id, buyer_id=buyer_id,
                    agreed_price=20_000.0, commission=600.0, status=status,
                    created_at=agreed,
                    released_at=agreed + took if took is not None else None)
        db.add(deal)
        if status == DealStatus.released:
            seller = await db.get(User, seller_id)
            seller.completed_deals = (seller.completed_deals or 0) + 1
        await db.commit()
        return deal.id


# ── Deal completion time ─────────────────────────────────────────────────────

class TestDealCompletionTime:
    @pytest.mark.asyncio
    async def test_a_buyer_sees_the_average_over_completed_deals(self, client):
        seller_id, _ = await _user("Grace Akinyi")
        buyer_id, as_buyer = await _user("Otieno Ouma")
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(hours=1))
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(hours=3))
        # Neither completed, so neither has a completion time: a refund is not
        # a completed deal, and an open one has not ended.
        await _deal(seller_id, buyer_id, DealStatus.refunded, took=timedelta(days=30))
        await _deal(seller_id, buyer_id, DealStatus.paid,
                    agreed=datetime.utcnow() - timedelta(days=40))

        body = (await client.get(f"/auth/user/{seller_id}", headers=as_buyer)).json()
        assert body["avg_deal_time_minutes"] == 120.0
        assert body["timed_deals"] == 2

    @pytest.mark.asyncio
    async def test_the_seller_sees_it_on_their_own_profile(self, client):
        # The seller dashboard reads the owner's view of the same endpoint.
        seller_id, as_seller = await _user("Wanjiru Kamau")
        buyer_id, _ = await _user("Brian Otieno")
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(days=2))
        body = (await client.get(f"/auth/user/{seller_id}", headers=as_seller)).json()
        assert body["avg_deal_time_minutes"] == 2 * 24 * 60
        assert body["timed_deals"] == 1

    @pytest.mark.asyncio
    async def test_no_completed_deal_is_no_figure_not_zero(self, client):
        seller_id, _ = await _user("New Seller")
        buyer_id, as_buyer = await _user("Curious Buyer")
        await _deal(seller_id, buyer_id, DealStatus.paid)
        body = (await client.get(f"/auth/user/{seller_id}", headers=as_buyer)).json()
        assert body.get("avg_deal_time_minutes") is None

    @pytest.mark.asyncio
    async def test_a_payout_stamped_before_agreement_is_ignored(self):
        from api.domains.trust.deal_time import deal_completion_time
        seller_id, _ = await _user("Clock Skew")
        buyer_id, _ = await _user("Buyer Skew")
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(minutes=-30))
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(minutes=90))
        async with AsyncSessionLocal() as db:
            assert await deal_completion_time(db, seller_id) == {
                "avg_deal_time_minutes": 90.0, "timed_deals": 1}

    @pytest.mark.asyncio
    async def test_only_the_latest_deals_count(self, monkeypatch):
        from api.domains.trust import deal_time
        monkeypatch.setattr(deal_time, "RECENT_DEALS", 2)
        seller_id, _ = await _user("Improving Seller")
        buyer_id, _ = await _user("Loyal Buyer")
        now = datetime.utcnow()
        # A slow first deal, then two quick recent ones.
        await _deal(seller_id, buyer_id, DealStatus.released,
                    agreed=now - timedelta(days=60), took=timedelta(days=10))
        await _deal(seller_id, buyer_id, DealStatus.released,
                    agreed=now - timedelta(days=3), took=timedelta(hours=2))
        await _deal(seller_id, buyer_id, DealStatus.released,
                    agreed=now - timedelta(days=2), took=timedelta(hours=4))
        async with AsyncSessionLocal() as db:
            got = await deal_time.deal_completion_time(db, seller_id)
        assert got == {"avg_deal_time_minutes": 180.0, "timed_deals": 2}


# ── Reviews ──────────────────────────────────────────────────────────────────

@pytest_asyncio.fixture(scope="module")
async def market():
    """A seller, a buyer whose deal with them was released, a buyer whose
    deal is still in escrow, and someone who never bought anything."""
    seller_id, as_seller = await _user("Grace Akinyi")
    buyer_id, as_buyer = await _user("Amina Wanjiku")
    waiting_id, as_waiting = await _user("Kevin Mutua")
    stranger_id, as_stranger = await _user("Stranger Danger")
    done = await _deal(seller_id, buyer_id, DealStatus.released,
                       took=timedelta(hours=5), listing_name="Samsung A54")
    in_escrow = await _deal(seller_id, waiting_id, DealStatus.paid, listing_name="JBL Flip 6")
    return {
        "seller": (seller_id, as_seller), "buyer": (buyer_id, as_buyer),
        "waiting": (waiting_id, as_waiting), "stranger": (stranger_id, as_stranger),
        "done": done, "in_escrow": in_escrow,
    }


class TestWhoMayReview:
    """Only the buyer of a deal. No setting turns that off - a review is a
    record of a deal both sides actually reached (2026-10-22)."""

    @pytest.mark.asyncio
    async def test_the_buyer_of_a_deal_has_it_to_review(self, client, market):
        seller_id, _ = market["seller"]
        _, as_buyer = market["buyer"]
        res = await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                               headers=as_buyer)
        assert res.status_code == 200
        [deal] = res.json()["deals"]
        assert deal["deal_id"] == market["done"]
        assert deal["seller_name"] == "Grace Akinyi"
        assert deal["listing_name"] == "Samsung A54"
        assert deal["status"] == "released"
        assert deal["already_reviewed"] is False

    @pytest.mark.asyncio
    async def test_a_deal_still_running_can_be_reviewed(self, client):
        """BROKA never learns that a deal completed (buyers pay outside it),
        so a deal in escrow is reviewable - waiting for a release that never
        comes is what left nobody able to review.

        Its own seller, not the shared market's: a review here would change
        that seller's summary for every later test.
        """
        seller_id, _ = await _user("In Escrow Seller")
        buyer_id, as_buyer = await _user("In Escrow Buyer")
        deal = await _deal(seller_id, buyer_id, DealStatus.paid, listing_name="JBL Flip 6")
        [offered] = (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                      headers=as_buyer)).json()["deals"]
        assert offered["deal_id"] == deal
        res = await client.post("/reviews/", json={"deal_id": deal, "rating": 4},
                                headers=as_buyer)
        assert res.status_code == 201, res.text

    @pytest.mark.asyncio
    async def test_no_one_else_has_anything_to_review(self, client, market):
        seller_id, as_seller = market["seller"]
        _, as_stranger = market["stranger"]
        res = await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                               headers=as_stranger)
        assert res.json() == {"deals": []}
        # The seller is not their own buyer.
        res = await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                               headers=as_seller)
        assert res.json() == {"deals": []}

    @pytest.mark.asyncio
    async def test_needs_a_signed_in_buyer(self, client, market):
        assert (await client.get("/reviews/my-deals")).status_code in (401, 403)

    @pytest.mark.asyncio
    async def test_a_stranger_cannot_review_someone_elses_deal(self, client, market):
        _, as_stranger = market["stranger"]
        res = await client.post("/reviews/", json={"deal_id": market["done"], "rating": 1},
                                headers=as_stranger)
        assert res.status_code == 403

    @pytest.mark.asyncio
    async def test_the_seller_cannot_review_their_own_sale(self, client, market):
        _, as_seller = market["seller"]
        res = await client.post("/reviews/", json={"deal_id": market["done"], "rating": 5},
                                headers=as_seller)
        assert res.status_code == 403

    @pytest.mark.asyncio
    async def test_an_account_that_dealt_with_itself_cannot_review(self, client):
        self_id, as_self = await _user("Self Dealer")
        deal = await _deal(self_id, self_id, DealStatus.released, took=timedelta(hours=1))
        res = await client.post("/reviews/", json={"deal_id": deal, "rating": 5}, headers=as_self)
        assert res.status_code == 403
        res = await client.get("/reviews/my-deals", headers=as_self)
        assert res.json() == {"deals": []}


async def _talk(seller_id: str, buyer_id: str, listing_name: str = "Sofa") -> str:
    """The buyer writes to the seller about one of their listings."""
    from api.database import NegotiationMessage
    async with AsyncSessionLocal() as db:
        listing = Listing(seller_id=seller_id, name=listing_name, category="furniture",
                          price=9_000.0, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        db.add(NegotiationMessage(listing_id=listing.id, sender_id=buyer_id, role="buyer",
                                  content="Is it still available?", buyer_id=buyer_id))
        await db.commit()
        return listing.id


class TestReviewsAreDealOnly:
    """2026-10-22: a conversation is not a purchase. Only the buyer of a
    deal may review - the guard random commenters were slipping past."""

    @pytest.mark.asyncio
    async def test_an_agreed_deal_can_be_reviewed(self, client):
        seller_id, _ = await _user("Agreed Seller")
        buyer_id, as_buyer = await _user("Agreed Buyer")
        deal = await _deal(seller_id, buyer_id, DealStatus.agreed)
        [offered] = (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                      headers=as_buyer)).json()["deals"]
        assert offered["deal_id"] == deal
        assert offered["status"] == "agreed"
        res = await client.post("/reviews/", json={"deal_id": deal, "rating": 5},
                                headers=as_buyer)
        assert res.status_code == 201

    @pytest.mark.asyncio
    async def test_a_cancelled_deal_is_not_a_purchase(self, client):
        seller_id, _ = await _user("Cancel Seller")
        buyer_id, as_buyer = await _user("Cancel Buyer")
        deal = await _deal(seller_id, buyer_id, DealStatus.cancelled)
        res = await client.post("/reviews/", json={"deal_id": deal, "rating": 1},
                                headers=as_buyer)
        assert res.status_code == 400
        assert (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                 headers=as_buyer)).json() == {"deals": []}

    @pytest.mark.asyncio
    async def test_a_refunded_deal_is_not_a_purchase(self, client):
        seller_id, _ = await _user("Refund Seller")
        buyer_id, as_buyer = await _user("Refund Buyer")
        deal = await _deal(seller_id, buyer_id, DealStatus.refunded)
        res = await client.post("/reviews/", json={"deal_id": deal, "rating": 1},
                                headers=as_buyer)
        assert res.status_code == 400

    @pytest.mark.asyncio
    async def test_a_buyer_who_only_talked_has_nothing_to_review(self, client):
        """The regression: anyone who opened a chat could post a review, so a
        stranger could leave a wrong comment about a seller."""
        seller_id, _ = await _user("Chatty Seller")
        buyer_id, as_buyer = await _user("Chatty Buyer")
        await _talk(seller_id, buyer_id, "Sofa")
        await _talk(seller_id, buyer_id, "Table")
        assert (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                 headers=as_buyer)).json() == {"deals": []}
        res = await client.post("/reviews/", json={"deal_id": f"chat:{seller_id}",
                                                    "rating": 4}, headers=as_buyer)
        assert res.status_code == 403
        assert "deal" in res.json()["detail"].lower()
        # Nothing was written: the seller's record is untouched.
        summary = (await client.get(f"/reviews/summary/{seller_id}")).json()
        assert summary["count"] == 0

    @pytest.mark.asyncio
    async def test_a_stranger_who_never_talked_cannot_review(self, client):
        seller_id, _ = await _user("Quiet Seller")
        _, as_stranger = await _user("Drive By")
        res = await client.post("/reviews/", json={"deal_id": f"chat:{seller_id}", "rating": 1},
                                headers=as_stranger)
        assert res.status_code == 403
        assert (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                 headers=as_stranger)).json() == {"deals": []}

    @pytest.mark.asyncio
    async def test_no_one_reviews_themselves_through_a_chat(self, client):
        self_id, as_self = await _user("Own Chat")
        await _talk(self_id, self_id)
        res = await client.post("/reviews/", json={"deal_id": f"chat:{self_id}", "rating": 5},
                                headers=as_self)
        assert res.status_code == 403


class TestReviewing:
    @pytest.mark.asyncio
    async def test_a_review_is_posted_once_and_shows_on_the_profile(self, client, market):
        seller_id, _ = market["seller"]
        _, as_buyer = market["buyer"]

        empty = (await client.get(f"/reviews/summary/{seller_id}")).json()
        # No reviews is no average - not 0, and not the 5.0 User.rating starts at.
        assert empty == {"avg": None, "count": 0,
                         "distribution": {"1": 0, "2": 0, "3": 0, "4": 0, "5": 0}}

        res = await client.post("/reviews/", json={
            "deal_id": market["done"], "rating": 4, "comment": "Phone as described."},
            headers=as_buyer)
        assert res.status_code == 201
        again = await client.post("/reviews/", json={"deal_id": market["done"], "rating": 5},
                                  headers=as_buyer)
        assert again.status_code == 409

        summary = (await client.get(f"/reviews/summary/{seller_id}")).json()
        assert summary == {"avg": 4.0, "count": 1,
                           "distribution": {"1": 0, "2": 0, "3": 0, "4": 1, "5": 0}}

        [card] = (await client.get(f"/reviews/seller/{seller_id}")).json()
        assert card["rating"] == 4
        assert card["comment"] == "Phone as described."
        # First name and initial: reviews are public, the full name is not.
        assert card["reviewer_name"] == "Amina W."

        # Reviewed, so nothing is left for this buyer to review of this seller.
        [deal] = (await client.get("/reviews/my-deals", params={"seller_id": seller_id},
                                   headers=as_buyer)).json()["deals"]
        assert deal["already_reviewed"] is True

        async with AsyncSessionLocal() as db:
            reviews = (await db.execute(
                select(Review).where(Review.seller_id == seller_id))).scalars().all()
            assert len(reviews) == 1

    @pytest.mark.asyncio
    async def test_reviews_page(self, client):
        seller_id, _ = await _user("Busy Seller")
        for i in range(3):
            buyer_id, as_buyer = await _user(f"Buyer{i} Test")
            deal = await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(hours=1))
            res = await client.post("/reviews/", json={"deal_id": deal, "rating": 5},
                                    headers=as_buyer)
            assert res.status_code == 201
        first = (await client.get(f"/reviews/seller/{seller_id}", params={"limit": 2})).json()
        rest = (await client.get(f"/reviews/seller/{seller_id}",
                                 params={"limit": 2, "offset": 2})).json()
        assert len(first) == 2 and len(rest) == 1
        assert not {r["id"] for r in first} & {r["id"] for r in rest}


class TestDealCompletionRateOff:
    """DCR_ENABLED off (the default, 2026-10-12): with payments made outside
    BROKA a completed deal can't be told from an abandoned one, so every
    seller scores the neutral prior and buyers are shown no rate."""

    @pytest.mark.asyncio
    async def test_every_seller_scores_the_neutral_prior(self):
        from api.database import SellerMetrics
        from api.domains.trust.completion_rate import PRIOR_MEAN, recompute_all_dcr
        seller_id, _ = await _user("Ranked Seller")
        buyer_id, _ = await _user("Ranked Buyer")
        for _ in range(3):
            await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(hours=1))
        async with AsyncSessionLocal() as db:
            await recompute_all_dcr(db)
            metrics = await db.get(SellerMetrics, seller_id)
            assert metrics.dcr_score == round(PRIOR_MEAN * 100, 2)

    @pytest.mark.asyncio
    async def test_buyers_and_the_seller_are_shown_no_rate(self, client):
        seller_id, as_seller = await _user("Unrated Seller")
        buyer_id, as_buyer = await _user("Unrated Buyer")
        await _deal(seller_id, buyer_id, DealStatus.released, took=timedelta(hours=1))
        from api.domains.trust.completion_rate import recompute_all_dcr
        async with AsyncSessionLocal() as db:
            await recompute_all_dcr(db)
        own = (await client.get(f"/auth/user/{seller_id}", headers=as_seller)).json()
        assert own.get("dcr_score") is None
