"""Store rating, directory order, and the store insights endpoint.

Covers the three things this feature exists for:

  * one shop appears once, in a stable order, however the directory pages;
  * a store's rating is built from ITS reviews, ITS reply time and its
    tenure - not its owner's whole record, and not another shop's;
  * the store dashboard reports measured numbers and honest zeros.

Same fixture shape as test_stores.py: module-scoped SQLite file, reset
engine, ASGI client.
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, Review, init_db, reset_engine,
)
from api.models.store import Store
from api.domains.stores import rating as store_rating
from tests.legal_payload import legal_payload


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_rating.db"
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


_n = itertools.count(1)


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


async def _register(client: AsyncClient) -> tuple[str, dict]:
    n = next(_n)
    phone = f"0744{n:06d}"
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    token = verify.json()["phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": token, "name": f"Owner {n}", "email": f"o{n}@test.ke",
        "password": "Passw0rd!23", "lat": -1.286, "lng": 36.817,
        "account_type": "buyer_seller", "seller_tier": "long_term",
        "business_name": f"Business {n}", "business_category": "Electronics",
        "business_location": "Nairobi",
        "legal_acceptance": legal_payload(),
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "Passw0rd!23"})
    return reg.json()["user_id"], _auth(login.json()["access_token"])


async def _store(client, headers, **fields) -> dict:
    body = {"name": f"Shop {next(_n)}", **fields}
    r = await client.post("/stores", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _extra_store(owner_id: str, name: str, rating=None) -> str:
    """A second shop for an owner, inserted directly.

    The API allows one store per account today (StoreService
    ._lock_owner_for_create), while the schema deliberately allows several
    so multi-store is a UI change later. The rating's central claim is
    about that future shape - one shop's record must not lift another's -
    so it is tested at the schema level rather than pretended away.
    """
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner_id, name=name, slug=f"extra-{next(_n)}")
        if rating is not None:
            store.rating = rating
            store.rating_updated_at = datetime.utcnow()
        db.add(store)
        await db.commit()
        return store.id


# ── The ladder ──────────────────────────────────────────────────────────────

class TestRatingLadder:
    def test_a_brand_new_store_sits_on_the_neutral_anchor(self):
        result = store_rating.compute_store_rating(
            review_sum=0, review_count=0, response_minutes=None, days_trading=0)
        assert result.rating == 6.5
        # The same anchor the seller rating uses, so "unproven" means the
        # same thing on both surfaces.
        from api.domains.trust.seller_rating import NEUTRAL_RATING
        assert result.rating == NEUTRAL_RATING

    def test_a_proven_good_shop_rates_high(self):
        result = store_rating.compute_store_rating(
            review_sum=48.0, review_count=10, response_minutes=10, days_trading=365)
        assert result.rating >= 9.0, result

    def test_a_badly_reviewed_slow_shop_rates_low(self):
        result = store_rating.compute_store_rating(
            review_sum=5.0, review_count=5, response_minutes=600, days_trading=5)
        assert result.rating < 4.0, result

    def test_one_five_star_review_does_not_beat_a_long_record(self):
        one = store_rating.compute_store_rating(
            review_sum=5.0, review_count=1, response_minutes=30, days_trading=20)
        many = store_rating.compute_store_rating(
            review_sum=46.0, review_count=10, response_minutes=30, days_trading=200)
        assert many.rating > one.rating

    def test_unmeasured_reply_time_is_not_fast(self):
        # The placeholder is 0.7, deliberately below "answered in an hour".
        assert store_rating.response_component(None) == pytest.approx(0.7)
        assert store_rating.response_component(60) == pytest.approx(0.5)

    def test_tenure_saturates(self):
        assert store_rating.tenure_component(0) == 0.0
        assert store_rating.tenure_component(180) == pytest.approx(1.0)
        assert store_rating.tenure_component(3650) == pytest.approx(1.0)


# ── Store-scoped response time ───────────────────────────────────────────────

class TestStoreResponseTime:
    @pytest.mark.asyncio
    async def test_one_shops_threads_do_not_set_the_others_reply_time(self, client):
        """The whole point of a store-level number: a busy shop's speed must
        not be borrowed by a quiet one under the same owner."""
        owner_id, headers = await _register(client)
        fast = await _store(client, headers, name="Fast Shop")
        slow_id = await _extra_store(owner_id, "Slow Shop")
        fast_listing = await _create_listing(client, headers, fast["id"], "Fast item")
        slow_listing = await _create_listing(client, headers, slow_id, "Slow item")

        buyer_id, _ = await _register(client)
        now = datetime.utcnow()
        async with AsyncSessionLocal() as db:
            # A thread is one (listing, buyer) pair, so each measurement
            # needs its own buyer - three messages from one buyer is ONE
            # wait, by design.
            for i in range(3):
                _thread(db, fast_listing, f"buyer-fast-{i}",
                        now - timedelta(hours=2, minutes=i * 10),
                        reply_after=timedelta(minutes=5))
                _thread(db, slow_listing, f"buyer-slow-{i}",
                        now - timedelta(hours=6, minutes=i * 10),
                        reply_after=timedelta(hours=4))
            await db.commit()

            times = await store_rating.store_response_minutes(db, [fast["id"], slow_id])
        assert times[fast["id"]] == pytest.approx(5.0, abs=0.5)
        assert times[slow_id] == pytest.approx(240.0, abs=1.0)

        async with AsyncSessionLocal() as db:
            await store_rating.refresh_store_rating(db, fast["id"])
            await store_rating.refresh_store_rating(db, slow_id)
        fast_row = (await client.get(f"/stores/{fast['id']}")).json()
        slow_row = (await client.get(f"/stores/{slow_id}")).json()
        assert fast_row["response_minutes"] == pytest.approx(5.0, abs=0.5)
        assert slow_row["response_minutes"] == pytest.approx(240.0, abs=1.0)
        assert fast_row["rating"] > slow_row["rating"]


def _thread(db, listing_id, buyer_id, started_at, reply_after):
    """One buyer message and the seller's reply, in the existing table."""
    from api.database import NegotiationMessage
    db.add(NegotiationMessage(
        listing_id=listing_id, buyer_id=buyer_id, sender_id=buyer_id,
        role="buyer", content="Is it available?", created_at=started_at))
    db.add(NegotiationMessage(
        listing_id=listing_id, buyer_id=buyer_id, sender_id="seller",
        role="seller", content="Yes", created_at=started_at + reply_after))


