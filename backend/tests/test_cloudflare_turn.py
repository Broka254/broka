"""
BROKA - Cloudflare TURN Tests
Run: pytest backend/tests/test_cloudflare_turn.py -v

Covers api/core/cloudflare_turn_client.py directly (config check, response
normalization/splitting, HTTP/timeout/malformed-response error handling,
secret redaction) and api/routers/calls.py's GET /turn-credentials by
calling the route function directly with a resolved `current` dict - the
same way test_sms.py calls mobitech_dlr() directly. Neither needs DB
access, so these stay plain unit tests rather than going through the ASGI
test client.

NOTE (written while implementing the Cloudflare TURN integration,
2026-09-01): this file matches the codebase's established test conventions
but has NOT been executed - the sandbox it was written in has no network
access and doesn't have this project's dependencies (fastapi/httpx/pytest)
installed, so there was no way to actually run pytest here. Every test was
syntax-checked (python3 -m py_compile) and carefully reviewed against
cloudflare_turn_client.py's real behavior, but please run
`pytest backend/tests/test_cloudflare_turn.py -v` before trusting it.
"""
from types import SimpleNamespace
from unittest.mock import patch
import logging

import httpx
import pytest
from fastapi import HTTPException

from api.core.cloudflare_turn_client import (
    generate_ice_servers,
    CloudflareTurnError,
    _split_ice_urls,
    _breaker,
)
from api.routers.calls import get_turn_credentials


@pytest.fixture(autouse=True)
def _reset_breaker():
    """_breaker is a module-level singleton shared across the whole test
    session - reset it before/after each test so a failure in one test
    can't trip the circuit and make an unrelated later test fail."""
    _breaker.reset()
    yield
    _breaker.reset()


def _settings(**overrides) -> SimpleNamespace:
    base = dict(
        cloudflare_turn_key_id="",
        cloudflare_turn_api_token="",
        cloudflare_account_id="",
    )
    base.update(overrides)
    base["cloudflare_turn_configured"] = bool(
        base["cloudflare_turn_key_id"] and base["cloudflare_turn_api_token"]
    )
    return SimpleNamespace(**base)


_CONFIGURED = dict(cloudflare_turn_key_id="key123", cloudflare_turn_api_token="tok_secret_abc")

# Cloudflare's documented response shape: iceServers as a single object,
# stun: and turn:/turns: urls sharing one username/credential pair.
_CLOUDFLARE_SUCCESS_BODY = {
    "iceServers": {
        "urls": [
            "stun:stun.cloudflare.com:3478",
            "turn:turn.cloudflare.com:3478?transport=udp",
            "turn:turn.cloudflare.com:3478?transport=tcp",
            "turns:turn.cloudflare.com:5349?transport=tcp",
        ],
        "username": "temp-user-xyz",
        "credential": "temp-cred-xyz",
    }
}


class _FakeResponse:
    def __init__(self, json_body, status_code=200):
        self._json_body = json_body
        self.status_code = status_code

    def raise_for_status(self):
        if self.status_code >= 400:
            # Same simplification test_sms.py uses: httpx.HTTPStatusError's
            # real constructor wants request=/response= kwargs that aren't
            # worth faking here - the base HTTPError is everything
            # generate_ice_servers()'s except clause needs to catch.
            raise httpx.HTTPError(f"Server error '{self.status_code}' for url 'x'")

    def json(self):
        if self._json_body is None:
            raise ValueError("not valid JSON")  # httpx raises a ValueError subclass on bad JSON
        return self._json_body


class _FakeAsyncClient:
    """Stand-in for httpx.AsyncClient as an async context manager."""

    def __init__(self, response=None, raise_exc=None):
        self.response = response
        self.raise_exc = raise_exc
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, headers=None, json=None, **kwargs):
        self.calls.append(("POST", url, headers, json))
        if self.raise_exc:
            raise self.raise_exc
        return self.response


# ── _split_ice_urls() - pure normalization logic ─────────────────────────────

class TestSplitIceUrls:
    def test_splits_single_object_shape_into_stun_and_turn(self):
        stun, turn, user, cred = _split_ice_urls(_CLOUDFLARE_SUCCESS_BODY["iceServers"])
        assert stun == ["stun:stun.cloudflare.com:3478"]
        assert turn == [
            "turn:turn.cloudflare.com:3478?transport=udp",
            "turn:turn.cloudflare.com:3478?transport=tcp",
            "turns:turn.cloudflare.com:5349?transport=tcp",
        ]
        assert user == "temp-user-xyz"
        assert cred == "temp-cred-xyz"

    def test_handles_list_of_one_shape_defensively(self):
        stun, turn, user, cred = _split_ice_urls([_CLOUDFLARE_SUCCESS_BODY["iceServers"]])
        assert stun == ["stun:stun.cloudflare.com:3478"]
        assert len(turn) == 3
        assert user == "temp-user-xyz"

    def test_stun_only_response_has_no_credentials(self):
        stun, turn, user, cred = _split_ice_urls({"urls": ["stun:stun.cloudflare.com:3478"]})
        assert stun == ["stun:stun.cloudflare.com:3478"]
        assert turn == []
        assert user is None
        assert cred is None

    def test_ignores_non_dict_entries_without_crashing(self):
        stun, turn, user, cred = _split_ice_urls([None, "garbage", 42])
        assert stun == [] and turn == [] and user is None and cred is None


# ── generate_ice_servers() ─────────────────────────────────────────────────────

