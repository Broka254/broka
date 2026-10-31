"""
BROKA - SMS Provider Tests (v6.3)
Run: pytest backend/tests/test_sms.py -v

Covers api/core/sms.py directly: the Texin provider (primary —
send/check_status/get_balance/get_sender_ids/test_connection, phone
normalization, GSM-7 handling, delivery tracking), the
get_sms_provider() priority chain (Texin -> Africa's Talking ->
ConsoleSMS; Mobitech is deprecated and never selected), the deprecated
MobitechSMS (still working for in-flight traffic), and api/routers/sms.py's
webhooks (Texin HMAC-verified DLR + legacy Mobitech DLR). No DB/app boot
needed for the provider tests — cost rows are asserted through a mocked
record_sms_cost, so no real credit is consumed and nothing is written.
"""
import hashlib
import hmac
import json
import logging
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from fastapi import Request, Response

from api.core import sms as sms_module
from api.core.sms import (
    ConsoleSMS,
    AfricasTalkingSMS,
    MobitechSMS,
    TexinSMS,
    get_sms_provider,
    current_sms_provider_name,
    normalize_ke_phone,
    sms_to_gsm7,
    sms_gsm7_segments,
    verify_texin_signature,
    record_texin_delivery,
    get_texin_delivery_status,
    get_texin_metrics,
    TEXIN_DELIVERY_CACHE,
    _mobitech_breaker,
    _at_breaker,
    _texin_breaker,
)
from api.routers import sms as sms_router_module
from api.routers.sms import (
    MobitechDLR,
    mobitech_dlr,
    texin_dlr,
    _TEXIN_DLR_SEEN,
    _extract_texin_report,
)
from api.core import cost_ledger


@pytest.fixture(autouse=True)
def _reset_sms_state():
    """Breakers are module-level singletons shared across the whole test
    session — reset before/after each test so a failure in one test can't
    trip a circuit and make an unrelated later test fail. Delivery caches
    and metrics are reset for the same reason."""
    _mobitech_breaker.reset()
    _at_breaker.reset()
    _texin_breaker.reset()
    TEXIN_DELIVERY_CACHE.clear()
    _TEXIN_DLR_SEEN.clear()
    for _key in sms_module._TEXIN_METRICS:
        sms_module._TEXIN_METRICS[_key] = 0
    yield
    _mobitech_breaker.reset()
    _at_breaker.reset()
    _texin_breaker.reset()
    TEXIN_DELIVERY_CACHE.clear()
    _TEXIN_DLR_SEEN.clear()
    for _key in sms_module._TEXIN_METRICS:
        sms_module._TEXIN_METRICS[_key] = 0


def _settings(**overrides) -> SimpleNamespace:
    base = dict(
        texin_api_key="",
        texin_base_url="https://sms.texin.co.ke/api",
        texin_sender_id="",
        texin_timeout_seconds=15,
        texin_webhook_secret="",
        sms_cost_minor_texin=29,
        mobitech_api_key="",
        mobitech_sender_name="",
        mobitech_base_url="https://textapi.mobitechtechnologies.com",
        mobitech_send_endpoint="/sms/sendsms",
        sms_cost_minor_mobitech=35,
        at_username="",
        at_api_key="",
        at_sender_id="",
        sms_cost_minor_at=80,
        is_production=False,
    )
    base.update(overrides)
    return SimpleNamespace(**base)


def _texin_settings(**overrides) -> SimpleNamespace:
    base = dict(texin_api_key="test-texin-key")
    base.update(overrides)
    return _settings(**base)


class _FakeResponse:
    def __init__(self, json_body, status_code=200, text=None, content_type="application/json"):
        self._json_body = json_body
        self.status_code = status_code
        self.text = text if text is not None else ""
        self.headers = {"content-type": content_type}

    def raise_for_status(self):
        if self.status_code >= 400:
            # httpx.HTTPStatusError's real constructor requires request=/
            # response= kwargs whose exact shape isn't worth guessing at
            # here — the provider code only needs the exception type, never
            # the object itself.
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


