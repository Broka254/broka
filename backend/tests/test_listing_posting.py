"""Posting a listing: what POST /listings, PATCH /listings/{id} and the
interest endpoint accept, and what a listing publishes about its seller.

Found in the 2026-09-25 review of the listing flow (LISTING_POSTING_REVIEW.md).
Each test here failed on the code before its fix:

  * a NaN price (Python's json accepts the literal) was saved on
    PostgreSQL and then broke every response containing it - the Home
    feed included; on SQLite it was a 500. Zero, negative and absurd
    prices, a latitude of 500 and a 100,000-character name all saved.
  * a NaN inside `attributes` broke every page the listing appeared on,
    on both databases (the value is JSON text).
  * a request refused for a NaN still got a 500: the 422 echoes the input.
  * an unknown listing_type or subcategory reached the database and 500'd.
  * trust score 0 - the worst there is - passed the trust gate.
  * a create sent twice (response lost, seller taps again) posted twice.
  * nothing limited how many listings an account could post.
  * an auction's listing and its window were two commits.
  * an auction could be created already closed.
  * the listing row published the seller's phone position, 7 decimals.
  * photos could be swapped after the buyer had paid.
"""
import asyncio
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.rate_limit import RateLimiter
from api import database
from api.database import (
    AsyncSessionLocal, Category, Deal, DealStatus, Listing, ListingStatus, User,
    init_db, reset_engine,
)
from api.domains.listings.location import COUNTY_POINTS
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_posting.db"
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
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def _user(**extra) -> tuple[User, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", **extra)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


def _body(**extra) -> dict:
    return {"description": "Well kept, works perfectly - selling because I upgraded.", "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 25000, "lat": -1.28, "lng": 36.82, **extra}


def _raw(text: str) -> dict:
    """Send `text` as the JSON body exactly - httpx won't encode NaN."""
    return {"content": text.encode(), "headers": {"Content-Type": "application/json"}}


async def _post_raw(client, headers, text):
    kw = _raw(text)
    return await client.post("/listings/", content=kw["content"],
                              headers={**headers, **kw["headers"]})


async def _row(listing_id: str) -> Listing:
    async with AsyncSessionLocal() as db:
        return await db.get(Listing, listing_id)


async def _count(seller_id: str) -> int:
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(Listing.id).where(Listing.seller_id == seller_id))).all()
    return len(rows)


# ── Non-finite numbers ────────────────────────────────────────────────────────

