"""Documents in a direct chat, and the chat upload's other gaps (2026-11-09).

Asked for: sharing documents (PDF, Word, Excel...) in the chat, and several
photos at once - each photo is its own upload, so that part is the app's.

A document is not stored inline like a photo: it is a chat_files row that
the message names, fetched with the thread's own sign-in by its two people
only (GET /media/chat-files/{id}). What a chat carries is a short list of
document types, recognised from their bytes, typed by the server.

Fixed along the way, in the same endpoint:
  * a voice note's type was whatever the upload said - "text/html" was
    stored and relayed as a voice note;
  * the whole upload was read before its size was checked;
  * a caption, and an edit, were the typed text the contact-leak scan
    never saw;
  * nothing limited how many uploads a user could make.
"""
import io
import uuid
import zipfile

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image
from sqlalchemy import select

from api.core import chat_files
from api.core.message_push import preview_of
from api.database import (
    AsyncSessionLocal, AuditLog, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.models.chat_file import ChatFile
from api.routers.negotiate import _reply_preview_for, inbox_preview
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_chat_files.db"
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


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


async def _people():
    """A seller's listing, a buyer chatting about it, and a stranger."""
    async with AsyncSessionLocal() as db:
        seller, buyer, stranger = (
            User(name=n, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
            for n in ("Seller", "Buyer", "Stranger"))
        db.add_all([seller, buyer, stranger])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Toyota Vitz", category="Automobiles",
                          price=650000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        return listing.id, seller.id, buyer.id, stranger.id


def _pdf() -> bytes:
    return b"%PDF-1.7\n1 0 obj << /Type /Catalog >> endobj\ntrailer\n%%EOF\n"


def _docx() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as archive:
        archive.writestr("[Content_Types].xml", "<Types/>")
        archive.writestr("word/document.xml", "<w:document/>")
    return buf.getvalue()


def _jpeg() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (64, 48), (200, 40, 40)).save(buf, "JPEG")
    return buf.getvalue()


async def _send(client, listing_id, sender, role, content_type, name, raw, mime,
                *, caption=None, buyer_id=None, client_msg_id=None, duration_secs=None):
    data = {"listing_id": listing_id, "sender_role": role, "sender_id": sender,
            "content_type": content_type}
    if caption:
        data["caption"] = caption
    if buyer_id:
        data["buyer_id"] = buyer_id
    if client_msg_id:
        data["client_msg_id"] = client_msg_id
    if duration_secs is not None:
        data["duration_secs"] = str(duration_secs)
    return await client.post("/media/upload", headers=_auth(sender), data=data,
                             files={"file": (name, raw, mime)})


@pytest.mark.asyncio
async def test_a_document_is_sent_and_only_the_thread_can_fetch_it(client):
    listing_id, seller, buyer, stranger = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "file", "Logbook scan.pdf", _pdf(),
                    "application/pdf", caption="Logbook", client_msg_id="doc-1")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["msg_type"] == "file"
    assert body["content"] == "Logbook"
    assert body["file_name"] == "Logbook scan.pdf"
    assert body["file_size"] == len(_pdf())
    assert body["file_mime"] == "application/pdf"
    assert body["media_url"].startswith("/media/chat-files/")

    for who in (buyer, seller):
        got = await client.get(body["media_url"], headers=_auth(who))
        assert got.status_code == 200, got.text
        assert got.content == _pdf()
        assert got.headers["content-type"].startswith("application/pdf")
        assert got.headers["content-disposition"].startswith("attachment;")
        assert "Logbook%20scan.pdf" in got.headers["content-disposition"]
        assert got.headers["x-content-type-options"] == "nosniff"

    # Anyone else is told nothing exists - not "forbidden", which confirms it.
    assert (await client.get(body["media_url"], headers=_auth(stranger))).status_code == 404
    assert (await client.get(body["media_url"])).status_code in (401, 403)

    # A resend under the same id is the same message, not a second file.
    again = await _send(client, listing_id, buyer, "buyer", "file", "Logbook scan.pdf", _pdf(),
                        "application/pdf", client_msg_id="doc-1")
    assert again.json()["id"] == body["id"]
    async with AsyncSessionLocal() as db:
        files = (await db.execute(select(ChatFile).where(ChatFile.listing_id == listing_id))).scalars().all()
    assert len(files) == 1


