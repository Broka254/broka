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

from api.core.rate_limit import stt_token_limiter, stt_transcribe_limiter
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
    await stt_transcribe_limiter.check_and_record(_user["id"])
    if not OPENAI_KEY:
        raise HTTPException(
            status_code=503,
            detail="Speech-to-text is not configured. Set OPENAI_API_KEY on the server.",
        )

    # Bounded read: one byte past the limit is enough to know it is too big,
    # without pulling an arbitrarily large upload into memory first.
    audio_bytes = await file.read(MAX_BYTES + 1)
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


# ── Deepgram streaming: short-lived client token ──────────────────────────────
#
# The Zeno voice card streams microphone audio straight from the phone to
# Deepgram's WebSocket, which means the phone needs a credential. It must not
# be the project's permanent Deepgram API key: anything shipped inside a
# Flutter binary is readable by anyone who downloads the app, and a leaked
# permanent key is billable until it is manually revoked.
#
# So the permanent key stays here, and the app asks this endpoint for a
# temporary token each time it opens a voice session. Deepgram's
# POST /v1/auth/grant mints a short-lived JWT from the permanent key; the JWT
# only has to be valid for the initial WebSocket handshake, since an
# established connection stays open after the token expires.
#
# Deployed alongside the Whisper /stt/transcribe endpoint above rather than in
# a new voice router: this is the same concern (speech to text) and the same
# auth dependency, and a second router for one endpoint would be architecture
# for its own sake.

DEEPGRAM_GRANT_URL = "https://api.deepgram.com/v1/auth/grant"


def _deepgram_key() -> str:
    """Read at call time, not import time.

    OPENAI_KEY above is a module-level constant and is the reason its
    not-configured branch cannot be exercised without reimporting the module.
    This one is a function so a test - and a deployment that sets the variable
    after the process starts - both see the current value.
    """
    return os.getenv("DEEPGRAM_API_KEY", "")

# Long enough to survive a slow handshake on a weak Kenyan mobile connection,
# short enough that a token captured in transit is worth little. Deepgram
# defaults to 30s and caps at 3600s; nothing here needs the cap, because the
# token is spent the moment the socket opens.
DEEPGRAM_TOKEN_TTL_SECONDS = 300


@router.post("/deepgram-token")
async def deepgram_token(_user: dict = Depends(get_current_user)):
    """Mint a short-lived Deepgram token for this authenticated BROKA user.

    Returns only the temporary token. The permanent key never leaves the
    server, is never logged, and is never part of any response body - the
    error paths below deliberately return fixed strings rather than echoing
    anything Deepgram sent back, since an upstream error body can quote the
    credential that was rejected.
    """
    await stt_token_limiter.check_and_record(_user["id"])
    api_key = _deepgram_key()
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="Voice transcription is not configured on this server.",
        )

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                DEEPGRAM_GRANT_URL,
                headers={
                    # Deepgram expects the PERMANENT key under the "Token"
                    # scheme here. The temporary JWT this returns is used by
                    # the client under "Bearer" instead - they are not
                    # interchangeable.
                    "Authorization": f"Token {api_key}",
                    "Content-Type": "application/json",
                },
                json={"ttl_seconds": DEEPGRAM_TOKEN_TTL_SECONDS},
            )
    except httpx.HTTPError as exc:
        # exc carries the request URL but not the header, so this is safe.
        logger.exception("Deepgram token request failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Voice service unreachable")

    if resp.status_code != 200:
        # Status code only. resp.text can contain the rejected credential.
        logger.warning("Deepgram token grant returned %s", resp.status_code)
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    try:
        body = resp.json()
    except ValueError:
        logger.warning("Deepgram token grant returned a non-JSON body")
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    token = body.get("access_token")
    if not token:
        logger.warning("Deepgram token grant returned no access_token")
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    return {
        "access_token": token,
        # Deepgram echoes the granted TTL; fall back to what we asked for.
        "expires_in": body.get("expires_in", DEEPGRAM_TOKEN_TTL_SECONDS),
    }


# ── AssemblyAI (fallback realtime STT) ───────────────────────────────────────
#
# Same shape as the Deepgram endpoint above and for the same reason: the
# permanent key stays on Render, the app gets something short-lived that is
# spent on one WebSocket handshake. The differences are AssemblyAI's, not
# ours - its token endpoint is a GET, its Authorization header takes the raw
# key with NO "Bearer" or "Token" prefix, and the TTL goes in the query string
# and is capped at 600 seconds.

ASSEMBLYAI_TOKEN_URL = "https://streaming.assemblyai.com/v3/token"


def _assemblyai_key() -> str:
    """Read at call time. See _deepgram_key."""
    return os.getenv("ASSEMBLYAI_API_KEY", "")


# 300s, matching Deepgram's. Well inside AssemblyAI's documented 1..600 range,
# and the token is spent the moment the socket opens.
ASSEMBLYAI_TOKEN_TTL_SECONDS = 300


@router.post("/assemblyai-token")
async def assemblyai_token(_user: dict = Depends(get_current_user)):
    """Mint a short-lived AssemblyAI streaming token for this BROKA user.

    Returns only the temporary token. As with Deepgram: the permanent key
    never leaves the server, is never logged, and is never echoed into a
    response - the error paths return fixed strings rather than anything
    upstream sent back, because an upstream error body can quote the
    credential that was rejected.
    """
    await stt_token_limiter.check_and_record(_user["id"])
    api_key = _assemblyai_key()
    if not api_key:
        raise HTTPException(
            status_code=503,
            detail="Voice transcription is not configured on this server.",
        )

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(
                ASSEMBLYAI_TOKEN_URL,
                # The raw key, no scheme prefix. AssemblyAI rejects
                # "Bearer <key>" here, which is an easy thing to copy in from
                # another vendor's example and a hard one to debug.
                headers={"Authorization": api_key},
                params={"expires_in_seconds": ASSEMBLYAI_TOKEN_TTL_SECONDS},
            )
    except httpx.HTTPError as exc:
        logger.exception("AssemblyAI token request failed: %s", type(exc).__name__)
        raise HTTPException(status_code=502, detail="Voice service unreachable")

    if resp.status_code != 200:
        # Status code only. resp.text can contain the rejected credential.
        logger.warning("AssemblyAI token request returned %s", resp.status_code)
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    try:
        body = resp.json()
    except ValueError:
        logger.warning("AssemblyAI token request returned a non-JSON body")
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    token = body.get("token")
    if not token:
        logger.warning("AssemblyAI token request returned no token")
        raise HTTPException(status_code=502, detail="Could not start a voice session")

    return {
        "token": token,
        "expires_in_seconds": body.get(
            "expires_in_seconds", ASSEMBLYAI_TOKEN_TTL_SECONDS
        ),
    }
