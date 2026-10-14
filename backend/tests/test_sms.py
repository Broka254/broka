"""
BROKA - SMS Provider Tests (v6.2)
Run: pytest backend/tests/test_sms.py -v

Covers api/core/sms.py directly: the Mobitech provider (send/get_balance/
validate_mobile), the get_sms_provider() priority chain (Mobitech ->
Africa's Talking -> ConsoleSMS), and api/routers/sms.py's DLR webhook.
No DB/app boot needed - none of this touches the database, so these stay
plain unit tests rather than going through the ASGI test client (see
test_interest_nudges.py for the higher-level sweep test that exercises
get_sms_provider() through a mocked call instead of testing it directly).
"""
from types import SimpleNamespace
from unittest.mock import patch
import logging

import httpx
import pytest

from api.core.sms import (
    ConsoleSMS,
    AfricasTalkingSMS,
    MobitechSMS,
    get_sms_provider,
    _mobitech_breaker,
)
from api.routers.sms import MobitechDLR, mobitech_dlr


@pytest.fixture(autouse=True)
def _reset_breaker():
    """_mobitech_breaker is a module-level singleton shared across the whole
    test session - reset it before/after each test so a failure in one test
    can't trip the circuit and make an unrelated later test fail."""
    _mobitech_breaker.reset()
    yield
    _mobitech_breaker.reset()


def _settings(**overrides) -> SimpleNamespace:
    base = dict(
        mobitech_api_key="",
        mobitech_sender_name="",
        mobitech_base_url="https://textapi.mobitechtechnologies.com",
        mobitech_send_endpoint="/sms/sendsms",
        at_username="",
        at_api_key="",
        at_sender_id="",
    )
    base.update(overrides)
    return SimpleNamespace(**base)


class _FakeResponse:
    def __init__(self, json_body, status_code=200, text=None, content_type="application/json"):
        self._json_body = json_body
        self.status_code = status_code
        # Every existing test uses status_code=200 (Mobitech signals its
        # own errors via a status_code *in* the body, at HTTP 200) so this
        # was previously a no-op; the new diagnostic-logging tests below
        # specifically need a real HTTP 4xx/5xx, so this now actually
        # raises, matching real httpx.Response.raise_for_status().
        self.text = text if text is not None else ""
        self.headers = {"content-type": content_type}

    def raise_for_status(self):
        if self.status_code >= 400:
            # httpx.HTTPStatusError's real constructor requires request=/
            # response= kwargs whose exact shape isn't worth guessing at
            # here - _send_once() captures every diagnostic it needs
            # BEFORE calling raise_for_status() (that's the whole point of
            # this change), so it never inspects the exception object
            # itself afterward. The base HTTPError - already used the
            # same way elsewhere in this file (httpx.ConnectError(...)) -
            # is everything send()'s except clause actually needs to catch.
            raise httpx.HTTPError(f"Server error '{self.status_code} Internal Server Error' for url 'x'")

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

    async def get(self, url, headers=None, params=None, **kwargs):
        self.calls.append(("GET", url, headers, params))
        if self.raise_exc:
            raise self.raise_exc
        return self.response


# ── get_sms_provider() priority chain ──────────────────────────────────────

class TestGetSmsProvider:
    def test_prefers_mobitech_when_configured(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="BROKA",
                       at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), MobitechSMS)

    def test_falls_back_to_africas_talking_when_mobitech_unset(self):
        s = _settings(at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), AfricasTalkingSMS)

    def test_falls_back_to_africas_talking_when_mobitech_partially_set(self):
        # sender_name missing - shouldn't be treated as "configured"
        s = _settings(mobitech_api_key="key123", at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), AfricasTalkingSMS)

    def test_falls_back_to_console_when_nothing_configured(self):
        with patch("api.core.sms.settings", _settings()):
            assert isinstance(get_sms_provider(), ConsoleSMS)


# ── ConsoleSMS ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_console_sms_never_raises_and_returns_true():
    assert await ConsoleSMS().send("+254712345678", "test message") is True


# ── MobitechSMS.send() ───────────────────────────────────────────────────────
# /sms/sendsms (2026-08-31, second correction - see MobitechSMS's class
# docstring for the full history). Flat payload - serviceId/shortcode/
# mobile/message/client_ref all at the top level, no nested messages[]
# array - empirically confirmed against this exact account/credentials
# (a manual request with this shape and field-name casing returned
# status_code 1000), which is the only ground truth that matters here.