@pytest.mark.asyncio
async def test_history_carries_the_name_not_the_bytes(client):
    listing_id, seller, buyer, _ = await _people()
    r = await _send(client, listing_id, seller, "seller", "file", "Price list.docx", _docx(),
                    "application/octet-stream", buyer_id=buyer)
    assert r.status_code == 200, r.text
    history = (await client.get(f"/negotiate/{listing_id}/history",
                                headers=_auth(buyer))).json()
    row = next(m for m in history if m["msg_type"] == "file")
    assert row["file_name"] == "Price list.docx"
    assert row["file_mime"].endswith("wordprocessingml.document")
    assert row["media_url"] == r.json()["media_url"]
    assert "base64" not in row["media_url"]


@pytest.mark.asyncio
async def test_a_renamed_program_or_an_unknown_type_is_refused(client):
    listing_id, _, buyer, _ = await _people()
    for name, raw in (("invoice.pdf", b"MZ\x90\x00\x03"), ("setup.exe", b"MZ\x90\x00"),
                      ("app.docx", b"PK\x03\x04not-really-a-docx")):
        r = await _send(client, listing_id, buyer, "buyer", "file", name, raw, "application/pdf")
        assert r.status_code == 422, (name, r.text)
    async with AsyncSessionLocal() as db:
        assert (await db.execute(select(ChatFile).where(ChatFile.listing_id == listing_id))).first() is None
        assert (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id))).first() is None


@pytest.mark.asyncio
async def test_the_type_is_the_servers_not_the_clients(client):
    listing_id, _, buyer, _ = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "file", "../../notes.txt",
                    "Bei ya mwisho ni 640,000".encode(), "text/html")
    assert r.status_code == 200, r.text
    assert r.json()["file_name"] == "notes.txt", "no folders in a name"
    got = await client.get(r.json()["media_url"], headers=_auth(buyer))
    assert got.headers["content-type"].startswith("text/plain")


@pytest.mark.asyncio
async def test_unsending_a_document_deletes_it(client):
    listing_id, _, buyer, _ = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "file", "id.pdf", _pdf(), "application/pdf")
    url = r.json()["media_url"]
    gone = await client.delete(f"/negotiate/message/{r.json()['id']}", headers=_auth(buyer))
    assert gone.status_code == 200, gone.text
    assert (await client.get(url, headers=_auth(buyer))).status_code == 404
    async with AsyncSessionLocal() as db:
        msg = await db.get(NegotiationMessage, r.json()["id"])
        assert msg.file_name is None and msg.media_url is None


@pytest.mark.asyncio
async def test_too_large_is_refused(client):
    listing_id, _, buyer, _ = await _people()
    big = b"%PDF-1.7\n" + b"0" * chat_files.MAX_FILE_BYTES
    r = await _send(client, listing_id, buyer, "buyer", "file", "scan.pdf", big, "application/pdf")
    assert r.status_code == 413


@pytest.mark.asyncio
async def test_a_voice_note_must_be_audio(client):
    listing_id, _, buyer, _ = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "audio", "voice.m4a",
                    b"<script>alert(1)</script>", "text/html")
    assert r.status_code == 415
    ok = await _send(client, listing_id, buyer, "buyer", "audio", "voice.m4a",
                     b"\x00\x00\x00\x18ftypM4A ", "audio/mp4")
    assert ok.status_code == 200, ok.text
    assert ok.json()["media_url"].startswith("data:audio/mp4;base64,")


