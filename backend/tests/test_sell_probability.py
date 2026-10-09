"""The sell probability, rebuilt on what is measured (2026-10-09).

A fifth of the score was the like rate, and nothing collected likes: the
wishlists table had no endpoint and the app no button. Every listing scored
zero on it, and every listing with 20 views was told "20 views and no
saves". Saves are now collected (POST /listings/{id}/save) and the model
reads the signals the platform really has: saves (smoothed), every buyer
who wrote about the listing, offers, the listing's photos and words, and
how long it has sat with nobody asking.
"""
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.database import (
    AsyncSessionLocal, Interest, Listing, NegotiationMessage, User, Wishlist,
    init_db, reset_engine,
)
from api.domains.listings.sell_probability import (
    ListingSignals, compute_sell_probability, listing_advice, smoothed_save_rate,
)
from api.security import create_access_token
from main import app


# ── The model ────────────────────────────────────────────────────────────────

def _p(**kw):
    return compute_sell_probability(ListingSignals(**kw))


def test_no_saves_yet_is_not_scored_as_nobody_wanting_it():
    """A listing nobody has had a chance to save starts at the prior, not 0.

    The old intent term was saves / views with saves always 0 - so every
    listing lost its whole intent weight."""
    assert _p(views=0).intent > 0.2
    # ...and a well-viewed one nobody saves does fall.
    assert _p(views=200).intent < 0.1


def test_saves_raise_the_probability():
    common = dict(views=60, interested_buyers=1, days_listed=5,
                  photo_count=4, description_chars=200)
    assert _p(likes=12, **common).probability > _p(likes=0, **common).probability


def test_one_early_save_is_not_extraordinary_demand():
    """1 save from 2 views is a 50% rate; smoothed, it is modest."""
    assert smoothed_save_rate(ListingSignals(views=2, likes=1)) < 0.1


def test_an_offer_near_the_price_counts():
    common = dict(views=40, interested_buyers=2, days_listed=4, price=10000)
    near = _p(best_offer=9500, **common)
    low = _p(best_offer=3000, **common)
    none = _p(**common)
    assert near.commitment > none.commitment
    # A lowball is still a buyer: it does not count against the listing.
    assert low.commitment == none.commitment


def test_photos_and_words_count():
    common = dict(views=40, interested_buyers=1, days_listed=4)
    full = _p(photo_count=5, description_chars=300, **common)
    bare = _p(photo_count=1, description_chars=0, **common)
    assert full.quality == 1.0
    assert bare.probability < full.probability


def test_listing_term_left_out_when_not_measured():
    """A caller that didn't look at the photos doesn't score "no photos"."""
    assert _p(views=40).quality is None


def test_a_listing_nobody_asks_about_goes_stale():
    common = dict(views=200, days_listed=60, photo_count=4, description_chars=200)
    stale = _p(interested_buyers=0, **common)
    asked = _p(interested_buyers=1, **common)
    assert stale.freshness < 1.0
    assert asked.freshness == 1.0
    fresh = _p(interested_buyers=0, **{**common, "days_listed": 10})
    assert fresh.freshness == 1.0


def test_buyers_asking_count_as_evidence():
    """Three buyers on eight views is not "too early to tell"."""
    assert _p(views=8, interested_buyers=3).confidence == 1.0
    assert _p(views=8).confidence < 0.5


def test_no_saves_card_waits_for_real_traffic():
    """Saves were only collected from 2026-10-09: 20 views from before had
    no way to become one, and the card accused every listing."""
    s = ListingSignals(views=25, likes=0, days_listed=10)
    codes = {c["code"] for c in listing_advice(s, compute_sell_probability(s))["negatives"]}
    assert "views_no_likes" not in codes
    s = ListingSignals(views=80, likes=0, days_listed=10)
    codes = {c["code"] for c in listing_advice(s, compute_sell_probability(s))["negatives"]}
    assert "views_no_likes" in codes


def test_few_photos_is_advice():
    s = ListingSignals(views=30, days_listed=5, photo_count=1, description_chars=10)
    codes = {c["code"] for c in listing_advice(s, compute_sell_probability(s))["negatives"]}
    assert {"few_photos", "thin_description"} <= codes


# ── Collecting saves, and reading every buyer ────────────────────────────────

@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_sell_probability.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    await init_db()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _setup():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyers = [User(name=f"Buyer {i}", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
                  for i in range(3)]
        db.add_all([seller, *buyers])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Casio watch", category="Fashion",
                          price=1500, lat=-1.1, lng=37.0, views=10,
                          description="Casio G-Shock, two years old, works perfectly.",
                          created_at=datetime.utcnow() - timedelta(days=3))
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, [b.id for b in buyers]


@pytest.mark.asyncio
async def test_a_buyer_saves_and_unsaves(client):
    listing_id, seller, (buyer, *_rest) = await _setup()
    r = await client.post(f"/listings/{listing_id}/save", headers=_auth(buyer))
    assert r.status_code == 200, r.text
    assert r.json() == {"saved": True}
    # Idempotent: a second tap is still one save.
    assert (await client.post(f"/listings/{listing_id}/save", headers=_auth(buyer))).status_code == 200
    assert (await client.get(f"/listings/{listing_id}/save", headers=_auth(buyer))).json() == {"saved": True}
    saved = (await client.get("/listings/saved", headers=_auth(buyer))).json()
    assert [l["id"] for l in saved] == [listing_id]

    m = (await client.get(f"/listings/{listing_id}/metrics", headers=_auth(seller))).json()
    assert m["current"]["likes"] == 1

    r = await client.delete(f"/listings/{listing_id}/save", headers=_auth(buyer))
    assert r.json() == {"saved": False}
    assert (await client.get("/listings/saved", headers=_auth(buyer))).json() == []


@pytest.mark.asyncio
async def test_a_seller_cannot_save_their_own(client):
    listing_id, seller, _ = await _setup()
    r = await client.post(f"/listings/{listing_id}/save", headers=_auth(seller))
    assert r.status_code == 400


@pytest.mark.asyncio
async def test_buyers_who_wrote_count_as_asking(client):
    """Most buyers simply write; the availability button alone missed them.
    A buyer who only talked to Zeno privately is not shown to the seller."""
    listing_id, seller, (b1, b2, b3) = await _setup()
    async with AsyncSessionLocal() as db:
        db.add(Interest(listing_id=listing_id, buyer_id=b1, offer_price=1400))
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=b2, role="buyer",
                                  content="still there?", buyer_id=b2, via_ai=False))
        # Private to Zeno, never relayed: not the seller's to know.
        db.add(NegotiationMessage(listing_id=listing_id, sender_id=b3, role="buyer",
                                  content="is this a good price?", buyer_id=b3, via_ai=True))
        await db.commit()
    m = (await client.get(f"/listings/{listing_id}/metrics", headers=_auth(seller))).json()
    assert m["current"]["interested_buyers"] == 2
    assert m["current"]["best_offer"] == 1400
    assert m["current"]["components"]["quality"] is not None


@pytest.mark.asyncio
async def test_the_seller_opening_their_listing_is_not_a_view(client):
    listing_id, seller, (buyer, *_r) = await _setup()
    await client.get(f"/listings/{listing_id}", headers=_auth(seller))
    await client.get(f"/listings/{listing_id}", headers=_auth(buyer))
    await client.get(f"/listings/{listing_id}")
    async with AsyncSessionLocal() as db:
        assert (await db.get(Listing, listing_id)).views == 12
    # An expired session still opens a public listing.
    r = await client.get(f"/listings/{listing_id}", headers={"Authorization": "Bearer junk"})
    assert r.status_code == 200
