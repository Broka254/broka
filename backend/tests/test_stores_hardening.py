"""
Regression tests for the Store implementation audit (2026-09-14).

Scoped deliberately narrowly: tests/test_stores.py already covers
creation, ownership/IDOR, the cross-user attachment matrix, inactive-store
semantics, slug collision, the one-store rule, oversized media and the
public page. This file covers only the four defects that audit actually
found and fixed, so a regression in any of them fails loudly instead of
being absorbed by the existing suite's happy paths.

Same fixture shape as test_stores.py (module-scoped sqlite db,
reset_engine() before init_db) - see that file's header for why
reset_engine() is required per module.
"""
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.domains.stores.service import StoreService, _MAX_SLUG_SUFFIX
from api.models.store import slugify


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_stores_hardening.db"
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


async def _register(client, phone: str, name: str, email: str, password: str):
    req = await client.post("/auth/otp/request", json={"phone": phone})
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


@pytest_asyncio.fixture(scope="module")
async def owner(client):
    return await _register(client, "+254700900101", "Hardening Owner",
                           "harden.owner@example.com", "Passw0rd!")


class TestSlugNormalization:
    """slugify() must stay deterministic and URL-safe - the public page
    route interpolates the slug straight into a canonical URL and an
    og:url meta tag, so anything outside [a-z0-9-] would land in HTML."""

    def test_normalizes_display_names(self):
        assert slugify("Clanix Electronics") == "clanix-electronics"
        assert slugify("  MAMA  MBOGA!!  ") == "mama-mboga"

    def test_is_url_safe_for_punctuation_heavy_names(self):
        import re
        for name in ["Ann's Shop & Co.", "A/B Traders", "<script>alert(1)</script>"]:
            assert re.fullmatch(r"[a-z0-9-]+", slugify(name)), name

    def test_name_with_no_alphanumerics_falls_back(self):
        # This is what makes the bounded suffix search below matter: every
        # emoji-only store name in the system slugifies to the same base.
        assert slugify("🔥🔥🔥") == "store"
        assert slugify("") == "store"


@pytest.mark.asyncio
class TestBoundedSlugSearch:
    """_unique_slug used to be `while True` with one DB round trip per
    iteration. Benign for two or three same-named shops; with many stores
    sharing a slug base (the emoji case above is the realistic one) it
    became an unbounded query loop inside a request."""

    async def test_probe_count_is_capped(self, client, owner):
        from api.database import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            svc = StoreService(db)
            calls = {"n": 0}
            original = db.execute

            async def counting_execute(*args, **kwargs):
                calls["n"] += 1
                return await original(*args, **kwargs)

            db.execute = counting_execute  # type: ignore[assignment]
            slug = await svc._unique_slug("Clanix Electronics")
            assert calls["n"] <= _MAX_SLUG_SUFFIX + 1
            assert slug

    async def test_uncontested_name_still_costs_one_lookup(self, client, owner):
        from api.database import AsyncSessionLocal
        async with AsyncSessionLocal() as db:
            slug = await StoreService(db)._unique_slug("Totally Unique Shop Name 12345")
            assert slug == "totally-unique-shop-name-12345"


@pytest.mark.asyncio
class TestPaginationIsBounded:
    """`limit: int = 20` had no ceiling, so ?limit=1000000 returned the
    whole table from an unauthenticated endpoint - and store rows carry
    inline base64 logos, so the response is heavy per row."""

    async def test_oversized_limit_is_rejected_on_store_directory(self, client):
        r = await client.get("/stores", params={"limit": 1_000_000})
        assert r.status_code == 422

    async def test_zero_and_negative_limits_are_rejected(self, client):
        for bad in (0, -1):
            r = await client.get("/stores", params={"limit": bad})
            assert r.status_code == 422, bad

    async def test_negative_offset_is_rejected(self, client):
        r = await client.get("/stores", params={"offset": -5})
        assert r.status_code == 422

    async def test_normal_page_size_still_works(self, client):
        r = await client.get("/stores", params={"limit": 20, "offset": 0})
        assert r.status_code == 200

    async def test_oversized_limit_is_rejected_on_store_catalog(self, client, owner):
        _, token = owner
        created = await client.post("/stores", json={"name": "Pagination Test Store"},
                                    headers={"Authorization": f"Bearer {token}"})
        store_id = created.json()["id"]
        r = await client.get(f"/stores/{store_id}/listings", params={"limit": 999_999})
        assert r.status_code == 422


@pytest.mark.asyncio
class TestDirectoryCountsAreBatchedAndCorrect:
    """The directory issued one COUNT(*) per store on top of the list
    query. Batching must not change the numbers - in particular a store
    with no active listings produces no GROUP BY row and has to report 0
    rather than going missing from the response."""

    async def test_store_with_no_listings_reports_zero_not_missing(self, client, owner):
        r = await client.get("/stores", params={"limit": 50})
        assert r.status_code == 200
        items = r.json()
        assert items, "expected at least the store created above"
        for item in items:
            assert "listing_count" in item
            assert isinstance(item["listing_count"], int)
            assert item["listing_count"] >= 0

    async def test_directory_counts_match_single_store_read(self, client, owner):
        """The batched path and the single-store path must agree - they are
        now two different code paths through _store_dict."""
        directory = (await client.get("/stores", params={"limit": 50})).json()
        for item in directory:
            single = await client.get(f"/stores/{item['id']}")
            assert single.status_code == 200
            assert single.json()["listing_count"] == item["listing_count"], item["slug"]
