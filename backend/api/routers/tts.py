"""
BROKA - TTS Router (Hybrid)
  English  → Microsoft Edge TTS (en-US-AvaMultilingualNeural, falling back
             to en-US-AriaNeural) - English text only
  Swahili  → Microsoft Edge TTS (sw-KE-ZuriNeural)
  Sheng    → Kokoro on Hugging Face Space (Xxavierxxbo/broka-tts)
  Luo      → Kokoro on Hugging Face Space
  Kikuyu   → Kokoro on Hugging Face Space
  Luganda  → Kokoro on Hugging Face Space

The English voice never reads another language (2026-09-26). It used to be
the default for anything without a voice of its own, and it read whatever
text it was given: a user on the English setting who chatted in Swahili got
Zeno's Swahili reply in an American accent. Now:
  * a language with no voice here is a 422 - the app shows the text and
    stays silent rather than mispronounce it;
  * text sent as "english" that reads as Swahili (or Swahili-based Sheng)
    is spoken by the Swahili voice (_reads_as_swahili).

English is tried in this order (2026-10-12):
  AssemblyAI (its Voice Agent's voice) -> Edge TTS -> Deepgram Aura -> 503
AssemblyAI leads because it is the voice that answers in production: Edge
(a free, unofficial endpoint) and Deepgram were failing, and with AssemblyAI
last every spoken reply waited out both of them first - the voice came
seconds after the text. AssemblyAI and Deepgram are English voices, so they
speak English only: Swahili with no Edge voice is silence, never Swahili in
an American accent (the rule above). Each is skipped when its key
(ASSEMBLYAI_API_KEY, DEEPGRAM_API_KEY - the ones speech-to-text already
uses) is unset. When every voice fails the answer is a 503 the app treats
as "voice down": the reply stays on screen.
"""

import asyncio
import base64
import io
import json
import logging
import os
import re
import struct
import httpx
import edge_tts
import websockets
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

MAX_CHARS = 500

# Edge TTS voices (free, no key needed). English is Ava (2026-10-11), one of
# Microsoft's newer conversational voices: Aria read Zeno's replies like an
# announcement. Aria stays as the fallback if Ava ever stops answering.
EDGE_VOICES = {
    "english": "en-US-AvaMultilingualNeural",
    "swahili": "sw-KE-ZuriNeural",
}
EDGE_FALLBACK_VOICES = {
    "english": "en-US-AriaNeural",
}

# The paid English voices: AssemblyAI ahead of Edge, Deepgram after it
# (see the module docstring).
DEEPGRAM_SPEAK_URL = "https://api.deepgram.com/v1/speak"
DEEPGRAM_TTS_MODEL = "aura-2-thalia-en"
ASSEMBLYAI_AGENT_URL = "wss://agents.assemblyai.com/v1/ws"
# "ivy" was one of the Voice Agent's early names. AssemblyAI has since removed
# those ("Don't use legacy names - they've been removed"; its voice catalogue
# now lists alba, eve, george, jane, jean, mary, michael, anna, charles, paul,
# vera and a few native-accent voices), so an unknown name was refused with a
# session.error that this code did not read - see _assemblyai_audio.
#
# "jane" (2026-10-25): the owner asked for Jane (US), an American woman's
# voice, replacing "eve" (older, flatter than the ask) and "anna" (British,
# picked earlier the same day). AssemblyAI publishes accent, not gender or
# personality, so ASSEMBLYAI_VOICE still picks another from the catalogue
# without a code change (alba, eve, jean, mary and vera are the other
# women's names).
ASSEMBLYAI_VOICE = "jane"
# The Voice Agent sends its speech as raw 16-bit mono PCM; wrapped in a WAV
# header here so the app plays it like any other reply.
ASSEMBLYAI_SAMPLE_RATE = 24000
# A fallback that hangs is worse than silence: the app is waiting to speak.
FALLBACK_TIMEOUT_SECONDS = 15

# Languages routed to HF Space Kokoro
KOKORO_LANGUAGES = {"sheng", "luo", "kikuyu", "luganda"}

# Everyday Swahili (and Swahili-based Sheng) words that English text almost
# never contains. Function words carry most of the signal: "na", "ya", "ni"
# and "kwa" turn up in nearly every Swahili sentence.
_SWAHILI_MARKERS = frozenset("""
    na ya wa za la kwa ni si ndio ndiyo hapana sawa asante tafadhali karibu
    habari mambo poa niaje vipi sasa hii hiyo hizi hizo huu hicho kile hapa
    pale kuna hakuna gani nini nani lini wapi je kama lakini pia tu bado
    kabisa sana zaidi kidogo mimi wewe yeye sisi nyinyi wao yangu yako yake
    yetu yenu yao kwenye kutoka mpaka ili bei pesa shilingi elfu laki milioni
    rahisi ghali nzuri mzuri safi nataka unataka anataka tunataka naweza
    unaweza nina una ana tuna mna wana niko uko yuko tuko nimeona umeona
    kununua kuuza nunua uza simu gari nyumba shamba kiwanja leo kesho jana
    wiki mwezi mwaka rafiki ndugu biashara muuzaji mnunuzi soko manze msee
    fiti rada sema ganji
""".split())

