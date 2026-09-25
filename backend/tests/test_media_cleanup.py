"""Uploads nothing ever used are removed; everything else is kept.

Photos upload as soon as they're picked, before the listing or store
exists, so an abandoned wizard used to leave its uploads stored forever -
and nothing bounded how many a script could leave (30 a minute, all day).

  * attach tracking - an upload is pending until something references it;
                      then attached, for good
  * clean-up        - pending uploads older than a week are claimed and
                      their files deleted; attached, legacy and recent ones
                      are never touched; a storage outage is retried
  * the race        - an upload claimed for clean-up can't then be used
  * quota           - uploads per user per day are capped
"""
import io
import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select, update

from api.core.media_storage import R2Storage, StorageError, storage_named, use_storage
from api.core.rate_limit import RateLimiter
from api.database import (
    AccountType, AsyncSessionLocal, SellerTier, User, init_db, reset_engine,
)
from api.models.media import AttachState, MediaAsset
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_media_cleanup.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
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


@pytest.fixture(autouse=True)
def _database_storage():
    use_storage(None)
    yield
    use_storage(None)


def _png() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (60, 60), (uuid.uuid4().int % 255, 20, 20)).save(buf, "PNG")
    return buf.getvalue()


async def _seller() -> dict:
    u = User(
        name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
        account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term,
    )
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _upload(client, headers, purpose="listing_photo") -> str:
    r = await client.post(
        "/media/images", headers=headers, data={"purpose": purpose},
        files={"file": ("p.png", _png(), "image/png")},
    )
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _asset(asset_id: str) -> MediaAsset:
    async with AsyncSessionLocal() as db:
        return await db.get(MediaAsset, asset_id)


async def _age(asset_id: str, days: float) -> None:
    async with AsyncSessionLocal() as db:
        await db.execute(update(MediaAsset).where(MediaAsset.id == asset_id).values(
            created_at=datetime.utcnow() - timedelta(days=days)))
        await db.commit()


async def _blobs_exist(asset: MediaAsset) -> bool:
    storage = storage_named(asset.storage)
    return all([await storage.get(v["key"]) is not None for v in asset.variant_map().values()])


def _listing(**extra) -> dict:
    return {"name": "Phone", "category": "Electronics", "price": 1000, "lat": -1.2, "lng": 36.8, **extra}


@pytest.mark.asyncio
class TestAttachTracking:
    async def test_an_upload_is_pending_until_used(self, client):
        headers = await _seller()
        asset_id = await _upload(client, headers)
        assert (await _asset(asset_id)).attach_state == AttachState.PENDING
        r = await client.post("/listings/", headers=headers, json=_listing(photo_ids=[asset_id]))
        assert r.status_code == 201
        assert (await _asset(asset_id)).attach_state == AttachState.ATTACHED

    async def test_a_refused_listing_doesnt_attach_its_photos(self, client):
        headers = await _seller()
        asset_id = await _upload(client, headers)
        # Valid photos, but the showcase rule fails: nothing is created.
        r = await client.post("/listings/", headers=headers, json=_listing(
            photo_ids=[asset_id], showcase_image_source="ai"))
        assert r.status_code == 400
        assert (await _asset(asset_id)).attach_state == AttachState.PENDING

    async def test_store_images_are_attached_too(self, client):
        headers = await _seller()
        logo = await _upload(client, headers, "store_logo")
        r = await client.post("/stores", headers=headers, json={"name": "Shop", "logo_id": logo})
        assert r.status_code == 201, r.text
        assert (await _asset(logo)).attach_state == AttachState.ATTACHED