class _SequencedFakeAsyncClient(_FakeAsyncClient):
    """Returns each queued response/exception in order (for retry tests)."""

    def __init__(self, steps):
        super().__init__()
        self.steps = list(steps)

    async def post(self, url, headers=None, json=None, **kwargs):
        self.calls.append(("POST", url, headers, json))
        step = self.steps.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


TEXIN_SUCCESS_BODY = {
    "success": True,
    "message": "SMS sent successfully!",
    "message_id": "1303443944556021016",
    "recipient": "254706462869",
    "sender_id": "Texin",
    "units_used": 1,
    "cost": 0.29,
    "new_balance": 170,
    "simulation_mode": False,
}


def _ledger_mock(amount_minor=29):
    """Mock for api.core.cost_ledger.record_sms_cost: never touches the DB."""
    return AsyncMock(return_value=SimpleNamespace(amount_minor=amount_minor))


# ── 1. Texin provider selection ──────────────────────────────────────────────

class TestGetSmsProvider:
    def test_prefers_texin_when_configured(self):
        s = _texin_settings(at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), TexinSMS)
            assert current_sms_provider_name() == "texin"

    def test_texin_wins_over_stale_mobitech_vars(self):
        """Old MOBITECH_* values lingering in Railway/Render must never
        override Texin — Mobitech is not consulted at all."""
        s = _texin_settings(mobitech_api_key="oldkey", mobitech_sender_name="BROKA")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), TexinSMS)

    def test_mobitech_alone_never_selects_mobitech(self):
        """Mobitech is deprecated: even fully configured on its own, it
        falls through to Africa's Talking, then ConsoleSMS."""
        s = _settings(mobitech_api_key="oldkey", mobitech_sender_name="BROKA",
                       at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), AfricasTalkingSMS)
        s = _settings(mobitech_api_key="oldkey", mobitech_sender_name="BROKA")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), ConsoleSMS)

    def test_falls_back_to_africas_talking_when_texin_unset(self):
        s = _settings(at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), AfricasTalkingSMS)
            assert current_sms_provider_name() == "africas_talking"

    def test_falls_back_to_console_when_nothing_configured(self):
        with patch("api.core.sms.settings", _settings()):
            assert isinstance(get_sms_provider(), ConsoleSMS)
            assert current_sms_provider_name() == "console"


# ── 20. ConsoleSMS development behavior ──────────────────────────────────────

class TestConsoleSMS:
    @pytest.mark.asyncio
    async def test_dev_logs_and_returns_true(self):
        with patch("api.core.sms.settings", _settings(is_production=False)):
            assert await ConsoleSMS().send("+254712345678", "test message") is True

    @pytest.mark.asyncio
    async def test_production_refuses_instead_of_logging_codes(self):
        """In production a logged-but-unsent OTP would both report success
        and leak a live code into log storage — so it fails instead."""
        with patch("api.core.sms.settings", _settings(is_production=True)):
            assert await ConsoleSMS().send("+254712345678", "test message") is False


# ── 5. Kenyan phone-number normalization ─────────────────────────────────────

