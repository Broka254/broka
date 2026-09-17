"""
BROKA - Categories Endpoint Tests
Run: pytest backend/tests/test_categories.py -v

Follows test_listings.py's fixture convention exactly (module-scoped sqlite
DB, a plain httpx client against the real app). There is no POST /categories
endpoint (categories are seeded by api.domains.categories.seed.seed_categories,
called automatically from init_db() below - see setup_db() - not created
over the API), so tests seed additional ad hoc rows directly through
AsyncSessionLocal for scoping/isolation checks, using their own explicit
ids ("cat-electronics", "cat-home", ...). setup_db() means the real
canonical taxonomy (Electronics, Vehicles, ...) is also present in this
module's db by the time these tests run, under its own auto-generated ids -
assertions below either check membership on the top-level list or filter
by one of the test's own explicit ids, so the two data sets never collide
even where a name (e.g. "Electronics") appears in both.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, Category


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_categories.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def _seed_category(**kwargs):
    async with AsyncSessionLocal() as db:
        db.add(Category(**kwargs))
        await db.commit()


class TestCategories:
    @pytest.mark.asyncio
    async def test_list_categories_returns_seeded_categories(self, client):
        await _seed_category(id="cat-electronics", name="Electronics", icon=None, parent_id=None)
        res = await client.get("/categories")
        assert res.status_code == 200
        assert "Electronics" in [c["name"] for c in res.json()]

    @pytest.mark.asyncio
    async def test_top_level_excludes_subcategories(self, client):
        await _seed_category(id="cat-autos", name="Automobiles", icon=None, parent_id=None)
        await _seed_category(id="cat-autos-suv", name="SUVs", icon=None, parent_id="cat-autos")
        names = [c["name"] for c in (await client.get("/categories")).json()]
        assert "Automobiles" in names
        assert "SUVs" not in names

    @pytest.mark.asyncio
    async def test_subcategories_scoped_to_parent(self, client):
        await _seed_category(id="cat-home", name="Home & Furniture", icon=None, parent_id=None)
        await _seed_category(id="cat-home-sofas", name="Sofas", icon=None, parent_id="cat-home")
        await _seed_category(id="cat-autos-trucks", name="Trucks", icon=None, parent_id="cat-autos")
        res = await client.get("/categories/cat-home/subcategories")
        assert res.status_code == 200
        assert [c["name"] for c in res.json()] == ["Sofas"]

    @pytest.mark.asyncio
    async def test_filters_scoped_to_category(self, client):
        from api.database import CategoryFilter
        import json as _json
        async with AsyncSessionLocal() as db:
            db.add(CategoryFilter(
                id="filt-1", category_id="cat-electronics",
                field_name="brand", field_type="select",
                options=_json.dumps(["Samsung", "Apple", "Tecno"]),
            ))
            await db.commit()
        res = await client.get("/categories/cat-electronics/filters")
        assert res.status_code == 200
        data = res.json()
        assert len(data) == 1
        assert data[0]["field_name"] == "brand"
        assert data[0]["options"] == ["Samsung", "Apple", "Tecno"]

    @pytest.mark.asyncio
    async def test_listings_filter_by_category_id_includes_children(self, client, seller_token):
        # A listing tagged at the child subcategory should still surface
        # when filtering by the parent category_id (Ch.24 — Listing.subcategory_id
        # may point at a top-level Category or a leaf one).
        create_resp = await client.post("/listings/", json={
            "name": "Toyota Prado", "category": "vehicles", "price": 3200000,
            "lat": -1.286, "lng": 36.817,
        }, headers={"Authorization": f"Bearer {seller_token}"})
        lid = create_resp.json()["id"]
        async with AsyncSessionLocal() as db:
            from api.database import Listing
            from sqlalchemy import select
            listing = (await db.execute(select(Listing).where(Listing.id == lid))).scalar_one()
            listing.subcategory_id = "cat-autos-trucks"
            await db.commit()

        res = await client.get("/listings/", params={"category_id": "cat-autos"})
        assert res.status_code == 200
        assert lid in [item["id"] for item in res.json()]


class TestSeedCategories:
    """Covers the auto-seed fix directly. setup_db() (module-scoped,
    autouse, top of file) already called init_db() -> seed_categories()
    against this module's fresh sqlite db before any test ran - these
    assert against that real run rather than re-seeding by hand, so they
    fail if the automatic startup seed ever regresses.
    """

    @pytest.mark.asyncio
    async def test_canonical_taxonomy_present_on_fresh_db(self, client):
        # No migrate script, no manual step - just the fresh db setup_db()
        # already built.
        names = [c["name"] for c in (await client.get("/categories")).json()]
        for expected in ("Vehicles", "Electronics", "Agriculture", "Other"):
            assert expected in names

    @pytest.mark.asyncio
    async def test_canonical_subcategories_and_filters_present(self, client):
        # "Vehicles", deliberately, not "Electronics": TestCategories above
        # seeds its own top-level row NAMED "Electronics" (id="cat-electronics",
        # with no subcategories of its own) - a bare name-keyed dict built
        # from the full /categories list can't tell that row apart from the
        # canonical one, and picking "Vehicles" (no same-named fixture
        # anywhere in this module) sidesteps the ambiguity entirely rather
        # than relying on dict-ordering luck.
        top = {c["name"]: c["id"] for c in (await client.get("/categories")).json()}
        vehicles_id = top["Vehicles"]

        subs = {c["name"]: c["id"] for c in
                (await client.get(f"/categories/{vehicles_id}/subcategories")).json()}
        assert "Cars" in subs

        filters = [f["field_name"] for f in
                   (await client.get(f"/categories/{subs['Cars']}/filters")).json()]
        assert "make" in filters

    @pytest.mark.asyncio
    async def test_seed_categories_is_idempotent(self, client):
        # Re-running against an already-seeded db (exactly what happens on
        # every subsequent app restart) must not duplicate rows or raise.
        # This is the real regression test for two collisions that only
        # exist by the time THIS test runs, after TestCategories above has
        # added its own fixtures: (1) "Gaming" is both a top-level category
        # and an Electronics subcategory - used to be able to raise
        # MultipleResultsFound (see seed.py's Pass 1 note); (2) this
        # module's own "Electronics" (id="cat-electronics") and
        # "Home & Furniture" (id="cat-home") fixtures share a name with a
        # canonical top-level category - used to make seed_categories()
        # resolve the WRONG same-named row internally and duplicate that
        # category's subcategories/filters under the fixture's id instead
        # of a no-op (see seed.py's by_name note) - this test is what
        # actually caught (2); the sibling assertion-shape issue was in
        # test_canonical_subcategories_and_filters_present above, not here.
        from api.domains.categories.seed import seed_categories
        before = len((await client.get("/categories")).json())
        result = await seed_categories()
        after = len((await client.get("/categories")).json())
        assert result == {
            "categories_created": 0,
            "subcategories_created": 0,
            "filters_created": 0,
            "subcategory_filters_created": 0,
        }
        assert before == after


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    phone = "0711223344"
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    verify_token = verify.json()["phone_verify_token"]
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": "Dan Seller",
        "email": "dan.seller@test.ke",
        "password": "SellerPass123!",
        "lat": -1.286,
        "lng": 36.817,
    })
    resp = await client.post("/auth/login", json={"phone": phone, "password": "SellerPass123!"})
    return resp.json()["access_token"]
