"""One free listing and one free store per person, however they post.

The launch offers (pricing/launch_offers.py) and the founding offer
(pricing/service.founding_discount) on together, as production configures
them. What must hold:
  * a seller gets ONE free listing - their first, on the launch offer - and
    the second pays. The founding offer's free band used to post the first
    live without a claim, and the second then took the launch claim: two
    free listings for one seller;
  * a seller whose first listing went free on the founding offer before
    that was fixed gets no launch claim on the next;
  * deleting the free listing, or moving it into the seller's own store,
    never makes the next one free;
  * the quote and GET /pricing/launch-offers say what creation does: no
    "post your first listing free" for a seller who has had theirs;
  * an owner who deleted the store they got free gets no free period on the
    next one - neither at creation nor from the grace round when store
    billing is switched on;
  * a deleted store takes no listing, posted into it or moved in.
"""
import dataclasses
import itertools
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.core.config import settings
from api.database import AccountType, AsyncSessionLocal, Listing, SellerTier, User, init_db, reset_engine
from api.domains.stores import billing as store_billing
from api.models.launch_offer import LaunchOfferClaim, LaunchOfferType
from api.models.store_billing import StoreBillingMeta, StoreSubscription
from api.security import create_access_token

_MODULES = (
    "api.domains.listings.service", "api.domains.listings.paid",
    "api.domains.pricing.service", "api.domains.pricing.payments",
    "api.domains.pricing.router", "api.domains.pricing.launch_offers",
    "api.domains.stores.service", "api.domains.stores.billing",
    "api.domains.stores.router",
)


def _patch(monkeypatch, **overrides):
    patched = dataclasses.replace(settings, **{
        "listing_fees_enabled": True, "store_billing_enabled": True,
        "in_app_payments_enabled": False, "free_listings_per_seller": 0,
        "founding_seller_tiers": ((50, 100), (150, 50)), "founding_discount_days": 30,
        "free_listing_offer_limit": 99, "free_store_offer_limit": 99,
        "free_listing_offer_days": 60, "free_store_offer_days": 60,
        **overrides,
    })
    for module in _MODULES:
        monkeypatch.setattr(f"{module}.settings", patched)
    return patched


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_free_offers_once.db"
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


@pytest.fixture(autouse=True)
def both_offers_on(monkeypatch):
    """Fees and store billing on; the launch offers AND the founding bands
    on, each with room - the combination that handed out two."""
    _patch(monkeypatch)


_n = itertools.count(1000)


async def _user(store_owner: bool = False) -> tuple[str, dict]:
    n = next(_n)
    u = User(name=f"Seller {n}", phone=f"+254798{n:06d}", password_hash="x")
    if store_owner:
        u.account_type, u.seller_tier = AccountType.buyer_seller, SellerTier.long_term
        u.business_name, u.business_category = f"Biz {n}", "Electronics"
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers, expect=201, **extra) -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
        "price": 20000, "lat": -1.28, "lng": 36.82, **extra})
    assert r.status_code == expect, r.text
    return r.json()


async def _quote(client, headers, **params) -> dict:
    r = await client.get("/pricing/listing-fee/quote", headers=headers,
                         params={"category": "Electronics", "price": 20000, **params})
    assert r.status_code == 200, r.text
    return r.json()


async def _offers(client, headers) -> dict:
    return (await client.get("/pricing/launch-offers", headers=headers)).json()


async def _store(client, headers) -> dict:
    r = await client.post("/stores", headers=headers, json={
        "name": f"Shop {next(_n)}", "store_type": "virtual",
        "slug": f"shop-{uuid.uuid4().hex[:8]}"})
    assert r.status_code == 201, r.text
    return r.json()


def _days_left(listing: dict) -> float:
    return (datetime.fromisoformat(listing["paid_until"]) - datetime.utcnow()).total_seconds() / 86400


async def _claims(user_id: str, offer_type: str) -> list[LaunchOfferClaim]:
    async with AsyncSessionLocal() as db:
        return (await db.execute(select(LaunchOfferClaim).where(
            LaunchOfferClaim.user_id == user_id,
            LaunchOfferClaim.offer_type == offer_type))).scalars().all()


