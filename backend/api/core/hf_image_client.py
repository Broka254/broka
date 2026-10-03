"""
BROKA - Hugging Face image client (AI Showcase/Cover Image generation)
─────────────────────────────────────────────────────────────────────────────
Raw REST wrapper around Hugging Face Inference Providers - no
huggingface_hub dependency. Its async client polls the provider with
time.sleep() and no deadline, which would stall the whole event loop (every
request on this worker) for as long as one generation takes.

HF doesn't run the model itself: its router forwards the call to a partner
provider and bills it to the HF account behind HF_TOKEN, so BROKA only ever
has an account (and a bill) with Hugging Face. The provider is fal-ai -
HF's main partner for image-to-image - and its queue contract, through HF's
router, is:
  0. GET   huggingface.co/api/models/{model}?expand[]=inferenceProviderMapping
       -> the provider's own id for the model (cached per process)
  1. POST  router.huggingface.co/fal-ai/{provider_model}?_subdomain=queue
       body = flat model input -> {request_id, response_url, ...}
  2. GET   router.huggingface.co/fal-ai{response_url path}/status?_subdomain=queue
       until status == COMPLETED
  3. GET   router.huggingface.co/fal-ai{response_url path}?_subdomain=queue
       -> {"images": [{"url": ...}]}
This is the same routing huggingface_hub's own fal-ai helper does.

Auth: "Authorization: Bearer $HF_TOKEN" (a fine-grained token with "Make
calls to Inference Providers").

image_url takes a data: URI, so the seller's photo is sent inline without
uploading it anywhere first.

Model: Qwen/Qwen-Image-Edit-2511 (settings.hf_showcase_model). An
instruction editor ("put this on a white backdrop, keep the product") under
Apache-2.0, so covers BROKA charges for are allowed - FLUX.1 Kontext [dev],
the closest open model to the [pro] this used before, is non-commercial.
"""
from __future__ import annotations

import asyncio
import logging
import time
from urllib.parse import urlparse

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_HUB_MODELS_API = "https://huggingface.co/api/models"
_ROUTER_BASE = "https://router.huggingface.co/fal-ai"
_PROVIDER = "fal-ai"
_TASK = "image-to-image"
_QUEUE_QUERY = {"_subdomain": "queue"}
_POLL_INTERVAL_SECONDS = 2.0
_POLL_TIMEOUT_SECONDS = 90.0
_HTTP_TIMEOUT_SECONDS = 30.0  # per individual request, not the whole poll loop
# A generated cover is a ~1 MP JPEG, a few hundred KB. Anything far past
# that is not what we asked for, and it would be held in memory whole.
_MAX_IMAGE_BYTES = 15 * 1024 * 1024

# The listing card shows its cover at 4:3 (product_grid_view.dart's
# _cardImageShare), so the cover is generated at 4:3: generated at the
# photo's own shape, a portrait phone photo lost its top and bottom on
# every card. Qwen's endpoint names the shape image_size, Kontext's
# aspect_ratio; both are sent so switching HF_SHOWCASE_MODEL keeps it.
DEFAULT_ASPECT_RATIO = "4:3"
_IMAGE_SIZES = {"4:3": "landscape_4_3"}

# 401/403 is our token, 402 our credit and 429 our quota - those are ours,
# and should trip the breaker; any other 4xx is this input.
_OUR_FAULT = (401, 402, 403, 429)

_breaker = CircuitBreaker("hf_showcase", failure_threshold=5, recovery_timeout=30)

# (model, provider) -> the provider's id for it. The mapping changes only
# when HF re-maps the model, so one lookup per process is enough.
_provider_models: dict[tuple[str, str], str] = {}


class ImageGenerationError(Exception):
    """Raised for any generation failure the caller should show the user
    (not configured, rejected input, generation error, timeout). Distinct
    from letting httpx/CircuitOpenError leak out, so showcase/service.py
    has one exception type to translate into a clean user-facing message.

    `code` says which, for the HTTP layer: "unavailable" (not configured,
    or the service is down - try later or use a gallery photo), "rejected"
    (the model refused this photo or prompt - try another), "failed"
    (anything else - try again)."""

    def __init__(self, message: str, code: str = "failed"):
        super().__init__(message)
        self.code = code