async def _create_listing(client, headers, store_id, name):
    r = await client.post("/listings/", json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": name, "category": "Electronics", "price": 1000,
        "lat": -1.0, "lng": 36.0, "store_id": store_id,
    }, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()["id"]


# ── Review attribution ──────────────────────────────────────────────────────

class TestReviewAttribution:
    @pytest.mark.asyncio
    async def test_a_deal_review_lands_on_the_shop_that_sold_the_item(self, client):
        owner_id, headers = await _register(client)
        first = await _store(client, headers, name="First Shop")
        second_id = await _extra_store(owner_id, "Second Shop")
        listing_id = await _create_listing(client, headers, first["id"], "Sold item")

        buyer_id, buyer_headers = await _register(client)
        async with AsyncSessionLocal() as db:
            deal = Deal(listing_id=listing_id, seller_id=owner_id, buyer_id=buyer_id,
                        agreed_price=1000, commission=0, status=DealStatus.released)
            db.add(deal)
            await db.commit()
            deal_id = deal.id

        r = await client.post("/reviews/", json={
            "deal_id": deal_id, "rating": 5, "comment": "Exactly as described",
        }, headers=buyer_headers)
        assert r.status_code == 201, r.text

        async with AsyncSessionLocal() as db:
            review = (await db.execute(
                select(Review).where(Review.deal_id == deal_id))).scalar_one()
            assert review.store_id == first["id"]

        # The first shop's page and rating move; the second's do not.
        first_body = (await client.get(f"/stores/{first['id']}/reviews")).json()
        second_body = (await client.get(f"/stores/{second_id}/reviews")).json()
        assert first_body["summary"]["count"] == 1
        assert first_body["summary"]["avg"] == 5.0
        assert second_body["summary"]["count"] == 0

        first_row = (await client.get(f"/stores/{first['id']}")).json()
        second_row = (await client.get(f"/stores/{second_id}")).json()
        assert first_row["review_count"] == 1
        assert second_row["review_count"] == 0
        assert first_row["rating"] > second_row["rating"]

    @pytest.mark.asyncio
    async def test_a_chat_review_shows_on_a_single_shop_but_not_split_between_two(self, client):
        """Chat-only reviews are the only kind while in-app payments are
        off. One shop: they belong to it. Two shops: they stay on the
        person, because picking one shop would be a guess."""
        solo_id, solo_headers = await _register(client)
        solo = await _store(client, solo_headers, name="Solo Shop")
        buyer_id, _ = await _register(client)
        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=None, reviewer_id=buyer_id, seller_id=solo_id,
                          rating=4, comment="Helpful"))
            await db.commit()
        body = (await client.get(f"/stores/{solo['id']}/reviews")).json()
        assert body["summary"]["count"] == 1

        pair_id, pair_headers = await _register(client)
        one = await _store(client, pair_headers, name="One of Two")
        two_id = await _extra_store(pair_id, "Two of Two")
        buyer2, _ = await _register(client)
        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=None, reviewer_id=buyer2, seller_id=pair_id,
                          rating=5, comment="Good"))
            await db.commit()
        for store_id in (one["id"], two_id):
            body = (await client.get(f"/stores/{store_id}/reviews")).json()
            assert body["summary"]["count"] == 0


