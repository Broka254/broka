"""Photos sent in a negotiation chat (POST /media/upload, content_type=image)
go through the same processing as listing photos (api/core/image_processing).

They used to be stored exactly as sent: never checked to be an image, and
never re-encoded, so a phone camera shot reached the other side of the chat
with its EXIF intact - GPS coordinates included, i.e. where the sender was
standing, usually their home or shop. Listing photos have had that stripped
since the media pipeline landed; chat photos are taken with the same camera.
"""
import base64
import io
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image

from api.database import AsyncSessionLocal, Listing, User, init_db, reset_engine
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_media_images.db"
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


def _camera_jpeg(size=(2400, 1800)) -> bytes:
    """A phone photo: rotated in EXIF, and carrying where it was taken."""
    exif = Image.Exif()
    exif[0x0112] = 6                                   # rotate 90° when shown
    exif[0x8825] = {1: "S", 2: (1.0, 17.0, 0.0)}       # GPS
    buf = io.BytesIO()
    Image.new("RGB", size, (40, 120, 200)).save(buf, "JPEG", exif=exif)
    return buf.getvalue()


async def _thread() -> tuple[str, str, dict]:
    """A listing, and a buyer's auth headers for chatting about it."""
    async with AsyncSessionLocal() as db:
        seller = User(name="Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, buyer.id, {
            "Authorization": f"Bearer {create_access_token({'sub': buyer.id})}"}


async def _send(client, raw: bytes, mime="image/jpeg"):
    listing_id, buyer_id, headers = await _thread()
    return await client.post(
        "/media/upload", headers=headers,
        data={"listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer_id,
              "content_type": "image"},
        files={"file": ("image.jpg", raw, mime)},
    )


def _stored_image(data_uri: str) -> Image.Image:
    head, _, b64 = data_uri.partition(",")
    assert head.startswith("data:image/") and head.endswith(";base64")
    return Image.open(io.BytesIO(base64.b64decode(b64)))


@pytest.mark.asyncio
async def test_location_metadata_is_stripped(client):
    r = await _send(client, _camera_jpeg())
    assert r.status_code == 200, r.text
    img = _stored_image(r.json()["media_url"])
    assert dict(img.getexif()) == {}


@pytest.mark.asyncio
async def test_the_photo_is_stored_upright_and_at_listing_size(client):
    r = await _send(client, _camera_jpeg(size=(2400, 1800)))
    assert r.status_code == 200, r.text
    img = _stored_image(r.json()["media_url"])
    assert img.format == "WEBP"
    # Rotated as EXIF said, and no longer on its side than a listing photo's
    # largest size.
    assert img.size == (1200, 1600)
    assert r.json()["media_url"].startswith("data:image/webp;base64,")


@pytest.mark.asyncio
async def test_something_that_is_not_an_image_is_refused(client):
    r = await _send(client, b"<html><script>alert(1)</script></html>", mime="image/jpeg")
    assert r.status_code == 422
