"""Image assets: processing, storage, upload, and what listings and stores do
with them (Online Stores phase 1).

Images used to live as base64 text inside listing, store and user rows, and
every list response shipped all of it: up to 6 photos, two videos and the
seller's selfie per product card. Now an upload is processed once into
WebP sizes, stored (R2, or the database here), and rows point at it by id.

Covered here:
  * processing   - only real images; metadata (GPS) stripped; upright;
                   never enlarged; bounded work
  * storage      - the R2 driver's calls and URLs; a storage outage fails
                   the upload cleanly
  * upload/serve - auth, purpose, size, rate limit, immutable caching
  * listings     - ids validated (owner, purpose, count); list responses
                   drop base64 and videos once assets exist; the single
                   listing read keeps base64 for older app builds
  * stores       - logo/photo ids; legacy data URIs converted and cleared
  * backfill     - converts legacy rows, idempotent, never overwrites an
                   edit made while it ran, stops cleanly on storage failure
"""
import base64
import io
import json
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.core import image_processing
from api.core.image_processing import ImageRejected, process_image
from api.core.media_storage import R2Storage, StorageError, current_storage, use_storage
from api.database import (
    AccountType, AsyncSessionLocal, Listing, SellerTier, User, init_db, reset_engine,
)
from api.models.media import MediaAsset
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_media_assets.db"
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

def _jpeg(size=(1200, 900), color=(180, 40, 40), exif=None) -> bytes:
    buf = io.BytesIO()
    kwargs = {"exif": exif} if exif is not None else {}
    Image.new("RGB", size, color).save(buf, "JPEG", **kwargs)
    return buf.getvalue()