class TestNonFiniteNumbers:
    @pytest.mark.asyncio
    async def test_nan_price_is_refused_and_the_feed_stays_up(self, client):
        seller, h = await _user()
        r = await _post_raw(client, h, '{"name": "Radio", "category": "Electronics", '
                                       '"price": NaN, "lat": -1.28, "lng": 36.82}')
        assert r.status_code == 422, r.text
        assert r.json()["detail"][0]["loc"] == ["body", "price"]
        assert await _count(seller.id) == 0
        assert (await client.get("/listings/")).status_code == 200

    @pytest.mark.asyncio
    @pytest.mark.parametrize("field", ["lat", "lng", "reserve_price", "min_bid_increment"])
    async def test_infinity_in_any_number_is_refused(self, client, field):
        _, h = await _user()
        base = {"description": "Well kept, works perfectly - selling because I upgraded.", "name": "Radio", "category": "Electronics", "price": 100, "lat": -1.28, "lng": 36.82}
        text = ", ".join(f'"{k}": {v if not isinstance(v, str) else chr(34) + v + chr(34)}'
                         for k, v in base.items() if k != field)
        r = await _post_raw(client, h, "{" + text + f', "{field}": Infinity}}')
        assert r.status_code == 422, r.text

    @pytest.mark.asyncio
    async def test_nan_inside_attributes_is_refused(self, client):
        seller, h = await _user()
        r = await _post_raw(client, h, '{"name": "Radio", "category": "Electronics", "price": 100, '
                                       '"lat": -1.28, "lng": 36.82, "attributes": {"watts": NaN}}')
        assert r.status_code == 422, r.text
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_a_stored_nan_attribute_no_longer_breaks_the_feed(self, client):
        """Rows saved before the check: read as no value, not a 500."""
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            row = Listing(seller_id=seller.id, name="Old radio", category="Electronics",
                          price=100, lat=-1.28, lng=36.82, attributes='{"watts": NaN, "brand": "Sony"}')
            db.add(row)
            await db.commit()
            listing_id = row.id
        r = await client.get("/listings/", params={"seller_id": seller.id})
        assert r.status_code == 200
        assert r.json()[0]["attributes"] == {"watts": None, "brand": "Sony"}
        assert (await client.get(f"/listings/{listing_id}")).status_code == 200

    @pytest.mark.asyncio
    async def test_patch_nan_price_is_refused(self, client):
        _, h = await _user()
        listing = (await client.post("/listings/", json=_body(), headers=h)).json()
        kw = _raw('{"price": NaN}')
        r = await client.patch(f"/listings/{listing['id']}", content=kw["content"],
                               headers={**h, **kw["headers"]})
        assert r.status_code == 422, r.text
        assert (await _row(listing["id"])).price == 25000

    @pytest.mark.asyncio
    async def test_interest_offer_must_be_a_real_price(self, client):
        _, seller_h = await _user()
        _, buyer_h = await _user()
        listing = (await client.post("/listings/", json=_body(), headers=seller_h)).json()
        kw = _raw('{"offer_price": NaN}')
        r = await client.post(f"/listings/{listing['id']}/interest", content=kw["content"],
                              headers={**buyer_h, **kw["headers"]})
        assert r.status_code == 422, r.text
        r = await client.post(f"/listings/{listing['id']}/interest",
                              json={"offer_price": -10}, headers=buyer_h)
        assert r.status_code == 422
        r = await client.post(f"/listings/{listing['id']}/interest",
                              json={"offer_price": 20000}, headers=buyer_h)
        assert r.status_code == 200


# ── What a listing may contain ────────────────────────────────────────────────

class TestListingFields:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("price", [0, -5, 20_000_001])
    async def test_price_must_be_positive_and_within_escrow(self, client, price):
        seller, h = await _user()
        r = await client.post("/listings/", json=_body(price=price), headers=h)
        assert r.status_code == 422
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_the_escrow_ceiling_itself_is_allowed(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(price=20_000_000), headers=h)
        assert r.status_code == 201, r.text

    @pytest.mark.asyncio
    async def test_price_message_names_the_limit(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(price=50_000_000), headers=h)
        assert "20,000,000" in r.json()["detail"][0]["msg"]

    @pytest.mark.asyncio
    @pytest.mark.parametrize("coords", [{"lat": 500}, {"lng": -900}, {"lat": -90.5}])
    async def test_coordinates_must_be_on_earth(self, client, coords):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(**coords), headers=h)
        assert r.status_code == 422

    @pytest.mark.asyncio
    @pytest.mark.parametrize("name", ["   ", "ab", "x" * 121])
    async def test_name_length(self, client, name):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(name=name), headers=h)
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_name_is_one_line(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(name="  Toyota\n\nVitz   2015 "), headers=h)
        assert r.json()["name"] == "Toyota Vitz 2015"

    @pytest.mark.asyncio
    async def test_description_is_bounded(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(description="d" * 2001), headers=h)
        assert r.status_code == 422
        r = await client.post("/listings/", json=_body(description="d" * 2000), headers=h)
        assert r.status_code == 201

    @pytest.mark.asyncio
    async def test_unknown_listing_type_is_a_422_not_a_500(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(listing_type="banana"), headers=h)
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_condition(self, client):
        _, h = await _user()
        assert (await client.post("/listings/", json=_body(condition="broken"), headers=h)).status_code == 422
        r = await client.post("/listings/", json=_body(condition=" Used "), headers=h)
        assert r.json()["condition"] == "used"

    @pytest.mark.asyncio
    async def test_attributes_are_flat_and_bounded(self, client):
        _, h = await _user()
        nested = await client.post("/listings/", json=_body(attributes={"a": {"b": 1}}), headers=h)
        assert nested.status_code == 422
        many = await client.post(
            "/listings/", json=_body(attributes={f"k{i}": "v" for i in range(31)}), headers=h)
        assert many.status_code == 422
        long = await client.post("/listings/", json=_body(attributes={"make": "x" * 201}), headers=h)
        assert long.status_code == 422
        ok = await client.post(
            "/listings/", json=_body(attributes={"make": "Toyota", "mileage": 45000}), headers=h)
        assert ok.json()["attributes"] == {"make": "Toyota", "mileage": 45000}

    @pytest.mark.asyncio
    async def test_unknown_subcategory_is_a_400(self, client):
        seller, h = await _user()
        r = await client.post("/listings/", json=_body(subcategory_id=str(uuid.uuid4())), headers=h)
        assert r.status_code == 400
        assert "category" in r.json()["detail"]
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_a_real_subcategory_is_kept(self, client):
        _, h = await _user()
        async with AsyncSessionLocal() as db:
            cat = Category(name=f"Phones {uuid.uuid4().hex[:4]}")
            db.add(cat)
            await db.commit()
            cat_id = cat.id
        r = await client.post("/listings/", json=_body(subcategory_id=cat_id), headers=h)
        assert r.status_code == 201
        assert r.json()["subcategory_id"] == cat_id


