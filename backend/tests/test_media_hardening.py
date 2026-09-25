"""Image processing and the media backfill under hostile or broken input.

  * processing - every way Pillow can fail on a file is an ImageRejected
                 (a user-facing 422), never an unhandled exception: a
                 header declaring a giant canvas raises Pillow's own
                 DecompressionBombError inside Image.open, which used to
                 escape as a 500
  * backfill   - one row that can't be converted never stops the pass:
                 that same header in a legacy base64 field used to abort
                 every pass, on the same row, every five minutes, so no
                 other image was ever converted again
               - a compare-and-swap lost to a concurrent edit rolls the
                 session back; the rows after it are still converted
               - BROKA's own image URLs, sent back by app builds that
                 predate assets, resolve to the asset instead of being
                 marked unconvertible
"""
import base64
import io
import struct
import uuid
import zlib

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image

from api.core.image_processing import ImageRejected, process_image
from api.core.media_storage import use_storage
from api.database import (
    AccountType, AsyncSessionLocal, Listing, SellerTier, User, init_db, reset_engine,
)
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_media_hardening.db"
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
    # raise_app_exceptions=False: an unhandled error must show up as the
    # 500 a real client would get, not as an exception in the test.
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as c:
        yield c


@pytest.fixture(autouse=True)
def _database_storage():
    use_storage(None)
    yield
    use_storage(None)


@pytest_asyncio.fixture(autouse=True)
async def _no_pending_rows():
    """Each test starts with nothing left for the backfill from earlier ones."""
    from api.domains.media.backfill import run_backfill_pass
    await run_backfill_pass(rows_per_kind=1000, time_budget=60)
    yield


# ── helpers ───────────────────────────────────────────────────────────────────

def _png_header(width: int, height: int) -> bytes:
    """A PNG that is nothing but a header declaring width x height."""
    def chunk(kind: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IEND", b"")


BOMB = _png_header(20_000, 10_000)          # 200 MP declared, ~50 bytes


def _png(color=(200, 10, 10), size=(40, 40)) -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "PNG")
    return buf.getvalue()


def _data_uri(raw: bytes) -> str:
    return "data:image/png;base64," + base64.b64encode(raw).decode()


async def _store_owner() -> tuple[User, dict]:
    u = User(
        name="Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
        account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term,
    )
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


async def _legacy_store(client, logo_url: str) -> str:
    _, headers = await _store_owner()
    r = await client.post("/stores", headers=headers, json={"name": "Shop", "logo_url": logo_url})
    assert r.status_code == 201, r.text
    return r.json()["id"]


async def _store_row(store_id: str) -> Store:
    async with AsyncSessionLocal() as db:
        return await db.get(Store, store_id)


# ── Processing ────────────────────────────────────────────────────────────────

class TestProcessing:
    def test_a_decompression_bomb_header_is_rejected_not_raised(self):
        with pytest.raises(ImageRejected, match="too large"):
            process_image(BOMB)

    @pytest.mark.parametrize("raw", [
        b"\x89PNG\r\n\x1a\n" + b"\x00" * 40,       # PNG signature, garbage header
        b"GIF89a\xff\xff",                          # truncated GIF header
        b"\xff\xd8\xff\xe0" + b"\x00" * 10,        # truncated JPEG
        b"RIFF\x10\x00\x00\x00WEBPVP8 ",            # truncated WebP
    ])
    def test_malformed_headers_are_rejected_not_raised(self, raw):
        with pytest.raises(ImageRejected):
            process_image(raw)

    def test_a_real_image_still_works(self):
        out = process_image(_png())
        assert set(out.variants) == {"thumb", "medium", "large"}


@pytest.mark.asyncio
class TestUpload:
    async def test_a_bomb_header_upload_is_a_422_with_a_reason(self, client):
        _, headers = await _store_owner()
        r = await client.post(
            "/media/images", headers=headers, data={"purpose": "store_logo"},
            files={"file": ("x.png", BOMB, "image/png")},
        )
        assert r.status_code == 422
        assert "too large" in r.json()["detail"]


