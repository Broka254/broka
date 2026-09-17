"""
BROKA - fal.ai Client (AI Showcase/Cover Image generation)
─────────────────────────────────────────────────────────────────────────────
Raw REST wrapper around fal.ai's queue API - no fal-client SDK dependency,
matching how api/core/sms.py talks to Mobitech/Africa's Talking directly
over httpx rather than pulling in a vendor package.

fal.ai's actual contract (queue.fal.run), confirmed against fal's own docs:
  1. POST  https://queue.fal.run/{model}          body = flat model input
       -> {request_id, status_url, response_url, ...}
  2. GET   {status_url}                           until status == COMPLETED
  3. GET   {response_url}                         -> {"images": [{"url": ...}]}

Auth: "Authorization: Key $FAL_KEY" (fal's own header scheme - NOT "Bearer").

image_url accepts a data: URI directly (fal's docs list "Data URI (base64)"
as a first-class input alongside hosted files), which is exactly what this
codebase already has on hand - verified_photos is stored as raw base64 in
the DB (see api/routers/media.py's docstring: no external object storage
anywhere in BROKA), so the seller's actual product photo can be sent as
image_url without uploading it anywhere first.

Model: fal-ai/flux-pro/kontext (settings.fal_showcase_model). Chosen
because its whole design goal is "change X, keep everything else the
same" - the closest fit to the product-preservation requirement of any
model on fal.ai, and it's Black Forest Labs' own model (not a fal-hosted
proxy to Gemini/OpenAI/Stability, which the showcase spec explicitly
rules out).
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Optional

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_QUEUE_BASE = "https://queue.fal.run"
_POLL_INTERVAL_SECONDS = 2.0
_POLL_TIMEOUT_SECONDS = 90.0
_HTTP_TIMEOUT_SECONDS = 30.0  # per individual request, not the whole poll loop

_breaker = CircuitBreaker("fal_ai_showcase", failure_threshold=5, recovery_timeout=30)


class FalGenerationError(Exception):
    """Raised for any fal.ai failure the caller should show the user
    (not configured, rejected input, generation error, timeout). Distinct
    from letting httpx/CircuitOpenError leak out, so showcase/service.py
    has one exception type to translate into a clean user-facing message."""


def _headers() -> dict:
    return {
        "Authorization": f"Key {settings.fal_key}",
        "Content-Type": "application/json",
    }


async def _run_once(prompt: str, image_data_uri: str) -> str:
    """Submits one generation request and polls it to completion. Returns
    the generated image's fal.ai-hosted URL - temporary, per fal.ai's own
    docs, so the caller must download and persist it (see
    domains/showcase/service.py) rather than storing this URL directly."""
    model = settings.fal_showcase_model
    payload = {"prompt": prompt, "image_url": image_data_uri}

    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_SECONDS) as client:
        submit = await client.post(f"{_QUEUE_BASE}/{model}", headers=_headers(), json=payload)
        submit.raise_for_status()
        submitted = submit.json()

        request_id = submitted.get("request_id")
        if not request_id:
            raise FalGenerationError(f"fal.ai did not return a request_id: {submitted!r}")
        status_url = submitted.get("status_url") or f"{_QUEUE_BASE}/{model}/requests/{request_id}/status"
        response_url = submitted.get("response_url") or f"{_QUEUE_BASE}/{model}/requests/{request_id}"

        deadline = time.monotonic() + _POLL_TIMEOUT_SECONDS
        while True:
            status_resp = await client.get(status_url, headers=_headers())
            status_resp.raise_for_status()
            status = str(status_resp.json().get("status", "")).upper()

            if status == "COMPLETED":
                break
            if status in ("ERROR", "FAILED"):
                raise FalGenerationError(f"fal.ai generation failed (status={status})")
            if time.monotonic() > deadline:
                raise FalGenerationError("fal.ai generation timed out")
            await asyncio.sleep(_POLL_INTERVAL_SECONDS)

        result = await client.get(response_url, headers=_headers())
        result.raise_for_status()
        body = result.json()

    images = body.get("images") or []
    url = images[0].get("url") if images else None
    if not url:
        raise FalGenerationError(f"fal.ai returned no image: {body!r}")
    return url


async def generate_showcase_image_url(prompt: str, image_data_uri: str) -> str:
    """Returns fal.ai's (temporary) URL for the generated image.
    Fails as FalGenerationError - never raises httpx/circuit-breaker
    internals past this point, so callers only need to handle one type."""
    if not settings.fal_key:
        raise FalGenerationError(
            "AI showcase generation is not configured (FAL_KEY unset) - "
            "you can still upload a cover from your gallery."
        )
    try:
        return await _breaker.call(_run_once, prompt, image_data_uri)
    except CircuitOpenError:
        raise FalGenerationError(
            "AI showcase generation is temporarily unavailable - please try again shortly."
        )
    except httpx.HTTPError as e:
        logger.error("[fal:showcase] generation request failed err=%s", e)
        raise FalGenerationError("AI showcase generation failed - please try again.")


async def download_generated_image(url: str) -> tuple[bytes, str]:
    """Downloads the (temporary) fal.ai image so it can be persisted into
    BROKA's own storage. Returns (bytes, mime_type)."""
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_SECONDS) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            mime = resp.headers.get("content-type", "image/jpeg").split(";")[0].strip()
            return resp.content, (mime or "image/jpeg")
    except httpx.HTTPError as e:
        logger.error("[fal:showcase] downloading generated image failed err=%s", e)
        raise FalGenerationError("Couldn't retrieve the generated image - please try again.")