class TestNormalizeKePhone:
    @pytest.mark.parametrize("raw,expected", [
        ("0706462869", "254706462869"),
        ("254706462869", "254706462869"),
        ("+254706462869", "254706462869"),
        (" 0706462869 ", "254706462869"),   # surrounding whitespace
        ("0706 462 869", "254706462869"),   # inner spaces
        ("0112345678", "254112345678"),     # 01… prefix also Kenyan
    ])
    def test_accepted_forms(self, raw, expected):
        assert normalize_ke_phone(raw) == expected

    @pytest.mark.parametrize("raw", [
        "", "   ", None, 12345,
        "070646286",        # too short
        "07064628690",      # too long for a local form
        "25470646286",      # Kenyan-shaped but short — rejected, not passed through
        "0254706462869",    # double-prefixed typo
        "++254706462869",   # double plus
        "07O6462869",       # letter inside
        "+254",             # far too short to be any number
    ])
    def test_rejected_forms(self, raw):
        assert normalize_ke_phone(raw) is None

    @pytest.mark.asyncio
    async def test_send_rejects_malformed_number_before_billing(self):
        """No HTTP call, no cost row for a number that was never valid."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("not-a-number", "hello")
        assert result is False
        assert fake_client.calls == []
        ledger.assert_not_awaited()


# ── GSM-7 message compatibility ──────────────────────────────────────────────

class TestGsm7:
    def test_plain_ascii_untouched(self):
        body = "123456 is your BROKA verification code. It expires in 5 minutes."
        assert sms_to_gsm7(body) == body

    def test_curly_quotes_and_dashes_mapped(self):
        assert sms_to_gsm7("\u201cHi\u201d \u2014 don\u2019t \u2026") == '"Hi" - don\'t ...'

    def test_emoji_removed_not_replaced(self):
        assert sms_to_gsm7("code 123456 \U0001f389\U0001f525") == "code 123456 "

    @pytest.mark.asyncio
    async def test_send_normalizes_sms_copy_only(self):
        """The SMS copy is GSM-7 normalized; the caller's original string
        is never modified (in-app notification text is out of scope)."""
        s = _texin_settings()
        original = "Hi \u2014 123456 \U0001f389"
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            result = await TexinSMS().send("+254706462869", original)
        assert result is True
        assert original == "Hi \u2014 123456 \U0001f389"  # untouched
        _, _, _, payload = fake_client.calls[0]
        assert payload["message"] == "Hi - 123456 "
        assert all(ord(c) < 128 for c in payload["message"])

    @pytest.mark.asyncio
    async def test_send_rejects_message_with_no_gsm7_content(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await TexinSMS().send("+254706462869", "\U0001f389\U0001f525")
        assert result is False
        assert fake_client.calls == []

    def test_segment_boundaries(self):
        """160 GSM-7 chars fit one segment; 161 spills into two; multipart
        parts hold 153 — billing follows units, never truncation."""
        assert sms_gsm7_segments("x" * 160) == 1
        assert sms_gsm7_segments("x" * 161) == 2
        assert sms_gsm7_segments("x" * 306) == 2
        assert sms_gsm7_segments("x" * 307) == 3
        # Extension-table characters cost two septets each.
        assert sms_gsm7_segments("[" * 80) == 1
        assert sms_gsm7_segments("[" * 81) == 2


# ── TexinSMS.send() — acceptance contract ────────────────────────────────────
# 2/3/4. Correct endpoint, JSON structure, default sender-ID behavior.

class TestTexinSend:
    @pytest.mark.asyncio
    async def test_send_success_posts_to_send_sms(self):
        """6. The documented happy path: HTTP 200 + success + message_id."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            provider = TexinSMS()
            result = await provider.send("0706462869", "Your BROKA verification code is 123456")

        assert result is True
        assert provider.last_message_id == "1303443944556021016"
        assert len(fake_client.calls) == 1
        method, url, headers, payload = fake_client.calls[0]
        assert method == "POST"
        assert url == "https://sms.texin.co.ke/api/send_sms"
        assert headers["Content-Type"] == "application/json"
        # 3. Exact JSON structure: api_key / recipient / message.
        assert payload["api_key"] == "test-texin-key"
        assert payload["recipient"] == "254706462869"  # normalized
        assert payload["message"] == "Your BROKA verification code is 123456"
        # 4. Empty TEXIN_SENDER_ID: sender_id omitted (account default used).
        assert "sender_id" not in payload

    @pytest.mark.asyncio
    async def test_send_includes_configured_sender_id(self):
        """A registered TEXIN_SENDER_ID is passed through when set."""
        s = _texin_settings(texin_sender_id="BROKA")
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is True
        _, _, _, payload = fake_client.calls[0]
        assert payload["sender_id"] == "BROKA"

    @pytest.mark.asyncio
    async def test_send_uses_custom_base_url(self):
        s = _texin_settings(texin_base_url="https://staging.texin.co.ke/api/")
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is True
        _, url, _, _ = fake_client.calls[0]
        assert url == "https://staging.texin.co.ke/api/send_sms"

    @pytest.mark.asyncio
    async def test_send_returns_false_on_auth_failure(self):
        """7. success=false (bad key) is a clean False — never an exception,
        and nothing is recorded as spent."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False, "message": "Invalid API key"}, status_code=200
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_on_http_401(self):
        """7b. Auth failures may also arrive as a real HTTP 401."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False, "message": "Unauthorized"},
            status_code=401, text='{"success": false}',
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_on_insufficient_balance(self):
        """8. A billed-out account fails soft with no cost row."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False, "message": "Insufficient balance"}, status_code=200
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_on_http_500(self):
        """9. HTTP 200 alone proves nothing — and neither does a 500 page:
        both are False, with the body captured in the logs (see the
        no-leakage tests below for what must NOT be in them)."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            None, status_code=500,
            text="<html><body>500 Internal Server Error</body></html>",
            content_type="text/html",
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_on_http_400(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False, "message": "Missing parameter"},
            status_code=400, text='{"success": false}',
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False

    @pytest.mark.asyncio
    async def test_send_never_retries_timeouts(self):
        """10. After an ambiguous timeout Texin may already have accepted
        and billed — so a timeout is final (exactly one attempt), not
        retried into a double charge or a second valid OTP."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(raise_exc=httpx.ReadTimeout("read timed out"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "Your code is 123456")
        assert result is False
        assert len(fake_client.calls) == 1
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_on_connect_error(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectError("connection refused"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False

    @pytest.mark.asyncio
    async def test_send_returns_false_on_malformed_json(self):
        """11. A 200 with a body that is not JSON is not an acceptance."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            None, status_code=200, text="<html>ok</html>", content_type="text/html",
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_when_message_id_missing(self):
        """12. success=true with no message_id cannot be tracked — False."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": True, "message": "SMS sent successfully!", "units_used": 1}
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is False
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_returns_false_in_simulation_mode(self):
        """13. simulation_mode=true reached nobody — never counts as sent,
        and nothing is billed."""
        s = _texin_settings()
        body = dict(TEXIN_SUCCESS_BODY, simulation_mode=True)
        fake_client = _FakeAsyncClient(response=_FakeResponse(body))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            provider = TexinSMS()
            result = await provider.send("+254706462869", "hello")
        assert result is False
        assert provider.last_message_id is None
        ledger.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_send_retries_explicit_transient_rejection_once(self):
        """Bounded retry: an explicit 429 (Texin definitely did NOT accept)
        is retried exactly once; the retry succeeding means one send."""
        s = _texin_settings()
        fake_client = _SequencedFakeAsyncClient([
            _FakeResponse({"success": False, "message": "rate limited"}, status_code=429,
                          text='{"success": false}'),
            _FakeResponse(dict(TEXIN_SUCCESS_BODY)),
        ])
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is True
        assert len(fake_client.calls) == 2

    @pytest.mark.asyncio
    async def test_accounting_failure_never_fails_send(self):
        """The ledger is best-effort by design: a detached-session failure
        must not flip an accepted send to False."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost",
                   new=AsyncMock(side_effect=RuntimeError("db down"))):
            result = await TexinSMS().send("+254706462869", "hello")
        assert result is True


