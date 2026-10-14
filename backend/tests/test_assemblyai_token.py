"""
BROKA - /stt/assemblyai-token tests
Run: pytest backend/tests/test_assemblyai_token.py -v

The AssemblyAI half of the same guarantee the Deepgram endpoint makes: the
permanent key never reaches a phone. Same shape of test for the same reason,
plus the three things that are AssemblyAI's own and easy to get wrong by
copying a Deepgram example:

  * it is a GET, not a POST;
  * the Authorization header carries the RAW key - no "Bearer", no "Token";
  * the TTL goes in the query string and is capped at 600 seconds.

AssemblyAI itself is never called. The `httpx` name inside the stt module is
patched, which also lets the "AssemblyAI is down" and "AssemblyAI rejected the
key" branches be exercised.
"""
import uuid

import httpx
import pytest
import pytest_asyncio
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine, AsyncSessionLocal, User
from api.security import create_access_token
from api.routers import stt

FAKE_PERMANENT_KEY = "aai_permanent_key_must_never_be_returned"
FAKE_TEMP_TOKEN = "aai-temp-streaming-token-0000"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    reset_engine()
    mp.setenv("ENV", "test")
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as ac:
        yield ac


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def auth_headers():
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Fallback Voice Tester",
        phone=f"+2547{tag}",
        password_hash="not-a-real-hash",
    )
    async with AsyncSessionLocal() as session:
        session.add(user)
        await session.commit()
        await session.refresh(user)
    token = create_access_token({"sub": user.id})
    return {"Authorization": f"Bearer {token}"}


class _FakeResponse:
    def __init__(self, status_code, payload=None, text=""):
        self.status_code = status_code
        self._payload = payload
        self.text = text

    def json(self):
        if self._payload is None:
            raise ValueError("not json")
        return self._payload


def _patch_assemblyai(monkeypatch, response=None, raises=None, captured=None):
    """Replace the outbound AssemblyAI call, capturing what we sent it.

    Patches the `httpx` name inside the stt module rather than
    httpx.AsyncClient.get globally: the test's own client is an
    httpx.AsyncClient too, so patching the class method would replace the call
    that reaches the app under test.
    """

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def get(self, url, **kwargs):
            if captured is not None:
                captured["url"] = url
                captured["headers"] = kwargs.get("headers", {})
                captured["params"] = kwargs.get("params", {})
            if raises is not None:
                raise raises
            return response

    class _FakeHttpx:
        AsyncClient = _FakeClient
        HTTPError = httpx.HTTPError

    monkeypatch.setattr(stt, "httpx", _FakeHttpx)


# ── Authentication ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_requires_authentication(client, monkeypatch):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)
    resp = await client.post("/stt/assemblyai-token")
    assert resp.status_code in (401, 403)
    assert FAKE_PERMANENT_KEY not in resp.text


@pytest.mark.asyncio
async def test_rejects_a_garbage_token(client, monkeypatch):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)
    resp = await client.post(
        "/stt/assemblyai-token",
        headers={"Authorization": "Bearer not-a-real-token"},
    )
    assert resp.status_code in (401, 403)


# ── Configuration ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_missing_key_is_a_clean_503(client, auth_headers, monkeypatch):
    """No fallback configured is not an error - it is a fallback that is off.

    The app treats 503 as "this provider is unavailable", which is what lets
    the manager fall through to whatever else it has (or to the text composer)
    rather than showing the user a failure.
    """
    monkeypatch.delenv("ASSEMBLYAI_API_KEY", raising=False)
    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_empty_key_is_treated_as_missing(client, auth_headers, monkeypatch):
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", "")
    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 503


# ── The happy path ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_returns_only_the_temporary_token(client, auth_headers, monkeypatch):
    captured = {}
    _patch_assemblyai(
        monkeypatch,
        response=_FakeResponse(
            200, {"token": FAKE_TEMP_TOKEN, "expires_in_seconds": 300}
        ),
        captured=captured,
    )
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()

    assert body["token"] == FAKE_TEMP_TOKEN
    assert body["expires_in_seconds"] == 300
    # The one property this endpoint exists to guarantee.
    assert FAKE_PERMANENT_KEY not in resp.text

    assert captured["url"] == stt.ASSEMBLYAI_TOKEN_URL
    # RAW key. "Bearer <key>" is rejected by AssemblyAI, and it is an easy
    # thing to copy in from another vendor's example.
    assert captured["headers"]["Authorization"] == FAKE_PERMANENT_KEY
    assert not captured["headers"]["Authorization"].lower().startswith("bearer")
    assert (
        captured["params"]["expires_in_seconds"]
        == stt.ASSEMBLYAI_TOKEN_TTL_SECONDS
    )


@pytest.mark.asyncio
async def test_ttl_is_inside_the_documented_range(client, auth_headers):
    """AssemblyAI accepts 1..600 seconds. Outside that, every mint 400s."""
    assert 1 <= stt.ASSEMBLYAI_TOKEN_TTL_SECONDS <= 600


# ── Upstream failures ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_assemblyai_unreachable_becomes_502(client, auth_headers, monkeypatch):
    _patch_assemblyai(monkeypatch, raises=httpx.ConnectError("no route"))
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 502
    assert FAKE_PERMANENT_KEY not in resp.text


@pytest.mark.asyncio
async def test_a_rejected_key_never_echoes_it_back(client, auth_headers, monkeypatch):
    """The point of returning a fixed string on every upstream error.

    An upstream 401 body can quote the credential that was rejected, so the
    endpoint must not pass any of it through - not to the client, and not into
    a log line.
    """
    _patch_assemblyai(
        monkeypatch,
        response=_FakeResponse(
            401,
            {"error": f"invalid api key: {FAKE_PERMANENT_KEY}"},
            text=f"invalid api key: {FAKE_PERMANENT_KEY}",
        ),
    )
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 502
    assert FAKE_PERMANENT_KEY not in resp.text


@pytest.mark.asyncio
async def test_a_non_json_body_is_handled(client, auth_headers, monkeypatch):
    _patch_assemblyai(monkeypatch, response=_FakeResponse(200, None, text="<html>"))
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_a_missing_token_field_is_handled(client, auth_headers, monkeypatch):
    _patch_assemblyai(monkeypatch, response=_FakeResponse(200, {"nope": 1}))
    monkeypatch.setenv("ASSEMBLYAI_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/assemblyai-token", headers=auth_headers)
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_the_whisper_batch_endpoint_is_untouched(client):
    """The two realtime providers are additive - /stt/transcribe still exists.

    It is a different feature (pre-recorded upload, Whisper) and removing it
    to tidy up would quietly break the older voice-note path.
    """
    paths = app.openapi()["paths"]
    assert "/stt/transcribe" in paths
    assert "/stt/deepgram-token" in paths
    assert "/stt/assemblyai-token" in paths
