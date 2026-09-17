"""Tests for AI broker with circuit breaker integration (v4.0)."""
import json
import pytest
from unittest.mock import AsyncMock, patch
from api.core.circuit_breaker import CircuitBreaker, CircuitOpenError
from api.domains.ai_broker.service import AIBrokerService

class TestAIBrokerService:
    @pytest.fixture
    def svc(self): return AIBrokerService()

    @pytest.mark.asyncio
    async def test_broker_chat(self, svc):
        with patch.object(svc, "_call_ai", AsyncMock(return_value="Fair price KES 5,000.")):
            r = await svc.broker_chat("What's a fair price?", [])
        assert r["role"] == "broker"

    @pytest.mark.asyncio
    async def test_detect_scam_parses_json(self, svc):
        resp = json.dumps({"risk_level": "high", "flags": ["off-platform"], "recommendation": "Stop."})
        with patch.object(svc, "_call_ai", AsyncMock(return_value=resp)):
            r = await svc.detect_scam("Send to my mpesa directly")
        assert r["risk_level"] == "high"

    @pytest.mark.asyncio
    async def test_detect_scam_handles_bad_json(self, svc):
        with patch.object(svc, "_call_ai", AsyncMock(return_value="Looks suspicious.")):
            r = await svc.detect_scam("msg")
        assert r["risk_level"] == "unknown"

    @pytest.mark.asyncio
    async def test_dispute_release_verdict(self, svc):
        raw = "ASSESSMENT: ok.\nVERDICT: release\nREASONING: ok.\nFRAUD_FLAGS: none"
        with patch.object(svc, "_call_ai", AsyncMock(return_value=raw)):
            r = await svc.dispute_analysis("not delivered", "I delivered", 5000, "Blender")
        assert r["recommended_resolution"] == "release"

    @pytest.mark.asyncio
    async def test_503_when_all_fail(self, svc):
        from fastapi import HTTPException
        svc.gemini_key = "fake"; svc.groq_key = "fake"
        async def fail(*a, **k): raise ConnectionError("down")
        with patch.object(svc, "_call_gemini", fail), \
             patch.object(svc, "_call_groq", fail), \
             patch("api.domains.ai_broker.service._cache_get", AsyncMock(return_value=None)):
            with pytest.raises(HTTPException) as exc:
                await svc._call_ai([{"role": "user", "content": "hi"}], cache_key="k")
        assert exc.value.status_code == 503

    def test_circuit_stats_keys(self, svc):
        s = svc.circuit_stats()
        assert "gemini" in s and "deepseek" in s and "groq" in s
