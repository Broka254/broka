"""The 2026-09-25 listing overhaul (LISTING_OVERHAUL.md): the category
taxonomy, what a listing must and may now say about itself, the seller's
SMS choice, and the AI cover image.

Each fix here has a test that failed on the code before it:

  * the seed could not rename or move a category: renaming "Vehicles"
    created a second, empty "Automobiles" and stranded every car listed.
  * categories came back alphabetically: "Other" in the middle of the Home
    rail, Agriculture first.
  * a listing needed no description, and a plot no size.
  * a listing's top-level category was whatever the client said, even for
    a subcategory of another category.
  * the availability SMS could not be declined.
  * an AI cover failure was a bare 500 whatever the cause; generation had
    no rate limit; any bytes behind "data:image/" were sent to fal.ai and
    paid for; the price went into the prompt; a refused photo tripped the
    circuit breaker for every seller; a transient poll error threw away a
    finished generation.
"""
import base64
import io
import json
import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import httpx
import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.core import fal_client
from api.core.nudge_templates import EAT
from api.database import (
    AsyncSessionLocal, BuyAgentRequest, Category, CategoryFilter, Interest, Listing, User,
    init_db, reset_engine,
)
from api.domains.categories import seed
from api.domains.listings import validation as rules
from api.domains.showcase import service as showcase
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_listing_overhaul.db"
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


DESCRIPTION = "Dry maize from this season's harvest, stored in clean bags."


def _body(**extra) -> dict:
    return {"name": f"Item {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 25000, "lat": -1.28, "lng": 36.82, "description": DESCRIPTION, **extra}


async def _top(name: str) -> Category:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(Category).where(Category.name == name, Category.parent_id.is_(None))
        )).scalars().first()


async def _child(parent: Category, name: str) -> Category:
    async with AsyncSessionLocal() as db:
        return (await db.execute(
            select(Category).where(Category.parent_id == parent.id, Category.name == name)
        )).scalars().first()


def _jpeg(size=(64, 48), color=(20, 120, 200)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format="JPEG")
    return buf.getvalue()


