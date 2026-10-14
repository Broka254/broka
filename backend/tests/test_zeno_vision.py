"""Zeno looking at photos (2026-10-02).

Assessed on request, and found not to work anywhere:

  * The Zeno tab (POST /zeno/assistant/turn) took text only.
  * The negotiation room (POST /negotiate/message) had no image field, so
    the photo the app attaches to a damaged-goods report was dropped by
    validation, and the report "analysed" the sentence "The goods arrived
    damaged." instead.
  * Gemini, first in line for photos, was pinned to gemini-2.0-flash, which
    Google shut down on 2026-06-01 - every call 404'd and fell through.
  * When the providers that can see were configured but failed, the photo
    fell through to a text-only model that answered as if none was sent.

Photos are checked, stripped of metadata and shrunk before any provider
sees them (core/vision.py). Models are stubbed throughout.
"""
import base64
import io
import json
import uuid
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from PIL import Image

from api.core import gemini
from api.core.vision import ImageRejected, prepare_for_model
from api.database import (
    AsyncSessionLocal, Deal, DealStatus, Listing, NegotiationMessage, User, init_db, reset_engine,
)
from api.security import create_access_token
from main import app


@pytest.fixture(autouse=True)
def _force_inprocess_events(monkeypatch):
    from api.core.config import settings
    monkeypatch.setattr(type(settings), "redis_enabled", property(lambda self: False))


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_zeno_vision.db"
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


def _photo(size=(3000, 2000), gps=True) -> str:
    """A phone photo, as base64: big, and carrying where it was taken."""
    exif = Image.Exif()
    if gps:
        exif[0x8825] = {1: "S", 2: (1.0, 17.0, 0.0)}
    buf = io.BytesIO()
    Image.new("RGB", size, (200, 80, 40)).save(buf, "JPEG", exif=exif)
    return base64.b64encode(buf.getvalue()).decode()


def _opened(b64: str) -> Image.Image:
    return Image.open(io.BytesIO(base64.b64decode(b64)))