def _is_free(listing: dict) -> bool:
    return listing["listing_fee"]["status"] in ("live", "ending")


# ── Listings ─────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_founding_seller_gets_one_free_listing_not_two(client):
    uid, h = await _user()
    before = await _quote(client, h)
    assert before["free_listing"] is True and before["launch_offer"]["eligible"] is True

    first = await _listing(client, h)
    assert _is_free(first)
    # On the launch offer's claim - its 60 days, as the sell screen says -
    # not on the founding band's 30 days without a claim.
    assert abs(_days_left(first) - 60) <= 1
    assert [c.entity_id for c in await _claims(uid, LaunchOfferType.LISTING_FREE)] == [first["id"]]

    after = await _quote(client, h)
    assert after["free_listing"] is False and after["fees_enabled"] is True
    assert after["launch_offer"]["eligible"] is False
    assert after["founding"]["percent"] == 0
    offers = (await _offers(client, h))["listing_free"]
    assert offers["already_claimed"] is True and offers["eligible"] is False

    second = await _listing(client, h)
    assert second["listing_fee"]["status"] == "unpaid"
    assert second["listing_fee"]["needs_payment"] is True


@pytest.mark.asyncio
async def test_a_first_listing_free_on_the_founding_offer_was_the_free_one(client):
    """Posted before the fix: live on the founding band's 30 days, no claim.
    The next listing used to take the launch claim as well."""
    uid, h = await _user()
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        db.add(Listing(seller_id=uid, name="Founding phone", category="Electronics",
                       price=15000, lat=-1.28, lng=36.82,
                       created_at=now - timedelta(days=5),
                       paid_until=now - timedelta(days=5) + timedelta(days=30)))
        await db.commit()

    q = await _quote(client, h)
    assert q["free_listing"] is False and q["fees_enabled"] is True
    assert q["launch_offer"]["eligible"] is False
    assert (await _offers(client, h))["listing_free"]["already_claimed"] is True

    second = await _listing(client, h)
    assert second["listing_fee"]["status"] == "unpaid"
    assert await _claims(uid, LaunchOfferType.LISTING_FREE) == []


@pytest.mark.asyncio
async def test_deleting_the_free_listing_makes_the_next_one_pay(client):
    uid, h = await _user()
    first = await _listing(client, h)
    assert _is_free(first)
    assert (await client.delete(f"/listings/{first['id']}", headers=h)).status_code == 200

    q = await _quote(client, h)
    assert q["free_listing"] is False and q["launch_offer"]["eligible"] is False
    assert (await _offers(client, h))["listing_free"]["already_claimed"] is True
    again = await _listing(client, h)
    assert again["listing_fee"]["status"] == "unpaid"
    assert len(await _claims(uid, LaunchOfferType.LISTING_FREE)) == 1


@pytest.mark.asyncio
async def test_a_seller_whose_first_listing_never_went_live_still_gets_theirs(client, monkeypatch):
    """Posted while no launch slot was left and never paid: no buyer ever saw
    it, so it was not the seller's free listing."""
    _patch(monkeypatch, free_listing_offer_limit=0, founding_seller_tiers=())
    uid, h = await _user()
    unpaid = await _listing(client, h)
    assert unpaid["listing_fee"]["status"] == "unpaid"

    _patch(monkeypatch)
    assert (await _quote(client, h))["launch_offer"]["eligible"] is True
    free = await _listing(client, h)
    assert _is_free(free)


@pytest.mark.asyncio
async def test_moving_the_free_listing_into_a_store_makes_the_next_one_pay(client, monkeypatch):
    """With no launch slot, the founding band covers a first listing. Moving
    it into the seller's store made the next listing their "first" again,
    and free again."""
    _patch(monkeypatch, free_listing_offer_limit=0)
    _, h = await _user(store_owner=True)
    store = await _store(client, h)

    first = await _listing(client, h)
    assert _is_free(first)
    assert abs(_days_left(first) - 30) <= 1  # the founding band's own window
    moved = await client.post(f"/listings/{first['id']}/store", headers=h,
                              json={"store_id": store["id"]})
    assert moved.status_code == 200, moved.text

    q = await _quote(client, h)
    assert q["free_listing"] is False and q["founding"]["percent"] == 0
    second = await _listing(client, h)
    assert second["listing_fee"]["status"] == "unpaid"


