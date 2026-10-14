"""
BROKA - Store Feature Tests
Run: pytest backend/tests/test_stores.py -v

Covers spec §24's checklist:
  Store: create / auth / ownership / duplicate slug / public read /
         owner update / reject non-owner update / list store listings /
         activate-deactivate
  Listings: personal listing still works / store listing works /
            invalid store ownership rejected / store filtering works

Same fixture shape as test_listings.py (module-scoped sqlite db,
seller/buyer-style token fixtures) - reset_engine() is required per
api/database.py's own docstring, since the engine is otherwise built once
at first import and every test module would silently share one db.
"""

import asyncio
import itertools
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_stores.db"
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


async def _register(client, phone: str, name: str, email: str, password: str) -> tuple[str, str]:
    """Returns (user_id, access_token). Phone-first registration (v6.1) -
    same otp/request -> otp/verify -> register -> login round trip as
    test_traders.py/test_listings.py. Registers a long-term seller: only
    they can open a store (tests/test_store_setup.py covers the others)."""
    req = await client.post("/auth/otp/request", json={"phone": phone})
    assert "debug_code" in req.json(), req.text
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    verify_token = verify.json()["phone_verify_token"]
    reg = await client.post("/auth/register", json={
        "phone_verify_token": verify_token, "name": name, "email": email,
        "password": password, "lat": -1.286, "lng": 36.817,
        "account_type": "buyer_seller", "seller_tier": "long_term",
        "business_name": name, "business_category": "Electronics",
        "business_location": "Nairobi",
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": password})
    return reg.json()["user_id"], login.json()["access_token"]


# Hardening-pass regression, found via the uploaded CI run: these two
# fixtures were module-scoped, so EVERY test in this file that called
# `owner`/`other_user` shared the exact same already-registered user for
# the whole module. That was fine before this hardening pass (a user
# could create unlimited stores) but broke the instant "one store per
# user" was enforced server-side - every test past the first one to call
# POST /stores under a given fixture got a 409, not the 201 it expected.
# No test here actually depends on sharing state across test functions
# (each creates whatever store/listing it needs within its own body), so
# function-scoping is strictly safer, not just a workaround - it's what
# these tests were already implicitly assuming.
_phone_counter = itertools.count(1)


@pytest_asyncio.fixture
async def owner(client):
    """The user who will own the primary test store. Function-scoped: a
    fresh user (and therefore zero existing stores) every test."""
    n = next(_phone_counter)
    return await _register(client, f"0722{n:06d}", "Clanix Owner", f"owner{n}@test.ke", "OwnerPass123!")


@pytest_asyncio.fixture
async def other_user(client):
    """A second, unrelated user - used for every ownership-rejection
    test. Function-scoped for the same reason as owner() above."""
    n = next(_phone_counter)
    return await _register(client, f"0733{n:06d}", "Other Person", f"other{n}@test.ke", "OtherPass123!")


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


class TestStoreCRUD:
    @pytest.mark.asyncio
    async def test_create_store_requires_auth(self, client):
        resp = await client.post("/stores", json={"name": "No Auth Store"})
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_create_store(self, client, owner):
        owner_id, owner_token = owner
        resp = await client.post("/stores", json={
            "name": "Clanix Electronics",
            "category": "Electronics",
            "county": "Nairobi",
            "subcounty": "Westlands",
            # No longer part of a store: ignored, never stored or returned.
            "official_phone": "0700111222",
            "official_whatsapp": "0700111222",
        }, headers=_auth(owner_token))
        assert resp.status_code == 201
        data = resp.json()
        assert data["name"] == "Clanix Electronics"
        assert data["slug"] == "clanix-electronics"
        assert data["url"].endswith("/clanix-electronics")
        assert data["is_active"] is True
        assert data["listing_count"] == 0
        assert data["category"] == "Electronics"
        assert data["specialization"] == "Electronics"
        assert "official_phone" not in data
        assert "official_whatsapp" not in data
        # Fields never set at creation must be absent, not fabricated -
        # spec §7/§19: no invented reputation numbers.
        assert "rating" not in data
        assert "completed_deals" not in data
        assert "dcr" not in data
        # Hardening pass: owner_id is intentionally no longer exposed -
        # nothing in the app reads it, and it was unnecessary internal-id
        # exposure on every public read (spec §9/§10).
        assert "owner_id" not in data

    @pytest.mark.asyncio
    async def test_duplicate_store_name_gets_a_different_slug(self, client, other_user):
        _, other_token = other_user
        resp = await client.post("/stores", json={"name": "Clanix Electronics"}, headers=_auth(other_token))
        assert resp.status_code == 201
        data = resp.json()
        # Same normalized base as the first store's slug, but never the
        # same slug (spec §23 - "Handle duplicate Store names using slugs
        # rather than silently overwriting another Store").
        assert data["slug"] != "clanix-electronics"
        assert data["slug"].startswith("clanix-electronics-")

    @pytest.mark.asyncio
    async def test_get_store_by_id_is_public(self, client, owner):
        owner_id, owner_token = owner
        create = await client.post("/stores", json={"name": "Public Read Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.get(f"/stores/{store_id}")  # no Authorization header at all
        assert resp.status_code == 200
        assert resp.json()["name"] == "Public Read Store"

    @pytest.mark.asyncio
    async def test_get_store_by_slug_is_public(self, client, owner):
        _, owner_token = owner
        create = await client.post("/stores", json={"name": "Slug Read Store"}, headers=_auth(owner_token))
        slug = create.json()["slug"]

        resp = await client.get(f"/stores/slug/{slug}")
        assert resp.status_code == 200
        assert resp.json()["slug"] == slug

    @pytest.mark.asyncio
    async def test_get_unknown_store_404s(self, client):
        resp = await client.get("/stores/does-not-exist")
        assert resp.status_code == 404

    @pytest.mark.asyncio
    async def test_owner_can_update_store(self, client, owner):
        _, owner_token = owner
        create = await client.post("/stores", json={"name": "Editable Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.patch(f"/stores/{store_id}", json={
            "description": "We sell quality electronics in Nairobi.",
        }, headers=_auth(owner_token))
        assert resp.status_code == 200
        assert resp.json()["description"] == "We sell quality electronics in Nairobi."
        # A field not sent in the PATCH must be left untouched.
        assert resp.json()["name"] == "Editable Store"

    @pytest.mark.asyncio
    async def test_update_requires_auth(self, client, owner):
        _, owner_token = owner
        create = await client.post("/stores", json={"name": "Auth Required Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.patch(f"/stores/{store_id}", json={"description": "x"})
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_non_owner_cannot_update_store(self, client, owner, other_user):
        _, owner_token = owner
        _, other_token = other_user
        create = await client.post("/stores", json={"name": "Protected Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.patch(f"/stores/{store_id}", json={
            "description": "Hijacked description",
        }, headers=_auth(other_token))
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_non_owner_cannot_deactivate_store(self, client, owner, other_user):
        _, owner_token = owner
        _, other_token = other_user
        create = await client.post("/stores", json={"name": "Status Protected Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.post(f"/stores/{store_id}/status", json={"is_active": False}, headers=_auth(other_token))
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_owner_can_deactivate_and_reactivate_store(self, client, owner):
        _, owner_token = owner
        create = await client.post("/stores", json={"name": "Togglable Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        off = await client.post(f"/stores/{store_id}/status", json={"is_active": False}, headers=_auth(owner_token))
        assert off.status_code == 200
        assert off.json()["is_active"] is False

        on = await client.post(f"/stores/{store_id}/status", json={"is_active": True}, headers=_auth(owner_token))
        assert on.status_code == 200
        assert on.json()["is_active"] is True

    @pytest.mark.asyncio
    async def test_list_store_listings_starts_empty(self, client, owner):
        _, owner_token = owner
        create = await client.post("/stores", json={"name": "Empty Catalog Store"}, headers=_auth(owner_token))
        store_id = create.json()["id"]

        resp = await client.get(f"/stores/{store_id}/listings")
        assert resp.status_code == 200
        assert resp.json() == []

    @pytest.mark.asyncio
    async def test_get_my_store_returns_null_when_none_exists(self, client, other_user):
        # A fresh user (not `owner`, who by now owns several stores from
        # the tests above) should see null, not 404 or an error.
        _, fresh_token = await _register(
            client, "0711000003", "No Store Person", "nostore@test.ke", "NoStorePass123!",
        )
        resp = await client.get("/stores/mine", headers=_auth(fresh_token))
        assert resp.status_code == 200
        assert resp.json() is None

    @pytest.mark.asyncio
    async def test_get_my_store_returns_the_owners_store(self, client):
        user_id, token = await _register(
            client, "0711000004", "Fresh Owner", "freshowner@test.ke", "FreshPass123!",
        )
        created = await client.post("/stores", json={"name": "Fresh Owner Store"}, headers=_auth(token))
        store_id = created.json()["id"]

        resp = await client.get("/stores/mine", headers=_auth(token))
        assert resp.status_code == 200
        assert resp.json()["id"] == store_id
        assert "owner_id" not in resp.json()


class TestListingStoreIntegration:
    @pytest.mark.asyncio
    async def test_personal_listing_without_store_still_works(self, client, owner):
        _, owner_token = owner
        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Personal Sofa",
            "category": "furniture",
            "price": 15000,
            "lat": -1.286,
            "lng": 36.817,
        }, headers=_auth(owner_token))
        assert resp.status_code == 201
        data = resp.json()
        assert data["store_id"] is None
        assert data["store_name"] is None

    @pytest.mark.asyncio
    async def test_create_listing_with_store(self, client, owner):
        _, owner_token = owner
        store = await client.post("/stores", json={"name": "Listing Test Store"}, headers=_auth(owner_token))
        store_id = store.json()["id"]

        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "LG 55-inch TV",
            "category": "electronics",
            "price": 65000,
            "lat": -1.286,
            "lng": 36.817,
            "store_id": store_id,
        }, headers=_auth(owner_token))
        assert resp.status_code == 201
        data = resp.json()
        assert data["store_id"] == store_id
        assert data["store_name"] == "Listing Test Store"
        assert data["store_slug"] == store.json()["slug"]

        # The store's own catalog must now include it, and listing_count
        # must reflect a real COUNT, not a placeholder.
        catalog = await client.get(f"/stores/{store_id}/listings")
        ids = [l["id"] for l in catalog.json()]
        assert data["id"] in ids
        refreshed_store = await client.get(f"/stores/{store_id}")
        assert refreshed_store.json()["listing_count"] == 1

    @pytest.mark.asyncio
    async def test_create_listing_with_someone_elses_store_is_rejected(self, client, owner, other_user):
        _, owner_token = owner
        _, other_token = other_user
        store = await client.post("/stores", json={"name": "Not Yours Store"}, headers=_auth(owner_token))
        store_id = store.json()["id"]

        resp = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Sneaky Listing",
            "category": "electronics",
            "price": 1000,
            "lat": -1.0,
            "lng": 36.0,
            "store_id": store_id,
        }, headers=_auth(other_token))
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_store_id_filter_on_listings_endpoint(self, client, owner, other_user):
        _, owner_token = owner
        _, other_token = other_user
        store_a = (await client.post("/stores", json={"name": "Filter Store A"}, headers=_auth(owner_token))).json()
        store_b = (await client.post("/stores", json={"name": "Filter Store B"}, headers=_auth(other_token))).json()

        for name, sid, token in (
            ("A-Item-1", store_a["id"], owner_token),
            ("A-Item-2", store_a["id"], owner_token),
            ("B-Item-1", store_b["id"], other_token),
        ):
            r = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
                "name": name, "category": "electronics", "price": 1000,
                "lat": -1.0, "lng": 36.0, "store_id": sid,
            }, headers=_auth(token))
            assert r.status_code == 201

        resp = await client.get("/listings/", params={"store_id": store_a["id"]})
        assert resp.status_code == 200
        names = {l["name"] for l in resp.json()}
        assert names == {"A-Item-1", "A-Item-2"}

    @pytest.mark.asyncio
    async def test_set_and_remove_listing_store(self, client, owner):
        _, owner_token = owner
        listing = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Reassignable Listing", "category": "electronics",
            "price": 2000, "lat": -1.0, "lng": 36.0,
        }, headers=_auth(owner_token))
        listing_id = listing.json()["id"]
        assert listing.json()["store_id"] is None

        store = await client.post("/stores", json={"name": "Reassign Target Store"}, headers=_auth(owner_token))
        store_id = store.json()["id"]

        attach = await client.post(
            f"/listings/{listing_id}/store", json={"store_id": store_id}, headers=_auth(owner_token),
        )
        assert attach.status_code == 200
        assert attach.json()["store_id"] == store_id

        detach = await client.request(
            "DELETE", f"/listings/{listing_id}/store", headers=_auth(owner_token),
        )
        assert detach.status_code == 200
        assert detach.json()["store_id"] is None

    @pytest.mark.asyncio
    async def test_cannot_attach_someone_elses_listing_to_your_store(self, client, owner, other_user):
        _, owner_token = owner
        other_id, other_token = other_user

        their_listing = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Other Person's Listing", "category": "electronics",
            "price": 3000, "lat": -1.0, "lng": 36.0,
        }, headers=_auth(other_token))
        listing_id = their_listing.json()["id"]

        my_store = await client.post("/stores", json={"name": "Grabby Store"}, headers=_auth(owner_token))
        store_id = my_store.json()["id"]

        resp = await client.post(
            f"/listings/{listing_id}/store", json={"store_id": store_id}, headers=_auth(owner_token),
        )
        assert resp.status_code == 403

    @pytest.mark.asyncio
    async def test_deactivated_store_hides_catalog_but_keeps_profile(self, client, owner):
        _, owner_token = owner
        store = await client.post("/stores", json={"name": "Pausing Store"}, headers=_auth(owner_token))
        store_id = store.json()["id"]
        await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Paused Item", "category": "electronics",
            "price": 4000, "lat": -1.0, "lng": 36.0, "store_id": store_id,
        }, headers=_auth(owner_token))

        await client.post(f"/stores/{store_id}/status", json={"is_active": False}, headers=_auth(owner_token))

        profile = await client.get(f"/stores/{store_id}")
        assert profile.status_code == 200  # the business profile itself is still visible

        catalog = await client.get(f"/stores/{store_id}/listings")
        assert catalog.status_code == 200
        assert catalog.json() == []  # but the public catalog is empty while paused