class TestMobitechSend:
    @pytest.mark.asyncio
    async def test_send_success(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({
            "status_code": "1000",
            "status_desc": "Success",
            "message_id": 8738598,
            "mobile_number": "254710986455",
            "network_id": "1",
            "message_cost": "0.75",
            "credit_balance": "9871",
        }))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is True
        method, url, headers, payload = fake_client.calls[0]
        assert method == "POST"
        assert url == "https://textapi.mobitechtechnologies.com/sms/sendsms"
        assert "/sms/sendsms/sms/" not in url  # the exact production double-path bug
        assert headers["h_api_key"] == "key123"
        assert payload["serviceId"] == "0"
        assert payload["shortcode"] == "FULL-CIRCLE"  # reads settings.mobitech_sender_name, unchanged config name
        assert payload["message"] == "hello there"
        assert isinstance(payload["client_ref"], int)  # docs' own examples use bare integers
        assert "messages" not in payload  # flat shape, not sendmultiple's nested array
        assert set(payload.keys()) == {"serviceId", "shortcode", "mobile", "message", "client_ref"}

    @pytest.mark.asyncio
    async def test_send_strips_leading_plus_from_phone(self):
        """Empirically confirmed against this account: a manual request
        without the leading + returned status_code 1000. auth/service.py
        hands every provider a +254... number, so this adapts it for the
        one endpoint confirmed to want the bare form - not a general
        phone-format change (that stays auth/service.py's job)."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({"status_code": "1000"}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            await MobitechSMS().send("+254706462869", "hi")

        _, _, _, payload = fake_client.calls[0]
        assert payload["mobile"] == "254706462869"

    @pytest.mark.asyncio
    async def test_send_leaves_already_bare_phone_unchanged(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({"status_code": "1000"}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            await MobitechSMS().send("254706462869", "hi")

        _, _, _, payload = fake_client.calls[0]
        assert payload["mobile"] == "254706462869"

    @pytest.mark.asyncio
    async def test_send_returns_false_on_application_level_error_status(self):
        """Mobitech returns HTTP 200 with an error status_code in the body
        (e.g. 1001 invalid shortcode) - this must fail soft, not raise."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({
            "status_code": "1001", "status_desc": "Invalid short code",
        }))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254706462869", "hello there")

        assert result is False

    @pytest.mark.asyncio
    async def test_send_handles_array_wrapped_response_defensively(self):
        """/sms/sendsms's own docs show the response wrapped in a JSON
        array even for one recipient - handled without assuming either
        shape away."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            [{"status_code": "1000", "status_desc": "Success"}]
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is True

    @pytest.mark.asyncio
    async def test_send_returns_false_on_transport_error(self):
        """A real network/HTTP failure must also fail soft, same as AfricasTalkingSMS."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectError("connection refused"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is False

    @pytest.mark.asyncio
    async def test_send_handles_malformed_response_defensively(self):
        """Neither a dict nor a list (or missing status_code entirely) -
        must degrade to False, not raise."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is False


# ── MobitechSMS HTTP-level (4xx/5xx) diagnostic logging ──────────────────────
# 2026-08-30: _send_once() used to call resp.raise_for_status() before ever
# looking at the response body, so a real HTTP error (e.g. the production
# 500 from /sms/sendmultiple) collapsed into send()'s generic
# "err=Server error '500 ...'" with none of what Mobitech (or a gateway in
# front of it) actually said. These verify the body is captured and logged
# BEFORE the exception propagates, and that the exception still propagates
# afterward unchanged (the circuit breaker's own failure counting depends
# on that - see api/core/circuit_breaker.py).

class TestMobitechHttpErrorDiagnostics:
    @pytest.mark.asyncio
    async def test_logs_diagnostic_info_before_raising_on_http_500(self, caplog):
        s = _settings(mobitech_api_key="realkey123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"error": "internal failure", "trace_id": "abc123"},
            status_code=500,
            text='{"error": "internal failure", "trace_id": "abc123"}',
        ))
        with caplog.at_level(logging.ERROR, logger="api.core.sms"), \
             patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254706462869", "Your BROKA verification code is 123456")

        assert result is False  # fail-soft preserved
        logged = caplog.text
        assert "http_status=500" in logged
        assert "sms/sendsms" in logged
        assert "application/json" in logged
        assert "trace_id" in logged and "abc123" in logged  # response body actually captured
        assert "FULL-CIRCLE" in logged  # sanitized payload's real (non-secret) shortcode value
        assert "123456" not in logged  # OTP text never logged
        assert "realkey123" not in logged  # API key never logged
        assert "<redacted>" in logged  # message field shown as redacted, not the real text

    @pytest.mark.asyncio
    async def test_logs_gracefully_on_non_json_error_body(self, caplog):
        """A gateway/proxy in front of Mobitech can return a plain HTML
        error page for a 500/502 - must not crash trying to parse it as JSON."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            None, status_code=502, text="<html><body>502 Bad Gateway</body></html>",
            content_type="text/html",
        ))
        with caplog.at_level(logging.ERROR, logger="api.core.sms"), \
             patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254706462869", "hi")

        assert result is False
        assert "502 Bad Gateway" in caplog.text
        assert "mobitech_status_code=None" in caplog.text

    @pytest.mark.asyncio
    async def test_extracts_mobitech_status_even_on_http_4xx(self, caplog):
        """If Mobitech's gateway ever pairs a real HTTP 4xx with their own
        JSON status_code/status_desc in the body, both should surface."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"status_code": "1015", "status_desc": "Missing Parameter"},
            status_code=400,
            text='{"status_code": "1015", "status_desc": "Missing Parameter"}',
        ))
        with caplog.at_level(logging.ERROR, logger="api.core.sms"), \
             patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254706462869", "hi")

        assert result is False
        assert "mobitech_status_code='1015'" in caplog.text
        assert "Missing Parameter" in caplog.text

    @pytest.mark.asyncio
    async def test_http_error_still_propagates_to_the_circuit_breaker(self):
        """The diagnostic logging must not swallow the exception - the
        circuit breaker's failure counting depends on it still propagating
        exactly as before this change."""
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({"status_code": "1005"}, status_code=500))
        _mobitech_breaker.reset()
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            for _ in range(3):
                await MobitechSMS().send("+254706462869", "hi")

        assert _mobitech_breaker._failure_count == 3
        _mobitech_breaker.reset()


# ── MobitechSMS extra endpoints ──────────────────────────────────────────────

class TestMobitechExtras:
    @pytest.mark.asyncio
    async def test_get_balance(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="BROKA")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"credit_balance": "5165.80", "date": "2026-08-28 10:00:00"}
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            balance = await MobitechSMS().get_balance()

        assert balance == {"credit_balance": "5165.80", "date": "2026-08-28 10:00:00"}
        method, url, headers, params = fake_client.calls[0]
        assert method == "GET"
        assert url == "https://textapi.mobitechtechnologies.com/sms/getbalance"

    @pytest.mark.asyncio
    async def test_get_balance_returns_none_on_failure(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="BROKA")
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectError("down"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            balance = await MobitechSMS().get_balance()

        assert balance is None

    @pytest.mark.asyncio
    async def test_validate_mobile(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="BROKA")
        fake_client = _FakeAsyncClient(response=_FakeResponse({"network": "Safaricom"}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().validate_mobile("+254712244243")

        assert result == {"network": "Safaricom"}
        _, url, _, params = fake_client.calls[0]
        assert url == "https://textapi.mobitechtechnologies.com/sms/mobile"
        assert params == {"mobile": "+254712244243", "return": "json"}


# ── DLR webhook ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_mobitech_dlr_endpoint_accepts_report():
    report = MobitechDLR(
        messageId="27312989",
        dlrTime="2022-02-22 11:46:42",
        dlrStatus="1",
        dlrDesc="DeliveredToTerminal",
        destaddr="+254710986455",
        sourceaddr="118",
        origin="Safaricom",
    )
    result = await mobitech_dlr(report)
    assert result == {"received": True}


@pytest.mark.asyncio
async def test_mobitech_dlr_endpoint_only_requires_message_id():
    result = await mobitech_dlr(MobitechDLR(messageId="1"))
    assert result == {"received": True}