def _data_uri(raw: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(raw).decode()


# ── Taxonomy ────────────────────────────────────────────────────────────────

class TestTaxonomyMigration:
    """A database seeded with the taxonomy before this change: "Vehicles"
    with its "Motorcycles", and "Land" under Property."""

    @pytest.mark.asyncio
    async def test_renames_and_moves_keep_ids_and_carry_the_data_along(self):
        automobiles = await _top("Automobiles")
        land = await _top("Land")
        property_ = await _top("Property")
        seller, _ = await _user()
        async with AsyncSessionLocal() as db:
            # Roll this database back to the old taxonomy.
            db_auto = await db.get(Category, automobiles.id)
            db_auto.name = "Vehicles"
            moto = (await db.execute(select(Category).where(
                Category.parent_id == automobiles.id,
                Category.name == "Motorcycles & Boda Bodas"))).scalars().first()
            moto.name = "Motorcycles"
            plots = (await db.execute(select(Category).where(
                Category.parent_id == land.id, Category.name == "Residential Plots"))).scalars().first()
            plots.parent_id = property_.id
            plots.name = "Land"
            db.add(CategoryFilter(id=str(uuid.uuid4()), category_id=plots.id,
                                  field_name="acreage", field_type="number_range"))
            car = Listing(seller_id=seller.id, name="Probox", category="Vehicles", price=500000,
                          lat=-1.28, lng=36.82, subcategory_id=moto.id)
            plot = Listing(seller_id=seller.id, name="Plot", category="Property", price=900000,
                           lat=-1.28, lng=36.82, subcategory_id=plots.id)
            store = Store(owner_id=seller.id, name=f"Autos {uuid.uuid4().hex[:6]}",
                          slug=f"autos-{uuid.uuid4().hex[:6]}", category="Vehicles")
            request = BuyAgentRequest(buyer_id=seller.id, category="vehicles", max_price=600000,
                                      must_have_features="[]", status="active")
            db.add_all([car, plot, store, request])
            await db.commit()
            ids = (car.id, plot.id, store.id, request.id, moto.id, plots.id)

        counts = await seed.seed_categories()

        assert counts["categories_renamed"] == 2          # Vehicles, Motorcycles
        assert counts["subcategories_moved"] == 1         # Property/Land
        assert counts["categories_created"] == 0          # no second "Automobiles"
        assert counts["filters_retired"] == 1             # the old free "acreage" box
        car_id, plot_id, store_id, request_id, moto_id, plots_id = ids
        async with AsyncSessionLocal() as db:
            assert (await db.get(Category, automobiles.id)).name == "Automobiles"
            assert (await db.get(Category, moto_id)).name == "Motorcycles & Boda Bodas"
            moved = await db.get(Category, plots_id)
            assert (moved.parent_id, moved.name) == (land.id, "Residential Plots")
            assert (await db.get(Listing, car_id)).category == "Automobiles"
            assert (await db.get(Listing, plot_id)).category == "Land"
            assert (await db.get(Store, store_id)).category == "Automobiles"
            assert (await db.get(BuyAgentRequest, request_id)).category == "Automobiles"
            fields = (await db.execute(select(CategoryFilter.field_name).where(
                CategoryFilter.category_id == plots_id))).scalars().all()
            assert "acreage" not in fields and "land_size" in fields
            tops = (await db.execute(select(Category.name).where(
                Category.parent_id.is_(None)))).scalars().all()
            assert "Vehicles" not in tops and tops.count("Automobiles") == 1

        again = await seed.seed_categories()
        assert not any(again.values()), again

    @pytest.mark.asyncio
    async def test_categories_come_in_the_curated_order(self, client):
        names = [c["name"] for c in (await client.get("/categories")).json()]
        assert names[:3] == ["Automobiles", "Property", "Land"]
        assert names[-1] == "Other"

    @pytest.mark.asyncio
    async def test_mtumba_leads_the_fashion_zone(self, client):
        fashion = await _top("Fashion")
        subs = [c["name"] for c in (await client.get(f"/categories/{fashion.id}/subcategories")).json()]
        assert subs[0] == "Mtumba (Second-hand Clothes)"

    @pytest.mark.asyncio
    async def test_the_tree_has_every_category_and_its_subcategories(self, client):
        tree = (await client.get("/categories/tree")).json()
        by_name = {c["name"]: c for c in tree}
        for name in seed.CANONICAL_CATEGORIES:
            got = [s["name"] for s in by_name[name]["subcategories"]]
            assert got[:len(seed.SUBCATEGORIES[name])] == seed.SUBCATEGORIES[name], name
        assert tree[0]["name"] == "Automobiles"

    def test_an_old_category_name_means_the_new_one(self):
        assert seed.canonical_category_name("vehicles") == "Automobiles"
        assert seed.canonical_category_name("Fashion") == "Fashion"


# ── What a listing must say ────────────────────────────────────────────────

class TestDescriptionIsRequired:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("description", [None, "", "   ", "Nice phone"])
    async def test_missing_or_too_short_is_refused(self, client, description):
        _, h = await _user()
        body = _body()
        if description is None:
            body.pop("description")
        else:
            body["description"] = description
        r = await client.post("/listings/", json=body, headers=h)
        assert r.status_code == 422
        assert "Describe the item" in r.text

    @pytest.mark.asyncio
    async def test_a_real_description_is_kept(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(description=f"  {DESCRIPTION}  "), headers=h)
        assert r.status_code == 201, r.text
        assert r.json()["description"] == DESCRIPTION


class TestLandSize:
    async def _plots(self) -> Category:
        return await _child(await _top("Land"), "Residential Plots")

    @pytest.mark.asyncio
    async def test_land_without_a_size_is_refused(self, client):
        _, h = await _user()
        plots = await self._plots()
        r = await client.post("/listings/", json=_body(category="Land", subcategory_id=plots.id),
                              headers=h)
        assert r.status_code == 400
        assert "size of the land" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_an_unknown_unit_is_refused(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(
            category="Land", subcategory_id=(await self._plots()).id,
            attributes={"land_size": "2", "land_size_unit": "football pitches"}), headers=h)
        assert r.status_code == 400
        assert "unit" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_a_size_is_stored_with_its_acres(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(
            category="Land", subcategory_id=(await self._plots()).id,
            # As an app form field sends them: text, the unit as displayed.
            attributes={"land_size": "2", "land_size_unit": "50x100 Plots"}), headers=h)
        assert r.status_code == 201, r.text
        attrs = r.json()["attributes"]
        assert attrs["land_size"] == 2
        assert attrs["land_size_unit"] == "50x100 plots"
        assert attrs["land_size_acres"] == pytest.approx(0.2296, abs=1e-4)

    @pytest.mark.asyncio
    async def test_the_category_comes_from_the_subcategory(self, client):
        """A plot sent as "Electronics" (a stale draft) is filed under Land,
        and so still has to give its size."""
        _, h = await _user()
        plots = await self._plots()
        refused = await client.post("/listings/", json=_body(category="Electronics",
                                                             subcategory_id=plots.id), headers=h)
        assert refused.status_code == 400
        ok = await client.post("/listings/", json=_body(
            category="Electronics", subcategory_id=plots.id,
            attributes={"land_size": 0.5, "land_size_unit": "acres"}), headers=h)
        assert ok.status_code == 201, ok.text
        assert ok.json()["category"] == "Land"

    def test_units_convert_to_acres(self):
        assert rules.clean_land_details({"land_size": "1", "land_size_unit": "ha"})[
            "land_size_acres"] == pytest.approx(2.4711, abs=1e-4)
        for bad in ({"land_size": "abc", "land_size_unit": "acres"},
                    {"land_size": -1, "land_size_unit": "acres"},
                    {"land_size": float("nan"), "land_size_unit": "acres"},
                    {"land_size": True, "land_size_unit": "acres"}):
            with pytest.raises(Exception):
                rules.clean_land_details(bad)


class TestSellingTerms:
    @pytest.mark.asyncio
    async def test_terms_are_stored_and_returned(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(
            price=3500, price_unit="per Bag", quantity=100, price_negotiable=False,
            delivery_available=True, delivery_note="Within Nakuru county", sms_alerts=False,
        ), headers=h)
        assert r.status_code == 201, r.text
        body = r.json()
        assert (body["price_unit"], body["quantity"], body["price_negotiable"]) == ("bag", 100, False)
        assert (body["delivery_available"], body["delivery_note"]) == (True, "Within Nakuru county")
        assert body["sms_alerts"] is False
        public = (await client.get(f"/listings/{body['id']}")).json()
        assert public["price_unit"] == "bag" and "sms_alerts" not in public

    @pytest.mark.asyncio
    async def test_older_builds_get_the_old_behaviour(self, client):
        _, h = await _user()
        body = (await client.post("/listings/", json=_body(), headers=h)).json()
        assert body["price_unit"] is None and body["quantity"] is None
        assert body["price_negotiable"] is True and body["sms_alerts"] is True

    @pytest.mark.asyncio
    @pytest.mark.parametrize("extra", [
        {"quantity": 0}, {"quantity": 2_000_000}, {"price_unit": "bag; DROP TABLE"},
        {"price_unit": "x" * 30},
    ])
    async def test_bad_terms_are_refused(self, client, extra):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(**extra), headers=h)
        assert r.status_code == 422

    def test_a_whole_item_price_has_no_unit(self):
        assert rules.clean_price_unit("item") is None
        assert rules.clean_price_unit(" per  KG ") == "kg"

    @pytest.mark.asyncio
    async def test_an_old_category_name_is_filed_and_found_under_the_new_one(self, client):
        _, h = await _user()
        r = await client.post("/listings/", json=_body(name="Old draft Probox", category="Vehicles"),
                              headers=h)
        assert r.status_code == 201
        assert r.json()["category"] == "Automobiles"
        found = (await client.get("/listings/", params={"category": "Vehicles", "limit": 200})).json()
        assert any(x["id"] == r.json()["id"] for x in found)

    def test_zeno_is_told_the_terms(self):
        from api.routers.negotiate import _selling_terms

        class L:
            price_unit, quantity, price_negotiable = "bag", 100, False
            delivery_available, delivery_note = True, "Nakuru"
        text = _selling_terms(L())
        assert "ONE bag" in text and "100 bag" in text
        assert "FIXED" in text and "Nakuru" in text