class TestStoreDiscovery:
    @pytest.mark.asyncio
    async def test_list_stores_is_public_and_returns_active_stores(self, client, owner):
        _, owner_token = owner
        created = await client.post("/stores", json={"name": "Discoverable Store"}, headers=_auth(owner_token))
        store_id = created.json()["id"]

        resp = await client.get("/stores")  # no auth header
        assert resp.status_code == 200
        ids = [s["id"] for s in resp.json()]
        assert store_id in ids

    @pytest.mark.asyncio
    async def test_list_stores_excludes_inactive(self, client, owner):
        _, owner_token = owner
        created = await client.post("/stores", json={"name": "Hidden From Directory"}, headers=_auth(owner_token))
        store_id = created.json()["id"]
        await client.post(f"/stores/{store_id}/status", json={"is_active": False}, headers=_auth(owner_token))

        resp = await client.get("/stores")
        assert resp.status_code == 200
        ids = [s["id"] for s in resp.json()]
        assert store_id not in ids

        # A direct link still resolves even though it's out of the directory.
        direct = await client.get(f"/stores/{store_id}")
        assert direct.status_code == 200

    @pytest.mark.asyncio
    async def test_list_stores_search_filters_by_name(self, client, owner):
        _, owner_token = owner
        await client.post("/stores", json={"name": "Searchable Widgets Co"}, headers=_auth(owner_token))

        resp = await client.get("/stores", params={"search": "Searchable Widgets"})
        assert resp.status_code == 200
        assert any(s["name"] == "Searchable Widgets Co" for s in resp.json())