# ── Backfill ──────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestBackfill:
    async def test_one_bad_image_doesnt_stop_the_others(self, client):
        from api.domains.media.backfill import pending_counts, run_backfill_pass
        bad = await _legacy_store(client, _data_uri(BOMB))
        good = await _legacy_store(client, _data_uri(_png()))

        await run_backfill_pass(rows_per_kind=100)

        assert (await _store_row(good)).logo_id not in (None, "")
        assert (await _store_row(bad)).logo_id == ""          # marked, not retried
        assert (await pending_counts())["store_logos"] == 0

    async def test_a_bad_listing_photo_doesnt_stop_later_kinds(self, client):
        """Listing photos are converted first in a pass; a failure there used
        to take every later kind (store logos, avatars...) down with it."""
        from api.domains.media.backfill import run_backfill_pass
        _, headers = await _store_owner()
        r = await client.post("/listings/", headers=headers, json={"description": "Well kept, works perfectly - selling because I upgraded.", 
            "name": "Phone", "category": "Electronics", "price": 1000, "lat": -1.2, "lng": 36.8,
            "verified_photos": base64.b64encode(BOMB).decode(),
        })
        assert r.status_code == 201, r.text
        store_id = await _legacy_store(client, _data_uri(_png()))

        await run_backfill_pass(rows_per_kind=100)

        async with AsyncSessionLocal() as db:
            assert (await db.get(Listing, r.json()["id"])).photo_ids == "[]"
        assert (await _store_row(store_id)).logo_id not in (None, "")

    async def test_an_unexpected_error_on_one_row_marks_it_and_moves_on(self, client, monkeypatch):
        from api.domains.media import backfill
        first = await _legacy_store(client, _data_uri(_png(color=(1, 1, 1))))
        second = await _legacy_store(client, _data_uri(_png(color=(2, 2, 2))))
        real = backfill.resolve_own_asset
        calls = {"n": 0}

        async def breaks_once(db, owner_id, value, purpose):
            calls["n"] += 1
            if calls["n"] == 1:
                raise RuntimeError("database hiccup")
            return await real(db, owner_id, value, purpose)

        monkeypatch.setattr(backfill, "resolve_own_asset", breaks_once)
        done = await backfill.run_backfill_pass(rows_per_kind=100)

        assert (await _store_row(first)).logo_id == ""
        assert (await _store_row(second)).logo_id not in (None, "")
        assert done["unconvertible"] >= 1 and done["store_logos"] >= 1

    async def test_a_lost_race_doesnt_break_the_rows_after_it(self, client, monkeypatch):
        """A compare-and-swap that loses to an owner's edit rolls the session
        back, which expires every ORM object it loaded. The rows after it
        must still convert."""
        from api.domains.media import backfill
        first = await _legacy_store(client, _data_uri(_png(color=(3, 3, 3))))
        second = await _legacy_store(client, _data_uri(_png(color=(4, 4, 4))))
        edited = _data_uri(_png(color=(9, 9, 9)))
        real = backfill._convert

        async def convert_then_owner_edits(db, owner_id, purpose, values):
            ids = await real(db, owner_id, purpose, values)
            async with AsyncSessionLocal() as other:
                row = await other.get(Store, first)
                if row.logo_url != edited:
                    row.logo_url = edited
                    await other.commit()
            return ids

        monkeypatch.setattr(backfill, "_convert", convert_then_owner_edits)
        await backfill.run_backfill_pass(rows_per_kind=100)

        row = await _store_row(first)
        assert row.logo_url == edited and row.logo_id is None     # the edit won; converted next pass
        assert (await _store_row(second)).logo_id not in (None, "")

    async def test_own_image_urls_resolve_to_their_asset(self, client):
        """An app build that predates assets shows the owner the logo's URL
        and sends it straight back when they save the store."""
        from api.domains.media.backfill import run_backfill_pass
        _, headers = await _store_owner()
        up = await client.post(
            "/media/images", headers=headers, data={"purpose": "store_logo"},
            files={"file": ("logo.png", _png(), "image/png")},
        )
        assert up.status_code == 201, up.text
        asset = up.json()
        r = await client.post("/stores", headers=headers, json={"name": "Shop", "logo_url": asset["medium"]})
        assert r.status_code == 201, r.text
        store_id = r.json()["id"]

        await run_backfill_pass(rows_per_kind=100)

        row = await _store_row(store_id)
        assert row.logo_id == asset["id"] and row.logo_url is None

    async def test_someone_elses_image_url_doesnt_resolve(self, client):
        """Refused when sent (see TestLegacyFields); a row saved before that
        check existed is marked unconvertible rather than taking the image."""
        from api.domains.media.backfill import run_backfill_pass
        _, other = await _store_owner()
        up = await client.post(
            "/media/images", headers=other, data={"purpose": "store_logo"},
            files={"file": ("logo.png", _png(), "image/png")},
        )
        store_id = await _legacy_store(client, _data_uri(_png()))
        async with AsyncSessionLocal() as db:
            row = await db.get(Store, store_id)
            row.logo_url, row.logo_id = up.json()["medium"], None
            await db.commit()

        await run_backfill_pass(rows_per_kind=100)

        assert (await _store_row(store_id)).logo_id == ""


