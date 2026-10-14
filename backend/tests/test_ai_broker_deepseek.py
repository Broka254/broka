"""
Tests for DeepSeek V4 Flash - DIRECT API integration in the AI broker
(api/domains/ai_broker/service.py).

All HTTP calls are mocked - this file never makes a real DeepSeek API
call and never requires a real DEEPSEEK_API_KEY to run.
"""
import pytest
import httpx
from unittest.mock import AsyncMock, patch

from api.domains.ai_broker.service import AIBrokerService
from api.core.circuit_breaker import deepseek_breaker


def _fake_response(status_code: int, json_data: dict | None = None, text: str | None = None) -> httpx.Response:
    """A real httpx.Response (not a hand-rolled fake) so .raise_for_status()
    behaves exactly like it would against a real DeepSeek reply."""
    request = httpx.Request("POST", "https://api.deepseek.com/chat/completions")
    if json_data is not None:
        return httpx.Response(status_code, json=json_data, request=request)
    return httpx.Response(status_code, text=text if text is not None else "", request=request)


def _mock_async_client(post_return=None, post_side_effect=None):
    """Builds a mock supporting `async with httpx.AsyncClient(...) as c: await c.post(...)`."""
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
    """deepseek_breaker is a module-level singleton shared across the whole
    test session - reset before/after each test so one test's induced
    failures can't leak into another as an unexpectedly-open breaker."""
    deepseek_breaker.reset()
    yield
    deepseek_breaker.reset()