class TestGenerateIceServers:
    @pytest.mark.asyncio
    async def test_raises_when_not_configured(self):
        with patch("api.core.cloudflare_turn_client.settings", _settings()):
            with pytest.raises(CloudflareTurnError, match="not configured"):
                await generate_ice_servers()

    @pytest.mark.asyncio
    async def test_success_returns_normalized_shape(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(response=_FakeResponse(_CLOUDFLARE_SUCCESS_BODY))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            result = await generate_ice_servers(ttl=3600)

        assert result["expires_in"] == 3600
        ice_servers = result["ice_servers"]
        assert ice_servers[0] == {"urls": ["stun:stun.cloudflare.com:3478"]}
        assert ice_servers[1]["username"] == "temp-user-xyz"
        assert ice_servers[1]["credential"] == "temp-cred-xyz"
        assert len(ice_servers[1]["urls"]) == 3

    @pytest.mark.asyncio
    async def test_sends_correct_request_shape(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(response=_FakeResponse(_CLOUDFLARE_SUCCESS_BODY))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            await generate_ice_servers(ttl=1800)

        method, url, headers, payload = fake_client.calls[0]
        assert method == "POST"
        assert url == "https://rtc.live.cloudflare.com/v1/turn/keys/key123/credentials/generate-ice-servers"
        assert headers["Authorization"] == "Bearer tok_secret_abc"
        assert payload == {"ttl": 1800}

    @pytest.mark.asyncio
    async def test_raises_on_http_error(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(response=_FakeResponse({"error": "bad key"}, status_code=403))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError):
                await generate_ice_servers()

    @pytest.mark.asyncio
    async def test_raises_on_timeout(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectTimeout("timed out"))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError, match="timed out"):
                await generate_ice_servers()

    @pytest.mark.asyncio
    async def test_raises_on_non_json_response(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(response=_FakeResponse(None))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError, match="non-JSON"):
                await generate_ice_servers()

    @pytest.mark.asyncio
    async def test_raises_on_missing_ice_servers_key(self):
        s = _settings(**_CONFIGURED)
        fake_client = _FakeAsyncClient(response=_FakeResponse({"error": "nope"}))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError, match="missing iceServers"):
                await generate_ice_servers()

    @pytest.mark.asyncio
    async def test_raises_on_turn_urls_without_credential(self):
        s = _settings(**_CONFIGURED)
        body = {"iceServers": {"urls": ["turn:turn.cloudflare.com:3478?transport=udp"]}}
        fake_client = _FakeAsyncClient(response=_FakeResponse(body))
        with patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError, match="without username/credential"):
                await generate_ice_servers()


# ── Secret redaction ──────────────────────────────────────────────────────────
# The integration spec this was built against is explicit: never log the
# Cloudflare API token, and never log a generated TURN username/credential.
# These check that end-to-end, including through the "invalid response"
# error paths, where a malformed-but-partially-populated Cloudflare
# response could otherwise leak a real credential into the exception
# message that api/routers/calls.py logs on failure.

class TestSecretRedaction:
    @pytest.mark.asyncio
    async def test_api_token_never_appears_in_error_log(self, caplog):
        s = _settings(cloudflare_turn_key_id="key123",
                       cloudflare_turn_api_token="SUPER_SECRET_TOKEN_1234")
        fake_client = _FakeAsyncClient(response=_FakeResponse({}, status_code=500))
        with caplog.at_level(logging.WARNING, logger="api.core.cloudflare_turn_client"), \
             patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError):
                await generate_ice_servers()

        assert "SUPER_SECRET_TOKEN_1234" not in caplog.text

    @pytest.mark.asyncio
    async def test_credential_never_leaks_via_malformed_response_path(self, caplog):
        """A malformed response with a real credential but no urls (an edge
        case Cloudflare's contract doesn't rule out) must not leak that
        credential into the 'no usable urls' error message/log line."""
        s = _settings(**_CONFIGURED)
        body = {"iceServers": {"username": "leaky-user", "credential": "LEAKY_CREDENTIAL_VALUE"}}
        fake_client = _FakeAsyncClient(response=_FakeResponse(body))
        with caplog.at_level(logging.WARNING, logger="api.core.cloudflare_turn_client"), \
             patch("api.core.cloudflare_turn_client.settings", s), \
             patch("api.core.cloudflare_turn_client.httpx.AsyncClient", return_value=fake_client):
            with pytest.raises(CloudflareTurnError, match="no usable"):
                await generate_ice_servers()

        assert "LEAKY_CREDENTIAL_VALUE" not in caplog.text


# ── GET /calls/turn-credentials router ─────────────────────────────────────────
# Called directly (bypassing FastAPI's Depends() wiring) the same way
# test_sms.py calls mobitech_dlr() directly - the handler needs no DB
# access, so a resolved `current` dict is all it takes.

class TestTurnCredentialsEndpoint:
    @pytest.mark.asyncio
    async def test_returns_client_result_on_success(self):
        expected = {"ice_servers": [{"urls": ["stun:stun.cloudflare.com:3478"]}], "expires_in": 3600}
        with patch("api.core.cloudflare_turn_client.generate_ice_servers", return_value=expected):
            result = await get_turn_credentials(current={"id": "user-1"})
        assert result == expected

    @pytest.mark.asyncio
    async def test_returns_controlled_503_on_failure_without_leaking_detail(self):
        internal_msg = ("Cloudflare TURN is not configured (CLOUDFLARE_TURN_KEY_ID / "
                         "CLOUDFLARE_TURN_API_TOKEN unset)")
        with patch("api.core.cloudflare_turn_client.generate_ice_servers",
                   side_effect=CloudflareTurnError(internal_msg)):
            with pytest.raises(HTTPException) as exc_info:
                await get_turn_credentials(current={"id": "user-1"})

        assert exc_info.value.status_code == 503
        # The client-facing detail must never repeat Cloudflare's internal
        # error text - only the generic, controlled message.
        assert "CLOUDFLARE_TURN_KEY_ID" not in exc_info.value.detail
        assert "temporarily unavailable" in exc_info.value.detail
