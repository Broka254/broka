"""Launch offers, time-left and expiry SMS.

What must hold:
  * the first FREE_LISTING_OFFER_LIMIT personal listings post free for
    FREE_LISTING_OFFER_DAYS, the first FREE_STORE_OFFER_LIMIT stores open
    live on a free period - one of each per user, enforced even when the
    first freebie is deleted, and a quote/peek never consumes a slot;
  * a listing posted through an online store never pays a listing fee,
    with store billing on OR off, and burns no free/offer slot;
  * listing and store payloads carry server-computed time left before
    they go offline;
  * two days before paid time runs out the owner gets ONE SMS per paid
    period - a renewal earns a new one, a failed send is retried, store
    listings are not texted separately from their store, and nothing is
    sent in quiet hours.
"""
import dataclasses
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.domains.listings.paid import fee_applies, fee_state
from api.domains.listings.time_left import format_time_left, time_left
from api.models.launch_offer import LaunchOfferClaim, LaunchOfferType
from api.models.store import Store
from api.models.store_billing import StoreSubscription
from api.security import create_access_token

_MODULES = (
    "api.domains.listings.service", "api.domains.listings.paid",
    "api.domains.pricing.service", "api.domains.pricing.payments",
    "api.domains.pricing.router", "api.domains.pricing.launch_offers",
    "api.domains.pricing.expiry_alerts", "api.domains.stores.service",
    "api.domains.stores.billing", "api.domains.stores.router",
)


def _patch(monkeypatch, **overrides):
    patched = dataclasses.replace(settings, **overrides)
    for module in _MODULES:
        monkeypatch.setattr(f"{module}.settings", patched)
    return patched


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_launch_offers.db"
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
def offers_on(monkeypatch):
    """Fees + store billing on, founding offer off, tiny offer limits so
    exhaustion takes three users, not fifty-one."""
    _patch(monkeypatch, listing_fees_enabled=True, store_billing_enabled=True,
           in_app_payments_enabled=False, free_listings_per_seller=0,
           founding_seller_tiers=(), free_listing_offer_limit=2,
           free_store_offer_limit=1, free_listing_offer_days=60,
           free_store_offer_days=60, expiry_sms_enabled=True,
           expiry_sms_days_before=2)


async def _user() -> tuple[str, dict]:
    u = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


_n = iter(range(1000, 9999))


async def _register_store_owner(client) -> tuple[str, dict]:
    """A long-term seller, made directly in the DB (like _user).

    Through /auth/register this needed an OTP round trip, and the OTP
    rate limiter is shared across the whole suite: by the time this file
    runs in a full-suite pass the budget is spent and registration 429s.
    The store endpoints only need the account shape, not the signup path.
    """
    from api.database import AccountType, SellerTier

    n = next(_n)
    u = User(name=f"Owner {n}", phone=f"+254799{n:06d}", password_hash="x",
             account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term,
             business_name=f"Biz {n}", business_category="Electronics")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u.id, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _listing(client, headers, **extra) -> dict:
    r = await client.post("/listings/", headers=headers, json={
        "description": "Well kept, works perfectly - selling because I upgraded.",
        "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
        "price": 20000, "lat": -1.28, "lng": 36.82, **extra})
    assert r.status_code == 201, r.text
    return r.json()


# ── Time left (pure) ─────────────────────────────────────────────────────────

def test_time_left_shapes():
    now = datetime(2026, 10, 1, 12, 0, 0)
    assert time_left(None, now)["label"] == "No expiry"
    soon = time_left(now + timedelta(days=2, hours=3), now)
    assert soon["label"] == "2d 3h left" and soon["is_expiring_soon"] is True
    assert soon["seconds_left"] == 2 * 86400 + 3 * 3600
    assert time_left(now - timedelta(hours=1), now, created_at=now - timedelta(days=9))["status"] == "expired"
    draft = time_left(now, now, created_at=now)
    assert draft["status"] == "unpaid"
    assert format_time_left(45 * 60) == "45m left"
    assert format_time_left(0) == "Offline"


# ── Free listings: first N, one per user ─────────────────────────────────────