class TestDeepSeekDirectCall:
    """_call_deepseek itself - the actual HTTP request/response handling."""

    @pytest.fixture
    def svc(self):
        s = AIBrokerService()
        s.deepseek_key = "fake-deepseek-key-for-tests"
        return s

    @pytest.mark.asyncio
    async def test_successful_response(self, svc):
        resp = _fake_response(200, {"choices": [{"message": {"content": "Hello from DeepSeek!"}}]})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            result = await svc._call_deepseek([{"role": "user", "content": "hi"}])
        assert result == "Hello from DeepSeek!"

    @pytest.mark.asyncio
    async def test_missing_api_key(self):
        svc = AIBrokerService()
        svc.deepseek_key = ""
        with pytest.raises(ValueError, match="DEEPSEEK_API_KEY"):
            await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_timeout(self, svc):
        cm, _ = _mock_async_client(post_side_effect=httpx.TimeoutException("timed out"))
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.TimeoutException):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_connection_error(self, svc):
        cm, _ = _mock_async_client(post_side_effect=httpx.ConnectError("connection refused"))
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.ConnectError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_401(self, svc):
        resp = _fake_response(401, {"error": "invalid api key"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.HTTPStatusError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_403(self, svc):
        resp = _fake_response(403, {"error": "forbidden"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.HTTPStatusError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_429(self, svc):
        resp = _fake_response(429, {"error": "rate limited"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.HTTPStatusError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_http_500(self, svc):
        resp = _fake_response(500, text="internal server error")
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(httpx.HTTPStatusError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_malformed_json(self, svc):
        resp = _fake_response(200, text="not json at all {{{")
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_missing_choices(self, svc):
        resp = _fake_response(200, {"not_choices": []})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError, match="missing"):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_empty_choices(self, svc):
        resp = _fake_response(200, {"choices": []})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError, match="missing"):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_missing_message(self, svc):
        resp = _fake_response(200, {"choices": [{}]})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError, match="missing"):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_missing_content(self, svc):
        resp = _fake_response(200, {"choices": [{"message": {}}]})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with pytest.raises(ValueError, match="missing"):
                await svc._call_deepseek([{"role": "user", "content": "hi"}])

    @pytest.mark.asyncio
    async def test_never_logs_api_key(self, svc, caplog):
        import logging
        resp = _fake_response(401, {"error": "bad key"})
        cm, _ = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            with caplog.at_level(logging.WARNING):
                with pytest.raises(httpx.HTTPStatusError):
                    await svc._call_deepseek([{"role": "user", "content": "hi"}])
        assert svc.deepseek_key not in caplog.text

    @pytest.mark.asyncio
    async def test_request_shape_matches_deepseek_contract(self, svc):
        """Verifies the exact endpoint, model, auth header, and non-thinking
        mode the task requires - the actual API contract, not just that
        *some* request was made."""
        resp = _fake_response(200, {"choices": [{"message": {"content": "ok"}}]})
        cm, mock_client = _mock_async_client(post_return=resp)
        with patch("httpx.AsyncClient", return_value=cm):
            await svc._call_deepseek([{"role": "user", "content": "hi"}])
        call = mock_client.post.call_args
        assert call.args[0] == "https://api.deepseek.com/chat/completions"
        assert call.kwargs["headers"]["Authorization"] == "Bearer fake-deepseek-key-for-tests"
        assert call.kwargs["headers"]["Content-Type"] == "application/json"
        assert call.kwargs["json"]["model"] == "deepseek-flash"
        assert call.kwargs["json"]["stream"] is False
        assert call.kwargs["json"]["thinking"] == {"type": "disabled"}


class TestFallbackOrchestration:
    """_call_ai's fallback chain ordering/behavior with DeepSeek inserted -
    mocks at the _call_XXX method level, matching test_ai_broker_v4.py's
    existing convention for testing orchestration separately from any one
    provider's own HTTP details."""

    @pytest.fixture
    def svc(self):
        return AIBrokerService()

    @pytest.mark.asyncio
    async def test_gemini_to_deepseek_to_nemotron_ordering(self, svc):
        """DeepSeek is used - not skipped - when Gemini is unavailable,
        and is tried before OpenRouter/Nemotron."""
        svc.gemini_key = ""
        svc.deepseek_key = "fake"
        svc.openrouter_key = "fake"
        with patch.object(svc, "_call_deepseek", AsyncMock(return_value="DeepSeek says hi")), \
             patch.object(svc, "_call_openrouter", AsyncMock(return_value="Nemotron says hi")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "DeepSeek says hi"

    @pytest.mark.asyncio
    async def test_falls_back_to_nemotron_on_deepseek_failure(self, svc):
        svc.gemini_key = ""
        svc.deepseek_key = "fake"
        svc.openrouter_key = "fake"
        with patch.object(svc, "_call_deepseek", AsyncMock(side_effect=ValueError("DeepSeek auth failed"))), \
             patch.object(svc, "_call_openrouter", AsyncMock(return_value="Nemotron says hi")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "Nemotron says hi"

    @pytest.mark.asyncio
    async def test_missing_deepseek_key_is_not_fatal(self, svc):
        """DEEPSEEK_API_KEY missing must not be treated as an error - it
        should be skipped entirely, continuing straight to OpenRouter."""
        svc.gemini_key = ""
        svc.deepseek_key = ""  # not configured
        svc.openrouter_key = "fake"
        with patch.object(svc, "_call_deepseek", AsyncMock(side_effect=AssertionError("must not be called when key is missing"))), \
             patch.object(svc, "_call_openrouter", AsyncMock(return_value="Nemotron says hi")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "Nemotron says hi"

    @pytest.mark.asyncio
    async def test_gemini_still_tried_first(self, svc):
        """Adding DeepSeek doesn't change Gemini's priority as the primary provider."""
        svc.gemini_key = "fake"
        svc.deepseek_key = "fake"
        with patch.object(svc, "_call_gemini", AsyncMock(return_value="Gemini says hi")), \
             patch.object(svc, "_call_deepseek", AsyncMock(side_effect=AssertionError("must not be called when Gemini succeeds"))):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "Gemini says hi"

    @pytest.mark.asyncio
    async def test_existing_openrouter_nemotron_path_still_works(self, svc):
        svc.gemini_key = ""
        svc.deepseek_key = ""
        svc.openrouter_key = "fake"
        with patch.object(svc, "_call_openrouter", AsyncMock(return_value="Nemotron says hi")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "Nemotron says hi"

    @pytest.mark.asyncio
    async def test_existing_groq_fallback_still_works(self, svc):
        svc.gemini_key = ""
        svc.deepseek_key = ""
        svc.openrouter_key = ""
        svc.groq_key = "fake"
        with patch.object(svc, "_call_groq", AsyncMock(return_value="Groq says hi")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}])
        assert result == "Groq says hi"

    @pytest.mark.asyncio
    async def test_existing_cache_fallback_still_works(self, svc):
        """Total-failure cache fallback (degraded mode) is unaffected by
        DeepSeek's presence in the chain."""
        svc.gemini_key = ""
        svc.deepseek_key = ""
        svc.openrouter_key = ""
        svc.groq_key = ""
        with patch("api.domains.ai_broker.service._cache_get", AsyncMock(return_value="cached reply")):
            result = await svc._call_ai([{"role": "user", "content": "hi"}], cache_key="k")
        assert "cached reply" in result

    @pytest.mark.asyncio
    async def test_503_when_everything_fails(self, svc):
        from fastapi import HTTPException
        svc.gemini_key = ""
        svc.deepseek_key = "fake"
        svc.openrouter_key = ""
        svc.groq_key = ""
        with patch.object(svc, "_call_deepseek", AsyncMock(side_effect=ValueError("down"))), \
             patch("api.domains.ai_broker.service._cache_get", AsyncMock(return_value=None)):
            with pytest.raises(HTTPException) as exc:
                await svc._call_ai([{"role": "user", "content": "hi"}], cache_key="k")
        assert exc.value.status_code == 503

    def test_circuit_stats_includes_deepseek(self, svc):
        stats = svc.circuit_stats()
        assert "deepseek" in stats
        assert "gemini" in stats and "openrouter" in stats and "groq" in stats
