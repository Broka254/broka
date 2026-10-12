"""
BROKA - Which voice speaks what (POST /tts/speak)
Run: pytest backend/tests/test_tts_voices.py -v

The English voice (en-US-AriaNeural) was the default for anything without a
voice of its own, and read whatever it was given - Swahili included. It now
reads English only: Swahili text goes to the Swahili voice even when sent as
"english", and a language with no voice here is refused instead of read in
an American accent. Microsoft's service is faked; nothing leaves the test.
"""

import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.routers import tts


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_tts_voices.db"
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


@pytest_asyncio.fixture(scope="module")
async def auth(client):
    phone = "0747771101"
    req = await client.post("/auth/otp/request", json={"phone": phone})
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": req.json()["debug_code"]})
    await client.post("/auth/register", json={
        "phone_verify_token": verify.json()["phone_verify_token"], "name": "Voice Tester",
        "email": "voice.tester@test.ke", "password": "TestPass123!", "lat": -1.28, "lng": 36.8,
    })
    login = await client.post("/auth/login", json={"phone": phone, "password": "TestPass123!"})
    return {"Authorization": f"Bearer {login.json()['access_token']}"}


@pytest.fixture
def voices_used(monkeypatch):
    """Replaces edge_tts.Communicate; records which voice was asked for."""
    used: list[str] = []

    class FakeCommunicate:
        def __init__(self, text, voice):
            used.append(voice)

        async def stream(self):
            yield {"type": "audio", "data": b"ID3fake-mp3"}

    monkeypatch.setattr(tts.edge_tts, "Communicate", FakeCommunicate)
    # AssemblyAI speaks English ahead of Edge; without its key it steps aside.
    monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
    return used


async def _speak(client, auth, text, language):
    return await client.post("/tts/speak", json={"text": text, "language": language}, headers=auth)


@pytest.mark.asyncio
async def test_english_text_gets_the_english_voice(client, auth, voices_used):
    res = await _speak(client, auth, "Here are three phones under your budget.", "english")
    assert res.status_code == 200
    assert voices_used == ["en-US-AvaMultilingualNeural"]


@pytest.mark.asyncio
async def test_swahili_text_is_never_read_by_the_english_voice(client, auth, voices_used):
    # The user's setting says English, but they chatted in Swahili and Zeno
    # answered in Swahili.
    res = await _speak(client, auth, "Bei ya simu hii ni elfu kumi, na iko safi kabisa.", "english")
    assert res.status_code == 200
    assert voices_used == ["sw-KE-ZuriNeural"]


@pytest.mark.asyncio
async def test_a_borrowed_greeting_does_not_make_english_swahili(client, auth, voices_used):
    res = await _speak(client, auth, "Karibu! I found two laptops that match what you asked for.", "english")
    assert res.status_code == 200
    assert voices_used == ["en-US-AvaMultilingualNeural"]


@pytest.mark.asyncio
async def test_swahili_setting_uses_the_swahili_voice(client, auth, voices_used):
    res = await _speak(client, auth, "Habari! Niko hapa kukusaidia.", "swahili")
    assert res.status_code == 200
    assert voices_used == ["sw-KE-ZuriNeural"]


@pytest.mark.asyncio
async def test_a_language_without_a_voice_is_refused_not_read_in_english(client, auth, voices_used):
    res = await _speak(client, auth, "Bonjour, voici trois téléphones.", "french")
    assert res.status_code == 422
    assert res.json()["detail"] == "no_voice_for_language"
    assert voices_used == []


def test_marker_words_need_weight_not_one_hit():
    assert not tts._reads_as_swahili("Sawa, that works for me.")
    assert tts._reads_as_swahili("Nataka gari nzuri kwa bei rahisi")
    assert not tts._reads_as_swahili("")