class _Rejected(Exception):
    """The provider refused the input itself (a 4xx on submit: the photo
    failed its safety check, or isn't an image it can use). The seller's
    problem, not the service's - so it must not count toward opening the
    circuit breaker, which would switch generation off for every seller for
    a bad photo from one."""


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {settings.hf_token}",
        "Content-Type": "application/json",
    }


def _is_transient(exc: Exception) -> bool:
    if isinstance(exc, httpx.TransportError):
        return True
    return isinstance(exc, httpx.HTTPStatusError) and exc.response.status_code >= 500


async def _provider_model(client: httpx.AsyncClient) -> str:
    """The provider's own id for settings.hf_showcase_model, from the Hub's
    inferenceProviderMapping (a dict keyed by provider, or a list - the Hub
    has returned both)."""
    model = settings.hf_showcase_model
    key = (model, _PROVIDER)
    if key in _provider_models:
        return _provider_models[key]
    resp = await client.get(
        f"{_HUB_MODELS_API}/{model}",
        params={"expand[]": "inferenceProviderMapping"},
        headers=_headers(),
    )
    resp.raise_for_status()
    mapping = resp.json().get("inferenceProviderMapping") or {}
    entries = (
        mapping.items() if isinstance(mapping, dict)
        else ((e.get("provider"), e) for e in mapping if isinstance(e, dict))
    )
    for provider, entry in entries:
        if provider == _PROVIDER and entry.get("task") == _TASK and entry.get("providerId"):
            _provider_models[key] = entry["providerId"]
            return entry["providerId"]
    # A configuration problem, not this photo: "unavailable", and it counts
    # toward the breaker like any other failure of ours.
    raise ImageGenerationError(
        f"{model} is not served for {_TASK} by {_PROVIDER} on Hugging Face",
        code="unavailable",
    )


async def _run_once(prompt: str, image_data_uri: str, aspect_ratio: str = DEFAULT_ASPECT_RATIO) -> str:
    """Submits one generation request and polls it to completion. Returns
    the generated image's provider-hosted URL - temporary, so the caller
    must download and persist it (see domains/showcase/service.py) rather
    than storing this URL directly."""
    payload = {
        "prompt": prompt,
        "image_url": image_data_uri,
        "image_urls": [image_data_uri],
        "num_images": 1,
        # JPEG, not PNG: the same picture at a fraction of the bytes, which
        # the seller then downloads over mobile data.
        "output_format": "jpeg",
        "aspect_ratio": aspect_ratio,
    }
    if aspect_ratio in _IMAGE_SIZES:
        payload["image_size"] = _IMAGE_SIZES[aspect_ratio]

    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_SECONDS) as client:
        provider_model = await _provider_model(client)
        submit = await client.post(
            f"{_ROUTER_BASE}/{provider_model}", params=_QUEUE_QUERY,
            headers=_headers(), json=payload,
        )
        if 400 <= submit.status_code < 500 and submit.status_code not in _OUR_FAULT:
            raise _Rejected(f"the model refused the input (HTTP {submit.status_code})")
        submit.raise_for_status()
        submitted = submit.json()

        request_id = submitted.get("request_id")
        if not request_id:
            raise ImageGenerationError(f"no request_id in the reply: {submitted!r}")
        # The response_url's path, not provider_model: for a model id with a
        # sub-path the queue files requests under the parent app.
        request_path = (
            urlparse(submitted.get("response_url") or "").path
            or f"/{provider_model}/requests/{request_id}"
        )
        status_url = f"{_ROUTER_BASE}{request_path}/status"
        response_url = f"{_ROUTER_BASE}{request_path}"

        deadline = time.monotonic() + _POLL_TIMEOUT_SECONDS
        while True:
            # A dropped connection or a 5xx from the status endpoint used to
            # abandon a generation the provider was still running - and
            # billing for. Poll again until the deadline instead.
            try:
                status_resp = await client.get(status_url, params=_QUEUE_QUERY, headers=_headers())
                status_resp.raise_for_status()
                status = str(status_resp.json().get("status", "")).upper()
            except (httpx.HTTPError, ValueError) as exc:
                if isinstance(exc, httpx.HTTPError) and not _is_transient(exc):
                    raise
                logger.warning("[hf:showcase] status poll failed, retrying: %s", exc)
                status = ""

            if status == "COMPLETED":
                break
            if status in ("ERROR", "FAILED"):
                raise ImageGenerationError(f"generation failed (status={status})")
            if time.monotonic() > deadline:
                raise ImageGenerationError("generation timed out")
            await asyncio.sleep(_POLL_INTERVAL_SECONDS)

        result = await client.get(response_url, params=_QUEUE_QUERY, headers=_headers())
        if 400 <= result.status_code < 500 and result.status_code not in _OUR_FAULT:
            # Finished, but the result was withheld - the output safety
            # check. Same as a refused input: nothing wrong with the service.
            raise _Rejected(f"the result was withheld (HTTP {result.status_code})")
        result.raise_for_status()
        body = result.json()

    images = body.get("images") or []
    url = images[0].get("url") if images else None
    if not url:
        raise ImageGenerationError(f"no image in the reply: {body!r}")
    return url