_WORD = re.compile(r"[a-zA-Z']+")


def _reads_as_swahili(text: str) -> bool:
    """True when [text] is mostly Swahili (or Sheng) rather than English.

    Zeno answers in the language it is written to, not only the one in the
    user's settings, so text sent as "english" can be Swahili. A greeting
    borrowed into English ("Karibu! Here are three phones") stays English:
    it takes at least two marker words, and a fifth of all the words.
    """
    words = [w.lower() for w in _WORD.findall(text)]
    if not words:
        return False
    hits = sum(1 for w in words if w in _SWAHILI_MARKERS)
    return hits >= 2 and hits / len(words) >= 0.2


def voice_language(text: str, requested: str) -> str | None:
    """The language to speak [text] in, or None when no voice here can."""
    if requested in KOKORO_LANGUAGES:
        return requested
    if requested == "english" and _reads_as_swahili(text):
        return "swahili"
    if requested in EDGE_VOICES:
        return requested
    return None

# Hugging Face Space API endpoint
HF_SPACE_URL = "https://xxavierxxbo-broka-tts.hf.space/run/predict"


class TtsRequest(BaseModel):
    text:     str
    language: str = "english"


@router.post("/speak", response_class=Response)
async def speak(
    body: TtsRequest,
    _user: dict = Depends(get_current_user),
):
    text = body.text.strip()[:MAX_CHARS]
    lang = body.language.lower()

    if not text:
        raise HTTPException(status_code=400, detail="Empty text")

    spoken = voice_language(text, lang)
    if spoken is None:
        # Silence beats an English voice mispronouncing another language.
        raise HTTPException(status_code=422, detail="no_voice_for_language")
    if spoken in KOKORO_LANGUAGES:
        return await _speak_kokoro(text, spoken)
    return await _speak_edge(text, spoken)


async def _edge_audio(text: str, voice: str) -> bytes:
    communicate = edge_tts.Communicate(text, voice)
    audio_buffer = io.BytesIO()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            audio_buffer.write(chunk["data"])
    return audio_buffer.getvalue()


async def _paid_voice(name: str, provider, text: str) -> Response | None:
    try:
        spoken = await asyncio.wait_for(provider(text), FALLBACK_TIMEOUT_SECONDS)
    except Exception as e:
        logger.warning("TTS %s failed: %s", name, e)
        return None
    if spoken is None:
        return None
    logger.info("TTS %s spoke", name)
    return Response(content=spoken[0], media_type=spoken[1])


async def _speak_edge(text: str, language: str) -> Response:
    """English: AssemblyAI first, then Microsoft Edge, then Deepgram (see the
    module docstring). Swahili: Edge's Swahili voice only."""
    if language == "english":
        spoken = await _paid_voice("assemblyai", _assemblyai_audio, text)
        if spoken is not None:
            return spoken
    voices = [EDGE_VOICES[language]]
    if language in EDGE_FALLBACK_VOICES:
        voices.append(EDGE_FALLBACK_VOICES[language])
    for voice in voices:
        logger.info("Edge TTS - voice=%s lang=%s", voice, language)
        try:
            audio_bytes = await _edge_audio(text, voice)
        except Exception as e:
            logger.exception("Edge TTS error (voice=%s): %s", voice, e)
            continue
        if audio_bytes:
            return Response(content=audio_bytes, media_type="audio/mpeg")
        logger.warning("Edge TTS returned no audio (voice=%s)", voice)
    if language == "english":
        spoken = await _paid_voice("deepgram", _deepgram_audio, text)
        if spoken is not None:
            return spoken
    # Graceful: the app shows the reply and stays silent (broka_tts.dart).
    raise HTTPException(status_code=503, detail="voice_unavailable")


async def _deepgram_audio(text: str) -> tuple[bytes, str] | None:
    """Deepgram Aura - None when no key is set or no audio came back."""
    key = os.getenv("DEEPGRAM_API_KEY", "")
    if not key:
        return None
    async with httpx.AsyncClient(timeout=FALLBACK_TIMEOUT_SECONDS) as client:
        resp = await client.post(
            DEEPGRAM_SPEAK_URL,
            params={"model": DEEPGRAM_TTS_MODEL, "encoding": "mp3"},
            headers={"Authorization": f"Token {key}"},
            json={"text": text},
        )
    if resp.status_code != 200 or not resp.content:
        logger.warning("Deepgram TTS %s: %s", resp.status_code, resp.text[:200])
        return None
    return resp.content, "audio/mpeg"