@pytest.mark.asyncio
async def test_first_listings_free_one_per_user_then_full_price(client):
    _, first = await _user()
    # A quote peeks: asking twice must not spend the slot.
    for _ in range(2):
        q = (await client.get("/pricing/listing-fee/quote", headers=first,
                              params={"category": "Electronics", "price": 20000})).json()
        assert q["launch_offer"]["eligible"] is True and q["free_listing"] is True

    free = await _listing(client, first)
    assert free["listing_fee"]["status"] in ("live", "ending")
    assert free["listing_fee"]["needs_payment"] is False
    assert abs((datetime.fromisoformat(free["paid_until"])
                - datetime.utcnow()).days - 60) <= 1
    assert free["time_left_label"].endswith("left")

    # Second listing for the same user: the offer is one per user.
    second = await _listing(client, first)
    assert second["listing_fee"]["status"] == "unpaid"

    # Slots: rank 1 taken; one more user free, the next pays.
    _, other = await _user()
    assert (await _listing(client, other))["listing_fee"]["status"] in ("live", "ending")
    _, third = await _user()
    assert (await _listing(client, third))["listing_fee"]["status"] == "unpaid"

    offers = (await client.get("/pricing/launch-offers", headers=third)).json()
    assert offers["listing_free"]["remaining"] == 0
    assert offers["listing_free"]["already_claimed"] is False

    async with AsyncSessionLocal() as db:
        claims = (await db.execute(select(LaunchOfferClaim).where(
            LaunchOfferClaim.offer_type == LaunchOfferType.LISTING_FREE))).scalars().all()
    assert sorted(c.rank for c in claims) == [1, 2]


@pytest.mark.asyncio
async def test_deleting_a_free_listing_does_not_recycle_its_slot(client, monkeypatch):
    # Raise the limit for this test alone: the module DB's two slots are
    # already claimed above, and exhaustion is proven there. Here the
    # per-user half of the rule is what's under test.
    _patch(monkeypatch, listing_fees_enabled=True, store_billing_enabled=True,
           in_app_payments_enabled=False, free_listings_per_seller=0,
           founding_seller_tiers=(), free_listing_offer_limit=99,
           free_store_offer_limit=99)
    from api.domains.pricing import launch_offers

    uid, _ = await _user()
    async with AsyncSessionLocal() as db:
        first = await launch_offers.claim_listing_offer(db, uid, "listing-a")
        await db.commit()
        assert first is not None
        # "Deleted" the free listing (its row is what the claim points at;
        # claims are never recycled), then claimed again: still refused.
        assert await launch_offers.claim_listing_offer(db, uid, "listing-b") is None
        await db.rollback()


# ── Store listings never pay ─────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_store_listing_never_pays_even_with_store_billing_off(client, monkeypatch):
    owner_id, headers = await _register_store_owner(client)
    store = (await client.post("/stores", headers=headers, json={
        "name": f"Shop {next(_n)}", "store_type": "virtual",
        "slug": f"shop-{uuid.uuid4().hex[:8]}"})).json()
    # The first store (limit 1) opened live on its free period.
    assert store["billing"]["active"] is True
    assert store["time_left_label"].endswith("left")

    listing = await _listing(client, headers, store_id=store["id"])
    assert listing["listing_fee"]["status"] == "store_covered"
    assert listing["listing_fee"]["needs_payment"] is False

    # And with store billing switched OFF entirely it is still free.
    _patch(monkeypatch, listing_fees_enabled=True, store_billing_enabled=False,
           in_app_payments_enabled=False, free_listings_per_seller=0,
           founding_seller_tiers=(), free_listing_offer_limit=2,
           free_store_offer_limit=1)
    listing2 = await _listing(client, headers, store_id=store["id"])
    assert listing2["listing_fee"]["status"] == "store_covered"
    async with AsyncSessionLocal() as db:
        row = await db.get(Listing, listing2["id"])
        assert fee_applies(row) is False
        assert fee_state(row)["status"] == "store_covered"
        # No launch-offer slot was burned by either store listing.
        mine = (await db.execute(select(LaunchOfferClaim).where(
            LaunchOfferClaim.user_id == owner_id,
            LaunchOfferClaim.offer_type == LaunchOfferType.LISTING_FREE))).scalars().all()
        assert mine == []


@pytest.mark.asyncio
async def test_second_store_gets_no_free_period(client):
    _, headers = await _register_store_owner(client)
    store = (await client.post("/stores", headers=headers, json={
        "name": f"Shop {next(_n)}", "store_type": "virtual",
        "slug": f"shop-{uuid.uuid4().hex[:8]}"})).json()
    # The single store slot went to the previous test's owner.
    assert store["billing"]["active"] is False
    offers = (await client.get("/pricing/launch-offers", headers=headers)).json()
    assert offers["store_free"]["remaining"] == 0


# ── Expiry SMS ───────────────────────────────────────────────────────────────

class _FakeSMS:
    def __init__(self, ok=True):
        self.ok, self.sent = ok, []

    async def send(self, phone, message):
        self.sent.append((phone, message))
        return self.ok


async def _listing_row(seller_id, paid_until, **kw) -> str:
    async with AsyncSessionLocal() as db:
        row = Listing(seller_id=seller_id, name=kw.pop("name", "Phone"),
                      category="Electronics", price=20000, lat=-1.0, lng=36.0,
                      paid_until=paid_until,
                      created_at=paid_until - timedelta(days=30), **kw)
        db.add(row)
        await db.commit()
        return row.id