# ── Who may post ──────────────────────────────────────────────────────────────

class TestTrustGate:
    @pytest.mark.asyncio
    async def test_trust_score_zero_is_blocked(self, client):
        seller, h = await _user(trust_score=0)
        r = await client.post("/listings/", json=_body(), headers=h)
        assert r.status_code == 403
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_unknown_trust_score_is_not_blocked(self, client):
        _, h = await _user(trust_score=None)
        assert (await client.post("/listings/", json=_body(), headers=h)).status_code == 201

    @pytest.mark.asyncio
    async def test_a_deleted_account_cannot_post(self, client):
        ghost = {"Authorization": f"Bearer {create_access_token({'sub': str(uuid.uuid4())})}"}
        r = await client.post("/listings/", json=_body(), headers=ghost)
        assert r.status_code == 401


# ── Sent twice ────────────────────────────────────────────────────────────────

class TestRetrySafeCreate:
    @pytest.mark.asyncio
    async def test_the_same_key_returns_the_same_listing(self, client):
        seller, h = await _user()
        key = str(uuid.uuid4())
        first = await client.post("/listings/", json=_body(name="Fridge"),
                                  headers={**h, "X-Idempotency-Key": key})
        again = await client.post("/listings/", json=_body(name="Fridge"),
                                  headers={**h, "X-Idempotency-Key": key})
        assert first.status_code == again.status_code == 201
        assert first.json()["id"] == again.json()["id"]
        assert await _count(seller.id) == 1

    @pytest.mark.asyncio
    async def test_a_double_tap_posts_once(self, client):
        seller, h = await _user()
        headers = {**h, "X-Idempotency-Key": str(uuid.uuid4())}
        a, b = await asyncio.gather(
            client.post("/listings/", json=_body(name="Cooker"), headers=headers),
            client.post("/listings/", json=_body(name="Cooker"), headers=headers),
        )
        assert a.status_code == b.status_code == 201, (a.text, b.text)
        assert a.json()["id"] == b.json()["id"]
        assert await _count(seller.id) == 1

    @pytest.mark.asyncio
    async def test_keys_belong_to_their_seller(self, client):
        key = str(uuid.uuid4())
        _, h1 = await _user()
        _, h2 = await _user()
        a = await client.post("/listings/", json=_body(), headers={**h1, "X-Idempotency-Key": key})
        b = await client.post("/listings/", json=_body(), headers={**h2, "X-Idempotency-Key": key})
        assert a.json()["id"] != b.json()["id"]

    @pytest.mark.asyncio
    async def test_without_a_key_each_create_is_new(self, client):
        seller, h = await _user()
        await client.post("/listings/", json=_body(name="Same"), headers=h)
        await client.post("/listings/", json=_body(name="Same"), headers=h)
        assert await _count(seller.id) == 2

    @pytest.mark.asyncio
    async def test_an_overlong_key_is_refused(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(), headers={**h, "X-Idempotency-Key": "k" * 65})
        assert r.status_code == 422