async def _assemblyai_audio(text: str) -> tuple[bytes, str] | None:
    """AssemblyAI has no plain text-to-speech endpoint; its Voice Agent
    speaks a session's greeting word for word, so the reply is sent as the
    greeting and the audio collected until the agent's reply is done.
    None when no key is set or no audio came back."""
    key = os.getenv("ASSEMBLYAI_API_KEY", "")
    if not key:
        return None
    voice = os.getenv("ASSEMBLYAI_VOICE", "").strip() or ASSEMBLYAI_VOICE
    pcm = bytearray()
    async with websockets.connect(
        ASSEMBLYAI_AGENT_URL, additional_headers={"Authorization": f"Bearer {key}"},
    ) as ws:
        await ws.send(json.dumps({"type": "session.update", "session": {
            "system_prompt": "Say the greeting exactly as written, then nothing else.",
            "greeting": text,
            "output": {"voice": voice},
        }}))
        async for raw in ws:
            if isinstance(raw, bytes):
                continue
            event = json.loads(raw)
            kind = event.get("type")
            if kind == "reply.audio":
                pcm.extend(base64.b64decode(event.get("data") or ""))
            elif kind == "reply.done":
                break
            elif kind == "session.error" or kind == "error":
                # AssemblyAI reports a refusal (an unknown voice, a bad key,
                # a field changed after the first update) as session.error
                # and then sends nothing more - no reply.done. This loop used
                # to wait for "error" only, so every refusal sat here until
                # FALLBACK_TIMEOUT_SECONDS cut it off: each English reply
                # reached Edge's voice 15 seconds late, long after its text.
                # Stepping aside at once puts Edge's voice a moment behind.
                logger.warning("AssemblyAI TTS refused (voice=%s): %s", voice, str(event)[:200])
                break
    if not pcm:
        return None
    return _wav(bytes(pcm), ASSEMBLYAI_SAMPLE_RATE), "audio/wav"


def _wav(pcm: bytes, sample_rate: int) -> bytes:
    """16-bit mono PCM with the 44-byte RIFF header a player needs."""
    return b"".join((
        b"RIFF", struct.pack("<I", 36 + len(pcm)), b"WAVE",
        b"fmt ", struct.pack("<IHHIIHH", 16, 1, 1, sample_rate, sample_rate * 2, 2, 16),
        b"data", struct.pack("<I", len(pcm)), pcm,
    ))


async def _speak_kokoro(text: str, language: str) -> Response:
    """Kokoro TTS on Hugging Face Space for Sheng/Luo/Kikuyu/Luganda."""
    logger.info("Kokoro TTS - lang=%s", language)
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                HF_SPACE_URL,
                json={"data": [text, language]},
                headers={"Content-Type": "application/json"},
            )

        if resp.status_code != 200:
            logger.error("Kokoro HF error %s: %s", resp.status_code, resp.text[:200])
            raise HTTPException(status_code=502, detail="Kokoro voice service error")

        result = resp.json()
        # Gradio returns audio as base64 or a URL
        audio_data = result.get("data", [None])[0]

        if audio_data is None:
            raise HTTPException(status_code=502, detail="No audio returned from Kokoro")

        # If it's a dict with 'url' key (Gradio file response)
        if isinstance(audio_data, dict) and "url" in audio_data:
            audio_url = audio_data["url"]
            if not audio_url.startswith("http"):
                audio_url = f"https://xxavierxxbo-broka-tts.hf.space{audio_url}"
            async with httpx.AsyncClient(timeout=30) as client:
                audio_resp = await client.get(audio_url)
            return Response(content=audio_resp.content, media_type="audio/wav")

        # If it's base64 string
        if isinstance(audio_data, str) and audio_data.startswith("data:audio"):
            import base64
            _, b64 = audio_data.split(",", 1)
            audio_bytes = base64.b64decode(b64)
            return Response(content=audio_bytes, media_type="audio/wav")

        raise HTTPException(status_code=502, detail="Unexpected audio format from Kokoro")

    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Kokoro TTS error: %s", e)
        raise HTTPException(status_code=500, detail="Kokoro voice service unavailable")


@router.get("/voices")
async def list_voices(_user: dict = Depends(get_current_user)):
    return {
        "edge_tts":  list(EDGE_VOICES.keys()),
        "kokoro":    list(KOKORO_LANGUAGES),
    }