async def _user(name="Ann") -> User:
    async with AsyncSessionLocal() as db:
        u = User(name=name, phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add(u)
        await db.commit()
        await db.refresh(u)
        return u


def _auth(uid: str) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': uid})}"}


# ── Getting a photo ready ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_photo_is_shrunk_and_stripped_before_a_model_sees_it():
    out = await prepare_for_model(_photo())
    img = _opened(out)
    assert img.format == "JPEG"
    assert max(img.size) == 960
    assert dict(img.getexif()) == {}


@pytest.mark.asyncio
async def test_a_data_uri_is_accepted():
    out = await prepare_for_model("data:image/jpeg;base64," + _photo(size=(400, 300)))
    assert _opened(out).size == (400, 300)


@pytest.mark.asyncio
@pytest.mark.parametrize("junk", ["A" * 600, base64.b64encode(b"<html>hi</html>").decode(), ""])
async def test_something_that_is_not_a_photo_is_refused(junk):
    with pytest.raises(ImageRejected):
        await prepare_for_model(junk)


# ── Gemini ────────────────────────────────────────────────────────────────────

def test_gemini_is_not_pinned_to_the_shut_down_model():
    from api.core.config import settings
    assert settings.gemini_model != "gemini-2.0-flash"
    assert gemini.endpoint().endswith(f"/models/{settings.gemini_model}:generateContent")


def test_gemini_model_is_a_setting(monkeypatch):
    from api.core.config import Settings
    monkeypatch.setenv("GEMINI_MODEL", "gemini-9-flash")
    assert Settings().gemini_model == "gemini-9-flash"


def test_gemini_answer_skips_thinking_and_refuses_an_empty_one():
    data = {"candidates": [{"content": {"parts": [
        {"text": "thinking about it", "thought": True}, {"text": " A red phone. "}]}}]}
    assert gemini.reply_text(data) == "A red phone."
    with pytest.raises(ValueError):
        gemini.reply_text({"candidates": [{"finishReason": "MAX_TOKENS", "content": {}}]})
    with pytest.raises(ValueError):
        gemini.reply_text({"promptFeedback": {"blockReason": "SAFETY"}})


# ── The Zeno tab ──────────────────────────────────────────────────────────────

def _assistant_model(monkeypatch, calls):
    from api.domains.ai_broker.service import AIBrokerService

    async def fake_call(self, messages, cache_key=None, image_base64=None):
        calls.append({"prompt": messages[0]["content"], "image": image_base64})
        return json.dumps({"reply": "That's a red phone.", "action": {"type": "NONE"}})

    monkeypatch.setattr(AIBrokerService, "_call_ai", fake_call)


@pytest.mark.asyncio
async def test_the_zeno_tab_looks_at_an_attached_photo(client, monkeypatch):
    calls = []
    _assistant_model(monkeypatch, calls)
    user = await _user()
    r = await client.post("/zeno/assistant/turn", headers=_auth(user.id), json={
        "message": "what is this worth?", "image_base64": _photo()})
    assert r.status_code == 200, r.text
    assert r.json()["reply"] == "That's a red phone."
    assert len(calls) == 1
    # The prepared photo, not the camera original.
    assert max(_opened(calls[0]["image"]).size) == 960
    assert "ATTACHED A PHOTO" in calls[0]["prompt"]


@pytest.mark.asyncio
async def test_a_photo_alone_is_a_question(client, monkeypatch):
    calls = []
    _assistant_model(monkeypatch, calls)
    user = await _user()
    r = await client.post("/zeno/assistant/turn", headers=_auth(user.id), json={
        "message": "", "image_base64": _photo(size=(300, 300))})
    assert r.status_code == 200, r.text
    assert calls and calls[0]["image"]


@pytest.mark.asyncio
async def test_a_command_typed_under_a_photo_is_a_question_about_it(client, monkeypatch):
    """"sell" alone opens the Sell screen without a model; under a photo it
    is about the photo, which only the model can see."""
    calls = []
    _assistant_model(monkeypatch, calls)
    user = await _user()
    r = await client.post("/zeno/assistant/turn", headers=_auth(user.id), json={
        "message": "sell", "image_base64": _photo(size=(300, 300))})
    assert r.status_code == 200
    assert r.json()["source"] == "model"
    assert len(calls) == 1


@pytest.mark.asyncio
async def test_nothing_at_all_is_refused(client, monkeypatch):
    calls = []
    _assistant_model(monkeypatch, calls)
    user = await _user()
    r = await client.post("/zeno/assistant/turn", headers=_auth(user.id), json={"message": "  "})
    assert r.status_code == 422
    assert calls == []


@pytest.mark.asyncio
async def test_a_file_that_is_not_a_photo_never_reaches_the_model(client, monkeypatch):
    calls = []
    _assistant_model(monkeypatch, calls)
    user = await _user()
    r = await client.post("/zeno/assistant/turn", headers=_auth(user.id), json={
        "message": "what is this", "image_base64": "A" * 5000})
    assert r.status_code == 422
    assert calls == []


@pytest.mark.asyncio
async def test_only_providers_that_can_see_are_given_the_photo(monkeypatch):
    from api.domains.ai_broker import service as svc_mod
    svc = svc_mod.AIBrokerService()
    svc.gemini_key, svc.deepseek_key = "g", "d"
    svc.openrouter_key, svc.groq_key = "o", ""
    gem = AsyncMock(return_value="seen by gemini")
    monkeypatch.setattr(svc, "_call_gemini", gem)
    out = await svc._call_ai([{"role": "user", "content": "hi"}], image_base64="IMG")
    assert out == "seen by gemini"
    assert gem.await_args.args[1] == "IMG"


@pytest.mark.asyncio
async def test_when_nobody_can_see_the_model_is_told_so(monkeypatch):
    from api.domains.ai_broker import service as svc_mod
    svc = svc_mod.AIBrokerService()
    svc.gemini_key, svc.deepseek_key = "g", "d"
    svc.openrouter_key, svc.groq_key = "o", ""
    monkeypatch.setattr(svc, "_call_gemini", AsyncMock(side_effect=ValueError("404")))
    monkeypatch.setattr(svc, "_call_deepseek", AsyncMock(side_effect=ValueError("400")))
    seen = {}

    async def text_model(messages):
        seen["messages"] = messages
        return "I can't see the photo - could you describe it?"

    monkeypatch.setattr(svc, "_call_openrouter", text_model)
    out = await svc._call_ai([{"role": "user", "content": "what is this?"}], image_base64="IMG")
    assert out.startswith("I can't see")
    assert seen["messages"][-1]["content"] == svc_mod.PHOTO_UNSEEN_NOTE


@pytest.mark.asyncio
async def test_deepseek_gets_the_photo_beside_the_text():
    from api.domains.ai_broker import service as svc_mod
    svc = svc_mod.AIBrokerService()
    svc.deepseek_key = "d"
    sent = {}

    class _Resp:
        status_code = 200

        def raise_for_status(self):
            pass

        def json(self):
            return {"choices": [{"message": {"content": "a phone"}}]}

    class _Client:
        def __init__(self, *a, **kw):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        async def post(self, url, json=None, headers=None):
            sent["json"] = json
            return _Resp()

    with patch.object(svc_mod.httpx, "AsyncClient", _Client):
        out = await svc._call_deepseek([{"role": "user", "content": "what is this?"}], "IMG")
    assert out == "a phone"
    content = sent["json"]["messages"][-1]["content"]
    assert content[0] == {"type": "text", "text": "what is this?"}
    assert content[1]["image_url"]["url"] == "data:image/jpeg;base64,IMG"


# ── The negotiation room ──────────────────────────────────────────────────────

async def _deal_awaiting_condition_check():
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.flush()
        deal = Deal(listing_id=listing.id, seller_id=seller.id, buyer_id=buyer.id,
                    agreed_price=25000, commission=750,
                    status=DealStatus.awaiting_condition_check)
        db.add(deal)
        await db.commit()
        return listing.id, seller.id, buyer.id


@pytest.mark.asyncio
async def test_a_damage_report_photo_is_analysed(client):
    listing_id, seller, buyer = await _deal_awaiting_condition_check()
    seen = {}

    async def fake_ai(system, messages, image_base64=None, **kw):
        seen.update(image=image_base64, **kw)
        return "The screen is cracked across the top left."

    with patch("api.routers.negotiate._call_ai", fake_ai):
        r = await client.post("/negotiate/message", headers=_auth(buyer), json={
            "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "The goods arrived damaged.", "intent": "buyer_reports_damaged",
            "image_base64": _photo(),
        })
    assert r.status_code == 200, r.text
    assert "screen is cracked" in r.json()["content"]
    assert max(_opened(seen["image"]).size) == 960
    # Quoted to the seller as "my image analysis shows", so only a model
    # that saw the photo may write it.
    assert seen["require_vision"] is True
    async with AsyncSessionLocal() as db:
        from sqlalchemy import select
        notice = (await db.execute(select(NegotiationMessage).where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.recipient_role == "seller"))).scalar_one()
    assert "screen is cracked" in notice.content