# ── 14. Cost accounting using actual units ────────────────────────────────────

class TestTexinCostAccounting:
    @pytest.mark.asyncio
    async def test_success_records_confirmed_actual_charge(self):
        """1 unit at KES 0.29 reported by Texin lands as amount_minor=29,
        estimated=False, keyed to the message_id."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            assert await TexinSMS().send("+254706462869", "hello") is True
        ledger.assert_awaited_once()
        kwargs = ledger.await_args.kwargs
        assert kwargs["provider"] == "texin"
        assert kwargs["units"] == 1
        assert kwargs["amount_minor"] == 29
        assert kwargs["message_id"] == "1303443944556021016"
        assert get_texin_metrics()["submitted"] == 1
        assert get_texin_metrics()["units"] == 1

    @pytest.mark.asyncio
    async def test_multipart_units_recorded(self):
        """2 units = KES 0.58, 3 units = KES 0.87 — the provider's units,
        not a flat per-message assumption."""
        s = _texin_settings()
        body = dict(TEXIN_SUCCESS_BODY, units_used=2, cost=0.58)
        fake_client = _FakeAsyncClient(response=_FakeResponse(body))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock(amount_minor=58)) as ledger:
            assert await TexinSMS().send("+254706462869", "hello") is True
        kwargs = ledger.await_args.kwargs
        assert kwargs["units"] == 2
        assert kwargs["amount_minor"] == 58

    @pytest.mark.asyncio
    async def test_ledger_math_per_unit_fallback(self):
        """record_sms_cost itself: no amount from the provider means
        units × SMS_COST_MINOR_TEXIN; no units either means one unit."""
        with patch("api.core.cost_ledger.record_cost_detached",
                   new=AsyncMock(return_value=SimpleNamespace(amount_minor=87))) as detached, \
             patch("api.core.config.settings", _settings()):
            await cost_ledger.record_sms_cost(provider="texin", units=3, message_id="m1")
        kwargs = detached.await_args.kwargs
        assert kwargs["amount_minor"] == 87  # 3 × 29
        assert kwargs["estimated"] is False
        assert kwargs["provider"] == "texin"
        assert kwargs["ref_id"] == "m1"
        assert kwargs["meta"]["units_used"] == 3

        with patch("api.core.cost_ledger.record_cost_detached",
                   new=AsyncMock(return_value=SimpleNamespace(amount_minor=29))) as detached2, \
             patch("api.core.config.settings", _settings()):
            await cost_ledger.record_sms_cost(provider="texin", message_id="m2")
        assert detached2.await_args.kwargs["amount_minor"] == 29
        assert detached2.await_args.kwargs["estimated"] is False

    @pytest.mark.asyncio
    async def test_ledger_prefers_reported_cost_over_units(self):
        """When Texin reports both, the reported cost is the charge."""
        with patch("api.core.cost_ledger.record_cost_detached",
                   new=AsyncMock(return_value=SimpleNamespace(amount_minor=58))) as detached, \
             patch("api.core.config.settings", _settings()):
            await cost_ledger.record_sms_cost(
                provider="texin", units=2, amount_minor=58, message_id="m3")
        kwargs = detached.await_args.kwargs
        assert kwargs["amount_minor"] == 58
        assert kwargs["estimated"] is False

    @pytest.mark.asyncio
    async def test_no_double_counting_single_send(self):
        """One accepted send writes exactly one cost row — never one for
        the attempt plus one for the acceptance."""
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(dict(TEXIN_SUCCESS_BODY)))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()) as ledger:
            assert await TexinSMS().send("+254706462869", "hello") is True
        ledger.assert_awaited_once()


# ── 15. Delivery-status lookup ───────────────────────────────────────────────

class TestTexinDeliveryStatus:
    @pytest.mark.asyncio
    async def test_check_status_delivered(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": True, "message_id": "1303443944556021016", "status": "delivered"}
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            status = await TexinSMS().check_status("1303443944556021016")
        assert status == "delivered"
        assert get_texin_delivery_status("1303443944556021016") == "delivered"
        method, url, _, payload = fake_client.calls[0]
        assert method == "POST"
        assert url == "https://sms.texin.co.ke/api/check_status"
        assert payload == {"api_key": "test-texin-key", "message_id": "1303443944556021016"}

    @pytest.mark.asyncio
    async def test_check_status_failed_and_rejected(self):
        for terminal in ("failed", "rejected"):
            _texin_breaker.reset()
            s = _texin_settings()
            fake_client = _FakeAsyncClient(response=_FakeResponse(
                {"success": True, "message_id": "mid-1", "status": terminal}
            ))
            with patch("api.core.sms.settings", s), \
                 patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
                assert await TexinSMS().check_status("mid-1") == terminal

    def test_sent_is_not_delivered(self):
        """'sent' means accepted by Texin — it must never read as delivered."""
        assert record_texin_delivery("mid-9", "sent") == "sent"
        assert get_texin_delivery_status("mid-9") == "sent"
        assert get_texin_metrics()["delivered"] == 0

    def test_unrecognized_status_ignored(self):
        assert record_texin_delivery("mid-x", "teleported") is None
        assert get_texin_delivery_status("mid-x") is None

    @pytest.mark.asyncio
    async def test_check_status_failure_returns_none(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectError("down"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            assert await TexinSMS().check_status("mid-1") is None

    @pytest.mark.asyncio
    async def test_extra_endpoints(self):
        s = _texin_settings()
        fake_client = _FakeAsyncClient(response=_FakeResponse({"balance": 170}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            assert await TexinSMS().get_balance() == {"balance": 170}
            _, url, _, payload = fake_client.calls[0]
            assert url == "https://sms.texin.co.ke/api/get_balance"
            assert payload == {"api_key": "test-texin-key"}

        fake_client2 = _FakeAsyncClient(response=_FakeResponse(["Texin", "BROKA"]))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client2):
            assert await TexinSMS().get_sender_ids() == ["Texin", "BROKA"]

        fake_client3 = _FakeAsyncClient(response=_FakeResponse({}, status_code=200))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client3):
            assert await TexinSMS().test_connection() is True
            method, url, _, _ = fake_client3.calls[0]
            assert method == "GET"
            assert url == "https://sms.texin.co.ke/api/test_connection"


# ── 16/17. Texin delivery webhook ────────────────────────────────────────────

def _sign(body: bytes, secret: str = "whsec") -> str:
    return "sha256=" + hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()


def _texin_request(body: bytes, signature=None) -> Request:
    headers = []
    if signature is not None:
        headers.append((b"x-texin-signature", signature.encode()))
    scope = {"type": "http", "method": "POST", "path": "/sms/texin/dlr",
             "headers": headers}

    async def receive():
        return {"type": "http.request", "body": body, "more_body": False}

    return Request(scope, receive)


def _webhook_settings(secret="whsec") -> SimpleNamespace:
    return SimpleNamespace(texin_webhook_secret=secret)


class TestTexinWebhook:
    @pytest.mark.asyncio
    async def test_valid_signature_accepted(self):
        """16. A correctly signed delivery report is recorded by message_id."""
        body = json.dumps({"message_id": "1303443944556021016",
                           "status": "delivered"}).encode()
        req = _texin_request(body, _sign(body))
        with patch("api.routers.sms.settings", _webhook_settings()):
            result = await texin_dlr(req, Response(), _sign(body))
        assert result == {"received": True}
        assert get_texin_delivery_status("1303443944556021016") == "delivered"
        assert get_texin_metrics()["delivered"] == 1

    @pytest.mark.asyncio
    async def test_invalid_signature_rejected(self):
        body = json.dumps({"message_id": "mid-1", "status": "delivered"}).encode()
        req = _texin_request(body, "sha256=" + "0" * 64)
        with patch("api.routers.sms.settings", _webhook_settings()):
            resp = Response()
            result = await texin_dlr(req, resp, "sha256=" + "0" * 64)
        assert result["received"] is False
        assert resp.status_code == 401
        assert get_texin_delivery_status("mid-1") is None

    @pytest.mark.asyncio
    async def test_missing_signature_rejected(self):
        body = json.dumps({"message_id": "mid-1", "status": "delivered"}).encode()
        req = _texin_request(body, None)
        with patch("api.routers.sms.settings", _webhook_settings()):
            resp = Response()
            result = await texin_dlr(req, resp, "")
        assert result["received"] is False
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_malformed_signature_format_rejected(self):
        body = json.dumps({"message_id": "mid-1", "status": "delivered"}).encode()
        req = _texin_request(body, "not-a-valid-signature")
        with patch("api.routers.sms.settings", _webhook_settings()):
            resp = Response()
            result = await texin_dlr(req, resp, "not-a-valid-signature")
        assert result["received"] is False
        assert resp.status_code == 401

    @pytest.mark.asyncio
    async def test_unconfigured_secret_rejects_everything(self):
        """Fail closed: without TEXIN_WEBHOOK_SECRET nothing verifies, so
        nothing is accepted (instead of silently dropping reports as 200)."""
        body = json.dumps({"message_id": "mid-1", "status": "delivered"}).encode()
        req = _texin_request(body, _sign(body, secret="whatever"))
        with patch("api.routers.sms.settings", _webhook_settings(secret="")):
            resp = Response()
            result = await texin_dlr(req, resp, _sign(body, secret="whatever"))
        assert result["received"] is False
        assert resp.status_code == 503

    @pytest.mark.asyncio
    async def test_malformed_json_rejected(self):
        body = b"<html>not json</html>"
        req = _texin_request(body, _sign(body))
        with patch("api.routers.sms.settings", _webhook_settings()):
            resp = Response()
            result = await texin_dlr(req, resp, _sign(body))
        assert result["received"] is False
        assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_missing_fields_and_unknown_status_rejected(self):
        for payload in ({"message_id": "mid-1"},                        # no status
                        {"status": "delivered"},                        # no message_id
                        {"message_id": "mid-1", "status": "teleported"}):  # unknown
            body = json.dumps(payload).encode()
            req = _texin_request(body, _sign(body))
            with patch("api.routers.sms.settings", _webhook_settings()):
                resp = Response()
                result = await texin_dlr(req, resp, _sign(body))
            assert result["received"] is False
            assert resp.status_code == 400

    @pytest.mark.asyncio
    async def test_duplicate_events_idempotent(self):
        """17. Replaying the same (message_id, status) is acknowledged but
        counted once — no double delivery stats."""
        body = json.dumps({"message_id": "mid-dup",
                           "status": "delivered"}).encode()
        sig = _sign(body)
        with patch("api.routers.sms.settings", _webhook_settings()):
            first = await texin_dlr(_texin_request(body, sig), Response(), sig)
            second = await texin_dlr(_texin_request(body, sig), Response(), sig)
        assert first == {"received": True}
        assert second == {"received": True, "duplicate": True}
        assert get_texin_metrics()["delivered"] == 1

    def test_verify_signature_unit(self):
        body = b'{"message_id": "m", "status": "sent"}'
        good = _sign(body)
        assert verify_texin_signature(body, good, "whsec") is True
        assert verify_texin_signature(body, good, "wrong") is False
        assert verify_texin_signature(body, "sha256=" + "0" * 64, "whsec") is False
        assert verify_texin_signature(body, "", "whsec") is False
        assert verify_texin_signature(body, good, "") is False
        assert verify_texin_signature(b"", good, "whsec") is False

    def test_extract_report_aliases(self):
        assert _extract_texin_report({"messageId": "m", "dlrStatus": "DELIVERED"}) == ("m", "DELIVERED")
        assert _extract_texin_report({"id": "m", "state": "failed"}) == ("m", "failed")
        assert _extract_texin_report({}) == (None, None)
        assert _extract_texin_report([]) == (None, None)


# ── 18. No OTP or API key leakage in logs ────────────────────────────────────

class TestNoSecretLeakage:
    @pytest.mark.asyncio
    async def test_failed_send_logs_neither_key_nor_otp_nor_phone(self, caplog):
        s = _texin_settings(texin_api_key="super-secret-texin-key")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False, "message": "Invalid API key"}, status_code=200
        ))
        with caplog.at_level(logging.ERROR, logger="api.core.sms"), \
             patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            result = await TexinSMS().send("+254706462869", "Your BROKA verification code is 493821")

        assert result is False
        logged = caplog.text
        assert "super-secret-texin-key" not in logged
        assert "493821" not in logged       # OTP text never logged
        assert "254706462869" not in logged  # recipient phone never logged

    @pytest.mark.asyncio
    async def test_http_error_logs_no_secrets(self, caplog):
        s = _texin_settings(texin_api_key="super-secret-texin-key")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"success": False}, status_code=500, text='{"success": false}',
        ))
        with caplog.at_level(logging.ERROR, logger="api.core.sms"), \
             patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            await TexinSMS().send("+254706462869", "Your BROKA verification code is 493821")

        logged = caplog.text
        assert "super-secret-texin-key" not in logged
        assert "493821" not in logged
        assert "254706462869" not in logged

    @pytest.mark.asyncio
    async def test_webhook_logs_no_phone_or_otp(self, caplog):
        body = json.dumps({"message_id": "1303443944556021016",
                           "status": "delivered",
                           "recipient": "+254706462869"}).encode()
        sig = _sign(body)
        with caplog.at_level(logging.INFO, logger="api.routers.sms"), \
             patch("api.routers.sms.settings", _webhook_settings()):
            result = await texin_dlr(_texin_request(body, sig), Response(), sig)
        assert result == {"received": True}
        assert "+254706462869" not in caplog.text
        assert "whsec" not in caplog.text


# ── 19. Africa's Talking fallback (selection + preserved behavior) ──────────

class TestAfricasTalkingFallback:
    def test_selected_when_texin_unset(self):
        s = _settings(at_username="sandbox", at_api_key="atkey")
        with patch("api.core.sms.settings", s):
            assert isinstance(get_sms_provider(), AfricasTalkingSMS)

    @pytest.mark.asyncio
    async def test_still_sends_when_selected(self):
        """The fallback path itself is preserved: an accepted AT message
        still returns True (cost row mocked — no live credit)."""
        s = _settings(at_username="sandbox", at_api_key="atkey")
        fake_client = _FakeAsyncClient(response=_FakeResponse(
            {"SMSMessageData": {"Recipients": [{"status": "Success"}]}}
        ))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client), \
             patch("api.core.cost_ledger.record_sms_cost", new=_ledger_mock()):
            assert await AfricasTalkingSMS().send("+254706462869", "hello") is True


# ── MobitechSMS (DEPRECATED — preserved behavior) ────────────────────────────
# The provider still works for in-flight traffic, but get_sms_provider()
# never selects it — the priority tests above pin that. These tests pin
# that the deprecated implementation itself is unchanged.

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
        assert payload["shortcode"] == "FULL-CIRCLE"
        assert payload["message"] == "hello there"
        assert isinstance(payload["client_ref"], int)
        assert "messages" not in payload
        assert set(payload.keys()) == {"serviceId", "shortcode", "mobile", "message", "client_ref"}

    @pytest.mark.asyncio
    async def test_send_strips_leading_plus_from_phone(self):
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
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(raise_exc=httpx.ConnectError("connection refused"))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is False

    @pytest.mark.asyncio
    async def test_send_handles_malformed_response_defensively(self):
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({}))
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            result = await MobitechSMS().send("+254710986455", "hello there")

        assert result is False


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

        assert result is False
        logged = caplog.text
        assert "http_status=500" in logged
        assert "sms/sendsms" in logged
        assert "application/json" in logged
        assert "trace_id" in logged and "abc123" in logged
        assert "FULL-CIRCLE" in logged
        assert "123456" not in logged
        assert "realkey123" not in logged
        assert "254706462869" not in logged
        assert "<redacted>" in logged

    @pytest.mark.asyncio
    async def test_logs_gracefully_on_non_json_error_body(self, caplog):
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
        s = _settings(mobitech_api_key="key123", mobitech_sender_name="FULL-CIRCLE")
        fake_client = _FakeAsyncClient(response=_FakeResponse({"status_code": "1005"}, status_code=500))
        _mobitech_breaker.reset()
        with patch("api.core.sms.settings", s), \
             patch("api.core.sms.httpx.AsyncClient", return_value=fake_client):
            for _ in range(3):
                await MobitechSMS().send("+254706462869", "hi")

        assert _mobitech_breaker._failure_count == 3
        _mobitech_breaker.reset()


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


# ── DLR webhooks ─────────────────────────────────────────────────────────────

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