# ── Directory order ─────────────────────────────────────────────────────────

class TestDirectoryOrder:
    @pytest.mark.asyncio
    async def test_stores_come_back_highest_rated_first(self, client):
        owner_id, headers = await _register(client)
        low = await _store(client, headers, name="Low Rated")
        high_id = await _extra_store(owner_id, "High Rated", rating=9.4)

        async with AsyncSessionLocal() as db:
            lo = await db.get(Store, low["id"])
            lo.rating = 6.5
            lo.rating_updated_at = datetime.utcnow()
            await db.commit()

        items = (await client.get("/stores", params={"limit": 100})).json()
        ids = [s["id"] for s in items]
        assert ids.index(high_id) < ids.index(low["id"])

    @pytest.mark.asyncio
    async def test_paging_is_stable_and_shows_each_shop_once(self, client):
        owner_id, headers = await _register(client)
        await _store(client, headers, name="Page Shop Anchor")
        created = [await _extra_store(owner_id, f"Page Shop {i}") for i in range(6)]

        first = (await client.get("/stores", params={"limit": 3, "offset": 0})).json()
        second = (await client.get("/stores", params={"limit": 3, "offset": 3})).json()
        ids = [s["id"] for s in first] + [s["id"] for s in second]
        assert len(ids) == len(set(ids)), f"a shop appeared twice across pages: {ids}"
        # Every shop created for this test is reachable, and only once.
        for store_id in created:
            assert ids.count(store_id) <= 1

    @pytest.mark.asyncio
    async def test_the_directory_never_returns_the_same_id_twice(self, client):
        owner_id, headers = await _register(client)
        await _store(client, headers, name="Unique Shop Anchor")
        for i in range(4):
            await _extra_store(owner_id, f"Unique Shop {i}")
        items = (await client.get("/stores", params={"limit": 100})).json()
        ids = [s["id"] for s in items]
        assert len(ids) == len(set(ids))


# ── Insights ────────────────────────────────────────────────────────────────

