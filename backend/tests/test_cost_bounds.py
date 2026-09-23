"""Endpoints that spend money per call must be bounded per caller.

  * /stt/deepgram-token, /stt/assemblyai-token and /stt/transcribe each open
    a paid session or make a paid call and had no rate limit at all;
  * chat `history` entries are pasted into billed LLM prompts and were
    unbounded in size, and the buying agent 422'd once a conversation passed
    40 entries because the app never trims its transcript;
  * the degraded-mode AI cache was keyed on the latest message alone, so a
    personalised reply could be served to a different user;
  * POST /negotiate/chat - the handler that actually serves Zeno - took no
    token, no rate limit and no size limit, so anyone could run unlimited
    prompts and images through BROKA's model keys.
"""
import uuid
from unittest.mock import patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from api.core.rate_limit import RateLimiter
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_cost_bounds.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


@pytest_asyncio.fixture
async def headers():
    user = User(name="Payer", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


# ── Zeno chat (/negotiate/chat) ──────────────────────────────────────────────

class TestZenoChatIsBounded:
    """negotiate.free_chat serves this path (see test_route_ordering.py)."""

    @pytest.mark.asyncio
    async def test_it_requires_a_signed_in_user(self, client):
        with patch("api.routers.negotiate._call_ai") as ai:
            r = await client.post("/negotiate/chat", json={"content": "hi"})
        assert r.status_code == 401
        ai.assert_not_called()

    @pytest.mark.asyncio
    async def test_a_non_access_token_is_refused(self, client):
        from api.security import create_refresh_token
        refresh, _, _ = create_refresh_token("someone")
        with patch("api.routers.negotiate._call_ai") as ai:
            r = await client.post("/negotiate/chat", json={"content": "hi"},
                                  headers={"Authorization": f"Bearer {refresh}"})
        assert r.status_code == 401
        ai.assert_not_called()

    @pytest.mark.asyncio
    async def test_it_is_limited_per_user(self, client, headers):
        strict = RateLimiter("zeno_chat_test", limit=2, window_seconds=60)

        async def fake_ai(*a, **kw):
            return "ok"

        with patch("api.core.rate_limit.zeno_chat_limiter", strict), \
             patch("api.routers.negotiate._call_ai", fake_ai):
            codes = [(await client.post("/negotiate/chat", json={"content": "hi"},
                                        headers=headers)).status_code for _ in range(3)]
        assert codes == [200, 200, 429]

    @pytest.mark.asyncio
    @pytest.mark.parametrize("body", [
        {"content": "x" * 8_001},
        {"content": "hi", "image_base64": "A" * ((10 * 1024 * 1024 * 4) // 3 + 5)},
        {"content": "hi", "history": [{"role": "user", "content": "x"}] * 101},
    ], ids=["content", "image", "history_length"])
    async def test_oversized_requests_never_reach_the_model(self, client, headers, body):
        with patch("api.routers.negotiate._call_ai") as ai:
            r = await client.post("/negotiate/chat", json=body, headers=headers)
        assert r.status_code == 422
        ai.assert_not_called()

    @pytest.mark.asyncio
    async def test_the_product_verdict_prompt_still_fits(self, client, headers):
        """The largest prompt the app builds (product_screen.dart) is ~3,000
        characters with a listing photo attached."""
        async def fake_ai(*a, **kw):
            return "verdict"

        with patch("api.routers.negotiate._call_ai", fake_ai):
            r = await client.post("/negotiate/chat", headers=headers, json={
                "content": "p" * 4_000, "image_base64": "A" * 600_000,
                "system_override": "zeno", "language": "english",
            })
        assert r.status_code == 200
        assert r.json()["content"] == "verdict"

    @pytest.mark.asyncio
    async def test_history_is_trimmed_and_clipped_before_the_model(self, client, headers):
        seen = {}

        async def fake_ai(system, messages, image_base64=None, **kw):
            seen["messages"] = messages
            return "ok"

        history = [{"role": "user", "content": f"{i}" + "y" * 5_000} for i in range(30)]
        with patch("api.routers.negotiate._call_ai", fake_ai):
            r = await client.post("/negotiate/chat", headers=headers,
                                  json={"content": "latest", "history": history})
        assert r.status_code == 200
        sent = seen["messages"]
        assert len(sent) == 21                      # newest 20 + the new message
        assert sent[0]["content"].startswith("10")  # the oldest ten were dropped
        assert all(len(m["content"]) <= 2_000 for m in sent[:-1])
        assert sent[-1] == {"role": "user", "content": "latest"}


# ── Speech-to-text ───────────────────────────────────────────────────────────

class TestSttIsRateLimited:
    @pytest.mark.asyncio
    @pytest.mark.parametrize("path", ["/stt/deepgram-token", "/stt/assemblyai-token"])
    async def test_token_minting_is_limited_per_user(self, client, headers, monkeypatch, path):
        monkeypatch.delenv("DEEPGRAM_API_KEY", raising=False)
        monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
        strict = RateLimiter("stt_token_test", limit=2, window_seconds=60)
        with patch("api.routers.stt.stt_token_limiter", strict):
            codes = [(await client.post(path, headers=headers)).status_code for _ in range(3)]
        # Unconfigured -> 503 for the allowed calls; the limiter runs first,
        # so the third is refused before anything else happens.
        assert codes == [503, 503, 429]

    @pytest.mark.asyncio
    async def test_the_two_vendors_share_one_budget(self, client, headers, monkeypatch):
        """A failover mints from the second vendor; together they still
        count as one user's voice sessions."""
        monkeypatch.delenv("DEEPGRAM_API_KEY", raising=False)
        monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
        strict = RateLimiter("stt_token_shared", limit=2, window_seconds=60)
        with patch("api.routers.stt.stt_token_limiter", strict):
            a = await client.post("/stt/deepgram-token", headers=headers)
            b = await client.post("/stt/assemblyai-token", headers=headers)
            c = await client.post("/stt/deepgram-token", headers=headers)
        assert (a.status_code, b.status_code, c.status_code) == (503, 503, 429)

    @pytest.mark.asyncio
    async def test_transcribe_is_limited_per_user(self, client, headers):
        strict = RateLimiter("stt_transcribe_test", limit=1, window_seconds=60)
        files = {"file": ("a.m4a", b"\x00" * 16, "audio/m4a")}
        with patch("api.routers.stt.stt_transcribe_limiter", strict):
            first = await client.post("/stt/transcribe", headers=headers, files=files)
            second = await client.post("/stt/transcribe", headers=headers, files=files)
        assert first.status_code != 429
        assert second.status_code == 429


# ── Prompt bounds ────────────────────────────────────────────────────────────

class TestConverseHistory:
    @pytest.mark.asyncio
    async def test_a_long_conversation_is_trimmed_not_rejected(self, client, headers):
        captured = {}

        async def fake_converse(**kwargs):
            captured.update(kwargs)
            return {"phase": "ASKING", "reply": "ok"}

        history = [
            {"role": "user" if i % 2 == 0 else "assistant", "content": f"turn {i} " + "x" * 50_000}
            for i in range(61)
        ]
        with patch("api.domains.buy_agent.router.conversation.converse", fake_converse):
            r = await client.post(
                "/buy-agent-requests/converse", headers=headers,
                json={"message": "a phone", "history": history},
            )
        assert r.status_code == 200, r.text
        sent = captured["history"]
        assert len(sent) == 40
        assert sent[-1]["content"].startswith("turn 60 ")  # the NEWEST turns are kept
        assert all(len(h["content"]) <= 2000 for h in sent)
        assert {h["role"] for h in sent} <= {"user", "assistant"}

    @pytest.mark.asyncio
    async def test_malformed_entries_are_dropped(self, client, headers):
        captured = {}

        async def fake_converse(**kwargs):
            captured.update(kwargs)
            return {"phase": "ASKING", "reply": "ok"}

        with patch("api.domains.buy_agent.router.conversation.converse", fake_converse):
            r = await client.post(
                "/buy-agent-requests/converse", headers=headers,
                json={"message": "a phone", "history": ["junk", {"role": "user", "content": None}, 7]},
            )
        assert r.status_code == 200, r.text
        assert captured["history"] == [{"role": "user", "content": ""}]


class TestPromptBuilding:
    def test_history_entries_and_the_client_message_are_clipped(self):
        from api.domains.ai_broker.service import AIBrokerService, _clip

        svc = AIBrokerService()
        messages = svc._build_messages(
            "SYSTEM", [{"role": "user", "content": "y" * 100_000}], _clip("z" * 100_000, 4000),
        )
        assert messages[0]["content"] == "SYSTEM"
        assert len(messages[1]["content"]) == 2000
        assert len(messages[-1]["content"]) == 4000

    def test_a_server_built_prompt_is_not_clipped(self):
        """shopping_advisor's prompt carries the listing shortlist."""
        from api.domains.ai_broker.service import AIBrokerService

        long_prompt = "Shortlist:\n" + "\n".join(f"- item {i}" for i in range(2000))
        messages = AIBrokerService()._build_messages("S", [], long_prompt)
        assert messages[-1]["content"] == long_prompt

    @pytest.mark.asyncio
    async def test_broker_chat_clips_what_the_client_sent(self):
        from api.domains.ai_broker.service import AIBrokerService

        seen = {}

        async def fake_call(self, messages, cache_key=None):
            seen["messages"] = messages
            return "reply"

        with patch.object(AIBrokerService, "_call_ai", fake_call):
            await AIBrokerService().broker_chat(content="q" * 50_000, history=[])
        assert len(seen["messages"][-1]["content"]) == 4000


class TestDegradedCacheKey:
    def test_personalised_prompts_never_share_a_key(self):
        from api.domains.ai_broker.service import _cache_key

        a = [{"role": "user", "content": "SYS\nThe user's name is Wanjiru."}, {"role": "user", "content": "hi"}]
        b = [{"role": "user", "content": "SYS\nThe user's name is Otieno."}, {"role": "user", "content": "hi"}]
        assert _cache_key("chat", a) != _cache_key("chat", b)

    def test_the_key_is_stable_across_processes(self):
        """sha256, not hash(): the same prompt must map to the same Redis key
        in every worker, or the shared cache never hits."""
        from api.domains.ai_broker.service import _cache_key

        m = [{"role": "user", "content": "hello"}]
        assert _cache_key("chat", m) == (
            "chat:" + __import__("hashlib").sha256(
                b'[{"content": "hello", "role": "user"}]'
            ).hexdigest()
        )
