"""AI covers switched off (AI_COVERS_ENABLED - off in production for now).

What must hold while they are off:
  * no cover is generated, whoever asks: both generate endpoints answer 503
    SHOWCASE_UNAVAILABLE with the "upload a cover from your gallery" reply
    older app builds already show - before the photo is read or a try is
    spent, plan or no plan;
  * the plans neither sell nor count them: no AI cover allowance, no pitch
    that mentions covers, and /premium/me shows none left;
  * a cover the seller uploads still posts with the listing.
With AI_COVERS_ENABLED on (the rest of the suite), all of it is as before.
"""
import dataclasses
import itertools
from datetime import datetime, timedelta
from unittest.mock import patch

import pytest
import pytest_asyncio
from fastapi import HTTPException
from httpx import AsyncClient, ASGITransport

from main import app
from api.core.config import settings
from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.domains.showcase import service as showcase_service
from api.security import create_access_token


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_ai_covers_off.db"
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


@pytest.fixture
def premium_on():
    before = settings.premium_enabled
    object.__setattr__(settings, "premium_enabled", True)
    yield
    object.__setattr__(settings, "premium_enabled", before)


_phones = itertools.count()


async def _user(plan: str | None = None) -> tuple[User, dict]:
    from api.models.subscription import Subscription
    async with AsyncSessionLocal() as db:
        u = User(name="Seller", phone=f"07{next(_phones):08d}", password_hash="x")
        db.add(u)
        await db.flush()
        if plan:
            now = datetime.utcnow()
            db.add(Subscription(user_id=u.id, plan_id=plan, started_at=now - timedelta(days=1),
                                paid_until=now + timedelta(days=29)))
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


def _model_must_not_run():
    def _never(*_a, **_kw):
        raise AssertionError("an AI cover was generated while they are off")
    return (patch("api.domains.showcase.service.hf_image_client.generate_showcase_image_url",
                  side_effect=_never),
            patch("api.domains.showcase.service._photo_from_data_uri", side_effect=_never))


def _unavailable(detail: dict):
    assert detail["code"] == "SHOWCASE_UNAVAILABLE"
    assert "gallery" in detail["message"]


class TestNothingIsGenerated:
    @pytest.mark.asyncio
    async def test_the_wizard_preview_is_refused_first(self, client, ai_covers_off, premium_on):
        _, h = await _user("pro")
        model, photo = _model_must_not_run()
        with model, photo:
            r = await client.post("/showcase/preview", headers=h, json={
                "photo_data_uri": "data:image/jpeg;base64,AAAA", "name": "Sofa",
                "category": "Home & Furniture", "theme": "studio"})
        assert r.status_code == 503
        _unavailable(r.json()["detail"])
        me = (await client.get("/premium/me", headers=h)).json()
        assert me["usage"]["ai_covers"] == {"allowance": 0, "used": 0, "left": 0}

    @pytest.mark.asyncio
    async def test_an_existing_listing_gets_none_either(self, ai_covers_off):
        async with AsyncSessionLocal() as db:
            seller = User(name="Owner", phone=f"07{next(_phones):08d}", password_hash="x")
            db.add(seller)
            await db.flush()
            listing = Listing(seller_id=seller.id, name="Bike", category="Automobiles",
                              price=50_000.0, lat=-1.28, lng=36.82)
            db.add(listing)
            await db.commit()
            model, photo = _model_must_not_run()
            with model, photo, pytest.raises(HTTPException) as exc:
                await showcase_service.generate_showcase_preview(
                    db, listing.id, seller.id, None, theme="studio", as_asset=True)
        assert exc.value.status_code == 503
        _unavailable(exc.value.detail)

    @pytest.mark.asyncio
    async def test_with_them_on_the_free_try_is_back(self, client, premium_on):
        _, h = await _user()
        me = (await client.get("/premium/me", headers=h)).json()
        assert me["trial"]["ai_covers"] == 1


class TestThePlansDoNotSellThem:
    @pytest.mark.asyncio
    async def test_no_allowance_and_no_pitch(self, client, ai_covers_off):
        plans = (await client.get("/pricing/plans")).json()["premium"]
        for plan in plans:
            assert plan["allowances"]["ai_covers"] == 0, plan["id"]
            assert plan["allowances"]["ai_cover_listings"] == 0, plan["id"]
            assert "cover" not in plan["pitch"].lower(), plan["id"]

    @pytest.mark.asyncio
    async def test_and_neither_with_auctions_off_too(self, client, ai_covers_off, auctions_off):
        plans = {p["id"]: p for p in (await client.get("/pricing/plans")).json()["premium"]}
        for plan in plans.values():
            assert "cover" not in plan["pitch"].lower() and "auction" not in plan["pitch"].lower()
        assert plans["pro"]["pitch"] == ("Zeno prices your listings against the market "
                                         "and hunts and haggles for you.")

    @pytest.mark.asyncio
    async def test_a_subscriber_and_a_new_user_have_none_left(self, client, ai_covers_off, premium_on):
        _, plus = await _user("plus")
        me = (await client.get("/premium/me", headers=plus)).json()
        assert me["usage"]["ai_covers"]["allowance"] == 0
        _, new = await _user()
        me = (await client.get("/premium/me", headers=new)).json()
        assert me["trial"]["ai_covers"] == 0
        assert me["trial"]["ai_descriptions"] == 1  # the rest of the trial is untouched

    @pytest.mark.asyncio
    async def test_with_them_on_the_plans_sell_them(self, client):
        plans = {p["id"]: p for p in (await client.get("/pricing/plans")).json()["premium"]}
        assert plans["pro"]["allowances"]["ai_covers"] == 20
        assert "covers" in plans["plus"]["pitch"]


class TestAnUploadedCoverStillPosts:
    @pytest.mark.asyncio
    async def test_a_gallery_cover_goes_with_the_listing(self, client, ai_covers_off):
        _, h = await _user()
        cover = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        r = await client.post("/listings/", headers=h, json={
            "description": "Barely used.", "name": "Sofa", "category": "Home & Furniture",
            "price": 18000, "lat": -1.28, "lng": 36.82,
            "showcase_image_url": cover, "showcase_image_source": "gallery"})
        assert r.status_code == 201, r.text
        assert r.json()["showcase_image_source"] == "gallery"


def test_the_switch_is_off_unless_set():
    """Production gets no AI covers unless AI_COVERS_ENABLED says so."""
    import os
    from api.core.config import Settings
    with patch.dict(os.environ, {}, clear=False):
        os.environ.pop("AI_COVERS_ENABLED", None)
        assert Settings().ai_covers_enabled is False
    assert dataclasses.replace(settings, ai_covers_enabled=True).ai_covers_enabled is True