class TestSmsChoice:
    @pytest.fixture(autouse=True)
    def _daytime(self):
        with patch("api.core.nudge_templates.now_eat",
                   return_value=datetime(2026, 9, 15, 14, 0, tzinfo=EAT)):
            yield

    async def _due_interest(self, sms_alerts: bool) -> str:
        seller, _ = await _user()
        buyer, _ = await _user()
        async with AsyncSessionLocal() as db:
            listing = Listing(seller_id=seller.id, name="Maize", category="Agriculture",
                              price=3500, lat=-1.28, lng=36.82, sms_alerts=sms_alerts)
            db.add(listing)
            await db.flush()
            interest = Interest(listing_id=listing.id, buyer_id=buyer.id,
                                nudge_deadline=datetime.utcnow() - timedelta(seconds=1))
            db.add(interest)
            await db.commit()
            return interest.id

    @pytest.mark.asyncio
    async def test_a_seller_who_said_no_gets_no_sms(self):
        interest_id = await self._due_interest(sms_alerts=False)
        send = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=send)):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})
        async with AsyncSessionLocal() as db:
            interest = await db.get(Interest, interest_id)
        assert interest.nudge_cancelled_at is not None and interest.nudge_sent_at is None
        send.assert_not_called()

    @pytest.mark.asyncio
    async def test_a_seller_who_said_yes_is_texted(self):
        interest_id = await self._due_interest(sms_alerts=True)
        send = AsyncMock(return_value=True)
        with patch("api.core.sms.get_sms_provider", return_value=AsyncMock(send=send)):
            from api.core.workers import task_check_interest_nudges
            await task_check_interest_nudges({})
        async with AsyncSessionLocal() as db:
            interest = await db.get(Interest, interest_id)
        assert interest.nudge_sent_at is not None
        send.assert_called_once()