@pytest.mark.asyncio
class TestCleanup:
    async def test_only_old_unused_uploads_are_removed(self, client):
        from api.domains.media.cleanup import collect_abandoned_uploads
        headers = await _seller()
        abandoned = await _upload(client, headers)
        recent = await _upload(client, headers)
        used = await _upload(client, headers)
        legacy = await _upload(client, headers)
        await client.post("/listings/", headers=headers, json=_listing(photo_ids=[used]))
        async with AsyncSessionLocal() as db:
            await db.execute(update(MediaAsset).where(MediaAsset.id == legacy).values(
                attach_state=AttachState.LEGACY))
            await db.commit()
        for asset_id in (abandoned, used, legacy):
            await _age(asset_id, 8)
        await _age(recent, 6)

        done = await collect_abandoned_uploads(batch=1000)

        assert done["purged"] >= 1
        gone = await _asset(abandoned)
        assert gone.attach_state == AttachState.PURGED and gone.deleted_at is not None
        assert not any([await storage_named(gone.storage).get(v["key"])
                        for v in gone.variant_map().values()])
        for kept, state in ((recent, AttachState.PENDING), (used, AttachState.ATTACHED),
                            (legacy, AttachState.LEGACY)):
            asset = await _asset(kept)
            assert asset.attach_state == state and asset.deleted_at is None
            assert await _blobs_exist(asset)

    async def test_a_removed_upload_cant_be_used_afterwards(self, client):
        from api.domains.media.cleanup import collect_abandoned_uploads
        headers = await _seller()
        asset_id = await _upload(client, headers)
        await _age(asset_id, 8)
        await collect_abandoned_uploads(batch=1000)
        r = await client.post("/listings/", headers=headers, json=_listing(photo_ids=[asset_id]))
        assert r.status_code == 400 and "upload it again" in r.json()["detail"]

    async def test_attach_loses_to_a_claim_made_while_it_was_checking(self, client, monkeypatch):
        """The clean-up claims the upload between the listing's check and its
        attach. The listing must fail, not reference a deleted image."""
        from api.domains.media import service as media_service
        headers = await _seller()
        asset_id = await _upload(client, headers)
        real = media_service.load_assets

        async def claimed_meanwhile(db, ids):
            found = await real(db, ids)
            async with AsyncSessionLocal() as other:
                await other.execute(update(MediaAsset).where(MediaAsset.id == asset_id).values(
                    attach_state=AttachState.DELETING))
                await other.commit()
            return found

        monkeypatch.setattr(media_service, "load_assets", claimed_meanwhile)
        r = await client.post("/listings/", headers=headers, json=_listing(photo_ids=[asset_id]))
        assert r.status_code == 400
        assert (await _asset(asset_id)).attach_state == AttachState.DELETING

    async def test_a_storage_outage_is_retried_next_pass(self, client):
        from api.domains.media.cleanup import collect_abandoned_uploads

        class Down(R2Storage):
            name = "db"

            async def delete(self, key):
                raise StorageError("down")

        headers = await _seller()
        asset_id = await _upload(client, headers)
        await _age(asset_id, 8)
        use_storage(Down(client=object()))
        done = await collect_abandoned_uploads(batch=1000)
        assert done["failed"] == 1
        assert (await _asset(asset_id)).attach_state == AttachState.DELETING
        use_storage(None)
        await collect_abandoned_uploads(batch=1000)
        assert (await _asset(asset_id)).attach_state == AttachState.PURGED

    async def test_rows_from_before_tracking_become_legacy(self):
        """What production runs: init_db's ALTER on a media_assets table that
        existed without the column. Every row already there must come out
        "legacy" - never mistakable for an abandoned upload."""
        from sqlalchemy import text
        from sqlalchemy.ext.asyncio import create_async_engine

        alter = next(
            stmt for stmt in _init_db_statements()
            if "media_assets ADD COLUMN attach_state" in stmt
        )
        engine = create_async_engine("sqlite+aiosqlite:///:memory:")
        async with engine.begin() as conn:
            await conn.execute(text("CREATE TABLE media_assets (id VARCHAR PRIMARY KEY, created_at DATETIME)"))
            await conn.execute(text("INSERT INTO media_assets VALUES ('old', '2026-01-01')"))
            await conn.execute(text(alter))
            state = (await conn.execute(text("SELECT attach_state FROM media_assets"))).scalar_one()
        await engine.dispose()
        assert state == AttachState.LEGACY

    async def test_a_fresh_database_defaults_to_legacy_too(self):
        """Rows written without the ORM (none today) get the safe default."""
        from sqlalchemy import text
        owner = User(name="Raw", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        asset_id = str(uuid.uuid4())
        async with AsyncSessionLocal() as db:
            db.add(owner)
            await db.commit()
            await db.execute(text(
                "INSERT INTO media_assets (id, owner_id, purpose, storage, width, height, sha256,"
                " variants, created_at) VALUES (:id, :owner, 'listing_photo', 'db', 1, 1, :sha, '{}', :now)"
            ), {"id": asset_id, "owner": owner.id, "sha": "0" * 64, "now": datetime.utcnow()})
            await db.commit()
            state = (await db.execute(select(MediaAsset.attach_state).where(
                MediaAsset.id == asset_id))).scalar_one()
        assert state == AttachState.LEGACY


def _init_db_statements() -> list[str]:
    """The best-effort schema statements init_db runs, read from its source."""
    import ast
    import inspect

    from api import database
    tree = ast.parse(inspect.getsource(database.init_db))
    out: list[str] = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and "ALTER TABLE" in node.value:
            out.append(node.value)
    return out


@pytest.mark.asyncio
class TestDailyQuota:
    async def test_uploads_per_day_are_capped(self, client, monkeypatch):
        from api.core import rate_limit
        monkeypatch.setattr(rate_limit, "image_upload_daily_limiter", RateLimiter("day", 3, 86400))
        headers = await _seller()
        statuses = []
        for _ in range(4):
            r = await client.post(
                "/media/images", headers=headers, data={"purpose": "listing_photo"},
                files={"file": ("p.png", _png(), "image/png")},
            )
            statuses.append(r.status_code)
        assert statuses == [201, 201, 201, 429]


@pytest.mark.asyncio
class TestAttachSurvivesRetries:
    async def test_a_store_created_on_its_second_attempt_keeps_its_images_attached(self, client, monkeypatch):
        """Creating a store retries after a rollback when its derived link
        was taken by someone else in the meantime. The rollback undoes the
        "attached" mark made in the first attempt; the retry must make it
        again, or the store's logo is deleted by the clean-up a week later."""
        from api.domains.stores.service import StoreService

        taken_by = await _seller()
        taken = await client.post("/stores", headers=taken_by, json={"name": "Race Shop"})
        assert taken.status_code == 201
        real = StoreService._unique_slug
        calls = {"n": 0}

        async def first_one_is_taken(self, name):
            calls["n"] += 1
            if calls["n"] == 1:
                return taken.json()["slug"]            # lost the race: IntegrityError, rollback
            return await real(self, name)

        monkeypatch.setattr(StoreService, "_unique_slug", first_one_is_taken)
        headers = await _seller()
        logo = await _upload(client, headers, "store_logo")
        r = await client.post("/stores", headers=headers, json={"name": "Race Shop", "logo_id": logo})
        assert r.status_code == 201, r.text
        assert calls["n"] == 2
        assert (await _asset(logo)).attach_state == AttachState.ATTACHED
