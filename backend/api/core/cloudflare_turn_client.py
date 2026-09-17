"""
BROKA - Cloudflare Realtime TURN Client
─────────────────────────────────────────────────────────────────────────────
Raw REST wrapper around Cloudflare Realtime's TURN credential-generation
API - no Cloudflare SDK dependency, matching how api/core/sms.py and
api/core/fal_client.py talk to their own external providers directly over
httpx rather than pulling in a vendor package.

Cloudflare's documented contract:
  POST https://rtc.live.cloudflare.com/v1/turn/keys/{TURN_KEY_ID}/credentials/generate-ice-servers
  Headers: Authorization: Bearer {CLOUDFLARE_TURN_API_TOKEN}
  Body:    {"ttl": <seconds>}
  Returns: {"iceServers": {"urls": [...], "username": "...", "credential": "..."}}
           (STUN and TURN urls share one temporary username/credential pair;
           STUN entries ignore the credential fields.)

This client never hands Cloudflare's raw shape back to a caller. Flutter's
createPeerConnection() wants an iceServers list it can use as-is, with STUN
(no credentials needed) kept separate from TURN (credentialed) - so
generate_ice_servers() normalizes into:
  {"ice_servers": [{"urls": [stun...]},
                    {"urls": [turn...], "username": "...", "credential": "..."}],
   "expires_in": <seconds>}
using only the real urls/username/credential values Cloudflare actually
returned in this call - never invented, never cached/reused past this
response. See api/routers/calls.py's GET /calls/turn-credentials, the only
caller.

The API token is a server-side secret (CLOUDFLARE_TURN_API_TOKEN) and must
never reach the client or a log line. Neither it nor the generated TURN
username/credential appear in any log statement below or in
api/routers/calls.py's handler.
"""
from __future__ import annotations

import logging
from typing import Optional

import httpx

from api.core.config import settings
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError

logger = logging.getLogger(__name__)

_TURN_ENDPOINT_TEMPLATE = (
    "https://rtc.live.cloudflare.com/v1/turn/keys/{key_id}/credentials/generate-ice-servers"
)
_HTTP_TIMEOUT_SECONDS = 10.0  # one quick credential-generation call, not a poll loop
_DEFAULT_TTL_SECONDS = 3600

_breaker = CircuitBreaker("cloudflare_turn", failure_threshold=5, recovery_timeout=30)


class CloudflareTurnError(Exception):
    """Raised for any Cloudflare TURN failure the caller should translate
    into a controlled client-facing error (not configured, HTTP failure,
    timeout, malformed response). Distinct from letting httpx/circuit-
    breaker internals leak out, so api/routers/calls.py has exactly one
    exception type to handle."""


def _headers() -> dict:
    return {
        "Authorization": f"Bearer {settings.cloudflare_turn_api_token}",
        "Content-Type": "application/json",
    }


def _split_ice_urls(raw_ice_servers) -> tuple[list[str], list[str], Optional[str], Optional[str]]:
    """Cloudflare's docs show iceServers as a single object; handled
    defensively as either a single object or a list of one, in case that
    ever changes. Returns (stun_urls, turn_urls, username, credential)."""
    entries = raw_ice_servers if isinstance(raw_ice_servers, list) else [raw_ice_servers]
    stun_urls: list[str] = []
    turn_urls: list[str] = []
    username: Optional[str] = None
    credential: Optional[str] = None
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        raw_urls = entry.get("urls")
        url_list = [raw_urls] if isinstance(raw_urls, str) else (raw_urls or [])
        for u in url_list:
            if not isinstance(u, str):
                continue
            if u.startswith("stun:"):
                stun_urls.append(u)
            elif u.startswith("turn:") or u.startswith("turns:"):
                turn_urls.append(u)
        # Cloudflare's documented shape has exactly one username/credential
        # pair shared across all TURN urls - first entry that actually
        # carries them wins.
        if username is None and entry.get("username"):
            username = entry.get("username")
        if credential is None and entry.get("credential"):
            credential = entry.get("credential")
    return stun_urls, turn_urls, username, credential


async def _generate_once(ttl: int) -> dict:
    url = _TURN_ENDPOINT_TEMPLATE.format(key_id=settings.cloudflare_turn_key_id)

    async with httpx.AsyncClient(timeout=_HTTP_TIMEOUT_SECONDS) as client:
        resp = await client.post(url, headers=_headers(), json={"ttl": ttl})
        resp.raise_for_status()
        try:
            body = resp.json()
        except ValueError as e:
            raise CloudflareTurnError(f"Cloudflare returned a non-JSON response: {e}")

    # Never interpolate the raw Cloudflare response body into an exception
    # message below - it can legitimately carry a real username/credential
    # even on a path we're about to treat as an error (e.g. urls missing
    # but credentials present), and this message is what calls.py logs on
    # failure. Describe the problem structurally instead.
    raw_ice_servers = body.get("iceServers") if isinstance(body, dict) else None
    if not raw_ice_servers:
        present_keys = list(body.keys()) if isinstance(body, dict) else type(body).__name__
        raise CloudflareTurnError(f"Cloudflare response missing iceServers (keys={present_keys})")

    stun_urls, turn_urls, username, credential = _split_ice_urls(raw_ice_servers)
    if not stun_urls and not turn_urls:
        raise CloudflareTurnError("Cloudflare response had no usable stun:/turn:/turns: urls")
    if turn_urls and not (username and credential):
        # TURN relay urls with no credential are useless as a relay - treat
        # as invalid rather than silently handing Flutter a broken config.
        raise CloudflareTurnError("Cloudflare TURN urls returned without username/credential")

    ice_servers = []
    if stun_urls:
        ice_servers.append({"urls": stun_urls})
    if turn_urls:
        ice_servers.append({"urls": turn_urls, "username": username, "credential": credential})

    return {"ice_servers": ice_servers, "expires_in": ttl}


async def generate_ice_servers(ttl: int = _DEFAULT_TTL_SECONDS) -> dict:
    """Returns BROKA's normalized {"ice_servers": [...], "expires_in": ...}.
    Fails as CloudflareTurnError only - never raises httpx/circuit-breaker
    internals past this point. Never logs CLOUDFLARE_TURN_API_TOKEN or the
    generated TURN username/credential."""
    if not settings.cloudflare_turn_configured:
        raise CloudflareTurnError(
            "Cloudflare TURN is not configured (CLOUDFLARE_TURN_KEY_ID / "
            "CLOUDFLARE_TURN_API_TOKEN unset)"
        )
    try:
        return await _breaker.call(_generate_once, ttl)
    except CircuitOpenError:
        raise CloudflareTurnError("Cloudflare TURN is temporarily unavailable")
    # CloudflareTurnError from _generate_once (malformed/invalid Cloudflare
    # response) isn't an httpx.HTTPError, so it already passes through the
    # except clauses below untouched - same pattern as fal_client.py's
    # FalGenerationError.
    except httpx.TimeoutException as e:
        logger.warning("[cloudflare:turn] request timed out err=%s", e)
        raise CloudflareTurnError("Cloudflare TURN credential request timed out")
    except httpx.HTTPError as e:
        logger.warning("[cloudflare:turn] request failed err=%s", e)
        raise CloudflareTurnError("Cloudflare TURN credential generation failed")
