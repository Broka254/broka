"""Image sizes whose object is missing, and asset records that are damaged.

A size's URL is built from the asset's record and nothing checks the object
is there. In production a thumbnail URL (GET /media/i/img/<id>/thumb.webp)
answered 404 while the same asset's link preview (GET /media/og/<id>.jpg)
answered 200: the record was fine, one object was gone, the rest were not.
The route used to answer that with a bare 404, so a client that asked for
only that size showed no picture.

Covered here:
  * a missing thumbnail / medium is rebuilt from a larger stored size, put
    back under its own key, and served as an immutable hit afterwards
  * a missing large size with only smaller ones left is answered with the
    nearest smaller one, not stored, cached briefly
  * nothing left -> 404, logged with the asset id and no owner details
  * a removed image is not brought back; a key the record doesn't name is
    never written; a failed store still serves what it rebuilt
  * an asset on R2 asked for through the database route is served from R2
  * variant_from_stored follows the pipeline's sizes and never enlarges
  * an asset whose record lists no size can't fail the listing page
"""
import io
import json
import logging
import uuid
from datetime import datetime

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import update

from api.core.image_processing import ImageRejected, process_image, variant_from_stored
from api.core.media_storage import (
    CACHE_FOREVER, DatabaseStorage, R2Storage, StorageError, storage_named, use_storage,
)
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.domains.media.router import UNSTORED_CACHE
from api.models.media import MediaAsset
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_media_recovery.db"
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
    """Every test writes to the database driver unless it installs another."""
    use_storage(None)
    yield
    use_storage(None)


# ── helpers ───────────────────────────────────────────────────────────────────

def _jpeg(size=(2400, 1800), color=(180, 40, 40)) -> bytes:
    """2400x1800 makes three different sizes: 1600x1200, 960x720, 480x360."""
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "JPEG")
    return buf.getvalue()


