"""
Online Stores phase 2: setting a store up, and what its owner sees.

  - who can open a store (long-term sellers; others upgrade first)
  - the link name: rules, the live availability check, fixed after setup
  - category (BROKA's own taxonomy, legacy values mapped, one or more per
    store - several put a store in the "Wholesale and General" facet)
  - the business email (optional, and only ever saved verified)
  - contact fields that are gone
  - the store payload's owner trust facts
  - the storefront's category rail and catalogue filters
  - visit and share counting, and the owner's stats

Same fixture shape as test_stores.py.
"""
import itertools
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import (
    AsyncSessionLocal, Review, SellerMetricSnapshot, User, init_db, reset_engine,
)
from api.domains.stores import naming, stats as store_stats
from api.domains.stores import categories as store_categories
from api.models.store import StoreDailyCount
from tests.legal_payload import legal_payload


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_store_setup.db"
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

# The API's own store page only renders when it is the link host (a
# deployment whose STORE_LINK_BASE is this service); otherwise it
# redirects to the web storefront. See TestWebStorefrontSupport.
ON_LINK_HOST = {"x-forwarded-host": "broka.co.ke"}


async def _register(client, tier="long_term", business_category="Electronics", email=None):
    """(user_id, headers). tier: "long_term", "short_term" or None (buyer)."""
    n = next(_n)
    phone = f"0745{n:06d}"
    code = (await client.post("/auth/otp/request", json={"phone": phone})).json()["debug_code"]
    token = (await client.post("/auth/otp/verify", json={"phone": phone, "code": code})).json()[
        "phone_verify_token"]
    body = {
        "phone_verify_token": token, "name": f"Seller {n}", "password": "Passw0rd!x",
        "lat": -1.286, "lng": 36.817, "email": email,
        "legal_acceptance": legal_payload(),
    }
    if tier:
        body.update(account_type="buyer_seller", seller_tier=tier)
    if tier == "long_term":
        body.update(business_name=f"Biz {n}", business_category=business_category,
                    business_location="Nairobi")
    reg = await client.post("/auth/register", json=body)
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], {"Authorization": f"Bearer {reg.json()['access_token']}"}


# A 1x1 PNG as a legacy data URI: a real, inline image the compulsory
# shop-photo rule accepts.
_SHOP_PHOTO = ("data:image/png;base64,"
               "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")


async def _store(client, headers, **fields) -> dict:
    body = {"name": f"Shop {next(_n)}", **fields}
    # A store opened by a current client (one that chose a link name) must
    # carry at least one shop photo. Tests about link names don't care
    # about the image, so the helper supplies one.
    if "slug" in body and "photos" not in body and "photo_ids" not in body:
        body["photos"] = [_SHOP_PHOTO]
    r = await client.post("/stores", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _listing(client, headers, store_id, name, category="Electronics", price=1000):
    r = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
        "name": name, "category": category, "price": price, "lat": -1.0, "lng": 36.0,
        "store_id": store_id,
    }, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


# ── Who can open a store ─────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestWhoCanOpenAStore:
    async def test_a_buyer_cannot(self, client):
        _, headers = await _register(client, tier=None)
        r = await client.post("/stores", json={"name": "Nope"}, headers=headers)
        assert r.status_code == 403
        assert "long-term" in r.json()["detail"]

    async def test_a_short_term_seller_cannot_until_they_upgrade(self, client):
        _, headers = await _register(client, tier="short_term")
        r = await client.post("/stores", json={"name": "Not Yet"}, headers=headers)
        assert r.status_code == 403

        up = await client.post("/auth/upgrade-to-seller", json={
            "business_name": "Upgraded Traders", "business_category": "Wholesale",
            "business_location": "Kisumu",
        }, headers=headers)
        assert up.status_code == 200
        assert up.json()["seller_tier"] == "long_term"

        store = await _store(client, headers)
        # No category sent: taken from the business category given when
        # upgrading, mapped onto BROKA's taxonomy.
        assert store["category"] == "Business & Industrial"

    async def test_a_long_term_seller_can(self, client):
        _, headers = await _register(client)
        await _store(client, headers)


# ── Link names ───────────────────────────────────────────────────────────────

class TestLinkNameRules:
    @pytest.mark.parametrize("name", ["clanix", "abc", "clanix-shop", "a1-b2-c3", "x" * 30])
    def test_valid(self, name):
        assert naming.check_link_name(name) is None

    @pytest.mark.parametrize("name,fragment", [
        ("ab", "at least 3"),
        ("x" * 31, "at most 30"),
        ("-clanix", "start or end"),
        ("clanix-", "start or end"),
        ("clanix--shop", "one hyphen"),
        ("clanix shop", "no spaces"),
        ("clanix_shop", "only letters"),
        ("klänix", "only letters"),
        ("admin", "reserved"),
        ("support", "reserved"),
        ("broka", "reserved"),
    ])
    def test_invalid(self, name, fragment):
        assert fragment in naming.check_link_name(name)

    def test_suggestions_are_always_valid(self):
        for text in ["Clanix Electronics", "A", "", "🔥🔥", "Admin", "x" * 80, "Mama Mboga & Sons Ltd."]:
            suggestion = naming.suggest_base(text)
            assert naming.check_link_name(suggestion) is None, (text, suggestion)
        assert naming.check_link_name(naming.numbered("x" * 30, 12)) is None
        assert len(naming.numbered("x" * 30, 12)) == 30