@pytest.mark.asyncio
async def test_with_no_launch_slot_the_founding_band_still_covers_the_first(client, monkeypatch):
    _patch(monkeypatch, free_listing_offer_limit=0)
    uid, h = await _user()
    q = await _quote(client, h)
    assert q["free_listing"] is True and q["founding"]["percent"] == 100

    first = await _listing(client, h)
    assert _is_free(first) and abs(_days_left(first) - 30) <= 1
    assert await _claims(uid, LaunchOfferType.LISTING_FREE) == []
    assert (await _listing(client, h))["listing_fee"]["status"] == "unpaid"


@pytest.mark.asyncio
async def test_listings_posted_into_a_store_leave_the_free_listing_alone(client, monkeypatch):
    """A store listing is covered by its store's plan: it was never the
    seller's free listing, so their first own listing still is."""
    uid, h = await _user(store_owner=True)
    store = await _store(client, h)
    for _ in range(2):
        covered = await _listing(client, h, store_id=store["id"])
        assert covered["listing_fee"]["status"] == "store_covered"
    assert (await _offers(client, h))["listing_free"]["already_claimed"] is False
    assert (await _quote(client, h))["launch_offer"]["eligible"] is True
    own = await _listing(client, h)
    assert _is_free(own) and abs(_days_left(own) - 60) <= 1
    assert [c.entity_id for c in await _claims(uid, LaunchOfferType.LISTING_FREE)] == [own["id"]]


@pytest.mark.asyncio
async def test_with_fees_off_the_claim_is_still_the_first_listing_only(client, monkeypatch):
    """While fees are off every listing goes live on a window; the claim
    (which counts against the 50) is taken by a seller's first listing
    only - not by a later one of a seller who already had one live."""
    _patch(monkeypatch, listing_fees_enabled=False)
    uid, h = await _user()
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        db.add(Listing(seller_id=uid, name="From before the offer", category="Electronics",
                       price=9000, lat=-1.28, lng=36.82, paid_until=None,
                       created_at=now - timedelta(days=40)))
        await db.commit()
    later = await _listing(client, h)
    assert _is_free(later) and later["paid_until"] is not None  # a window, as ever
    assert await _claims(uid, LaunchOfferType.LISTING_FREE) == []

    newcomer, nh = await _user()
    first = await _listing(client, nh)
    assert [c.entity_id for c in await _claims(newcomer, LaunchOfferType.LISTING_FREE)] == [first["id"]]


@pytest.mark.asyncio
async def test_a_listing_taken_out_of_its_store_is_no_free_listing(client, monkeypatch):
    """Posted into the store it had no listing time of its own, and taken
    out it read as "free, never expires" - a way round the fee."""
    _, h = await _user(store_owner=True)
    store = await _store(client, h)
    covered = await _listing(client, h, store_id=store["id"])
    out = await client.delete(f"/listings/{covered['id']}/store", headers=h)
    assert out.status_code == 200, out.text
    assert out.json()["store_id"] is None
    assert out.json()["listing_fee"]["status"] == "unpaid"
    assert out.json()["listing_fee"]["needs_payment"] is True

    # While fees are off it is a personal listing like any other: a window.
    _patch(monkeypatch, listing_fees_enabled=False)
    covered = await _listing(client, h, store_id=store["id"])
    out = (await client.delete(f"/listings/{covered['id']}/store", headers=h)).json()
    assert out["listing_fee"]["status"] in ("live", "ending")
    assert abs(_days_left(out) - 60) <= 1

    # Personal before it moved in: it keeps the time it had.
    _patch(monkeypatch)
    own = await _listing(client, h)
    before = own["paid_until"]
    assert (await client.post(f"/listings/{own['id']}/store", headers=h,
                              json={"store_id": store["id"]})).status_code == 200
    back = (await client.delete(f"/listings/{own['id']}/store", headers=h)).json()
    assert back["paid_until"] == before