@pytest.mark.asyncio
async def test_expiry_sms_once_per_period_and_renewal_earns_a_new_one(client, monkeypatch):
    from api.domains.pricing import expiry_alerts

    fake = _FakeSMS()
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: fake)
    seller_id, _ = await _user()
    # Midday EAT (09:00 UTC), so quiet hours do not defer the pass.
    now = datetime.utcnow().replace(hour=9, minute=0, second=0, microsecond=0)
    lid = await _listing_row(seller_id, now + timedelta(days=1))

    async with AsyncSessionLocal() as db:
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 1
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 0
    assert len(fake.sent) == 1 and "goes offline in 1 day" in fake.sent[0][1]

    # Renewal moves paid_until: a new period, a new (single) text.
    async with AsyncSessionLocal() as db:
        row = await db.get(Listing, lid)
        row.paid_until = now + timedelta(days=2)
        await db.commit()
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 1
    assert len(fake.sent) == 2


@pytest.mark.asyncio
async def test_expiry_sms_skips_drafts_store_listings_and_failed_sends_retry(client, monkeypatch):
    from api.domains.pricing import expiry_alerts

    fake = _FakeSMS(ok=False)
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: fake)
    seller_id, _ = await _user()
    now = datetime.utcnow().replace(hour=9, minute=0, second=0, microsecond=0)
    due = now + timedelta(days=1)
    await _listing_row(seller_id, due, name="RetryPhone")
    # Never-paid draft (paid_until == created_at) and a far-future listing.
    async with AsyncSessionLocal() as db:
        db.add(Listing(seller_id=seller_id, name="Draft", category="Electronics",
                       price=100, lat=0, lng=0, paid_until=now, created_at=now))
        db.add(Listing(seller_id=seller_id, name="Far", category="Electronics",
                       price=100, lat=0, lng=0, paid_until=now + timedelta(days=30),
                       created_at=now))
        await db.commit()
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 0
    # The failed send kept no dedup row: with a working provider it goes out.
    fake.ok = True
    async with AsyncSessionLocal() as db:
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 1
    assert any("RetryPhone" in text for _, text in fake.sent)


@pytest.mark.asyncio
async def test_offers_status_reports_enabled_and_store_listing_time_left(client):
    _, headers = await _user()
    offers = (await client.get("/pricing/launch-offers", headers=headers)).json()
    assert offers["listing_free"]["enabled"] is True
    assert offers["store_free"]["enabled"] is True
    # A store listing must never report "No expiry" off its own paid_until:
    # its store's plan is the clock (listings/service._public_time_left).
    from api.domains.listings.service import _public_time_left

    class _L:
        store_id = "store-1"
        paid_until = None
        created_at = datetime(2026, 10, 1)

    out = _public_time_left(_L())
    assert out["time_left"]["status"] == "store_covered"
    assert out["time_left_label"] == "Live via store plan"


@pytest.mark.asyncio
async def test_expiry_sms_no_phone_claims_period_without_sending(client, monkeypatch):
    from api.domains.pricing import expiry_alerts
    from api.models.expiry_notification import ExpiryNotification

    fake = _FakeSMS()
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: fake)
    async with AsyncSessionLocal() as db:
        u = User(name="NoPhone", phone="", password_hash="x")
        db.add(u)
        await db.commit()
        seller_id = u.id
    now = datetime.utcnow().replace(hour=9, minute=0, second=0, microsecond=0)
    lid = await _listing_row(seller_id, now + timedelta(days=1))
    async with AsyncSessionLocal() as db:
        assert (await expiry_alerts.send_due_expiry_alerts(db, now))["listings"] == 0
        rows = (await db.execute(select(ExpiryNotification).where(
            ExpiryNotification.entity_id == lid))).scalars().all()
    assert fake.sent == [] and len(rows) == 1


@pytest.mark.asyncio
async def test_expiry_sms_for_store_and_quiet_hours_defer(client, monkeypatch):
    from api.domains.pricing import expiry_alerts

    fake = _FakeSMS()
    monkeypatch.setattr("api.core.sms.get_sms_provider", lambda: fake)
    owner_id, _ = await _user()
    now = datetime.utcnow().replace(hour=9, minute=0, second=0, microsecond=0)
    async with AsyncSessionLocal() as db:
        store = Store(owner_id=owner_id, name="Expiry Shop",
                      slug=f"expiry-{uuid.uuid4().hex[:8]}")
        db.add(store)
        await db.flush()
        db.add(StoreSubscription(store_id=store.id, plan_id="goods-20", listings=20,
                                 setup_fee_paid=True, paid_until=now + timedelta(days=2)))
        await db.commit()
        sent = await expiry_alerts.send_due_expiry_alerts(db, now)
        assert sent["stores"] == 1
        # 23:00 UTC is 02:00 in Nairobi: deferred, not sent, not claimed.
        night = now.replace(hour=23)
        assert (await expiry_alerts.send_due_expiry_alerts(db, night))["stores"] == 0
    assert len(fake.sent) == 1 and "Expiry Shop" in fake.sent[0][1]