@pytest.mark.asyncio
class TestLinkNames:
    async def test_the_chosen_link_is_saved(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Clanix Electronics", slug="Clanix")
        assert store["slug"] == "clanix"
        assert store["url"].endswith("/store/clanix")

    async def test_an_invalid_or_reserved_link_is_refused(self, client):
        _, headers = await _register(client)
        for slug, status in [("no spaces", 400), ("admin", 400), ("x", 400)]:
            r = await client.post("/stores", json={"name": "Shop", "slug": slug}, headers=headers)
            assert r.status_code == status, slug

    async def test_a_taken_link_is_refused_not_renumbered(self, client):
        _, a = await _register(client)
        _, b = await _register(client)
        await _store(client, a, slug="taken-link")
        r = await client.post("/stores", json={"name": "Shop", "slug": "taken-link"}, headers=b)
        assert r.status_code == 409

    async def test_the_availability_check(self, client):
        _, owner = await _register(client)
        await _store(client, owner, slug="mama-mboga")
        _, headers = await _register(client)

        assert (await client.get("/stores/name-available", params={"name": "x"})).status_code == 401

        async def check(name):
            r = await client.get("/stores/name-available", params={"name": name}, headers=headers)
            assert r.status_code == 200
            return r.json()

        free = await check("Mama-Mboga-Kisumu")
        assert free["available"] is True and free["name"] == "mama-mboga-kisumu"
        assert free["url"].endswith("/store/mama-mboga-kisumu")

        taken = await check("mama-mboga")
        assert taken["available"] is False
        assert taken["reason"] == "That link is already taken."
        assert taken["suggestion"] == "mama-mboga-2"

        reserved = await check("admin")
        assert reserved["available"] is False and "reserved" in reserved["reason"]
        assert naming.check_link_name(reserved["suggestion"]) is None

        invalid = await check("Mama Mboga!")
        assert invalid["available"] is False
        assert invalid["suggestion"] == "mama-mboga-2"

    async def test_renaming_never_changes_the_link(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Old Name", slug="fixed-link")
        r = await client.patch(f"/stores/{store['id']}", json={"name": "New Name"}, headers=headers)
        assert r.status_code == 200
        assert r.json()["name"] == "New Name"
        assert r.json()["slug"] == "fixed-link"
        # Sending the same link back (a settings form does) is fine...
        same = await client.patch(f"/stores/{store['id']}", json={"slug": "fixed-link"}, headers=headers)
        assert same.status_code == 200
        # ...changing it isn't.
        other = await client.patch(f"/stores/{store['id']}", json={"slug": "new-link"}, headers=headers)
        assert other.status_code == 400

    async def test_links_are_case_insensitive(self, client):
        _, headers = await _register(client)
        await _store(client, headers, slug="casey-shop")
        assert (await client.get("/stores/slug/Casey-Shop")).status_code == 200
        assert (await client.get("/store/CASEY-SHOP", headers=ON_LINK_HOST)).status_code == 200

    async def test_a_store_without_a_chosen_link_gets_a_valid_one(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name="Support")
        assert naming.check_link_name(store["slug"]) is None


# ── Category ─────────────────────────────────────────────────────────────────

class TestCategoryMapping:
    def test_mapping(self):
        assert store_categories.canonical("electronics") == "Electronics"
        assert store_categories.canonical("Phones") is None
        assert store_categories.from_legacy("Clothing & Fashion") == "Fashion"
        assert store_categories.from_legacy("Building Materials") == "Construction"
        assert store_categories.from_legacy("Something else") == "Other"
        assert store_categories.from_legacy(None) is None
        assert store_categories.for_listing("furniture") == "Other"
        assert store_categories.for_listing("home & furniture") == "Home & Furniture"


@pytest.mark.asyncio
class TestCategory:
    async def test_a_canonical_category_is_saved_and_filterable(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, category="beauty & personal care")
        assert store["category"] == "Beauty & Personal Care"
        found = (await client.get("/stores", params={"category": "Beauty & Personal Care",
                                                       "limit": 100})).json()
        assert store["id"] in [s["id"] for s in found]

    async def test_an_unknown_category_is_refused(self, client):
        _, headers = await _register(client)
        r = await client.post("/stores", json={"name": "Shop", "category": "Gadgets"}, headers=headers)
        assert r.status_code == 400

    async def test_an_old_app_specialization_is_mapped(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, specialization="Phones & Accessories")
        assert store["category"] == "Electronics"

    async def test_the_category_can_be_changed(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, category="Fashion")
        r = await client.patch(f"/stores/{store['id']}", json={"category": "Gaming"}, headers=headers)
        assert r.json()["category"] == "Gaming"

    async def test_several_categories_find_the_store_in_each(self, client):
        """A store may sell across several categories. It is listed under
        every one it chose, and the first chosen stays the primary for
        clients that read a single category."""
        _, headers = await _register(client)
        store = await _store(client, headers, categories=["Fashion", "Electronics"])
        assert store["category"] == "Fashion"
        assert store["categories"] == ["Fashion", "Electronics"]

        async def directory(category):
            found = (await client.get(
                "/stores", params={"category": category, "limit": 100})).json()
            return [s["id"] for s in found]

        assert store["id"] in await directory("Fashion")
        assert store["id"] in await directory("Electronics")

    async def test_the_wholesale_facet_lists_stores_with_two_or_more_categories(self, client):
        _, headers = await _register(client)
        both = await _store(client, headers, categories=["Electronics", "Fashion"])
        _, other = await _register(client)
        one = await _store(client, other, categories=["Electronics"])

        async def facet():
            found = (await client.get(
                "/stores", params={"category": "Wholesale and General", "limit": 100})).json()
            return [s["id"] for s in found]

        assert both["id"] in await facet()
        assert one["id"] not in await facet()

    async def test_a_list_with_an_unknown_category_is_refused(self, client):
        _, headers = await _register(client)
        r = await client.post("/stores", json={
            "name": "Bad List", "categories": ["Electronics", "Gadgets"]}, headers=headers)
        assert r.status_code == 400

    async def test_an_empty_category_list_is_refused(self, client):
        _, headers = await _register(client)
        r = await client.post("/stores", json={
            "name": "Empty List", "categories": []}, headers=headers)
        assert r.status_code == 400

    async def test_updating_replaces_the_chosen_set(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, categories=["Fashion", "Electronics"])
        r = await client.patch(f"/stores/{store['id']}", json={"categories": ["Gaming"]},
                               headers=headers)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["category"] == "Gaming" and body["categories"] == ["Gaming"]

        async def directory(category):
            found = (await client.get(
                "/stores", params={"category": category, "limit": 100})).json()
            return [s["id"] for s in found]

        assert store["id"] in await directory("Gaming")
        assert store["id"] not in await directory("Fashion")
        assert store["id"] not in await directory("Electronics")

    async def test_a_store_without_links_is_backfilled(self, client):
        """Stores that predate multi-category carry `category` but no link
        rows; the startup backfill gives each its one link so the
        directory's link-based filter finds them."""
        from api.domains.stores.categories import backfill_store_category_links
        from api.models.store import Store, StoreCategoryLink

        owner_id, _ = await _register(client)
        async with AsyncSessionLocal() as db:
            store = Store(owner_id=owner_id, name="Old Timer", slug="old-timer",
                          category="Gaming")
            db.add(store)
            await db.commit()
            await db.refresh(store)
            store_id = store.id

        created = await backfill_store_category_links()
        assert created >= 1
        async with AsyncSessionLocal() as db:
            names = (await db.execute(
                select(StoreCategoryLink.category)
                .where(StoreCategoryLink.store_id == store_id))).scalars().all()
        assert list(names) == ["Gaming"]

        found = (await client.get("/stores", params={"category": "Gaming", "limit": 100})).json()
        assert store_id in [s["id"] for s in found]

    async def test_a_wholesaler_is_found_under_every_category_it_stocks(self, client):
        """A wholesaler is listed under one category but sells in many.
        Matching only Store.category hid it from every category it stocks;
        a live listing in the category is what should find it - the setup
        screen has always said products from any category can go in."""
        _, headers = await _register(client, business_category="Wholesale")
        store = await _store(client, headers)
        assert store["category"] == "Business & Industrial"

        async def directory(category):
            found = (await client.get(
                "/stores", params={"category": category, "limit": 100})).json()
            return [s["id"] for s in found]

        # Its own category finds it before it has listed anything...
        assert store["id"] in await directory("Business & Industrial")
        # ...and Electronics does not.
        assert store["id"] not in await directory("Electronics")

        await _listing(client, headers, store["id"], "Wholesale chargers",
                       category="Electronics")
        assert store["id"] in await directory("Electronics")

    async def test_a_store_is_found_under_its_main_category_with_no_listings(self, client):
        """A new shop isn't hidden until its first product is live."""
        _, headers = await _register(client)
        store = await _store(client, headers, category="Gaming")
        found = (await client.get(
            "/stores", params={"category": "Gaming", "limit": 100})).json()
        assert store["id"] in [s["id"] for s in found]

    async def test_other_matches_a_store_with_an_outside_category_listing(self, client):
        """"Other" is every listing outside BROKA's named categories, the
        same rule the storefront's rail counts by - not just the literal
        word "Other"."""
        _, headers = await _register(client)
        store = await _store(client, headers, category="Gaming")
        await _listing(client, headers, store["id"], "Old shelf item", category="furniture")
        found = (await client.get(
            "/stores", params={"category": "Other", "limit": 100})).json()
        assert store["id"] in [s["id"] for s in found]


# ── The compulsory shop photo ────────────────────────────────────────────────

@pytest.mark.asyncio
class TestShopPhotoRequired:
    async def test_a_current_client_must_send_a_shop_photo(self, client):
        _, headers = await _register(client)
        r = await client.post("/stores", json={
            "name": "Bare Shop", "slug": "bare-shop"}, headers=headers)
        assert r.status_code == 400
        assert "photo" in r.json()["detail"].lower()

    async def test_a_shop_photo_opens_the_store(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, slug="photo-shop")
        assert store["photos"] == [_SHOP_PHOTO]

    async def test_an_old_build_without_a_link_name_is_never_refused(self, client):
        # App builds that predate phase 2 send no slug and no image assets;
        # refusing them would lock sellers on old builds out entirely.
        _, headers = await _register(client)
        store = await _store(client, headers)
        assert store["photos"] == []


# ── Business email ───────────────────────────────────────────────────────────

async def _email_token(client, headers, email: str) -> str:
    sent = await client.post("/stores/email/request-code", json={"email": email}, headers=headers)
    assert sent.status_code == 200, sent.text
    verified = await client.post("/stores/email/verify", json={
        "email": email, "code": sent.json()["debug_code"]}, headers=headers)
    assert verified.status_code == 200, verified.text
    return verified.json()["email_verify_token"]


@pytest.mark.asyncio
class TestBusinessEmail:
    async def test_it_is_optional(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers)
        assert store["business_email"] is None
        assert store["business_email_verified"] is False

    async def test_an_unverified_address_is_refused(self, client):
        _, headers = await _register(client)
        r = await client.post("/stores", json={
            "name": "Shop", "business_email": "sales@clanix.co.ke"}, headers=headers)
        assert r.status_code == 400
        assert "Verify" in r.json()["detail"]

    async def test_a_verified_address_is_saved(self, client):
        _, headers = await _register(client)
        token = await _email_token(client, headers, "Sales@Clanix.co.ke")
        store = await _store(client, headers, business_email="sales@clanix.co.ke",
                             business_email_token=token)
        assert store["business_email"] == "sales@clanix.co.ke"
        assert store["business_email_verified"] is True

    async def test_a_token_for_another_address_doesnt_count(self, client):
        _, headers = await _register(client)
        token = await _email_token(client, headers, "mine@clanix.co.ke")
        r = await client.post("/stores", json={
            "name": "Shop", "business_email": "someone.else@clanix.co.ke",
            "business_email_token": token}, headers=headers)
        assert r.status_code == 400

    async def test_an_address_that_has_an_account_can_still_be_verified(self, client):
        # The signup email step refuses addresses already in use; a store's
        # business email is often exactly that (the owner's own address).
        _, headers = await _register(client, email="owner.taken@clanix.co.ke")
        assert (await client.post("/auth/email/otp/request",
                                  json={"email": "owner.taken@clanix.co.ke"})).status_code == 409
        await _email_token(client, headers, "owner.taken@clanix.co.ke")

    async def test_the_owners_verified_account_email_needs_no_code(self, client):
        user_id, headers = await _register(client, email="proven@clanix.co.ke")
        async with AsyncSessionLocal() as db:
            user = await db.get(User, user_id)
            user.email_verified = True
            await db.commit()
        store = await _store(client, headers, business_email="proven@clanix.co.ke")
        assert store["business_email_verified"] is True

    async def test_saving_the_same_address_again_keeps_it_verified_and_it_can_be_cleared(self, client):
        _, headers = await _register(client)
        token = await _email_token(client, headers, "keep@clanix.co.ke")
        store = await _store(client, headers, business_email="keep@clanix.co.ke",
                             business_email_token=token)
        again = await client.patch(f"/stores/{store['id']}", json={
            "business_email": "keep@clanix.co.ke", "description": "Hi"}, headers=headers)
        assert again.json()["business_email_verified"] is True
        cleared = await client.patch(f"/stores/{store['id']}", json={"business_email": ""},
                                     headers=headers)
        assert cleared.json()["business_email"] is None
        assert cleared.json()["business_email_verified"] is False

    async def test_old_app_builds_can_still_send_an_unverified_email(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, official_email="old@clanix.co.ke")
        assert store["business_email"] == "old@clanix.co.ke"
        assert store["business_email_verified"] is False
        bad = await client.post("/stores", json={"name": "Shop", "official_email": "not an email"},
                                headers=(await _register(client))[1])
        assert bad.status_code == 400

    async def test_an_unverified_address_is_shown_only_to_the_owner(self, client):
        """It may be a typo or someone else's address: public reads - the
        store page, the directory - never show it."""
        _, headers = await _register(client)
        store = await _store(client, headers, official_email="typo@clanix.co.ke")
        assert store["business_email"] == "typo@clanix.co.ke"            # the owner's own response
        mine = (await client.get("/stores/mine", headers=headers)).json()
        assert mine["business_email"] == "typo@clanix.co.ke"
        by_id = (await client.get(f"/stores/{store['id']}")).json()
        by_slug = (await client.get(f"/stores/slug/{store['slug']}")).json()
        listed = next(s for s in (await client.get("/stores", params={"limit": 100})).json()
                      if s["id"] == store["id"])
        for public in (by_id, by_slug, listed):
            assert public["business_email"] is None
            assert public["business_email_verified"] is False

    async def test_a_verified_address_is_public(self, client):
        _, headers = await _register(client)
        token = await _email_token(client, headers, "hello@verified-shop.co.ke")
        store = await _store(client, headers, business_email="hello@verified-shop.co.ke",
                             business_email_token=token)
        public = (await client.get(f"/stores/{store['id']}")).json()
        assert public["business_email"] == "hello@verified-shop.co.ke"


# ── Payload ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestStorePayload:
    async def test_owner_trust_facts_are_real(self, client):
        user_id, headers = await _register(client)
        async with AsyncSessionLocal() as db:
            user = await db.get(User, user_id)
            user.is_verified = True
            user.completed_deals = 7
            user.rating = 4.46
            await db.commit()
        store = await _store(client, headers)
        owner = store["owner"]
        assert owner["verified"] is True
        assert owner["completed_deals"] == 7
        assert owner["rating"] == 4.5
        assert owner["member_since"]
        assert "id" not in owner and "phone" not in owner

        # Who runs the store: the store page's "Store details" names them.
        async with AsyncSessionLocal() as db:
            expected_name = (await db.get(User, user_id)).name
        assert owner["name"] == expected_name
        public = (await client.get(f"/stores/{store['id']}")).json()
        assert public["owner"] == owner

        directory = (await client.get("/stores", params={"limit": 100})).json()
        listed = next(s for s in directory if s["id"] == store["id"])
        assert listed["owner"] == owner

    async def test_owner_online_status(self, client):
        # The store cards say whether the owner is around, by the chat
        # header's rule: a heartbeat in the last five minutes.
        user_id, headers = await _register(client)
        store = await _store(client, headers)
        owner = (await client.get(f"/stores/{store['id']}")).json()["owner"]
        assert owner["online"] is False
        assert owner["last_active"] is None       # never seen: no guess

        await client.patch("/auth/heartbeat", headers=headers)
        owner = (await client.get(f"/stores/{store['id']}")).json()["owner"]
        assert owner["online"] is True
        assert owner["last_active"] == "Active now"

        async with AsyncSessionLocal() as db:
            (await db.get(User, user_id)).last_seen = datetime.utcnow() - timedelta(hours=3)
            await db.commit()
        directory = (await client.get("/stores", params={"limit": 100})).json()
        owner = next(s for s in directory if s["id"] == store["id"])["owner"]
        assert owner["online"] is False
        assert owner["last_active"] == "Active 3h ago"

    async def test_the_web_page_shows_no_phone_numbers(self, client):
        from api.models.store import Store
        _, headers = await _register(client)
        store = await _store(client, headers, slug="no-phones")
        # Even a store that has old contact values in its row.
        async with AsyncSessionLocal() as db:
            row = await db.get(Store, store["id"])
            row.official_phone = "0700123456"
            row.official_whatsapp = "254700123456"
            await db.commit()
        page = (await client.get("/store/no-phones", headers=ON_LINK_HOST)).text
        assert "0700123456" not in page and "wa.me" not in page and "tel:" not in page
        assert "0700123456" not in (await client.get(f"/stores/{store['id']}")).text


# ── Store details: buyer reviews and the owner's standing ────────────────────

@pytest.mark.asyncio
class TestStoreReviews:
    async def test_the_reviews_and_owner_standing_are_public(self, client):
        owner_id, headers = await _register(client)
        store = await _store(client, headers, category="Gaming")
        # The reviews are written directly: the review flow itself is
        # tested where it lives; this endpoint is about what a store's
        # details screen reads.
        buyer_id, _ = await _register(client)
        async with AsyncSessionLocal() as db:
            db.add(Review(deal_id=None, reviewer_id=buyer_id, seller_id=owner_id,
                          rating=4, comment="Quick delivery, as described"))
            db.add(SellerMetricSnapshot(
                seller_id=owner_id, snapshot_date=datetime.utcnow().date(),
                overall_rating=4.5, dcr_score=90.0, median_response_min=12.5,
                completed_deals=12))
            await db.commit()

        body = (await client.get(f"/stores/{store['id']}/reviews")).json()
        assert body["summary"]["avg"] == 4.0 and body["summary"]["count"] == 1
        assert body["summary"]["distribution"]["4"] == 1
        assert body["reviews"][0]["rating"] == 4
        assert body["reviews"][0]["comment"] == "Quick delivery, as described"
        from api.domains.reviews.service import ReviewService

        async with AsyncSessionLocal() as db:
            buyer_name = (await db.get(User, buyer_id)).name
        assert body["reviews"][0]["reviewer_name"] == ReviewService._public_name(buyer_name)
        assert body["seller_standing"]["median_response_minutes"] == 12.5
        # A store page is public and indexed: no seller, reviewer or deal
        # ids ride along, and no phone numbers either.
        assert owner_id not in str(body) and buyer_id not in str(body)
        assert "seller_id" not in body["reviews"][0]

    async def test_an_unknown_store_404s(self, client):
        assert (await client.get("/stores/nope/reviews")).status_code == 404

    async def test_a_store_without_reviews_reports_none_not_zero_ratings(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers)
        body = (await client.get(f"/stores/{store['id']}/reviews")).json()
        assert body["summary"] == {
            "avg": None, "count": 0,
            "distribution": {str(s): 0 for s in range(1, 6)},
        }
        assert body["reviews"] == []
        assert body["seller_standing"] is None   # no snapshot: unmeasured, not zero


# ── Storefront: categories and catalogue ─────────────────────────────────────

@pytest.mark.asyncio
class TestCatalogue:
    async def test_category_rail_and_filters(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers)
        sid = store["id"]
        await _listing(client, headers, sid, "Samsung A15", price=18000)
        await _listing(client, headers, sid, "Tecno Spark", price=12000)
        await _listing(client, headers, sid, "iPhone 12", price=45000)
        await _listing(client, headers, sid, "Office Chair", category="Home & Furniture", price=9000)
        await _listing(client, headers, sid, "Mystery Item", category="random stuff", price=100)

        cats = (await client.get(f"/stores/{sid}/categories")).json()
        # Online stores never browse by Other (nor Property, Automobiles,
        # Land, Services): the free-text row stays stored and listed, just
        # not railed.
        assert cats == [
            {"name": "Electronics", "count": 3},
            {"name": "Home & Furniture", "count": 1},
        ]

        async def names(**params):
            r = await client.get(f"/stores/{sid}/listings", params=params)
            assert r.status_code == 200, r.text
            return [item["name"] for item in r.json()]

        assert set(await names(category="electronics")) == {"Samsung A15", "Tecno Spark", "iPhone 12"}
        assert await names(search="tecno") == ["Tecno Spark"]
        assert (await names(sort="price_low"))[:2] == ["Mystery Item", "Office Chair"]
        assert (await names(sort="price_high"))[0] == "iPhone 12"
        assert (await names(sort="newest"))[0] == "Mystery Item"
        assert (await client.get(f"/stores/{sid}/listings", params={"sort": "cheapest"})).status_code == 422
        assert (await client.get(f"/stores/{sid}/listings", params={"category": "Gadgets"})).status_code == 400

        paged = (await client.get(f"/stores/{sid}/listings",
                                  params={"with_total": True, "limit": 2})).json()
        assert paged["total"] == 5 and len(paged["items"]) == 2

    async def test_directory_search_reaches_a_store_through_its_products(self, client):
        # Typing "router" used to match only a store NAME, so a shop selling
        # routers was invisible to the search that the storefronts offer.
        _, headers = await _register(client)
        store = await _store(client, headers, slug=f"router-shop-{next(_n)}")
        sid = store["id"]
        await _listing(client, headers, sid, "Airtel 5G router", price=1500)

        async def found(text):
            r = await client.get("/stores", params={"search": text, "limit": 100})
            assert r.status_code == 200, r.text
            return {s["id"] for s in r.json()}

        assert sid in await found("router")
        assert sid in await found("5g router")
        assert sid not in await found("cement mixer")

    async def test_directory_search_also_matches_place_and_category(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, name=f"Nyali Traders {next(_n)}",
                             county="Mombasa", subcounty="Nyali")
        sid = store["id"]
        assert sid in {s["id"] for s in (await client.get(
            "/stores", params={"search": "nyali"})).json()}
        assert sid in {s["id"] for s in (await client.get(
            "/stores", params={"search": "mombasa electronics"})).json()}

    async def test_a_store_cannot_lose_its_last_shop_photo(self, client):
        # Settings could take every photo away, leaving a shopfront with
        # nothing to show - the state the setup wizard already refuses.
        _, headers = await _register(client)
        store = await _store(client, headers, slug=f"photo-keep-{next(_n)}")
        r = await client.patch(f"/stores/{store['id']}",
                               json={"photos": []}, headers=headers)
        assert r.status_code == 400
        assert "photo" in r.json()["detail"].lower()
        assert (await client.get(f"/stores/{store['id']}")).json()["photos"] == [_SHOP_PHOTO]

    async def test_condition_and_price_filters(self, client):
        # The storefront's filter panel: condition and a price range, as on
        # Home. Before them the store's catalogue took only search, category
        # and sort, and a panel offering them would have filtered nothing.
        _, headers = await _register(client)
        sid = (await _store(client, headers))["id"]
        for name, price, condition in [("New Phone", 30000, "new"), ("Used Phone", 12000, "used"),
                                       ("Refurb Laptop", 25000, "refurbished")]:
            listing = await _listing(client, headers, sid, name, price=price)
            await _set_listing(listing["id"], condition=condition)

        async def names(**params):
            r = await client.get(f"/stores/{sid}/listings", params=params)
            assert r.status_code == 200, r.text
            return {item["name"] for item in r.json()}

        assert await names(condition="used") == {"Used Phone"}
        assert await names(max_price=25000) == {"Used Phone", "Refurb Laptop"}
        assert await names(min_price=20000, max_price=26000) == {"Refurb Laptop"}
        assert await names(condition="new", max_price=20000) == set()
        bad = [{"condition": "broken"}, {"max_price": -1}]
        for params in bad:
            r = await client.get(f"/stores/{sid}/listings", params=params)
            assert r.status_code == 422, params

    async def test_the_other_shelf_holds_what_the_rail_counts_there(self, client):
        # The rail used to count free-text categories as "Other"; tapping
        # "Other" filtered on the literal word, so it showed only "Odd Thing".
        # Online stores no longer rail Other at all, but the filter still
        # returns every listing outside the named categories.
        _, headers = await _register(client)
        store = await _store(client, headers)
        sid = store["id"]
        await _listing(client, headers, sid, "Phone", category="Electronics")
        await _listing(client, headers, sid, "Mystery Item", category="random stuff")
        await _listing(client, headers, sid, "Odd Thing", category="Other")

        cats = (await client.get(f"/stores/{sid}/categories")).json()
        assert all(c["name"] != "Other" for c in cats)
        r = await client.get(f"/stores/{sid}/listings",
                             params={"category": "other", "with_total": True})
        assert r.status_code == 200, r.text
        assert r.json()["total"] == 2
        assert {item["name"] for item in r.json()["items"]} == {"Mystery Item", "Odd Thing"}

    async def test_directory_search_matches_the_text_not_wildcards(self, client):
        # "_" and "%" were LIKE wildcards: searching "_" listed every store.
        _, a = await _register(client)
        await _store(client, a, name="Plain Name Shop")
        _, b = await _register(client)
        await _store(client, b, name="Under_score Shop")

        async def found(text):
            r = await client.get("/stores", params={"search": text, "limit": 100})
            assert r.status_code == 200, r.text
            return {s["name"] for s in r.json()}

        assert "Under_score Shop" in await found("_")
        assert "Plain Name Shop" not in await found("_")
        assert "Plain Name Shop" not in await found("%")
        assert "Plain Name Shop" in await found("plain name")

    async def test_a_paused_store_has_no_categories(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers)
        await _listing(client, headers, store["id"], "Thing")
        await client.post(f"/stores/{store['id']}/status", json={"is_active": False}, headers=headers)
        assert (await client.get(f"/stores/{store['id']}/categories")).json() == []


# ── My Store: the owner's product list ───────────────────────────────────────

async def _listing_row(listing_id: str):
    from api.database import Listing
    async with AsyncSessionLocal() as db:
        return await db.get(Listing, listing_id)


async def _set_listing(listing_id: str, **fields) -> None:
    """Puts a listing into a state the API reaches through deals and fees."""
    from api.database import Listing
    async with AsyncSessionLocal() as db:
        row = await db.get(Listing, listing_id)
        for name, value in fields.items():
            setattr(row, name, value(row) if callable(value) else value)
        await db.commit()


@pytest.mark.asyncio
class TestOwnerProducts:
    async def _stocked_store(self, client, headers) -> tuple[str, dict]:
        """A store with a product in every state, plus a deleted one."""
        from api.database import ListingStatus
        sid = (await _store(client, headers))["id"]
        made = {name: (await _listing(client, headers, sid, name))["id"] for name in (
            "Live phone", "Unpaid charger", "Expired cable", "Phone in a deal",
            "Sold laptop", "Deleted case")}
        now = datetime.utcnow()
        # Never paid: paid_until no later than it was listed.
        await _set_listing(made["Unpaid charger"], paid_until=lambda row: row.created_at)
        await _set_listing(made["Expired cable"], created_at=now - timedelta(days=40),
                           paid_until=now - timedelta(days=1))
        await _set_listing(made["Phone in a deal"], status=ListingStatus.pending)
        await _set_listing(made["Sold laptop"], status=ListingStatus.completed)
        await _set_listing(made["Deleted case"], status=ListingStatus.cancelled)
        return sid, made

    async def test_the_owner_sees_every_product_the_public_catalogue_hides(self, client):
        _, headers = await _register(client)
        sid, _ = await self._stocked_store(client, headers)

        public = (await client.get(f"/stores/{sid}/listings")).json()
        assert [p["name"] for p in public] == ["Live phone"]

        r = await client.get(f"/stores/{sid}/manage/listings", headers=headers)
        assert r.status_code == 200, r.text
        body = r.json()
        states = {p["name"]: p["store_state"] for p in body["items"]}
        assert states == {
            "Live phone": "live", "Unpaid charger": "hidden", "Expired cable": "hidden",
            "Phone in a deal": "in_deal", "Sold laptop": "sold",
        }
        assert body["counts"] == {
            "live": 1, "hidden": 2, "in_deal": 1, "sold": 1, "archived": 0, "all": 5,
        }
        fees = {p["name"]: p["listing_fee"]["status"] for p in body["items"]}
        assert fees["Unpaid charger"] == "unpaid" and fees["Expired cable"] == "expired"
        assert all(p["listing_fee"]["needs_payment"] for p in body["items"]
                   if p["store_state"] == "hidden")

    async def test_filtering_by_state_and_search(self, client):
        _, headers = await _register(client)
        sid, _ = await self._stocked_store(client, headers)

        async def get(**params):
            r = await client.get(f"/stores/{sid}/manage/listings", params=params, headers=headers)
            assert r.status_code == 200, r.text
            return r.json()

        hidden = await get(state="hidden")
        assert {p["name"] for p in hidden["items"]} == {"Unpaid charger", "Expired cable"}
        # The counts are for every state, whichever one is shown.
        assert hidden["counts"]["all"] == 5

        phones = await get(search="phone")
        assert {p["name"] for p in phones["items"]} == {"Live phone", "Phone in a deal"}
        assert phones["counts"] == {
            "live": 1, "hidden": 0, "in_deal": 1, "sold": 0, "archived": 0, "all": 2,
        }

        # "_" is text, not a wildcard (api/core/text_search.py).
        assert (await get(search="_"))["counts"]["all"] == 0

        first = await get(limit=2)
        second = await get(limit=2, offset=2)
        assert len(first["items"]) == 2 and len(second["items"]) == 2
        assert not {p["id"] for p in first["items"]} & {p["id"] for p in second["items"]}

        r = await client.get(f"/stores/{sid}/manage/listings", params={"state": "deleted"},
                             headers=headers)
        assert r.status_code == 422

    async def test_a_paused_store_still_shows_its_owner_everything(self, client):
        _, headers = await _register(client)
        sid = (await _store(client, headers))["id"]
        await _listing(client, headers, sid, "Kept for later")
        await client.post(f"/stores/{sid}/status", json={"is_active": False}, headers=headers)
        assert (await client.get(f"/stores/{sid}/listings")).json() == []
        body = (await client.get(f"/stores/{sid}/manage/listings", headers=headers)).json()
        assert [p["name"] for p in body["items"]] == ["Kept for later"]

    async def test_only_the_owner_and_only_their_store(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        sid = (await _store(client, owner))["id"]
        other_sid = (await _store(client, other))["id"]
        await _listing(client, owner, sid, "Mine")
        await _listing(client, other, other_sid, "Theirs")

        path = f"/stores/{sid}/manage/listings"
        assert (await client.get(path)).status_code == 401
        assert (await client.get(path, headers=other)).status_code == 403
        assert (await client.get("/stores/missing/manage/listings", headers=owner)).status_code == 404
        names = [p["name"] for p in (await client.get(path, headers=owner)).json()["items"]]
        assert names == ["Mine"]


# ── Visits, shares and stats ─────────────────────────────────────────────────

class TestVisitSource:
    @pytest.mark.parametrize("via,referer,expected", [
        ("whatsapp", None, "whatsapp"),
        ("WA", None, "whatsapp"),
        ("ig", None, "instagram"),
        ("tiktok", "https://www.facebook.com/", "tiktok"),
        ("newsletter", None, "other"),
        ("qr", None, "qr"),
        (None, "https://t.co/abc", "x"),
        (None, None, "direct"),
        (None, "https://l.facebook.com/l.php?u=x", "facebook"),
        (None, "https://www.tiktok.com/@clanix", "tiktok"),
        (None, "https://broka.co.ke/", "direct"),
        (None, "https://example.com/", "other"),
        (None, "not a url", "direct"),
    ])
    def test_sources(self, via, referer, expected):
        assert store_stats.visit_source(via, referer) == expected

    def test_share_channels(self):
        assert store_stats.share_channel("twitter") == "x"
        assert store_stats.share_channel("fb") == "facebook"
        assert store_stats.share_channel("carrier-pigeon") == "other"


@pytest.mark.asyncio
class TestVisitsAndStats:
    async def test_visits_are_counted_once_per_visitor_and_not_for_the_owner(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        sid = store["id"]
        _, buyer = await _register(client, tier=None)

        first = await client.post(f"/stores/{sid}/visit", json={"via": "whatsapp"}, headers=buyer)
        again = await client.post(f"/stores/{sid}/visit", json={"via": "whatsapp"}, headers=buyer)
        mine = await client.post(f"/stores/{sid}/visit", json={}, headers=owner)
        guest = await client.post(f"/stores/{sid}/visit", json={"via": "tiktok"})
        assert first.status_code == 202
        assert [first.json()["counted"], again.json()["counted"], mine.json()["counted"],
                guest.json()["counted"]] == [True, False, False, True]

        stats = (await client.get(f"/stores/{sid}/stats", headers=owner)).json()
        assert stats["days"] == 7 and len(stats["visits"]["by_day"]) == 7
        assert stats["visits"]["total"] == 2
        assert stats["visits"]["by_day"][-1] == {"date": store_stats.today().isoformat(), "count": 2}
        assert stats["visits"]["by_source"]["whatsapp"] == 1
        assert stats["visits"]["by_source"]["tiktok"] == 1
        assert stats["visits"]["by_surface"] == {"app": 2, "web": 0}

    async def test_a_long_link_tag_is_still_a_visit(self, client):
        # The app passes on the ?via= of whatever link opened it. A tag over
        # 32 characters was a 422, so the visit was silently never counted;
        # on the API's own store page it was a JSON error, not the page.
        _, owner = await _register(client)
        store = await _store(client, owner, slug="long-tags")
        _, buyer = await _register(client, tier=None)
        tag = "whatsapp-status-from-the-church-group-2026"
        r = await client.post(f"/stores/{store['id']}/visit", json={"via": tag}, headers=buyer)
        assert r.status_code == 202, r.text
        assert r.json()["counted"] is True
        stats = (await client.get(f"/stores/{store['id']}/stats", headers=owner)).json()
        assert stats["visits"]["by_source"]["other"] == 1

        page = await client.get(f"/store/long-tags?via={tag}", headers={
            **ON_LINK_HOST, "user-agent": "Mozilla/5.0 (Linux; Android 13) Chrome/120.0 Mobile"})
        assert page.status_code == 200
        away = await client.get(f"/store/long-tags?via={tag}", follow_redirects=False)
        assert away.status_code == 302

    async def test_web_page_visits_are_counted_with_their_source(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner, slug="web-visits")
        phone_a = "Mozilla/5.0 (Linux; Android 13) Chrome/120.0 Mobile"
        phone_b = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1"
        await client.get("/store/web-visits?via=instagram", headers={**ON_LINK_HOST, "user-agent": phone_a})
        await client.get("/store/web-visits?via=instagram", headers={**ON_LINK_HOST, "user-agent": phone_a})
        await client.get("/store/web-visits", headers={
            **ON_LINK_HOST, "user-agent": phone_b, "referer": "https://www.tiktok.com/@web"})
        stats = (await client.get(f"/stores/{store['id']}/stats", headers=owner)).json()
        assert stats["visits"]["by_surface"]["web"] == 2
        assert stats["visits"]["by_source"]["instagram"] == 1
        assert stats["visits"]["by_source"]["tiktok"] == 1

    async def test_link_preview_fetchers_are_not_visitors(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner, slug="preview-bots")
        for ua in [
            "WhatsApp/2.23.20.0 A",
            "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
            "TelegramBot (like TwitterBot)",
            "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
            "",
        ]:
            r = await client.get("/store/preview-bots?via=whatsapp",
                                 headers={**ON_LINK_HOST, "user-agent": ua})
            assert r.status_code == 200
        await client.get("/store/preview-bots?via=whatsapp", headers={
            **ON_LINK_HOST, "user-agent": "Mozilla/5.0 (Linux; Android 13; SM-A145F) AppleWebKit/537.36 "
                          "(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36"})
        stats = (await client.get(f"/stores/{store['id']}/stats", headers=owner)).json()
        assert stats["visits"]["total"] == 1

    async def test_shares_are_counted_by_channel(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        for channel in ["whatsapp", "whatsapp", "qr", "carrier-pigeon"]:
            r = await client.post(f"/stores/{store['id']}/share", json={"channel": channel},
                                  headers=owner)
            assert r.status_code == 202
        shares = (await client.get(f"/stores/{store['id']}/stats", headers=owner)).json()["shares"]
        assert shares["total"] == 4
        assert shares["by_channel"]["whatsapp"] == 2
        assert shares["by_channel"]["qr"] == 1
        assert shares["by_channel"]["other"] == 1

    async def test_stats_are_for_the_owner_only(self, client):
        _, owner = await _register(client)
        _, other = await _register(client)
        store = await _store(client, owner)
        assert (await client.get(f"/stores/{store['id']}/stats")).status_code == 401
        assert (await client.get(f"/stores/{store['id']}/stats", headers=other)).status_code == 403
        assert (await client.get(f"/stores/{store['id']}/stats", params={"days": 400},
                                 headers=owner)).status_code == 422
        assert (await client.post("/stores/missing/visit", json={})).status_code == 404

    async def test_older_days_and_the_window(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        today = store_stats.today()
        async with AsyncSessionLocal() as db:
            for days_ago, n in [(0, 1), (3, 4), (6, 2), (7, 50)]:
                db.add(StoreDailyCount(store_id=store["id"], day=today - timedelta(days=days_ago),
                                       kind="visit", surface="app", source="facebook", count=n))
            await db.commit()
        week = (await client.get(f"/stores/{store['id']}/stats", headers=owner)).json()["visits"]
        assert week["total"] == 7
        assert [d["count"] for d in week["by_day"]] == [2, 0, 0, 4, 0, 0, 1]
        month = (await client.get(f"/stores/{store['id']}/stats", params={"days": 30},
                                  headers=owner)).json()["visits"]
        assert month["total"] == 57

    async def test_increments_share_one_row_per_day(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        async with AsyncSessionLocal() as db:
            for _ in range(3):
                await store_stats.record_share(db, store["id"], "app", "copy")
            rows = (await db.execute(select(StoreDailyCount).where(
                StoreDailyCount.store_id == store["id"]))).scalars().all()
        assert len(rows) == 1 and rows[0].count == 3


@pytest.mark.asyncio
async def test_old_stores_get_a_category_at_startup(client):
    from api.domains.stores.categories import backfill_store_categories
    from api.models.store import Store
    _, headers = await _register(client)
    store = await _store(client, headers)
    async with AsyncSessionLocal() as db:
        row = await db.get(Store, store["id"])
        row.category = None
        row.specialization = "Clothing & Fashion"
        await db.commit()
    assert await backfill_store_categories() >= 1
    found = (await client.get("/stores", params={"category": "Fashion", "limit": 100})).json()
    assert store["id"] in [s["id"] for s in found]
    assert await backfill_store_categories() == 0


# ── Deleting a store ────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestDeletingAStore:
    async def test_the_owner_can_delete_and_the_link_dies(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, slug=f"doomed-{next(_n)}")
        sid, slug = store["id"], store["slug"]

        r = await client.delete(f"/stores/{sid}", headers=headers)
        assert r.status_code == 200, r.text
        assert r.json()["deleted"] is True

        # Gone from every public read: the directory, both id and link, the
        # catalogue, and the owner's own "my store".
        assert sid not in {s["id"] for s in (await client.get("/stores", params={"limit": 100})).json()}
        assert (await client.get(f"/stores/{sid}")).status_code == 404
        assert (await client.get(f"/stores/slug/{slug}")).status_code == 404
        assert (await client.get("/stores/mine", headers=headers)).json() is None

    async def test_deleting_archives_the_products_instead_of_losing_them(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers, slug=f"archived-{next(_n)}")
        sid = store["id"]
        listing = await _listing(client, headers, sid, "Archived Chair")

        r = await client.delete(f"/stores/{sid}", headers=headers)
        assert r.json()["archived_listings"] == 1

        # The row is still there, cancelled: no buyer-facing list shows it.
        row = await _listing_row(listing["id"])
        assert getattr(row.status, "value", row.status) == "cancelled"
        assert listing["id"] not in {
            i["id"] for i in (await client.get("/listings/", params={"limit": 100})).json()}

    async def test_only_the_owner_can_delete(self, client):
        _, headers = await _register(client)
        _, other = await _register(client)
        sid = (await _store(client, headers, slug=f"mine-only-{next(_n)}"))["id"]
        assert (await client.delete(f"/stores/{sid}", headers=other)).status_code == 403
        assert (await client.delete(f"/stores/{sid}")).status_code == 401

    async def test_an_owner_may_open_another_store_after_deleting(self, client):
        _, headers = await _register(client)
        sid = (await _store(client, headers, slug=f"first-{next(_n)}"))["id"]
        assert (await client.delete(f"/stores/{sid}", headers=headers)).status_code == 200
        second = await _store(client, headers, slug=f"second-{next(_n)}")
        assert second["id"] != sid

    async def test_a_deleted_slug_stays_reserved_for_its_old_link(self, client):
        _, headers = await _register(client)
        slug = f"reserved-{next(_n)}"
        sid = (await _store(client, headers, slug=slug))["id"]
        await client.delete(f"/stores/{sid}", headers=headers)

        _, other = await _register(client)
        r = await client.post("/stores", json={
            "name": "Claiming The Old Link", "slug": slug,
            "photos": [_SHOP_PHOTO]}, headers=other)
        assert r.status_code == 409


# ── Removing photo-less stores (one-off cleanup) ────────────────────────────

@pytest.mark.asyncio
class TestPhotoLessCleanup:
    async def test_it_finds_and_removes_only_stores_without_a_photo(self, client):
        # Shops opened before the photo rule existed can sit in the
        # directory with only BROKA's placeholder. The one-off script
        # removes them the same way an owner deleting a store does.
        from cleanup_photoless_stores import has_shop_photo, photo_less
        from api.models.store import Store

        # Two owners: one store per account.
        _, bare_owner = await _register(client)
        _, photo_owner = await _register(client)
        # No slug -> an old build's store, which create_store still allows
        # without a photo (test_an_old_build_without_a_link_name_is_never_refused).
        bare = await _store(client, bare_owner, name=f"Bare {next(_n)}")
        await _listing(client, bare_owner, bare["id"], "Orphan Product")
        with_photo = await _store(client, photo_owner, slug=f"snapped-{next(_n)}")

        async with AsyncSessionLocal() as db:
            found = {s.id for s in await photo_less(db)}
            assert bare["id"] in found
            assert with_photo["id"] not in found
            bare_row = await db.get(Store, bare["id"])
            assert has_shop_photo(bare_row) is False

        r = await client.delete(f"/stores/{bare['id']}", headers=bare_owner)
        assert r.status_code == 200
        assert r.json()["archived_listings"] == 1

        async with AsyncSessionLocal() as db:
            row = await db.get(Store, bare["id"])
            assert row.deleted_at is not None
            assert row.id not in {s.id for s in await photo_less(db)}
        # The shop with a photo is untouched.
        assert (await client.get(f"/stores/{with_photo['id']}")).status_code == 200

    async def test_the_script_archives_listings_and_keeps_the_row(self, client):
        from cleanup_photoless_stores import main as cleanup_main

        _, headers = await _register(client)
        store = await _store(client, headers, name=f"Untouched {next(_n)}")
        listing = await _listing(client, headers, store["id"], "Gone With The Shop")

        await cleanup_main([store["slug"]], apply=True)

        row = await _listing_row(listing["id"])
        assert getattr(row.status, "value", row.status) == "cancelled"
        assert (await client.get(f"/stores/{store['id']}")).status_code == 404


# ── Web storefront support (phase 3) ────────────────────────────────────────

@pytest.mark.asyncio
class TestWebStorefrontSupport:
    async def test_the_old_page_sends_browsers_to_the_web_storefront(self, client):
        r = await client.get("/store/Clanix-Shop?via=qr")
        assert r.status_code == 302
        assert r.headers["location"] == "https://broka.co.ke/store/clanix-shop?via=qr"

    async def test_on_the_link_host_the_page_still_renders(self, client):
        _, headers = await _register(client)
        await _store(client, headers, slug="served-here")
        r = await client.get("/store/served-here", headers=ON_LINK_HOST)
        assert r.status_code == 200 and "text/html" in r.headers["content-type"]

    async def test_web_visits_come_from_the_browser_with_a_visitor_id(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        sid = store["id"]
        chrome = {"user-agent": "Mozilla/5.0 (Linux; Android 14) Chrome/124.0 Mobile Safari/537.36"}

        async def visit(**body):
            r = await client.post(f"/stores/{sid}/visit", json={"surface": "web", **body},
                                  headers=chrome)
            assert r.status_code == 202, r.text
            return r.json()["counted"]

        assert await visit(visitor="browser-aaaa-1111", via="tiktok") is True
        assert await visit(visitor="browser-aaaa-1111", via="tiktok") is False
        # Another browser, arriving from an Instagram link with no tag.
        assert await visit(visitor="browser-bbbb-2222",
                           referrer="https://l.instagram.com/?u=x") is True
        # A crawler running the page's script is still a crawler.
        r = await client.post(f"/stores/{sid}/visit",
                              json={"surface": "web", "visitor": "browser-cccc-3333"},
                              headers={"user-agent": "Googlebot/2.1"})
        assert r.json()["counted"] is False

        stats = (await client.get(f"/stores/{sid}/stats", headers=owner)).json()["visits"]
        assert stats["total"] == 2
        assert stats["by_surface"] == {"app": 0, "web": 2}
        assert stats["by_source"]["tiktok"] == 1 and stats["by_source"]["instagram"] == 1

    async def test_a_malformed_visitor_id_is_refused(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner)
        r = await client.post(f"/stores/{store['id']}/visit",
                              json={"surface": "web", "visitor": "<script>"})
        assert r.status_code == 422