class TestEnglishVoice:
    @pytest.mark.asyncio
    async def test_ava_speaks_and_aria_stands_in_when_ava_fails(self, monkeypatch):
        from api.routers import tts
        tried = []

        async def fake_audio(text, voice):
            tried.append(voice)
            if voice == "en-US-AvaMultilingualNeural":
                raise RuntimeError("voice gone")
            return b"mp3"

        async def no_assemblyai(text):
            return None

        monkeypatch.setattr(tts, "_edge_audio", fake_audio)
        monkeypatch.setattr(tts, "_assemblyai_audio", no_assemblyai)
        r = await tts._speak_edge("Hello there", "english")
        assert r.body == b"mp3"
        assert tried == ["en-US-AvaMultilingualNeural", "en-US-AriaNeural"]


class TestFallbackChain:
    """AssemblyAI -> Edge -> Deepgram -> a graceful 503 (2026-10-12)."""

    @pytest.fixture
    def edge_down(self, monkeypatch):
        async def broken(text, voice):
            raise RuntimeError("edge gone")
        monkeypatch.setattr(tts, "_edge_audio", broken)

    @pytest.mark.asyncio
    async def test_assemblyai_speaks_first(self, monkeypatch):
        tried = []

        async def edge(text, voice):
            tried.append("edge")
            return b"edge-mp3"

        async def deepgram(text):
            tried.append("deepgram")
            return b"dg-mp3", "audio/mpeg"

        async def assemblyai(text):
            tried.append("assemblyai")
            return b"aai-wav", "audio/wav"

        monkeypatch.setattr(tts, "_edge_audio", edge)
        monkeypatch.setattr(tts, "_deepgram_audio", deepgram)
        monkeypatch.setattr(tts, "_assemblyai_audio", assemblyai)
        r = await tts._speak_edge("Hello there", "english")
        assert r.body == b"aai-wav"
        assert r.media_type == "audio/wav"
        assert tried == ["assemblyai"]

    @pytest.mark.asyncio
    async def test_deepgram_speaks_when_assemblyai_and_edge_fail(self, monkeypatch, edge_down):
        tried = []

        async def deepgram(text):
            tried.append("deepgram")
            return b"dg-mp3", "audio/mpeg"

        async def assemblyai(text):
            tried.append("assemblyai")
            raise RuntimeError("agent down")

        monkeypatch.setattr(tts, "_deepgram_audio", deepgram)
        monkeypatch.setattr(tts, "_assemblyai_audio", assemblyai)
        r = await tts._speak_edge("Hello there", "english")
        assert r.body == b"dg-mp3"
        assert tried == ["assemblyai", "deepgram"]

    @pytest.mark.asyncio
    async def test_every_voice_down_is_a_graceful_503(self, monkeypatch, edge_down):
        async def nothing(text):
            return None

        monkeypatch.setattr(tts, "_deepgram_audio", nothing)
        monkeypatch.setattr(tts, "_assemblyai_audio", nothing)
        with pytest.raises(tts.HTTPException) as err:
            await tts._speak_edge("Hello there", "english")
        assert err.value.status_code == 503
        assert err.value.detail == "voice_unavailable"

    @pytest.mark.asyncio
    async def test_swahili_never_falls_back_to_an_english_voice(self, monkeypatch, edge_down):
        tried = []

        async def english_voice(text):
            tried.append(text)
            return b"x", "audio/mpeg"

        monkeypatch.setattr(tts, "_deepgram_audio", english_voice)
        monkeypatch.setattr(tts, "_assemblyai_audio", english_voice)
        with pytest.raises(tts.HTTPException):
            await tts._speak_edge("Habari yako", "swahili")
        assert tried == []

    @pytest.mark.asyncio
    async def test_unset_keys_skip_the_fallbacks(self, monkeypatch):
        monkeypatch.delenv("DEEPGRAM_API_KEY", raising=False)
        monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
        assert await tts._deepgram_audio("Hello") is None
        assert await tts._assemblyai_audio("Hello") is None

    def test_wav_header_matches_the_pcm(self):
        wav = tts._wav(b"\x00\x01" * 10, 24000)
        assert wav[:4] == b"RIFF" and wav[8:12] == b"WAVE"
        assert len(wav) == 44 + 20


def httpx_error():
    import httpx
    return httpx.ConnectError("deepgram unreachable")