class TestCreateRateLimit:
    @pytest.mark.asyncio
    async def test_posting_is_limited_per_seller(self, client, monkeypatch):
        from api.core import rate_limit
        monkeypatch.setattr(rate_limit, "listing_create_limiter",
                            RateLimiter("listing_create_t", 2, 3600))
        seller, h = await _user()
        other, other_h = await _user()
        for _ in range(2):
            assert (await client.post("/listings/", json=_body(), headers=h)).status_code == 201
        refused = await client.post("/listings/", json=_body(), headers=h)
        assert refused.status_code == 429
        assert "hour" in refused.json()["detail"]
        assert await _count(seller.id) == 2
        # Someone else's allowance is their own.
        assert (await client.post("/listings/", json=_body(), headers=other_h)).status_code == 201

    @pytest.mark.asyncio
    async def test_a_retry_is_not_counted_again(self, client, monkeypatch):
        from api.core import rate_limit
        monkeypatch.setattr(rate_limit, "listing_create_limiter",
                            RateLimiter("listing_create_t2", 1, 3600))
        _, h = await _user()
        headers = {**h, "X-Idempotency-Key": str(uuid.uuid4())}
        first = await client.post("/listings/", json=_body(), headers=headers)
        again = await client.post("/listings/", json=_body(), headers=headers)
        assert again.status_code == 201
        assert again.json()["id"] == first.json()["id"]


# ── Auctions ──────────────────────────────────────────────────────────────────

class TestAuctionCreate:
    @pytest.mark.asyncio
    async def test_no_auction_listing_without_its_window(self, client, monkeypatch):
        """Listing and auction record are one commit: if the second can't be
        written, neither is."""
        from api.domains.listings.service import ListingService

        def boom(self, listing, terms):
            raise RuntimeError("auction_meta write failed")
        monkeypatch.setattr(ListingService, "_add_auction_meta", boom)
        seller, h = await _user()
        with pytest.raises(RuntimeError):
            await client.post("/listings/", json=_body(listing_type="auction"), headers=h)
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_an_auction_that_already_closed_is_refused(self, client):
        seller, h = await _user()
        now = datetime.utcnow()
        r = await client.post("/listings/", json=_body(
            listing_type="auction",
            auction_starts_at=(now - timedelta(days=3)).isoformat(),
            auction_ends_at=(now - timedelta(hours=1)).isoformat(),
        ), headers=h)
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "WINDOW_IN_PAST"
        assert await _count(seller.id) == 0

    @pytest.mark.asyncio
    async def test_terms_cannot_move_the_close_into_the_past(self, client):
        _, h = await _user()
        now = datetime.utcnow()
        listing = (await client.post("/listings/", json=_body(
            listing_type="auction",
            auction_starts_at=(now + timedelta(days=1)).isoformat(),
            auction_ends_at=(now + timedelta(days=3)).isoformat(),
        ), headers=h)).json()
        r = await client.patch(f"/auctions/{listing['id']}/terms", json={
            "starts_at": (now - timedelta(days=2)).isoformat(),
            "ends_at": (now - timedelta(days=1)).isoformat(),
        }, headers=h)
        assert r.status_code == 422
        assert r.json()["detail"]["code"] == "WINDOW_IN_PAST"


# ── Where a listing is ────────────────────────────────────────────────────────