def _png_rgba(size=(300, 300)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGBA", size, (0, 0, 0, 0)).save(buf, "PNG")
    return buf.getvalue()


async def _user(name="Seller", **extra) -> tuple[User, dict]:
    u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", **extra)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _store_owner() -> tuple[User, dict]:
    """Only long-term sellers can open a store."""
    return await _user(account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term)


async def _upload(client, headers, purpose="listing_photo", raw=None) -> dict:
    r = await client.post(
        "/media/images", headers=headers, data={"purpose": purpose},
        files={"file": ("photo.jpg", raw or _jpeg(), "image/jpeg")},
    )
    assert r.status_code == 201, r.text
    return r.json()


def _listing_body(**extra) -> dict:
    return {"name": f"Phone {uuid.uuid4().hex[:6]}", "category": "Electronics",
            "price": 25000, "lat": -1.28, "lng": 36.82, **extra}


async def _card(client, listing_id: str, seller_id: str) -> dict:
    r = await client.get("/listings/", params={"seller_id": seller_id, "limit": 50})
    assert r.status_code == 200
    return next(item for item in r.json() if item["id"] == listing_id)


# ── Processing ────────────────────────────────────────────────────────────────

class TestProcessing:
    def test_non_image_bytes_are_refused(self):
        with pytest.raises(ImageRejected):
            process_image(b"<?php echo 'not an image'; ?>")

    def test_oversized_bytes_are_refused_before_decoding(self):
        with pytest.raises(ImageRejected, match="10 MB"):
            process_image(b"\xff" * (image_processing.MAX_UPLOAD_BYTES + 1))

    def test_a_huge_declared_canvas_is_refused(self, monkeypatch):
        monkeypatch.setattr(image_processing, "MAX_PIXELS", 10_000)
        with pytest.raises(ImageRejected, match="too large"):
            process_image(_jpeg(size=(200, 200)))

    def test_metadata_is_stripped_and_rotation_applied(self):
        exif = Image.Exif()
        exif[0x0112] = 6                                   # rotate 90° when shown
        exif[0x8825] = {1: "S", 2: (1.0, 17.0, 0.0)}       # GPS: where the seller lives
        out = process_image(_jpeg(size=(1200, 900), exif=exif))
        assert (out.width, out.height) == (900, 1200)
        for data, _, _ in out.variants.values():
            img = Image.open(io.BytesIO(data))
            assert img.format == "WEBP"
            assert dict(img.getexif()) == {}

    def test_sizes_bound_the_longest_side_and_never_enlarge(self):
        big = process_image(_jpeg(size=(2000, 1000)))
        assert {k: (w, h) for k, (_, w, h) in big.variants.items()} == {
            "thumb": (480, 240), "medium": (960, 480), "large": (1600, 800),
        }
        small = process_image(_jpeg(size=(300, 200)))
        assert {(w, h) for _, w, h in small.variants.values()} == {(300, 200)}

    def test_a_big_camera_jpeg_is_decoded_at_reduced_scale(self):
        big = _jpeg(size=(6000, 4000))
        out = process_image(big)
        assert (out.variants["large"][1], out.variants["large"][2]) == (1600, 1067)
        assert (out.variants["thumb"][1], out.variants["thumb"][2]) == (480, 320)

    def test_formats_without_reduced_decoding_have_a_lower_ceiling(self, monkeypatch):
        monkeypatch.setattr(image_processing, "MAX_PIXELS_FULL_DECODE", 10_000)
        with pytest.raises(ImageRejected, match="too large"):
            process_image(_png_rgba(size=(200, 200)))
        # A JPEG of the same size is fine: it decodes at reduced scale.
        process_image(_jpeg(size=(200, 200)))

    def test_transparency_survives_for_logos(self):
        out = process_image(_png_rgba())
        img = Image.open(io.BytesIO(out.variants["thumb"][0]))
        assert img.mode == "RGBA"


# ── Storage ───────────────────────────────────────────────────────────────────

class _FakeS3:
    def __init__(self):
        self.puts = []

    def put_object(self, **kwargs):
        self.puts.append(kwargs)


class TestR2Storage:
    @pytest.mark.asyncio
    async def test_objects_are_written_immutable_and_served_from_the_public_domain(self):
        fake = _FakeS3()
        r2 = R2Storage(client=fake, bucket="broka-media",
                       public_base_url="https://media.broka.co.ke/")
        await r2.put("img/x/thumb.webp", b"data", "image/webp")
        assert fake.puts == [{
            "Bucket": "broka-media", "Key": "img/x/thumb.webp", "Body": b"data",
            "ContentType": "image/webp",
            "CacheControl": "public, max-age=31536000, immutable",
        }]
        assert r2.public_url("img/x/thumb.webp") == "https://media.broka.co.ke/img/x/thumb.webp"

    def test_r2_is_used_only_when_fully_configured(self):
        from api.core.config import Settings
        env = {"R2_ACCOUNT_ID": "acct", "R2_ACCESS_KEY_ID": "key",
               "R2_SECRET_ACCESS_KEY": "secret", "R2_BUCKET": "broka-media"}
        with pytest.MonkeyPatch.context() as mp:
            for k, v in env.items():
                mp.setenv(k, v)
            mp.delenv("MEDIA_PUBLIC_BASE_URL", raising=False)
            assert Settings().r2_configured is False      # no public URL, no R2
            mp.setenv("MEDIA_PUBLIC_BASE_URL", "https://media.broka.co.ke")
            assert Settings().r2_configured is True

    def test_new_uploads_follow_configuration(self, monkeypatch):
        from api.core.config import Settings
        monkeypatch.setattr(Settings, "r2_configured", property(lambda self: False))
        assert current_storage().name == "db"
        monkeypatch.setattr(Settings, "r2_configured", property(lambda self: True))
        use_storage(None)
        assert current_storage().name == "r2"

    @pytest.mark.asyncio
    async def test_a_storage_outage_fails_the_upload_and_leaves_no_asset(self, client):
        class Down(R2Storage):
            async def put(self, *a, **kw):
                raise StorageError("down")
        use_storage(Down(client=object()))
        user, headers = await _user()
        r = await client.post("/media/images", headers=headers, data={"purpose": "listing_photo"},
                              files={"file": ("a.jpg", _jpeg(), "image/jpeg")})
        assert r.status_code == 503
        async with AsyncSessionLocal() as db:
            rows = (await db.execute(select(MediaAsset).where(MediaAsset.owner_id == user.id))).all()
        assert rows == []


# ── Upload and serving ────────────────────────────────────────────────────────

class TestUpload:
    @pytest.mark.asyncio
    async def test_requires_sign_in(self, client):
        r = await client.post("/media/images", data={"purpose": "listing_photo"},
                              files={"file": ("a.jpg", _jpeg(), "image/jpeg")})
        assert r.status_code == 401

    @pytest.mark.asyncio
    @pytest.mark.parametrize("purpose", ["avatar", "anything", ""])
    async def test_purpose_must_be_an_uploadable_one(self, client, purpose):
        _, headers = await _user()
        r = await client.post("/media/images", headers=headers, data={"purpose": purpose},
                              files={"file": ("a.jpg", _jpeg(), "image/jpeg")})
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_a_non_image_is_refused_with_a_readable_reason(self, client):
        _, headers = await _user()
        r = await client.post("/media/images", headers=headers, data={"purpose": "listing_photo"},
                              files={"file": ("a.jpg", b"not an image", "image/jpeg")})
        assert r.status_code == 422
        assert "image" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_an_oversized_upload_is_refused(self, client):
        _, headers = await _user()
        r = await client.post("/media/images", headers=headers, data={"purpose": "listing_photo"},
                              files={"file": ("a.jpg", b"\xff" * (10 * 1024 * 1024 + 1), "image/jpeg")})
        assert r.status_code == 413

    @pytest.mark.asyncio
    async def test_upload_returns_every_size_and_they_are_served_cacheable(self, client):
        _, headers = await _user()
        body = await _upload(client, headers)
        assert set(body) >= {"id", "thumb", "medium", "large", "width", "height"}
        r = await client.get(body["thumb"])
        assert r.status_code == 200
        assert r.headers["content-type"] == "image/webp"
        assert r.headers["cache-control"] == "public, max-age=31536000, immutable"
        assert Image.open(io.BytesIO(r.content)).size == (480, 360)

    @pytest.mark.asyncio
    @pytest.mark.parametrize("path", [
        "/media/i/img/00000000-0000-0000-0000-000000000000/thumb.webp",
        "/media/i/../../etc/passwd",
        "/media/i/img/x/thumb.webp",
    ])
    async def test_unknown_or_malformed_keys_are_404(self, client, path):
        assert (await client.get(path)).status_code == 404

    @pytest.mark.asyncio
    async def test_uploads_are_rate_limited_per_user(self, client):
        from unittest.mock import patch
        from api.core.rate_limit import RateLimiter
        _, headers = await _user()
        strict = RateLimiter("image_upload_test", limit=2, window_seconds=60)
        with patch("api.core.rate_limit.image_upload_limiter", strict):
            codes = [
                (await client.post("/media/images", headers=headers, data={"purpose": "listing_photo"},
                                   files={"file": ("a.jpg", _jpeg((40, 40)), "image/jpeg")})).status_code
                for _ in range(3)
            ]
        assert codes == [201, 201, 429]


# ── Listings ──────────────────────────────────────────────────────────────────

class TestListings:
    @pytest.mark.asyncio
    async def test_a_listing_made_from_uploads_ships_urls_not_base64(self, client):
        seller, headers = await _user()
        a = await _upload(client, headers)
        b = await _upload(client, headers)
        r = await client.post("/listings/", headers=headers, json=_listing_body(
            photo_ids=[a["id"], b["id"]], verified_video="dmlkZW8=",
        ))
        assert r.status_code == 201, r.text
        listing_id = r.json()["id"]

        card = await _card(client, listing_id, seller.id)
        assert [p["id"] for p in card["photos"]] == [a["id"], b["id"]]
        assert card["cover"]["thumb"] == a["thumb"]
        assert card["cover"]["kind"] == "photo"
        assert card["verified_photos"] is None
        assert card["verified_video"] is None          # cards never carry video

        detail = (await client.get(f"/listings/{listing_id}")).json()
        assert [p["large"] for p in detail["photos"]] == [a["large"], b["large"]]
        assert detail["verified_video"] == "dmlkZW8="

    @pytest.mark.asyncio
    async def test_someone_elses_image_is_refused_and_nothing_is_created(self, client):
        _, owner_headers = await _user()
        thief, thief_headers = await _user()
        theirs = await _upload(client, owner_headers)
        r = await client.post("/listings/", headers=thief_headers, json=_listing_body(photo_ids=[theirs["id"]]))
        assert r.status_code == 403
        async with AsyncSessionLocal() as db:
            count = (await db.execute(select(Listing).where(Listing.seller_id == thief.id))).all()
        assert count == []

    @pytest.mark.asyncio
    async def test_an_image_uploaded_for_something_else_is_refused(self, client):
        _, headers = await _user()
        logo = await _upload(client, headers, purpose="store_logo")
        r = await client.post("/listings/", headers=headers, json=_listing_body(photo_ids=[logo["id"]]))
        assert r.status_code == 400

    @pytest.mark.asyncio
    async def test_at_most_six_photos(self, client):
        _, headers = await _user()
        ids = [str(uuid.uuid4()) for _ in range(7)]
        r = await client.post("/listings/", headers=headers, json=_listing_body(photo_ids=ids))
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_the_showcase_becomes_the_cover_and_needs_a_source(self, client):
        seller, headers = await _user()
        photo = await _upload(client, headers)
        showcase = await _upload(client, headers, purpose="listing_showcase")
        r = await client.post("/listings/", headers=headers, json=_listing_body(
            photo_ids=[photo["id"]], showcase_id=showcase["id"]))
        assert r.status_code == 400                     # no showcase_image_source
        r = await client.post("/listings/", headers=headers, json=_listing_body(
            photo_ids=[photo["id"]], showcase_id=showcase["id"], showcase_image_source="ai"))
        assert r.status_code == 201
        card = await _card(client, r.json()["id"], seller.id)
        assert card["cover"]["id"] == showcase["id"]
        assert card["cover"]["kind"] == "showcase"

    @pytest.mark.asyncio
    async def test_a_legacy_listing_sends_only_its_first_photo_until_converted(self, client):
        from api.domains.media.backfill import run_backfill_pass
        seller, headers = await _user()
        legacy = ",".join(base64.b64encode(_jpeg(color=c)).decode()
                          for c in ((10, 10, 10), (20, 20, 20), (30, 30, 30)))
        r = await client.post("/listings/", headers=headers, json=_listing_body(verified_photos=legacy))
        listing_id = r.json()["id"]

        card = await _card(client, listing_id, seller.id)
        assert card["verified_photos"] == legacy.split(",")[0]
        assert card["cover"] is None

        await run_backfill_pass(rows_per_kind=500)
        card = await _card(client, listing_id, seller.id)
        assert card["verified_photos"] is None
        assert len(card["photos"]) == 3
        # Older app builds' product page still gets the photos.
        detail = (await client.get(f"/listings/{listing_id}")).json()
        assert detail["verified_photos"] == legacy
        assert len(detail["photos"]) == 3

    @pytest.mark.asyncio
    async def test_editing_photos(self, client):
        seller, headers = await _user()
        first = await _upload(client, headers)
        r = await client.post("/listings/", headers=headers, json=_listing_body(photo_ids=[first["id"]]))
        listing_id = r.json()["id"]

        second = await _upload(client, headers)
        r = await client.patch(f"/listings/{listing_id}", headers=headers, json={"photo_ids": [second["id"]]})
        assert r.status_code == 200
        assert [p["id"] for p in (await _card(client, listing_id, seller.id))["photos"]] == [second["id"]]

        # An older app build replacing the photos with base64 marks them
        # for conversion again rather than leaving the old assets showing.
        r = await client.patch(f"/listings/{listing_id}", headers=headers,
                               json={"verified_photos": base64.b64encode(_jpeg()).decode()})
        assert r.status_code == 200
        async with AsyncSessionLocal() as db:
            listing = await db.get(Listing, listing_id)
        assert listing.photo_ids is None

    @pytest.mark.asyncio
    async def test_the_sellers_avatar_is_a_url_once_converted(self, client):
        from api.domains.media.backfill import run_backfill_pass
        selfie = base64.b64encode(_jpeg((400, 400))).decode()
        seller, headers = await _user(profile_photo=selfie)
        photo = await _upload(client, headers)
        r = await client.post("/listings/", headers=headers, json=_listing_body(photo_ids=[photo["id"]]))
        listing_id = r.json()["id"]

        assert (await _card(client, listing_id, seller.id))["seller_profile_photo"] == selfie
        await run_backfill_pass(rows_per_kind=500)
        card = await _card(client, listing_id, seller.id)
        assert card["seller_profile_photo"] is None
        assert card["seller_avatar_url"].endswith("/thumb.webp")


# ── Stores ────────────────────────────────────────────────────────────────────

class TestStores:
    @pytest.mark.asyncio
    async def test_a_store_made_from_uploads_returns_urls(self, client):
        _, headers = await _store_owner()
        logo = await _upload(client, headers, purpose="store_logo", raw=_png_rgba())
        photo = await _upload(client, headers, purpose="store_photo")
        r = await client.post("/stores", headers=headers, json={
            "name": f"Clanix {uuid.uuid4().hex[:5]}", "logo_id": logo["id"], "photo_ids": [photo["id"]],
        })
        assert r.status_code == 201, r.text
        store = r.json()
        assert store["logo_url"] == logo["medium"]
        assert store["photos"] == [photo["large"]]
        directory = (await client.get("/stores", params={"limit": 100})).json()
        assert not any("base64" in json.dumps(s) for s in directory if s["id"] == store["id"])

    @pytest.mark.asyncio
    async def test_a_legacy_logo_is_converted_and_its_base64_cleared(self, client):
        from api.domains.media.backfill import run_backfill_pass
        _, headers = await _store_owner()
        data_uri = "data:image/jpeg;base64," + base64.b64encode(_jpeg((200, 200))).decode()
        r = await client.post("/stores", headers=headers, json={
            "name": f"Legacy {uuid.uuid4().hex[:5]}", "logo_url": data_uri})
        store_id = r.json()["id"]
        assert r.json()["logo_url"] == data_uri

        await run_backfill_pass(rows_per_kind=500)
        async with AsyncSessionLocal() as db:
            row = await db.get(Store, store_id)
        assert row.logo_id and row.logo_url is None
        assert (await client.get(f"/stores/{store_id}")).json()["logo_url"].endswith("/medium.webp")

    @pytest.mark.asyncio
    async def test_a_listing_photo_cant_be_a_store_logo(self, client):
        _, headers = await _store_owner()
        photo = await _upload(client, headers)
        r = await client.post("/stores", headers=headers, json={
            "name": f"Wrong {uuid.uuid4().hex[:5]}", "logo_id": photo["id"]})
        assert r.status_code == 400


# ── Backfill ──────────────────────────────────────────────────────────────────

class TestBackfill:
    @pytest.mark.asyncio
    async def test_unconvertible_data_is_marked_and_not_retried(self, client):
        from api.domains.media.backfill import run_backfill_pass
        seller, headers = await _user()
        r = await client.post("/listings/", headers=headers, json=_listing_body(verified_photos="bm90IGFuIGltYWdl"))
        listing_id = r.json()["id"]
        await run_backfill_pass(rows_per_kind=500)
        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, listing_id)).photo_ids == "[]"
        # Still shown the legacy way, and a second pass leaves everything alone.
        assert (await _card(client, listing_id, seller.id))["verified_photos"] == "bm90IGFuIGltYWdl"
        second = await run_backfill_pass(rows_per_kind=500)
        assert sum(v for v in second.values() if isinstance(v, int)) == 0

    @pytest.mark.asyncio
    async def test_an_edit_made_during_conversion_wins(self, client, monkeypatch):
        from api.domains.media import backfill
        _, headers = await _user()
        r = await client.post("/listings/", headers=headers, json=_listing_body(
            verified_photos=base64.b64encode(_jpeg()).decode()))
        listing_id = r.json()["id"]
        edited = base64.b64encode(_jpeg(color=(1, 2, 3))).decode()

        real_convert = backfill._convert

        async def convert_then_seller_edits(db, owner_id, purpose, values):
            ids = await real_convert(db, owner_id, purpose, values)
            if purpose == "listing_photo":
                async with AsyncSessionLocal() as other:
                    row = await other.get(Listing, listing_id)
                    if row.verified_photos != edited:
                        row.verified_photos = edited
                        row.photo_ids = None
                        await other.commit()
            return ids

        monkeypatch.setattr(backfill, "_convert", convert_then_seller_edits)
        await backfill.run_backfill_pass(rows_per_kind=500)
        async with AsyncSessionLocal() as db:
            row = await db.get(Listing, listing_id)
        assert row.verified_photos == edited
        assert row.photo_ids is None        # still pending: the new photos get converted next pass

    @pytest.mark.asyncio
    async def test_a_storage_outage_stops_the_pass_without_marking_rows(self, client):
        from api.domains.media.backfill import run_backfill_pass

        class Down(R2Storage):
            async def put(self, *a, **kw):
                raise StorageError("down")

        _, headers = await _user()
        r = await client.post("/listings/", headers=headers, json=_listing_body(
            verified_photos=base64.b64encode(_jpeg()).decode()))
        listing_id = r.json()["id"]
        use_storage(Down(client=object()))
        done = await run_backfill_pass(rows_per_kind=500)
        assert done.get("stopped") == "storage unavailable"
        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, listing_id)).photo_ids is None

    @pytest.mark.asyncio
    async def test_admin_trigger_is_admin_only_and_reports_what_is_left(self, client):
        _, headers = await _user()
        assert (await client.post("/media/backfill", headers=headers)).status_code in (404, 405)
        assert (await client.post("/admin/media/backfill", headers=headers)).status_code == 403
        _, admin_headers = await _user(is_admin=True)
        r = await client.post("/admin/media/backfill", headers=admin_headers)
        assert r.status_code == 200
        assert set(r.json()["remaining"]) == {
            "listing_photos", "showcases", "store_logos", "store_photos", "avatars",
        }


# ── Showcase input ────────────────────────────────────────────────────────────

class TestShowcaseInput:
    @pytest.mark.asyncio
    async def test_the_first_photo_is_read_from_assets_as_jpeg(self, client):
        from api.domains.showcase.service import _first_actual_photo_data_uri
        _, headers = await _user()
        photo = await _upload(client, headers)
        r = await client.post("/listings/", headers=headers, json=_listing_body(photo_ids=[photo["id"]]))
        async with AsyncSessionLocal() as db:
            listing = await db.get(Listing, r.json()["id"])
            uri = await _first_actual_photo_data_uri(db, listing)
        assert uri.startswith("data:image/jpeg;base64,")
        img = Image.open(io.BytesIO(base64.b64decode(uri.split(",", 1)[1])))
        assert img.format == "JPEG"
