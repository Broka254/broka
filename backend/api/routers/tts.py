"""
BROKA - TTS Router (Hybrid)
  English  → Microsoft Edge TTS (en-US-AriaNeural)
  Swahili  → Microsoft Edge TTS (sw-KE-ZuriNeural)
  Sheng    → Kokoro on Hugging Face Space (Xxavierxxbo/broka-tts)
  Luo      → Kokoro on Hugging Face Space
  Kikuyu   → Kokoro on Hugging Face Space
  Luganda  → Kokoro on Hugging Face Space

No API keys needed - both services are free.
"""

import io
import logging
import httpx
import edge_tts
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

MAX_CHARS = 500

# Edge TTS voices (free, no key needed)
EDGE_VOICES = {
    "english": "en-US-AriaNeural",
    "swahili": "sw-KE-ZuriNeural",
}

# Languages routed to HF Space Kokoro
KOKORO_LANGUAGES = {"sheng", "luo", "kikuyu", "luganda"}

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

    if lang in KOKORO_LANGUAGES:
        return await _speak_kokoro(text, lang)
    else:
        return await _speak_edge(text, lang)


async def _speak_edge(text: str, language: str) -> Response:
    """Microsoft Edge TTS for English and Swahili."""
    voice = EDGE_VOICES.get(language, EDGE_VOICES["english"])
    logger.info("Edge TTS - voice=%s lang=%s", voice, language)
    try:
        communicate = edge_tts.Communicate(text, voice)
        audio_buffer = io.BytesIO()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio_buffer.write(chunk["data"])
        audio_buffer.seek(0)
        audio_bytes = audio_buffer.read()
        if not audio_bytes:
            raise HTTPException(status_code=502, detail="Edge TTS returned no audio")
        return Response(content=audio_bytes, media_type="audio/mpeg")
    except HTTPException:
        raise
    except Exception as e:
        logger.exception("Edge TTS error: %s", e)
        raise HTTPException(status_code=500, detail="Voice service unavailable")


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