@pytest.mark.asyncio
async def test_a_voice_notes_length_is_what_one_can_last(client):
    # The length is the sender's word: a billion seconds was shown on the
    # other phone as the note's length.
    listing_id, _, buyer, _ = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "audio", "voice.m4a",
                    b"\x00\x00\x00\x18ftypM4A ", "audio/mp4", duration_secs=10**9)
    assert r.status_code == 200, r.text
    assert r.json()["duration_secs"] == 3600
    negative = await _send(client, listing_id, buyer, "buyer", "audio", "voice.m4a",
                           b"\x00\x00\x00\x18ftypM4A ", "audio/mp4", duration_secs=-5)
    assert negative.json()["duration_secs"] == 0


@pytest.mark.asyncio
async def test_uploads_are_limited_per_user(client, monkeypatch):
    from api.core.rate_limit import RateLimiter
    from api.routers import media as media_router
    monkeypatch.setattr(media_router, "chat_media_limiter", RateLimiter("chat_media_test", 2, 60))
    listing_id, seller, buyer, _ = await _people()

    async def voice(sender, role, **extra):
        r = await _send(client, listing_id, sender, role, "audio", "voice.m4a",
                        b"\x00\x00\x00\x18ftypM4A ", "audio/mp4", **extra)
        return r.status_code

    codes = [await voice(buyer, "buyer") for _ in range(3)]
    assert codes == [200, 200, 429]
    # Keyed on the signed-in user: the other side of the chat is not
    # stopped by it.
    assert await voice(seller, "seller", buyer_id=buyer) == 200


async def _solicitations(listing_id: str) -> list:
    async with AsyncSessionLocal() as db:
        rows = await db.execute(
            select(AuditLog)
            .join(NegotiationMessage, NegotiationMessage.id == AuditLog.resource_id)
            .where(AuditLog.action == "off_platform_solicitation_detected",
                   NegotiationMessage.listing_id == listing_id))
        return rows.scalars().all()


@pytest.mark.asyncio
async def test_a_caption_and_an_edit_are_scanned_like_any_message(client):
    listing_id, seller, buyer, _ = await _people()
    r = await _send(client, listing_id, buyer, "buyer", "image", "car.jpg", _jpeg(),
                    "image/jpeg", caption="Nipigie 0712345678")
    assert r.status_code == 200, r.text
    assert len(await _solicitations(listing_id)) == 1

    sent = await client.post("/negotiate/direct-message", headers=_auth(seller), json={
        "listing_id": listing_id, "sender_role": "seller", "sender_id": seller,
        "content": "Iko bado", "buyer_id": buyer,
    })
    assert sent.status_code == 200, sent.text
    assert len(await _solicitations(listing_id)) == 1
    edited = await client.patch(f"/negotiate/message/{sent.json()['message']['id']}",
                                headers=_auth(seller), json={"content": "Piga 0798765432"})
    assert edited.status_code == 200, edited.text
    assert len(await _solicitations(listing_id)) == 2


def test_a_document_is_announced_and_quoted_by_its_name():
    assert preview_of("file", "see attached", "Invoice March.pdf") == "\U0001F4C4 Invoice March.pdf"
    assert preview_of("file", None, None) == "\U0001F4C4 Document"

    class Row:
        id, role, msg_type, content = "m1", "seller", "file", None
        file_name, deleted_at = "Invoice March.pdf", None

    assert _reply_preview_for(Row())["preview"] == "Invoice March.pdf"
    assert inbox_preview(Row()) == "\U0001F4C4 Invoice March.pdf"

    class Photo:
        content, msg_type, deleted_at, file_name = "", "image", None, None

    # It used to read "[media]".
    assert inbox_preview(Photo()) == "\U0001F4F7 Photo"


def test_names_are_cleaned_and_documents_recognised():
    assert chat_files.clean_file_name("C:\\Users\\me\\Invoice.pdf") == "Invoice.pdf"
    assert chat_files.clean_file_name("\x07bad<name>.docx") == "badname.docx"
    assert len(chat_files.clean_file_name("a" * 300 + ".xlsx")) == chat_files.MAX_NAME_CHARS
    assert chat_files.accept_document("a.docx", _docx())[1].endswith("wordprocessingml.document")
    with pytest.raises(chat_files.FileRejected):
        chat_files.accept_document("a.txt", b"\x00binary")
