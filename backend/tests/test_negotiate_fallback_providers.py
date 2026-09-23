"""The text-only fallback providers in routers/negotiate.py must actually run.

A copy of DeepSeek's image-attachment block had been pasted into _call_groq
and _call_openrouter, referencing an `image_base64` neither function takes.
Every call raised NameError before any request was sent; the fallback chain
caught it as an "unexpected error" and moved on, so neither provider ever
answered - Zeno chat failed outright whenever Gemini and DeepSeek were both
unavailable, and the cheap-tier Groq route never worked at all.
"""
import pytest

import api.routers.negotiate as negotiate


class _Resp:
    status_code = 200
    text = ""

    @staticmethod
    def json():
        return {"choices": [{"message": {"content": "  hello from the fallback  "}}]}


class _Client:
    sent: list = []

    def __init__(self, *a, **kw):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, url, **kwargs):
        _Client.sent.append(kwargs["json"])
        return _Resp()


@pytest.fixture(autouse=True)
def _fake_http(monkeypatch):
    _Client.sent = []
    monkeypatch.setattr(negotiate.httpx, "AsyncClient", _Client)
    monkeypatch.setattr(negotiate, "GROQ_API_KEY", "gk")
    monkeypatch.setattr(negotiate, "OPENROUTER_API_KEY", "ok")


@pytest.mark.asyncio
@pytest.mark.parametrize("call", ["_call_groq", "_call_openrouter"])
async def test_text_only_fallback_answers(call):
    reply = await getattr(negotiate, call)(
        "SYSTEM", [{"role": "user", "content": "is this still available?"}],
    )
    assert reply == "hello from the fallback"
    body = _Client.sent[-1]
    # Plain text content only - these models are text-only.
    assert all(isinstance(m["content"], str) for m in body["messages"])