@pytest.mark.asyncio
async def test_a_damage_report_says_nothing_it_did_not_see(client):
    listing_id, seller, buyer = await _deal_awaiting_condition_check()

    async def no_vision(*a, **kw):
        raise ValueError("no vision-capable provider answered")

    with patch("api.routers.negotiate._call_ai", no_vision):
        r = await client.post("/negotiate/message", headers=_auth(buyer), json={
            "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer,
            "content": "The goods arrived damaged.", "intent": "buyer_reports_damaged",
            "image_base64": _photo(size=(300, 300)),
        })
    assert r.status_code == 200
    assert "image assessment" not in r.json()["content"]


@pytest.mark.asyncio
async def test_require_vision_never_falls_through_to_a_text_model(monkeypatch):
    from api.routers import negotiate
    monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "g")
    monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "")
    monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "o")
    monkeypatch.setattr(negotiate, "_call_gemini", AsyncMock(side_effect=ValueError("404")))
    text_only = AsyncMock(return_value="I can't see it")
    monkeypatch.setattr(negotiate, "_call_openrouter", text_only)
    with pytest.raises(ValueError):
        await negotiate._call_ai("sys", [{"role": "user", "content": "x"}],
                                 image_base64="IMG", require_vision=True)
    text_only.assert_not_awaited()


@pytest.mark.asyncio
async def test_a_failed_vision_provider_does_not_leave_the_photo_unmentioned(monkeypatch):
    from api.routers import negotiate
    monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "g")
    monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "")
    monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "o")
    monkeypatch.setattr(negotiate, "_call_gemini", AsyncMock(side_effect=ValueError("404")))
    text_only = AsyncMock(return_value="I can't see it")
    monkeypatch.setattr(negotiate, "_call_openrouter", text_only)
    await negotiate._call_ai("sys", [{"role": "user", "content": "x"}], image_base64="IMG")
    system = text_only.await_args.args[0]
    assert "CANNOT see it" in system


@pytest.mark.asyncio
async def test_a_photo_sent_to_zeno_in_the_room_reaches_only_the_senders_reply(client):
    async with AsyncSessionLocal() as db:
        seller = User(name="Sam Seller", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        buyer = User(name="Bea Buyer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        db.add_all([seller, buyer])
        await db.flush()
        listing = Listing(seller_id=seller.id, name="Phone", category="Electronics",
                          price=25000, lat=-1.28, lng=36.82)
        db.add(listing)
        await db.commit()
        listing_id, buyer_id = listing.id, buyer.id

    calls = []

    async def fake_ai(system, messages, image_base64=None, **kw):
        calls.append(image_base64)
        return "Looks like the same model as the listing."

    relay = {"needs_relay": True, "relay_summary": "The buyer wants to know the storage size.",
             "is_availability_confirmation": False}
    with patch("api.routers.negotiate._call_ai", fake_ai), \
         patch("api.routers.negotiate._classify_relay", AsyncMock(return_value=relay)):
        r = await client.post("/negotiate/message", headers=_auth(buyer_id), json={
            "listing_id": listing_id, "sender_role": "buyer", "sender_id": buyer_id,
            "content": "is this the same as mine? what storage?", "image_base64": _photo(),
        })
    assert r.status_code == 200, r.text
    with_photo = [c for c in calls if c]
    assert len(with_photo) == 1, "only the sender's own reply sees the photo"
    assert len(calls) >= 2, "the relay to the seller was drafted without it"
