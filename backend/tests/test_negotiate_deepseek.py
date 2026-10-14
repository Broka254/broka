"""
Tests for DeepSeek V4 Flash in api/routers/negotiate.py's own (separate
from ai_broker/service.py) AI-provider fallback chain.

negotiate.py has no existing dedicated test file for its AI-provider logic
- this is scoped to the new DeepSeek behavior specifically, mirroring the
patterns already established in test_ai_broker_deepseek.py, rather than
writing a full test suite for a previously-untested module.

All HTTP calls are mocked - never makes a real DeepSeek API call, never
requires a real DEEPSEEK_API_KEY.
"""
import pytest
import httpx
from unittest.mock import AsyncMock, patch

import api.routers.negotiate as negotiate
from api.core.circuit_breaker import deepseek_breaker


def _fake_response(status_code: int, json_data: dict | None = None, text: str | None = None) -> httpx.Response:
    request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
    if json_data is not None:
        return httpx.Response(status_code, json=json_data, request=request)
    return httpx.Response(status_code, text=text if text is not None else "", request=request)


def _mock_async_client(post_return=None, post_side_effect=None):
    mock_client = AsyncMock()
    if post_side_effect is not None:
        mock_client.post = AsyncMock(side_effect=post_side_effect)
    else:
        mock_client.post = AsyncMock(return_value=post_return)
    mock_cm = AsyncMock()
    mock_cm.__aenter__ = AsyncMock(return_value=mock_client)
    mock_cm.__aexit__ = AsyncMock(return_value=False)
    return mock_cm, mock_client


@pytest.fixture(autouse=True)
def reset_breaker():
    deepseek_breaker.reset()
    yield
    deepseek_breaker.reset()


@pytest.fixture(autouse=True)
def fake_deepseek_key(monkeypatch):
    """negotiate.py reads its config as module-level constants captured at
    import time, not a live settings object - patch the module attribute
    directly rather than the environment variable, which would be too late."""
    monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "fake-deepseek-key-for-tests")
    yield


class TestNegotiateDeepSeekDirectCall:
    @pytest.mark.asyncio
    async def test_successful_response(self):
        resp = _fake_response(200, {"choices": [{"message": {"content": "Hello from DeepSeek!"}}]})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            result = await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])
        assert result == "Hello from DeepSeek!"

    @pytest.mark.asyncio
    async def test_missing_api_key(self, monkeypatch):
        monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "")
        with pytest.raises(ValueError, match="DEEPSEEK_API_KEY"):
            await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_timeout(self):
        cm, _ = _mock_async_client(post_side_effect=httpx.TimeoutException("timed out"))
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.TimeoutException):
                await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_401_raises_value_error(self):
        """This file's other _call_XXX functions signal failure via
        ValueError (not letting HTTPStatusError propagate) - matching that
        convention here too."""
        resp = _fake_response(401, {"error": "invalid api key"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError):
                await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_429_raises_value_error(self):
        resp = _fake_response(429, {"error": "rate limited"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError):
                await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_500_raises_value_error(self):
        resp = _fake_response(500, text="internal server error")
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError):
                await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_malformed_response_raises_value_error(self):
        resp = _fake_response(200, {"choices": [{"message": {}}]})  # missing content
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError):
                await negotiate._call_deepseek("system prompt", [{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_request_shape_matches_deepseek_contract(self):
        resp = _fake_response(200, {"choices": [{"message": {"content": "ok"}}]})
        cm, mock_client = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            await negotiate._call_deepseek("You are Zeno.", [{"role": "user", "content": "hi"}])
        call = mock_client.post.call_args
        assert call.args[0] == "https://api.deepseek.com/chat/completions"
        assert call.kwargs["headers"]["Authorization"] == "Bearer fake-deepseek-key-for-tests"
        assert call.kwargs["json"]["model"] == "deepseek-flash"
        assert call.kwargs["json"]["stream"] is False
        assert call.kwargs["json"]["thinking"] == {"type": "disabled"}
        assert call.kwargs["json"]["messages"][0] == {"role": "system", "content": "You are Zeno."}


class TestNegotiateFallbackOrdering:
    @pytest.mark.asyncio
    async def test_deepseek_tried_before_openrouter(self, monkeypatch):
        monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "")
        monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "fake")
        with patch.object(negotiate, "_call_deepseek", AsyncMock(return_value="DeepSeek reply")), \
             patch.object(negotiate, "_call_openrouter", AsyncMock(return_value="Nemotron reply")):
            result = await negotiate._call_ai("system", [{"role": "user", "content": "hi"}])
        assert result == "DeepSeek reply"

    @pytest.mark.asyncio
    async def test_falls_back_to_nemotron_on_deepseek_failure(self, monkeypatch):
        monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "")
        monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "fake")
        with patch.object(negotiate, "_call_deepseek", AsyncMock(side_effect=ValueError("DeepSeek down"))), \
             patch.object(negotiate, "_call_openrouter", AsyncMock(return_value="Nemotron reply")):
            result = await negotiate._call_ai("system", [{"role": "user", "content": "hi"}])
        assert result == "Nemotron reply"

    @pytest.mark.asyncio
    async def test_missing_key_skips_to_openrouter(self, monkeypatch):
        monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "")
        monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "")
        monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "fake")
        with patch.object(negotiate, "_call_deepseek", AsyncMock(side_effect=AssertionError("must not be called"))), \
             patch.object(negotiate, "_call_openrouter", AsyncMock(return_value="Nemotron reply")):
            result = await negotiate._call_ai("system", [{"role": "user", "content": "hi"}])
        assert result == "Nemotron reply"

    @pytest.mark.asyncio
    async def test_existing_openrouter_path_still_works(self, monkeypatch):
        monkeypatch.setattr(negotiate, "GEMINI_API_KEY", "")
        monkeypatch.setattr(negotiate, "DEEPSEEK_API_KEY", "")
        monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "fake")
        with patch.object(negotiate, "_call_openrouter", AsyncMock(return_value="Nemotron reply")):
            result = await negotiate._call_ai("system", [{"role": "user", "content": "hi"}])
        assert result == "Nemotron reply"