# ── AI cover image ─────────────────────────────────────────────────────────

class TestShowcaseGeneration:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("code,status", [("unavailable", 503), ("rejected", 422), ("failed", 502)])
    async def test_a_failure_is_a_readable_error_not_a_500(self, client, code, status):
        _, h = await _user()
        with patch.object(fal_client, "generate_showcase_image_url",
                          AsyncMock(side_effect=fal_client.FalGenerationError("boom", code=code))):
            r = await client.post("/showcase/preview", headers=h, json={
                "photo_data_uri": _data_uri(_jpeg()), "name": "Sofa", "category": "Home & Furniture",
            })
        assert r.status_code == status
        assert r.json()["detail"]["code"] == f"SHOWCASE_{code.upper()}"
        assert "boom" not in r.text        # the log's words, not the seller's

    @pytest.mark.asyncio
    async def test_not_an_image_never_reaches_fal(self, client):
        _, h = await _user()
        generate = AsyncMock(return_value="https://fal.media/x.jpg")
        with patch.object(fal_client, "generate_showcase_image_url", generate):
            r = await client.post("/showcase/preview", headers=h, json={
                "photo_data_uri": "data:image/jpeg;base64," + base64.b64encode(b"not a photo").decode(),
                "name": "Sofa", "category": "Home & Furniture",
            })
        assert r.status_code == 400
        generate.assert_not_called()

    @pytest.mark.asyncio
    async def test_generation_is_rate_limited_per_seller(self, client, monkeypatch):
        from api.core import rate_limit
        monkeypatch.setattr(rate_limit, "showcase_generate_limiter",
                            rate_limit.RateLimiter("showcase_test", 2, 3600))
        _, h = await _user()
        with patch.object(fal_client, "generate_showcase_image_url",
                          AsyncMock(return_value="https://fal.media/x.jpg")), \
             patch.object(fal_client, "download_generated_image",
                          AsyncMock(return_value=(_jpeg(), "image/jpeg"))):
            codes = [
                (await client.post("/showcase/preview", headers=h, json={
                    "photo_data_uri": _data_uri(_jpeg()), "name": "Sofa",
                    "category": "Home & Furniture"})).status_code
                for _ in range(3)
            ]
        assert codes == [200, 200, 429]

    @pytest.mark.asyncio
    async def test_the_result_is_an_asset_from_the_sellers_own_photo(self, client):
        seller, h = await _user()
        up = await client.post("/media/images", headers=h, data={"purpose": "listing_photo"},
                               files={"file": ("p.jpg", _jpeg((320, 240)), "image/jpeg")})
        assert up.status_code in (200, 201), up.text
        photo_id = up.json()["id"]
        generate = AsyncMock(return_value="https://fal.media/x.jpg")
        with patch.object(fal_client, "generate_showcase_image_url", generate), \
             patch.object(fal_client, "download_generated_image",
                          AsyncMock(return_value=(_jpeg((400, 300), (250, 250, 250)), "image/jpeg"))):
            r = await client.post("/showcase/preview", headers=h, json={
                "photo_id": photo_id, "name": "Sofa", "category": "Home & Furniture",
                "theme": "studio", "result": "asset", "price": 45000,
            })
        assert r.status_code == 200, r.text
        body = r.json()
        assert "image_data_uri" not in body
        assert body["asset"]["id"] and body["asset"]["medium"]
        prompt = generate.call_args.args[0]
        assert "seamless soft white backdrop" in prompt
        assert "45,000" not in prompt and "Price" not in prompt
        assert "price tags" in prompt
        # The generated cover is the seller's to use on their listing.
        created = await client.post("/listings/", headers=h, json=_body(
            showcase_id=body["asset"]["id"], showcase_image_source="ai"))
        assert created.status_code == 201, created.text

    @pytest.mark.asyncio
    async def test_someone_elses_photo_is_refused(self, client):
        _, owner = await _user()
        _, other = await _user()
        up = await client.post("/media/images", headers=owner, data={"purpose": "listing_photo"},
                               files={"file": ("p.jpg", _jpeg((320, 240)), "image/jpeg")})
        r = await client.post("/showcase/preview", headers=other, json={
            "photo_id": up.json()["id"], "name": "Sofa", "category": "Home & Furniture",
        })
        assert r.status_code == 403

    @pytest.mark.asyncio
    async def test_an_unknown_theme_is_refused(self, client):
        _, h = await _user()
        r = await client.post("/showcase/preview", headers=h, json={
            "photo_data_uri": _data_uri(_jpeg()), "name": "Sofa", "category": "Home & Furniture",
            "theme": "disco",
        })
        assert r.status_code == 400