def _png_rgba(size=(900, 600)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", size, (0, 0, 0, 0)).save(buf, "PNG")
    return buf.getvalue()


async def _user(name="Seller") -> tuple[User, dict]:
    u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _upload(client, headers, raw=None) -> dict:
    r = await client.post(
        "/media/images", headers=headers, data={"purpose": "listing_photo"},
        files={"file": ("photo.jpg", raw or _jpeg(), "image/jpeg")},
    )
    assert r.status_code == 201, r.text
    return r.json()


def _key(asset_id: str, size: str) -> str:
    return f"img/{asset_id}/{size}.webp"


async def _lose(asset_id: str, size: str) -> None:
    """What the production asset looked like: the record names the object,
    the object is gone."""
    await storage_named("db").delete(_key(asset_id, size))


async def _is_stored(asset_id: str, size: str) -> bool:
    return await storage_named("db").get(_key(asset_id, size)) is not None


def _size_of(data: bytes) -> tuple[int, int]:
    img = Image.open(io.BytesIO(data))
    assert img.format == "WEBP"
    return img.size


# ── The route ─────────────────────────────────────────────────────────────────

class TestMissingSize:
    @pytest.mark.asyncio
    async def test_a_missing_thumbnail_is_rebuilt_from_medium_and_stored_again(self, client, caplog):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "thumb")
        assert not await _is_stored(body["id"], "thumb")

        caplog.set_level(logging.INFO, logger="api.domains.media.router")
        r = await client.get(body["thumb"])

        assert r.status_code == 200
        assert r.headers["content-type"] == "image/webp"
        assert r.headers["cache-control"] == CACHE_FOREVER
        assert _size_of(r.content) == (480, 360)
        # Back under its own key: the next request is a plain hit.
        assert await _is_stored(body["id"], "thumb")
        assert (await client.get(body["thumb"])).content == r.content
        assert any(body["id"] in m and "thumb" in m for m in (rec.getMessage() for rec in caplog.records))

    @pytest.mark.asyncio
    async def test_a_missing_medium_is_rebuilt_from_large(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "medium")

        r = await client.get(body["medium"])

        assert r.status_code == 200
        assert r.headers["cache-control"] == CACHE_FOREVER
        assert _size_of(r.content) == (960, 720)
        assert await _is_stored(body["id"], "medium")

    @pytest.mark.asyncio
    async def test_a_missing_large_with_only_smaller_sizes_left_is_answered_not_stored(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        medium = (await client.get(body["medium"])).content
        await _lose(body["id"], "large")

        r = await client.get(body["large"])

        assert r.status_code == 200
        assert r.content == medium                       # the nearest smaller size, as it is
        assert r.headers["cache-control"] == UNSTORED_CACHE
        assert not await _is_stored(body["id"], "large")  # never kept as if it were the real one

    @pytest.mark.asyncio
    async def test_thumbnail_and_medium_missing_still_rebuilds_the_thumbnail_from_large(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "thumb")
        await _lose(body["id"], "medium")

        r = await client.get(body["thumb"])

        assert r.status_code == 200
        assert _size_of(r.content) == (480, 360)
        assert await _is_stored(body["id"], "thumb")

    @pytest.mark.asyncio
    async def test_nothing_left_is_a_404_and_the_log_names_the_asset_only(self, client, caplog):
        owner, headers = await _user()
        body = await _upload(client, headers)
        for size in ("thumb", "medium", "large"):
            await _lose(body["id"], size)

        caplog.set_level(logging.INFO, logger="api.domains.media.router")
        r = await client.get(body["thumb"])

        assert r.status_code == 404
        assert body["id"] in caplog.text and "nothing is left" in caplog.text
        assert owner.id not in caplog.text and owner.phone not in caplog.text
        assert not await _is_stored(body["id"], "thumb")

    @pytest.mark.asyncio
    async def test_a_well_formed_key_for_an_image_that_never_existed_is_a_404(self, client):
        key = _key("00000000-0000-0000-0000-000000000000", "thumb")
        r = await client.get(f"/media/i/{key}")
        assert r.status_code == 404
        assert await storage_named("db").get(key) is None

    @pytest.mark.asyncio
    async def test_a_removed_image_is_not_brought_back(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "thumb")
        async with AsyncSessionLocal() as db:
            await db.execute(update(MediaAsset).where(MediaAsset.id == body["id"])
                             .values(deleted_at=datetime.utcnow()))
            await db.commit()

        r = await client.get(body["thumb"])

        assert r.status_code == 404
        assert not await _is_stored(body["id"], "thumb")

    @pytest.mark.asyncio
    async def test_only_a_key_the_assets_record_names_is_ever_written(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "thumb")
        async with AsyncSessionLocal() as db:
            asset = await db.get(MediaAsset, body["id"])
            variants = json.loads(asset.variants)
            del variants["thumb"]                         # the record no longer names it
            asset.variants = json.dumps(variants)
            await db.commit()

        r = await client.get(f"/media/i/{_key(body['id'], 'thumb')}")

        assert r.status_code == 404
        assert not await _is_stored(body["id"], "thumb")

    @pytest.mark.asyncio
    async def test_a_failed_store_still_serves_what_was_rebuilt_for_a_short_while(self, client, monkeypatch):
        _, headers = await _user()
        body = await _upload(client, headers)
        await _lose(body["id"], "thumb")

        async def refuse(self, key, data, content_type):
            raise StorageError("down")
        monkeypatch.setattr(DatabaseStorage, "put", refuse)

        r = await client.get(body["thumb"])

        assert r.status_code == 200
        assert _size_of(r.content) == (480, 360)
        assert r.headers["cache-control"] == UNSTORED_CACHE
        assert not await _is_stored(body["id"], "thumb")


# ── An asset on R2, asked for through the database route ──────────────────────

class _MemoryS3:
    """The few calls of boto3's S3 client that R2Storage makes, over a dict."""

    class _NoSuchKey(Exception):
        response = {"Error": {"Code": "NoSuchKey"}}

    def __init__(self):
        self.objects: dict[str, tuple[bytes, str]] = {}

    def put_object(self, *, Bucket, Key, Body, ContentType, CacheControl):
        self.objects[Key] = (Body, ContentType)

    def get_object(self, *, Bucket, Key):
        if Key not in self.objects:
            raise self._NoSuchKey()
        data, content_type = self.objects[Key]
        return {"Body": io.BytesIO(data), "ContentType": content_type}

    def delete_object(self, *, Bucket, Key):
        self.objects.pop(Key, None)


class TestR2AssetThroughTheDatabaseRoute:
    @pytest.mark.asyncio
    async def test_it_is_served_from_r2_and_a_missing_size_is_rebuilt_into_r2(self, client):
        s3 = _MemoryS3()
        use_storage(R2Storage(client=s3, bucket="broka-media", public_base_url="https://media.test"))
        _, headers = await _user()
        body = await _upload(client, headers)
        key = _key(body["id"], "thumb")
        assert body["thumb"] == f"https://media.test/{key}"

        r = await client.get(f"/media/i/{key}")
        assert r.status_code == 200
        assert r.content == s3.objects[key][0]

        del s3.objects[key]                                # lost from R2
        r = await client.get(f"/media/i/{key}")
        assert r.status_code == 200
        assert _size_of(r.content) == (480, 360)
        assert key in s3.objects                           # put back where the asset lives


# ── variant_from_stored ───────────────────────────────────────────────────────

class TestVariantFromStored:
    def test_a_size_is_made_from_a_larger_one_the_way_the_pipeline_makes_it(self):
        made = process_image(_jpeg()).variants
        data, w, h = variant_from_stored(made["large"][0], "medium")
        assert (w, h) == (made["medium"][1], made["medium"][2]) == (960, 720)
        assert _size_of(data) == (960, 720)
        _, w, h = variant_from_stored(made["medium"][0], "thumb")
        assert (w, h) == (made["thumb"][1], made["thumb"][2]) == (480, 360)

    def test_it_never_enlarges(self):
        thumb = process_image(_jpeg()).variants["thumb"][0]
        _, w, h = variant_from_stored(thumb, "large")
        assert (w, h) == (480, 360)

    def test_transparency_survives(self):
        large = process_image(_png_rgba()).variants["large"][0]
        data, _, _ = variant_from_stored(large, "thumb")
        assert Image.open(io.BytesIO(data)).mode == "RGBA"

    def test_unreadable_bytes_and_unknown_sizes_are_refused(self):
        with pytest.raises(ImageRejected):
            variant_from_stored(b"not an image", "thumb")
        with pytest.raises(ValueError):
            variant_from_stored(process_image(_jpeg()).variants["large"][0], "huge")


# ── A damaged record ──────────────────────────────────────────────────────────

class TestDamagedAssetRecord:
    @pytest.mark.asyncio
    async def test_a_listing_whose_image_record_lists_no_size_still_lists(self, client):
        """asset_urls is None for such an asset; spreading it into the card's
        cover raised TypeError and failed the whole page."""
        seller, headers = await _user()
        good = await _upload(client, headers)
        damaged = await _upload(client, headers)
        r = await client.post("/listings/", headers=headers, json={
            "description": "Well kept, works perfectly - selling because I upgraded.",
            "name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 25000, "lat": -1.28, "lng": 36.82,
            "photo_ids": [damaged["id"], good["id"]],
        })
        assert r.status_code == 201, r.text
        listing_id = r.json()["id"]
        async with AsyncSessionLocal() as db:
            asset = await db.get(MediaAsset, damaged["id"])
            asset.variants = "{}"
            await db.commit()

        page = await client.get("/listings/", params={"seller_id": seller.id, "limit": 50})

        assert page.status_code == 200
        card = next(item for item in page.json() if item["id"] == listing_id)
        assert card["cover"] is None                      # the cover was the damaged one
        assert [p["id"] for p in card["photos"]] == [good["id"]]