# ── Legacy image fields ───────────────────────────────────────────────────────

FOREIGN = "https://tracker.example/p.gif"


async def _user(**extra) -> tuple[User, dict]:
    u = User(name="U", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", **extra)
    async with AsyncSessionLocal() as db:
        db.add(u)
        await db.commit()
        await db.refresh(u)
    return u, {"Authorization": f"Bearer {create_access_token({'sub': u.id})}"}


def _listing(**extra) -> dict:
    return {"description": "Well kept, works perfectly - selling because I upgraded.", "name": "Phone", "category": "Electronics", "price": 1000, "lat": -1.2, "lng": 36.8, **extra}


@pytest.mark.asyncio
class TestLegacyFields:
    """Fields older app builds fill with base64 accepted any string: a store
    logo could be a link to any site, which the storefront then loaded for
    every visitor - a tracking pixel on broka.co.ke."""

    async def test_a_store_logo_or_photo_cant_be_a_link_elsewhere(self, client):
        _, headers = await _store_owner()
        r = await client.post("/stores", headers=headers, json={"name": "Shop", "logo_url": FOREIGN})
        assert r.status_code == 400
        r = await client.post("/stores", headers=headers, json={"name": "Shop", "photos": [FOREIGN]})
        assert r.status_code == 400
        store_id = await _legacy_store(client, _data_uri(_png()))
        async with AsyncSessionLocal() as db:
            owner_id = (await db.get(Store, store_id)).owner_id
        owner = {"Authorization": f"Bearer {create_access_token({'sub': owner_id})}"}
        r = await client.patch(f"/stores/{store_id}", headers=owner, json={"logo_url": FOREIGN})
        assert r.status_code == 400

    async def test_inline_images_and_empty_values_are_still_fine(self, client):
        _, headers = await _store_owner()
        r = await client.post("/stores", headers=headers, json={
            "name": "Shop", "logo_url": _data_uri(_png()),
            "photos": [base64.b64encode(_png()).decode()],
        })
        assert r.status_code == 201, r.text
        r = await client.patch(f"/stores/{r.json()['id']}", headers=headers, json={"logo_url": ""})
        assert r.status_code == 200

    async def test_someone_elses_broka_image_is_refused(self, client):
        _, other = await _store_owner()
        up = await client.post(
            "/media/images", headers=other, data={"purpose": "store_logo"},
            files={"file": ("logo.png", _png(), "image/png")},
        )
        _, headers = await _store_owner()
        r = await client.post("/stores", headers=headers, json={"name": "Shop", "logo_url": up.json()["medium"]})
        assert r.status_code == 403

    async def test_listing_photos_and_showcase(self, client):
        _, headers = await _user()
        photo = base64.b64encode(_png()).decode()
        r = await client.post("/listings/", headers=headers, json=_listing(verified_photos=f"{photo},{FOREIGN}"))
        assert r.status_code == 400
        r = await client.post("/listings/", headers=headers, json=_listing(
            showcase_image_url=FOREIGN, showcase_image_source="gallery"))
        assert r.status_code == 400
        r = await client.post("/listings/", headers=headers, json=_listing(verified_photos=photo))
        assert r.status_code == 201
        listing_id = r.json()["id"]
        r = await client.patch(f"/listings/{listing_id}", headers=headers, json={"verified_photos": FOREIGN})
        assert r.status_code == 400

    async def test_profile_photos(self, client):
        _, headers = await _user()
        r = await client.patch("/auth/profile", headers=headers, json={"profile_photo": FOREIGN})
        assert r.status_code == 400
        r = await client.patch("/auth/profile", headers=headers, json={"profile_photo": _data_uri(_png())})
        assert r.status_code == 200

    async def test_links_saved_before_the_check_never_leave_the_api(self, client):
        owner, headers = await _store_owner()
        store_id = await _legacy_store(client, _data_uri(_png()))
        r = await client.post("/listings/", headers=headers, json=_listing(verified_photos="QUJDRA=="))
        listing_id = r.json()["id"]
        async with AsyncSessionLocal() as db:
            store = await db.get(Store, store_id)
            store.logo_url, store.logo_id = FOREIGN, ""
            store.photos, store.photo_ids = f'["{FOREIGN}"]', "[]"
            listing = await db.get(Listing, listing_id)
            listing.verified_photos, listing.photo_ids = f"QUJDRA==,{FOREIGN}", "[]"
            listing.showcase_image_url, listing.showcase_id = FOREIGN, ""
            await db.commit()

        store_json = (await client.get(f"/stores/{store_id}")).json()
        assert store_json["logo_url"] is None and store_json["photos"] == []
        listing_json = (await client.get(f"/listings/{listing_id}")).json()
        assert listing_json["verified_photos"] == "QUJDRA=="
        assert listing_json["showcase_image_url"] is None


class TestInlineImageCheck:
    @pytest.mark.parametrize("value,ok", [
        ("data:image/png;base64,iVBORw0KGgo=", True),
        ("data:image/jpeg;base64,/9j/4AAQ", True),
        ("/9j/4AAQSkZJRgABAQ==", True),                    # bare base64 JPEG starts with '/'
        ("iVBORw0K\nGgoAAAANSUhEUg==", True),               # line-wrapped base64
        ("https://tracker.example/p.gif", False),
        ("http://x", False),
        ("//tracker.example/p.gif", False),
        ("//localhost/p", False),                           # scheme-relative, no dot
        ("data:text/html;base64,PHNjcmlwdD4=", False),
        ("data:image/svg+xml,<svg/>", False),               # not base64
        ("javascript:alert(1)", False),
        ("", False),
    ])
    def test_what_counts_as_an_inline_image(self, value, ok):
        from api.domains.media.service import is_inline_image
        assert is_inline_image(value) is ok

    def test_it_is_cheap_on_megabytes(self):
        """Every list page runs it over legacy photos of up to a few MB each."""
        import time
        from api.domains.media.service import is_inline_image
        big = base64.b64encode(b"\xff\xd8" + b"x" * 3_000_000).decode()
        start = time.perf_counter()
        for _ in range(50):
            assert is_inline_image(big)
        assert time.perf_counter() - start < 0.5
