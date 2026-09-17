"""
BROKA - Speech-to-Text Router

Multilingual Whisper-based STT for: English, Swahili, Sheng, Luo, Kikuyu, Luganda.
Backed by OpenAI's hosted Whisper API (whisper-1) for production reliability.

ENV VAR:
    OPENAI_API_KEY    - required for transcription

If the key is missing, the endpoint returns 503 with a clear message so the
Flutter app can fall back to text input gracefully.
"""

import os
import logging
import httpx
from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form

from api.security import get_current_user

logger = logging.getLogger(__name__)
router = APIRouter()

OPENAI_KEY = os.getenv("OPENAI_API_KEY", "")
OPENAI_URL = "https://api.openai.com/v1/audio/transcriptions"

# Whisper ISO-639-1 hints for the languages BROKA supports
WHISPER_LANG_HINTS = {
    "english": "en",
    "swahili": "sw",
    "sheng":   "sw",   # closest match
    "luo":     None,   # let Whisper auto-detect
    "kikuyu":  None,
    "luganda": None,
}

MAX_BYTES = 25 * 1024 * 1024   # OpenAI hard limit


@router.post("/transcribe")
async def transcribe(
    file: UploadFile = File(...),
    language: str = Form("english"),
    _user: dict = Depends(get_current_user),
):
    """Accepts an audio file (mp3/m4a/wav/ogg/webm) and returns transcript text."""
    if not OPENAI_KEY:
        raise HTTPException(
            status_code=503,
            detail="Speech-to-text is not configured. Set OPENAI_API_KEY on the server.",
        )

    audio_bytes = await file.read()
    if not audio_bytes:
        raise HTTPException(status_code=400, detail="Empty audio file")
    if len(audio_bytes) > MAX_BYTES:
        raise HTTPException(status_code=413, detail="Audio file too large (max 25 MB)")

    lang_hint = WHISPER_LANG_HINTS.get(language.lower())

    files = {"file": (file.filename or "audio.m4a", audio_bytes, file.content_type or "audio/m4a")}
    data = {"model": "whisper-1", "response_format": "json"}
    if lang_hint:
        data["language"] = lang_hint

    try:
        async with httpx.AsyncClient(timeout=60) as client:
            resp = await client.post(
                OPENAI_URL,
                headers={"Authorization": f"Bearer {OPENAI_KEY}"},
                files=files,
                data=data,
            )
    except httpx.HTTPError as exc:
        logger.exception("Whisper request failed: %s", exc)
        raise HTTPException(status_code=502, detail="Transcription service unreachable")

    if resp.status_code != 200:
        logger.warning("Whisper %s: %s", resp.status_code, resp.text[:300])
        raise HTTPException(status_code=502, detail="Transcription failed")

    body = resp.json()
    return {
        "text": body.get("text", "").strip(),
        "language": language,
    }
