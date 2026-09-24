"""
Online Stores phase 2: setting a store up, and what its owner sees.

  - who can open a store (long-term sellers; others upgrade first)
  - the link name: rules, the live availability check, fixed after setup
  - category (BROKA's own taxonomy, legacy values mapped)
  - the business email (optional, and only ever saved verified)
  - contact fields that are gone
  - the store payload's owner trust facts
  - the storefront's category rail and catalogue filters
  - visit and share counting, and the owner's stats

Same fixture shape as test_stores.py.
"""
import itertools
from datetime import timedelta

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport
from sqlalchemy import select

from main import app
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.stores import naming, stats as store_stats
from api.domains.stores import categories as store_categories
from api.models.store import StoreDailyCount


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
    }
    if tier:
        body.update(account_type="buyer_seller", seller_tier=tier)
    if tier == "long_term":
        body.update(business_name=f"Biz {n}", business_category=business_category,
                    business_location="Nairobi")
    reg = await client.post("/auth/register", json=body)
    assert reg.status_code == 201, reg.text
    return reg.json()["user_id"], {"Authorization": f"Bearer {reg.json()['access_token']}"}


async def _store(client, headers, **fields) -> dict:
    body = {"name": f"Shop {next(_n)}", **fields}
    r = await client.post("/stores", json=body, headers=headers)
    assert r.status_code == 201, r.text
    return r.json()


async def _listing(client, headers, store_id, name, category="Electronics", price=1000):
    r = await client.post("/listings/", json={
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
        assert (await client.get("/store/CASEY-SHOP")).status_code == 200

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

        directory = (await client.get("/stores", params={"limit": 100})).json()
        listed = next(s for s in directory if s["id"] == store["id"])
        assert listed["owner"] == owner

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
        page = (await client.get("/store/no-phones")).text
        assert "0700123456" not in page and "wa.me" not in page and "tel:" not in page
        assert "0700123456" not in (await client.get(f"/stores/{store['id']}")).text


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
        assert cats == [
            {"name": "Electronics", "count": 3},
            {"name": "Home & Furniture", "count": 1},
            {"name": "Other", "count": 1},
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

    async def test_a_paused_store_has_no_categories(self, client):
        _, headers = await _register(client)
        store = await _store(client, headers)
        await _listing(client, headers, store["id"], "Thing")
        await client.post(f"/stores/{store['id']}/status", json={"is_active": False}, headers=headers)
        assert (await client.get(f"/stores/{store['id']}/categories")).json() == []


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

    async def test_web_page_visits_are_counted_with_their_source(self, client):
        _, owner = await _register(client)
        store = await _store(client, owner, slug="web-visits")
        phone_a = "Mozilla/5.0 (Linux; Android 13) Chrome/120.0 Mobile"
        phone_b = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0) Safari/604.1"
        await client.get("/store/web-visits?via=instagram", headers={"user-agent": phone_a})
        await client.get("/store/web-visits?via=instagram", headers={"user-agent": phone_a})
        await client.get("/store/web-visits", headers={
            "user-agent": phone_b, "referer": "https://www.tiktok.com/@web"})
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
            r = await client.get("/store/preview-bots?via=whatsapp", headers={"user-agent": ua})
            assert r.status_code == 200
        await client.get("/store/preview-bots?via=whatsapp", headers={
            "user-agent": "Mozilla/5.0 (Linux; Android 13; SM-A145F) AppleWebKit/537.36 "
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