class TestListingLocation:
    @pytest.mark.asyncio
    async def test_the_sellers_position_is_not_published(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(
            lat=-1.2921234, lng=36.8219876, location_county="Atlantis"), headers=h)
        public = (await client.get(f"/listings/{r.json()['id']}")).json()
        assert (public["lat"], public["lng"]) == (-1.29, 36.82)

    @pytest.mark.asyncio
    async def test_a_known_county_places_the_listing_there(self, client):
        """The app sends the signup position - a fixed point in Nairobi CBD -
        for everyone; the listing goes where the seller says it is."""
        _, h = await _user()
        r = await client.post("/listings/", json=_body(
            lat=-1.286389, lng=36.817223,
            location_county="mombasa county", location_subcounty="  Nyali "), headers=h)
        body = r.json()
        assert (body["lat"], body["lng"]) == COUNTY_POINTS["Mombasa"]
        assert body["location_county"] == "Mombasa"
        assert body["location_subcounty"] == "Nyali"
        assert body["location_name"] == "Nyali, Mombasa"

    @pytest.mark.asyncio
    async def test_the_location_filter_finds_it_however_it_was_typed(self, client):
        seller, h = await _user()
        await client.post("/listings/", json=_body(
            location_county="MURANGA", location_subcounty="Kandara"), headers=h)
        r = await client.get("/listings/", params={"seller_id": seller.id, "location": "Murang'a"})
        assert len(r.json()) == 1

    @pytest.mark.asyncio
    async def test_existing_positions_are_rounded_on_start(self):
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            row = Listing(seller_id=seller.id, name="Old sofa", category="Furniture",
                          price=100, lat=-1.2921234, lng=36.8219876)
            db.add(row)
            await db.commit()
            listing_id = row.id
        await init_db()
        stored = await _row(listing_id)
        assert (stored.lat, stored.lng) == (-1.29, 36.82)

    @pytest.mark.asyncio
    async def test_a_non_finite_listing_is_taken_off_sale_on_start(self, client):
        if database.engine.dialect.name != "postgresql":
            pytest.skip("SQLite can't store NaN; PostgreSQL, which production runs, can")
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            row = Listing(seller_id=seller.id, name="Poison", category="Electronics",
                          price=float("nan"), lat=-1.28, lng=36.82)
            db.add(row)
            await db.commit()
            listing_id = row.id
        await init_db()
        assert (await _row(listing_id)).status == ListingStatus.cancelled
        assert (await client.get("/listings/")).status_code == 200


# ── Edits after a buyer pays ──────────────────────────────────────────────────

async def _listing_with_deal(client, status: DealStatus):
    seller, h = await _user()
    buyer, _ = await _user()
    listing = (await client.post("/listings/", json=_body(), headers=h)).json()
    async with AsyncSessionLocal() as db:
        db.add(Deal(listing_id=listing["id"], seller_id=seller.id, buyer_id=buyer.id,
                    agreed_price=24000, commission=720, status=status))
        await db.commit()
    return listing, h


class TestEditsWhileMoneyIsHeld:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("status", [
        DealStatus.paid, DealStatus.disputed, DealStatus.awaiting_resolution,
    ])
    async def test_nothing_changes_while_a_buyers_money_is_held(self, client, status):
        listing, h = await _listing_with_deal(client, status)
        r = await client.patch(f"/listings/{listing['id']}",
                               json={"showcase_id": ""}, headers=h)
        assert r.status_code == 409
        assert "escrow" in r.json()["detail"]
        r = await client.patch(f"/listings/{listing['id']}", json={"price": 30000}, headers=h)
        assert r.status_code == 409
        assert (await _row(listing["id"])).price == 25000

    @pytest.mark.asyncio
    @pytest.mark.parametrize("status", [DealStatus.released, DealStatus.refunded, DealStatus.cancelled])
    async def test_a_settled_deal_does_not_lock_the_listing(self, client, status):
        listing, h = await _listing_with_deal(client, status)
        r = await client.patch(f"/listings/{listing['id']}", json={"showcase_id": ""}, headers=h)
        assert r.status_code == 200, r.text


# ── Images a draft no longer has ──────────────────────────────────────────────

class TestImageGone:
    @pytest.mark.asyncio
    async def test_a_missing_upload_says_so_in_a_header(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(photo_ids=[str(uuid.uuid4())]), headers=h)
        assert r.status_code == 400
        assert r.headers["X-Error-Code"] == "IMAGE_GONE"