class TestFalClient:
    @pytest.fixture(autouse=True)
    def _configured(self, monkeypatch):
        monkeypatch.setattr(fal_client, "settings", type("S", (), {
            "fal_key": "k", "fal_showcase_model": "fal-ai/flux-pro/kontext"})())
        monkeypatch.setattr(fal_client, "_POLL_INTERVAL_SECONDS", 0)
        fal_client._breaker._state = fal_client._breaker._state.__class__("closed")
        fal_client._breaker._failure_count = 0

    def _transport(self, monkeypatch, handler):
        real = httpx.AsyncClient

        def make(*args, **kwargs):
            kwargs["transport"] = httpx.MockTransport(handler)
            return real(*args, **kwargs)
        monkeypatch.setattr(fal_client.httpx, "AsyncClient", make)

    @pytest.mark.asyncio
    async def test_a_refused_photo_does_not_switch_generation_off_for_everyone(self, monkeypatch):
        self._transport(monkeypatch, lambda req: httpx.Response(422, json={"detail": "nsfw"}))
        for _ in range(8):
            with pytest.raises(fal_client.FalGenerationError) as exc:
                await fal_client.generate_showcase_image_url("p", "data:image/jpeg;base64,AA")
            assert exc.value.code == "rejected"
        assert fal_client._breaker.state.value == "closed"

    @pytest.mark.asyncio
    async def test_a_dropped_status_poll_does_not_lose_the_generation(self, monkeypatch):
        polls = {"n": 0}

        def handler(req):
            if req.method == "POST":
                return httpx.Response(200, json={"request_id": "r1"})
            if req.url.path.endswith("/status"):
                polls["n"] += 1
                if polls["n"] == 1:
                    return httpx.Response(503)
                return httpx.Response(200, json={"status": "COMPLETED"})
            return httpx.Response(200, json={"images": [{"url": "https://fal.media/out.jpg"}]})
        self._transport(monkeypatch, handler)
        url = await fal_client.generate_showcase_image_url("p", "data:image/jpeg;base64,AA")
        assert url == "https://fal.media/out.jpg"

    @pytest.mark.asyncio
    async def test_the_request_asks_for_a_card_shaped_jpeg(self, monkeypatch):
        seen = {}

        def handler(req):
            if req.method == "POST":
                seen.update(json.loads(req.content))
                return httpx.Response(200, json={"request_id": "r1"})
            if req.url.path.endswith("/status"):
                return httpx.Response(200, json={"status": "COMPLETED"})
            return httpx.Response(200, json={"images": [{"url": "https://fal.media/out.jpg"}]})
        self._transport(monkeypatch, handler)
        await fal_client.generate_showcase_image_url("p", "data:image/jpeg;base64,AA")
        assert seen["output_format"] == "jpeg" and seen["aspect_ratio"] == "4:3"

    @pytest.mark.asyncio
    async def test_a_download_that_is_not_an_image_is_refused(self, monkeypatch):
        self._transport(monkeypatch, lambda req: httpx.Response(
            200, content=b"<html>", headers={"content-type": "text/html"}))
        with pytest.raises(fal_client.FalGenerationError):
            await fal_client.download_generated_image("https://fal.media/out.jpg")