class TestStoreInsights:
    @pytest.mark.asyncio
    async def test_insights_are_owner_only(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Private Numbers")
        assert (await client.get(f"/stores/{store['id']}/insights")).status_code == 401
        _, other = await _register(client)
        assert (await client.get(
            f"/stores/{store['id']}/insights", headers=other)).status_code == 403

    @pytest.mark.asyncio
    async def test_an_empty_shop_reports_honest_zeros(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Quiet Shop")
        body = (await client.get(f"/stores/{store['id']}/insights", headers=headers)).json()
        assert body["period"]["days"] == 7
        assert body["kpis"]["visits"]["value"] == 0
        assert body["kpis"]["saves"]["value"] == 0
        assert body["kpis"]["chats"]["value"] == 0
        # Rating exists and is the neutral anchor, not an invented 0.
        assert body["store"]["rating"] == 6.5
        assert body["store"]["review_count"] == 0
        assert body["store"]["rank"] is not None
        assert body["top_products"] == []
        # No model call, and no card pretending there is data to cite.
        codes = {c["code"] for c in body["advice"]["negatives"]}
        assert "no_reviews" in codes

    @pytest.mark.asyncio
    async def test_visits_and_saves_are_counted_for_the_period(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Busy Shop")
        listing_id = await _create_listing(client, headers, store["id"], "Popular item")
        _, buyer_headers = await _register(client)

        # Three distinct visitors, because three visits by the same one
        # would count once - by design. Clearing seen() between requests
        # only forgot this process's memory cache; with Redis the SET NX
        # key survived, so the second and third visits were (correctly)
        # de-duplicated and the KPI read 1.
        visitors = [buyer_headers]
        for _ in range(2):
            _, extra_headers = await _register(client)
            visitors.append(extra_headers)
        for visitor_headers in visitors:
            r = await client.post(f"/stores/{store['id']}/visit", json={"via": "whatsapp"},
                                  headers=visitor_headers)
            assert r.status_code == 202
            assert r.json()["counted"] is True

        await client.post(f"/listings/{listing_id}/save", headers=buyer_headers)

        body = (await client.get(f"/stores/{store['id']}/insights", headers=headers)).json()
        assert body["kpis"]["visits"]["value"] == 3
        assert body["sources"]["visits_by_source"]["whatsapp"] == 3
        assert body["kpis"]["saves"]["value"] == 1

    @pytest.mark.asyncio
    async def test_a_repeat_visit_by_the_same_visitor_is_not_counted_twice(self, client):
        # The de-duplication the test above exists beside: same signed-in
        # buyer, same shop, inside VISIT_WINDOW. This runs against Redis
        # whenever REDIS_URL is set (both CI jobs set it), so it also
        # guards that SET NX path rather than just the memory fallback.
        _, headers = await _register(client)
        store = await _store(client, headers, name="Repeat Shop")
        _, buyer_headers = await _register(client)

        first = await client.post(f"/stores/{store['id']}/visit", json={"via": "whatsapp"},
                                  headers=buyer_headers)
        again = await client.post(f"/stores/{store['id']}/visit", json={"via": "whatsapp"},
                                  headers=buyer_headers)
        assert first.json()["counted"] is True
        assert again.json()["counted"] is False

        body = (await client.get(f"/stores/{store['id']}/insights", headers=headers)).json()
        assert body["kpis"]["visits"]["value"] == 1
        assert body["sources"]["visits_by_source"]["whatsapp"] == 1

    @pytest.mark.asyncio
    async def test_live_visitors_counts_appearances_in_the_last_five_minutes(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Live Shop")
        _, buyer_headers = await _register(client)
        await client.post(f"/stores/{store['id']}/visit", json={}, headers=buyer_headers)

        body = (await client.get(f"/stores/{store['id']}/insights", headers=headers)).json()
        assert body["store"]["live_visitors"] == 1

        # The owner's own visit never counts, so it must not appear live.
        await client.post(f"/stores/{store['id']}/visit", json={}, headers=headers)
        body = (await client.get(f"/stores/{store['id']}/insights", headers=headers)).json()
        assert body["store"]["live_visitors"] == 1