class TestStorePublicWebPage:
    @pytest.mark.asyncio
    async def test_public_page_renders_store_name(self, client, owner):
        _, owner_token = owner
        created = await client.post("/stores", json={
            "name": "Web Page Store", "description": "<script>alert(1)</script>",
        }, headers=_auth(owner_token))
        slug = created.json()["slug"]

        # As the link host: elsewhere this page redirects to the web store.
        resp = await client.get(f"/store/{slug}", headers={"x-forwarded-host": "broka.co.ke"})
        assert resp.status_code == 200
        assert "text/html" in resp.headers["content-type"]
        assert "Web Page Store" in resp.text
        # The description must be HTML-escaped, not executable - this is
        # the one endpoint in the app where user text becomes raw HTML.
        assert "<script>alert(1)</script>" not in resp.text
        assert "&lt;script&gt;" in resp.text

    @pytest.mark.asyncio
    async def test_public_page_404s_gracefully_for_unknown_slug(self, client):
        resp = await client.get("/store/does-not-exist-at-all",
                                headers={"x-forwarded-host": "broka.co.ke"})
        assert resp.status_code == 404
        assert "text/html" in resp.headers["content-type"]


class TestHardeningPass:
    """Added for the second-pass engineering hardening review."""

    @pytest.mark.asyncio
    async def test_cross_user_store_listing_matrix(self, client, owner, other_user):
        """The exact 4-case matrix from the hardening review: A's listing
        into A's store succeeds, B's into B's succeeds, A's into B's
        store fails, B's into A's store fails. Confirms
        listing.seller_id == store.owner_id can never be violated."""
        a_id, a_token = owner
        b_id, b_token = other_user

        store_a = (await client.post("/stores", json={"name": "Matrix Store A"}, headers=_auth(a_token))).json()
        store_b = (await client.post("/stores", json={"name": "Matrix Store B"}, headers=_auth(b_token))).json()
        listing_a = (await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Matrix Listing A", "category": "electronics", "price": 1000, "lat": -1.0, "lng": 36.0,
        }, headers=_auth(a_token))).json()
        listing_b = (await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Matrix Listing B", "category": "electronics", "price": 1000, "lat": -1.0, "lng": 36.0,
        }, headers=_auth(b_token))).json()

        # A -> Store A succeeds
        r1 = await client.post(f"/listings/{listing_a['id']}/store",
                                json={"store_id": store_a["id"]}, headers=_auth(a_token))
        assert r1.status_code == 200

        # B -> Store B succeeds
        r2 = await client.post(f"/listings/{listing_b['id']}/store",
                                json={"store_id": store_b["id"]}, headers=_auth(b_token))
        assert r2.status_code == 200

        # A -> Store B fails (wrong store owner)
        r3 = await client.post(f"/listings/{listing_a['id']}/store",
                                json={"store_id": store_b["id"]}, headers=_auth(a_token))
        assert r3.status_code == 403

        # B -> Store A fails (wrong store owner)
        r4 = await client.post(f"/listings/{listing_b['id']}/store",
                                json={"store_id": store_a["id"]}, headers=_auth(b_token))
        assert r4.status_code == 403

    @pytest.mark.asyncio
    async def test_listing_count_is_accurate_via_count_query(self, client, owner):
        """Not just 'a number changes' - confirms the exact count after a
        real COUNT(*) rewrite (was: fetch every id, len() in Python)."""
        _, token = owner
        store = (await client.post("/stores", json={"name": "Count Query Store"}, headers=_auth(token))).json()
        for i in range(3):
            r = await client.post("/listings/", json={"description": "Well kept, works perfectly - selling because I upgraded.", 
                "name": f"Count Item {i}", "category": "electronics", "price": 500,
                "lat": -1.0, "lng": 36.0, "store_id": store["id"],
            }, headers=_auth(token))
            assert r.status_code == 201

        refreshed = await client.get(f"/stores/{store['id']}")
        assert refreshed.json()["listing_count"] == 3

    @pytest.mark.asyncio
    async def test_second_store_creation_is_rejected(self, client):
        """Phase 8 decision: V1 is one store per user, enforced server-side
        now (previously only the UI discouraged a second store)."""
        _, token = await _register(client, "0711000099", "Single Store Person",
                                    "singlestore@test.ke", "SinglePass123!")
        first = await client.post("/stores", json={"name": "First Store"}, headers=_auth(token))
        assert first.status_code == 201

        second = await client.post("/stores", json={"name": "Second Store"}, headers=_auth(token))
        assert second.status_code == 409

    @pytest.mark.asyncio
    async def test_oversized_logo_is_rejected(self, client, owner):
        _, token = owner
        huge = "data:image/jpeg;base64," + ("A" * 14 * 1024 * 1024)  # ~14MB, over the 10MB limit
        resp = await client.post("/stores", json={
            "name": "Oversized Logo Store", "logo_url": huge,
        }, headers=_auth(token))
        assert resp.status_code == 413

    @pytest.mark.asyncio
    async def test_oversized_photo_in_list_is_rejected(self, client, owner):
        _, token = owner
        huge = "data:image/jpeg;base64," + ("A" * 14 * 1024 * 1024)
        resp = await client.post("/stores", json={
            "name": "Oversized Photo Store", "photos": [huge],
        }, headers=_auth(token))
        assert resp.status_code == 413

    @pytest.mark.asyncio
    async def test_reasonable_sized_media_is_accepted(self, client, owner):
        _, token = owner
        # Well under the 10MB limit - confirms the size check doesn't
        # reject normal-sized images, only abusive ones.
        reasonable = "data:image/jpeg;base64," + ("A" * 1024 * 50)  # ~50KB
        resp = await client.post("/stores", json={
            "name": "Reasonable Media Store", "logo_url": reasonable, "photos": [reasonable],
        }, headers=_auth(token))
        assert resp.status_code == 201
        assert resp.json()["logo_url"] == reasonable

    @pytest.mark.asyncio
    async def test_concurrent_same_name_store_creation_does_not_crash(self, client):
        """Concurrency-oriented test for the slug race (hardening §4):
        several different users creating a store with the identical name
        at the same time must all get a clean 201 with a unique slug each
        - never an unhandled 500 from the database's unique constraint."""
        users = [
            await _register(client, f"07120001{i:02d}", f"Racer {i}", f"racer{i}@test.ke", "RacerPass123!")
            for i in range(5)
        ]
        results = await asyncio.gather(*[
            client.post("/stores", json={"name": "Race Condition Store"}, headers=_auth(token))
            for _, token in users
        ])
        assert all(r.status_code == 201 for r in results)
        slugs = [r.json()["slug"] for r in results]
        assert len(slugs) == len(set(slugs)), f"duplicate slugs allocated under concurrency: {slugs}"