async def _run_guarded(prompt: str, image_data_uri: str, aspect_ratio: str):
    """_run_once, with a rejected input returned instead of raised, so the
    breaker (which counts every exception) only counts service failures."""
    try:
        return await _run_once(prompt, image_data_uri, aspect_ratio)
    except _Rejected as exc:
        return exc


async def generate_showcase_image_url(
    prompt: str, image_data_uri: str, aspect_ratio: str = DEFAULT_ASPECT_RATIO,
) -> str:
    """Returns the provider's (temporary) URL for the generated image.
    Fails as ImageGenerationError - never raises httpx/circuit-breaker
    internals past this point, so callers only need to handle one type."""
    if not settings.hf_token:
        raise ImageGenerationError(
            "AI showcase generation is not configured (HF_TOKEN unset) - "
            "you can still upload a cover from your gallery.",
            code="unavailable",
        )
    try:
        outcome = await _breaker.call(_run_guarded, prompt, image_data_uri, aspect_ratio)
    except CircuitOpenError:
        raise ImageGenerationError(
            "AI showcase generation is temporarily unavailable - please try again shortly.",
            code="unavailable",
        )
    except httpx.HTTPError as e:
        logger.error("[hf:showcase] generation request failed err=%s", e)
        raise ImageGenerationError("AI showcase generation failed - please try again.")
    if isinstance(outcome, _Rejected):
        logger.info("[hf:showcase] input rejected: %s", outcome)
        raise ImageGenerationError(
            "The AI couldn't use this photo. Try a clearer photo of the item, "
            "or upload a cover from your gallery.",
            code="rejected",
        )
    return outcome


async def download_generated_image(url: str) -> tuple[bytes, str]:
    """Downloads the (temporary) generated image so it can be persisted
    into BROKA's own storage. Returns (bytes, mime_type). Streams with a
    size cap, and refuses anything that isn't an image."""
    try:
        async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_SECONDS) as client:
            async with client.stream("GET", url) as resp:
                resp.raise_for_status()
                mime = resp.headers.get("content-type", "image/jpeg").split(";")[0].strip() or "image/jpeg"
                if not mime.startswith("image/"):
                    raise ImageGenerationError("The generated file wasn't an image - please try again.")
                chunks, size = [], 0
                async for chunk in resp.aiter_bytes():
                    size += len(chunk)
                    if size > _MAX_IMAGE_BYTES:
                        raise ImageGenerationError("The generated image was too large - please try again.")
                    chunks.append(chunk)
                return b"".join(chunks), mime
    except httpx.HTTPError as e:
        logger.error("[hf:showcase] downloading generated image failed err=%s", e)
        raise ImageGenerationError("Couldn't retrieve the generated image - please try again.")
