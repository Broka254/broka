"""Reviews and seller ratings: the contract every surface relies on.

  * a review comment is at most 500 characters and is either saved whole
    or refused - never silently cut;
  * a public review carries no deal, reviewer or seller id;
  * a seller with no reviews has NO average anywhere (store page, trader
    card, listing card, profile) - User.rating's 5.0 starting value is
    not a score anyone gave;
  * a store page tells a signed-in buyer whether they can still review a
    purchase from that shop, using only their own deals for THAT shop;
  * a review survives a later refund/dispute: status decides whether one
    may be written, not whether the record of what happened is erased.
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from main import app
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, Review, User,
    init_db, reset_engine,
)
from api.models.store import Store
from api.security import create_access_token


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_reviews_hardening.db"
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


_seq = itertools.count(1)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def _user(name: str, *, completed_deals: int = 0) -> tuple[str, dict]:
    async with AsyncSessionLocal() as db:
        user = User(
            name=name, phone=f"0755{next(_seq):06d}", password_hash="x",
            phone_verified=True, completed_deals=completed_deals,
        )
        db.add(user)
        await db.commit()
        return user.id, _auth(create_access_token({"sub": user.id}))


async def _store(owner_id: str, name: str) -> str:
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner_id, name=name, slug=f"test-shop-{next(_seq)}")
        db.add(store)
        await db.commit()
        return store.id


async def _listing(seller_id: str, *, store_id: str | None = None,
                   name: str = "Samsung A54") -> str:
    async with AsyncSessionLocal() as db:
        listing = Listing(
            seller_id=seller_id, name=name, category="electronics",
            price=20_000.0, store_id=store_id, lat=-1.28, lng=36.82,
        )
        db.add(listing)
        await db.commit()
        return listing.id


async def _deal(seller_id: str, buyer_id: str, listing_id: str,
                status: DealStatus = DealStatus.paid) -> str:
    async with AsyncSessionLocal() as db:
        deal = Deal(
            listing_id=listing_id, seller_id=seller_id, buyer_id=buyer_id,
            agreed_price=20_000.0, commission=0, status=status,
            created_at=datetime.utcnow() - timedelta(days=2),
        )
        db.add(deal)
        await db.commit()
        return deal.id


async def _review(client, headers, deal_id: str, rating: int,
                  comment: str | None = None):
    body = {"deal_id": deal_id, "rating": rating}
    if comment is not None:
        body["comment"] = comment
    return await client.post("/reviews/", json=body, headers=headers)


# ── Comment contract ────────────────────────────────────────────────────────


class TestCommentContract:
    @pytest.mark.asyncio
    async def test_the_limit_matches_the_form_and_long_comments_are_refused(self, client):
        seller_id, _ = await _user("Limit Seller")
        buyer_id, as_buyer = await _user("Limit Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))

        too_long = await _review(client, as_buyer, deal, 5, "a" * 501)
        assert too_long.status_code == 422
        async with AsyncSessionLocal() as db:
            assert (await db.execute(
                select(Review).where(Review.deal_id == deal))).first() is None

        exact = await _review(client, as_buyer, deal, 5, "b" * 500)
        assert exact.status_code == 201, exact.text
        assert exact.json()["comment"] == "b" * 500
        async with AsyncSessionLocal() as db:
            saved = (await db.execute(
                select(Review.comment).where(Review.deal_id == deal))).scalar_one()
        assert len(saved) == 500

    @pytest.mark.asyncio
    async def test_comment_whitespace_is_trimmed_and_never_invented(self, client):
        seller_id, _ = await _user("Trim Seller")
        buyer_id, as_buyer = await _user("Trim Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))

        res = await _review(client, as_buyer, deal, 4, "  Phone as described.  ")
        assert res.status_code == 201, res.text
        assert res.json()["comment"] == "Phone as described."

        other_id, as_other = await _user("Blank Buyer")
        blank_deal = await _deal(seller_id, other_id, await _listing(seller_id))
        blank = await _review(client, as_other, blank_deal, 5, "   \n  ")
        assert blank.status_code == 201
        assert blank.json()["comment"] == ""

    @pytest.mark.asyncio
    async def test_ratings_outside_one_to_five_are_refused(self, client):
        seller_id, _ = await _user("Star Seller")
        buyer_id, as_buyer = await _user("Star Buyer")
        listing = await _listing(seller_id)

        for rating in (0, 6, -1, 4.5):
            deal = await _deal(seller_id, buyer_id, listing)
            res = await _review(client, as_buyer, deal, rating)
            assert res.status_code == 422, (rating, res.text)

        for rating in (1, 5):
            deal = await _deal(seller_id, buyer_id, listing)
            res = await _review(client, as_buyer, deal, rating)
            assert res.status_code == 201, (rating, res.text)


# ── What a public review may say ────────────────────────────────────────────


class TestPublicReviewShape:
    @pytest.mark.asyncio
    async def test_seller_reviews_expose_no_internal_ids(self, client):
        seller_id, _ = await _user("Private Seller")
        buyer_id, as_buyer = await _user("Amina Wanjiku")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))
        posted = await _review(client, as_buyer, deal, 5, "Exactly as described")
        assert posted.status_code == 201

        public_keys = {"id", "rating", "comment", "created_at", "reviewer_name"}
        assert set(posted.json()) == public_keys

        [card] = (await client.get(f"/reviews/seller/{seller_id}")).json()
        assert set(card) == public_keys
        assert card["reviewer_name"] == "Amina W."
        for forbidden in ("deal_id", "reviewer_id", "seller_id"):
            assert forbidden not in card

    @pytest.mark.asyncio
    async def test_store_reviews_expose_no_internal_ids(self, client):
        seller_id, _ = await _user("Store Private Seller")
        buyer_id, as_buyer = await _user("Store Buyer")
        store_id = await _store(seller_id, "Private Shop")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id, store_id=store_id))
        assert (await _review(client, as_buyer, deal, 4, "Good")).status_code == 201

        body = (await client.get(f"/stores/{store_id}/reviews")).json()
        [card] = body["reviews"]
        assert set(card) == {"id", "rating", "comment", "created_at", "reviewer_name"}
        for forbidden in ("deal_id", "reviewer_id", "seller_id"):
            assert forbidden not in card


# ── Store attribution, summary and the viewer's own eligibility ─────────────


class TestStoreScopeAndViewer:
    @pytest.mark.asyncio
    async def test_store_summary_counts_only_that_shop_and_sums_the_distribution(self, client):
        seller_id, _ = await _user("Two Shops")
        first = await _store(seller_id, "First Shop")
        second = await _store(seller_id, "Second Shop")
        first_listing = await _listing(seller_id, store_id=first, name="Phone")
        second_listing = await _listing(seller_id, store_id=second, name="Sofa")

        for rating in (5, 4, 4):
            buyer_id, as_buyer = await _user(f"Shop Buyer {rating}")
            deal = await _deal(seller_id, buyer_id, first_listing)
            assert (await _review(client, as_buyer, deal, rating)).status_code == 201
        other_id, as_other = await _user("Second Shop Buyer")
        deal = await _deal(seller_id, other_id, second_listing)
        assert (await _review(client, as_other, deal, 1)).status_code == 201

        body = (await client.get(f"/stores/{first}/reviews")).json()
        summary = body["summary"]
        assert summary["count"] == 3
        assert summary["avg"] == 4.3
        assert summary["distribution"] == {"1": 0, "2": 0, "3": 0, "4": 2, "5": 1}
        assert sum(summary["distribution"].values()) == summary["count"]
        assert len(body["reviews"]) == 3

        second_body = (await client.get(f"/stores/{second}/reviews")).json()
        assert second_body["summary"] == {
            "avg": 1.0, "count": 1,
            "distribution": {"1": 1, "2": 0, "3": 0, "4": 0, "5": 0},
        }

    @pytest.mark.asyncio
    async def test_a_store_page_offers_only_its_own_sales_and_reflects_the_review(
        self, client,
    ):
        seller_id, _ = await _user("Viewer Seller")
        first = await _store(seller_id, "Viewer Shop")
        second = await _store(seller_id, "Other Viewer Shop")
        first_listing = await _listing(seller_id, store_id=first, name="Phone")
        second_listing = await _listing(seller_id, store_id=second, name="Sofa")
        buyer_id, as_buyer = await _user("Viewer Buyer")
        first_deal = await _deal(seller_id, buyer_id, first_listing)
        await _deal(seller_id, buyer_id, second_listing)

        anonymous = (await client.get(f"/stores/{first}/reviews")).json()
        assert "viewer" not in anonymous

        body = (await client.get(f"/stores/{first}/reviews", headers=as_buyer)).json()
        viewer = body["viewer"]
        assert viewer["can_review"] is True
        assert viewer["already_reviewed"] is False
        # The other shop's sale is not offered here - it would land on the
        # wrong shop if the buyer picked it.
        assert [d["deal_id"] for d in viewer["reviewable_deals"]] == [first_deal]
        assert viewer["reviewable_deals"][0]["listing_name"] == "Phone"

        assert (await _review(client, as_buyer, first_deal, 5)).status_code == 201
        after = (await client.get(f"/stores/{first}/reviews", headers=as_buyer)).json()
        assert after["viewer"]["can_review"] is False
        assert after["viewer"]["already_reviewed"] is True

        # A shopper with no deal at this shop is neither eligible nor a
        # returning reviewer.
        _, as_stranger = await _user("Viewer Stranger")
        stranger = (await client.get(f"/stores/{first}/reviews", headers=as_stranger)).json()
        assert stranger["viewer"]["can_review"] is False
        assert stranger["viewer"]["already_reviewed"] is False
        assert stranger["viewer"]["reviewable_deals"] == []


# ── No reviews means no average, on every surface ───────────────────────────


class TestNoReviewsNoAverage:
    @pytest.mark.asyncio
    async def test_every_surface_says_no_reviews_until_one_is_written(self, client):
        seller_id, as_seller = await _user("Fresh Seller", completed_deals=2)
        store_id = await _store(seller_id, "Fresh Shop")
        listing_id = await _listing(seller_id, store_id=store_id, name="Fresh Item")
        _, as_viewer = await _user("Profile Viewer")

        store = (await client.get(f"/stores/{store_id}")).json()
        # The shop's own composite (0-10) starts at the documented neutral
        # anchor; the person's buyer rating has no value yet.
        assert store["rating"] == 6.5
        assert store["review_count"] == 0
        assert store["owner"]["rating"] is None
        assert store["owner"]["review_count"] == 0

        listing = (await client.get(f"/listings/{listing_id}")).json()
        assert listing["seller_rating"] is None
        assert listing["seller_review_count"] == 0
        assert listing["seller_completed_deals"] == 2

        traders = (await client.get("/traders", params={"limit": 100})).json()
        [card] = [t for t in traders if t["id"] == seller_id]
        assert card["rating"] is None
        assert card["review_count"] == 0

        profile = (await client.get(f"/traders/{seller_id}")).json()
        assert profile["rating"] is None
        assert profile["review_avg"] is None
        assert profile["review_count"] == 0

        public = (await client.get(f"/auth/user/{seller_id}", headers=as_viewer)).json()
        assert public["rating"] is None
        assert public["review_count"] == 0

        mine = (await client.get("/auth/me", headers=as_seller)).json()
        assert mine["rating"] is None
        assert mine["review_count"] == 0

    @pytest.mark.asyncio
    async def test_one_review_fills_every_surface_with_the_real_average(self, client):
        seller_id, as_seller = await _user("Rated Seller", completed_deals=1)
        store_id = await _store(seller_id, "Rated Shop")
        listing_id = await _listing(seller_id, store_id=store_id, name="Rated Item")
        buyer_id, as_buyer = await _user("Rated Buyer")
        deal = await _deal(seller_id, buyer_id, listing_id)
        assert (await _review(client, as_buyer, deal, 4)).status_code == 201

        store = (await client.get(f"/stores/{store_id}")).json()
        assert store["owner"]["rating"] == 4.0
        assert store["owner"]["review_count"] == 1
        assert store["review_count"] == 1

        listing = (await client.get(f"/listings/{listing_id}")).json()
        assert listing["seller_rating"] == 4.0
        assert listing["seller_review_count"] == 1

        traders = (await client.get("/traders", params={"limit": 100})).json()
        [card] = [t for t in traders if t["id"] == seller_id]
        assert card["rating"] == 4.0
        assert card["review_count"] == 1

        profile = (await client.get(f"/traders/{seller_id}")).json()
        assert profile["rating"] == 4.0
        assert profile["review_avg"] == 4.0
        assert profile["review_count"] == 1

        mine = (await client.get("/auth/me", headers=as_seller)).json()
        assert mine["rating"] == 4.0
        assert mine["review_count"] == 1

        summary = (await client.get(f"/reviews/summary/{seller_id}")).json()
        assert summary == {
            "avg": 4.0, "count": 1,
            "distribution": {"1": 0, "2": 0, "3": 0, "4": 1, "5": 0},
        }


# ── A later refund does not erase the review ────────────────────────────────


class TestAfterSubmission:
    @pytest.mark.asyncio
    async def test_a_review_stays_after_the_deal_is_refunded(self, client):
        seller_id, _ = await _user("Refunded Seller")
        buyer_id, as_buyer = await _user("Refunded Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))
        assert (await _review(client, as_buyer, deal, 2, "Arrived damaged")).status_code == 201

        async with AsyncSessionLocal() as db:
            row = await db.get(Deal, deal)
            row.status = DealStatus.refunded
            await db.commit()

        summary = (await client.get(f"/reviews/summary/{seller_id}")).json()
        assert summary["count"] == 1
        assert summary["avg"] == 2.0
        [card] = (await client.get(f"/reviews/seller/{seller_id}")).json()
        assert card["comment"] == "Arrived damaged"

        # The refund changes what the deal is now: a second review is
        # refused (as a refunded deal, or as an already-reviewed one -
        # both guards hold the line). Nothing is overwritten.
        again = await _review(client, as_buyer, deal, 5)
        assert again.status_code in (400, 409)
        async with AsyncSessionLocal() as db:
            assert len((await db.execute(
                select(Review).where(Review.deal_id == deal))).all()) == 1


# ── Who may review, and only once ───────────────────────────────────────────


class TestReviewEligibility:
    @pytest.mark.asyncio
    async def test_only_the_buyer_of_that_deal_may_review_it(self, client):
        seller_id, _ = await _user("Eligible Seller")
        buyer_id, _ = await _user("Eligible Buyer")
        _, as_other = await _user("Other Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))

        res = await _review(client, as_other, deal, 5)
        assert res.status_code == 403
        async with AsyncSessionLocal() as db:
            assert (await db.execute(
                select(Review).where(Review.deal_id == deal))).first() is None

    @pytest.mark.asyncio
    async def test_a_seller_cannot_review_themselves(self, client):
        seller_id, as_seller = await _user("Self Reviewer")
        # A deal an account opened with itself: the buyer check passes
        # because the ids match, so the self-review guard must hold.
        deal = await _deal(seller_id, seller_id, await _listing(seller_id))

        res = await _review(client, as_seller, deal, 5)
        assert res.status_code == 403
        async with AsyncSessionLocal() as db:
            assert (await db.execute(
                select(Review).where(Review.deal_id == deal))).first() is None

    @pytest.mark.asyncio
    async def test_a_cancelled_or_refunded_deal_cannot_be_reviewed(self, client):
        seller_id, _ = await _user("Unwound Seller")
        buyer_id, as_buyer = await _user("Unwound Buyer")
        listing = await _listing(seller_id)

        for status in (DealStatus.cancelled, DealStatus.refunded):
            deal = await _deal(seller_id, buyer_id, listing, status=status)
            res = await _review(client, as_buyer, deal, 5)
            assert res.status_code == 400, (status, res.text)
            async with AsyncSessionLocal() as db:
                assert (await db.execute(
                    select(Review).where(Review.deal_id == deal))).first() is None

    @pytest.mark.asyncio
    async def test_a_second_review_of_the_same_deal_is_refused(self, client):
        seller_id, _ = await _user("One Review Seller")
        buyer_id, as_buyer = await _user("One Review Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))

        assert (await _review(client, as_buyer, deal, 5, "First")).status_code == 201
        second = await _review(client, as_buyer, deal, 1, "Second")
        assert second.status_code == 409
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(
                select(Review).where(Review.deal_id == deal))).scalars().all()
        assert len(rows) == 1
        assert rows[0].comment == "First"

    @pytest.mark.asyncio
    async def test_the_database_refuses_a_duplicate_even_without_the_service_check(self):
        """Two submissions sent together both pass `_already_reviewed`;
        the unique index is what actually holds the one-review rule."""
        seller_id, _ = await _user("Race Seller")
        buyer_id, _ = await _user("Race Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))

        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=deal, reviewer_id=buyer_id,
                          seller_id=seller_id, rating=5))
            await db.commit()

        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=deal, reviewer_id=buyer_id,
                          seller_id=seller_id, rating=1))
            with pytest.raises(IntegrityError):
                await db.commit()
            await db.rollback()


# ── The store score moves with the review ───────────────────────────────────


class TestStoreCompositeRefresh:
    @pytest.mark.asyncio
    async def test_a_review_refreshes_the_stored_store_rating_immediately(self, client):
        seller_id, _ = await _user("Composite Seller")
        store_id = await _store(seller_id, "Composite Shop")
        buyer_id, as_buyer = await _user("Composite Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id, store_id=store_id))

        before = (await client.get(f"/stores/{store_id}")).json()
        assert before["rating"] == 6.5
        assert before["review_count"] == 0

        assert (await _review(client, as_buyer, deal, 5)).status_code == 201

        after = (await client.get(f"/stores/{store_id}")).json()
        assert after["review_count"] == 1
        # Five stars on a brand-new shop: 0.55 * ((5+20)/6/5) + 0.30 * 0.7
        # + ~0 tenure = 6.68, not the 5.5 a flat star average would give and
        # not the untouched 6.5 a missed refresh would leave.
        assert after["rating"] == pytest.approx(6.68, abs=0.05)
        async with AsyncSessionLocal() as db:
            stored = (await db.execute(
                select(Store.rating).where(Store.id == store_id))).scalar_one()
        assert stored == pytest.approx(6.68, abs=0.05)


# ── Legacy rating defaults must not leak into ranking or prompts ────────────


class TestLegacyDefaultDoesNotLeak:
    @pytest.mark.asyncio
    async def test_traders_with_real_reviews_rank_above_unreviewed_ones(self, client):
        reviewed_id, _ = await _user("Ranked Reviewed", completed_deals=3)
        unreviewed_id, _ = await _user("Ranked Unreviewed", completed_deals=3)
        buyer_id, as_buyer = await _user("Ranked Buyer")
        listing = await _listing(reviewed_id)
        deal = await _deal(reviewed_id, buyer_id, listing)
        assert (await _review(client, as_buyer, deal, 4)).status_code == 201

        traders = (await client.get("/traders", params={"limit": 100})).json()
        ids = [t["id"] for t in traders]
        # The unreviewed account's User.rating is still the 5.0 default;
        # ranking on that column put it first. A real 4.0 must win.
        assert ids.index(reviewed_id) < ids.index(unreviewed_id)

    @pytest.mark.asyncio
    async def test_zenos_trust_map_reads_reviews_not_the_user_column(self):
        from api.domains.buy_agent.actions import _seller_trust_map, _trust_score

        reviewed_id, _ = await _user("Trust Reviewed")
        unreviewed_id, _ = await _user("Trust Unreviewed")
        buyer_id, _ = await _user("Trust Buyer")
        deal = await _deal(reviewed_id, buyer_id, await _listing(reviewed_id))
        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=deal, reviewer_id=buyer_id,
                          seller_id=reviewed_id, rating=4))
            await db.commit()

        async with AsyncSessionLocal() as db:
            trust = await _seller_trust_map(db, {reviewed_id, unreviewed_id})

        assert trust[reviewed_id]["rating"] == 4.0
        assert trust[reviewed_id]["review_count"] == 1
        assert trust[unreviewed_id]["rating"] is None
        assert trust[unreviewed_id]["review_count"] == 0
        assert _trust_score({"seller_id": reviewed_id}, trust) > \
            _trust_score({"seller_id": unreviewed_id}, trust)

    @pytest.mark.asyncio
    async def test_zenos_context_never_quotes_the_unearned_default(self):
        from api.routers.negotiate import _context_block

        fresh_id, _ = await _user("Prompt Fresh")
        rated_id, _ = await _user("Prompt Rated")
        buyer_id, _ = await _user("Prompt Buyer")
        fresh_listing = await _listing(fresh_id, name="Fresh")
        rated_listing = await _listing(rated_id, name="Rated")
        deal = await _deal(rated_id, buyer_id, rated_listing)
        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=deal, reviewer_id=buyer_id,
                          seller_id=rated_id, rating=4))
            await db.commit()

        async with AsyncSessionLocal() as db:
            fresh_block = await _context_block(
                db, await db.get(Listing, fresh_listing), await db.get(User, fresh_id),
                "Prompt Buyer", "")
            rated_block = await _context_block(
                db, await db.get(Listing, rated_listing), await db.get(User, rated_id),
                "Prompt Buyer", "")
        assert "Seller rating:     no buyer reviews yet" in fresh_block
        assert "5.0/5.0" not in fresh_block
        assert "Seller rating:     4.0/5.0 from 1 buyer review" in rated_block

    @pytest.mark.asyncio
    async def test_releasing_a_deal_does_not_invent_stars(self, client):
        seller_id, _ = await _user("Release Seller", completed_deals=4)
        buyer_id, as_buyer = await _user("Release Buyer")
        deal = await _deal(seller_id, buyer_id, await _listing(seller_id))
        async with AsyncSessionLocal() as db:
            seller = await db.get(User, seller_id)
            seller.rating = 4.0
            await db.commit()

        res = await client.post(f"/escrow/confirm-delivery/{deal}", headers=as_buyer)
        assert res.status_code == 200, res.text

        async with AsyncSessionLocal() as db:
            seller = await db.get(User, seller_id)
        assert seller.completed_deals == 5
        assert seller.rating == 4.0