# ── Stores ───────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_an_owner_who_had_a_store_before_gets_no_free_one(client, monkeypatch):
    """A store from before the offer (free while billing was off), deleted,
    and another opened: the free store is a person's first."""
    _patch(monkeypatch, free_store_offer_limit=0)
    owner, h = await _user(store_owner=True)
    old = await _store(client, h)
    assert (await client.delete(f"/stores/{old['id']}", headers=h)).status_code == 200

    _patch(monkeypatch)
    offers = (await _offers(client, h))["store_free"]
    assert offers["already_claimed"] is True and offers["eligible"] is False
    new = await _store(client, h)
    assert new["billing"]["active"] is False
    assert await _claims(owner, LaunchOfferType.STORE_FREE) == []


@pytest.mark.asyncio
async def test_deleting_the_free_store_gives_no_second_free_store(client):
    _, h = await _user(store_owner=True)
    first = await _store(client, h)
    assert first["billing"]["active"] is True  # opened on its free period
    assert (await client.delete(f"/stores/{first['id']}", headers=h)).status_code == 200

    offers = (await _offers(client, h))["store_free"]
    assert offers["already_claimed"] is True and offers["eligible"] is False
    second = await _store(client, h)
    assert second["billing"]["active"] is False
    async with AsyncSessionLocal() as db:
        sub = (await db.execute(select(StoreSubscription).where(
            StoreSubscription.store_id == second["id"]))).scalar_one()
    assert sub.paid_until is None and sub.setup_fee_paid is False


@pytest.mark.asyncio
async def test_the_grace_round_gives_no_second_free_store_period(client, monkeypatch):
    """Store billing off: the free store, deleted, then another opened - no
    claim and no row. Switching billing on used to give that one 30 days."""
    _patch(monkeypatch, store_billing_enabled=False)
    owner, h = await _user(store_owner=True)
    claimed = await _store(client, h)
    assert (await client.delete(f"/stores/{claimed['id']}", headers=h)).status_code == 200
    second = await _store(client, h)
    _, other_h = await _user(store_owner=True)
    _patch(monkeypatch, store_billing_enabled=False, free_store_offer_limit=0)
    pre_billing = await _store(client, other_h)  # nobody's free store: grace is theirs

    async with AsyncSessionLocal() as db:
        marker = await db.get(StoreBillingMeta, store_billing.GRACE_MARKER_ID)
        if marker is not None:
            await db.delete(marker)
            await db.commit()
    _patch(monkeypatch)
    await store_billing.ensure_grace_subscriptions()

    async with AsyncSessionLocal() as db:
        rows = {s.store_id: s for s in (await db.execute(select(StoreSubscription).where(
            StoreSubscription.store_id.in_([second["id"], pre_billing["id"]])))).scalars()}
    assert rows[second["id"]].paid_until is None, "a second free period for the same owner"
    grace = rows[pre_billing["id"]].paid_until - datetime.utcnow()
    assert timedelta(days=29) < grace <= timedelta(days=settings.store_billing_grace_days)


@pytest.mark.asyncio
async def test_a_deleted_store_takes_no_listings(client):
    _, h = await _user(store_owner=True)
    store = await _store(client, h)
    own = await _listing(client, h)
    assert (await client.delete(f"/stores/{store['id']}", headers=h)).status_code == 200

    posted = await client.post("/listings/", headers=h, json={
        "description": "Well kept.", "name": "Into a closed shop", "category": "Electronics",
        "price": 20000, "lat": -1.28, "lng": 36.82, "store_id": store["id"]})
    assert posted.status_code == 400 and posted.json()["detail"] == "Store not found"
    moved = await client.post(f"/listings/{own['id']}/store", headers=h,
                              json={"store_id": store["id"]})
    assert moved.status_code == 404
    quoted = await client.get("/pricing/listing-fee/quote", headers=h, params={
        "category": "Electronics", "price": 20000, "store_id": store["id"]})
    assert quoted.status_code == 403
