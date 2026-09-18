"""
BROKA - /stt/deepgram-token tests
Run: pytest backend/tests/test_deepgram_token.py -v

This endpoint exists so the permanent Deepgram key never reaches a phone. The
tests below are mostly about that one property: an unauthenticated caller gets
nothing, a configured server returns only the short-lived token, and none of
the failure paths leak the key - not in the response body, and not through an
upstream error body echoed back to the client.

Deepgram itself is never called. httpx.AsyncClient.post is patched, which also
lets the "Deepgram is down" and "Deepgram rejected the key" branches be
exercised, neither of which is reachable against the real service without
deliberately breaking the account.
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

FAKE_PERMANENT_KEY = "dg_permanent_key_must_never_be_returned"
FAKE_TEMP_TOKEN = "eyJhbGciOi.fake.temporary.jwt"


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
    """A real user row plus a real access token, same as the other suites."""
    tag = uuid.uuid4().hex[:10]
    user = User(name="Voice Tester", phone=f"+2547{tag}", password_hash="not-a-real-hash")
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


def _patch_deepgram(monkeypatch, response=None, raises=None, captured=None):
    """Replace the outbound Deepgram call, capturing what we sent it.

    Patches the `httpx` name inside the stt module rather than
    httpx.AsyncClient.post globally: the test's own client is an
    httpx.AsyncClient too, so patching the class method replaces the call that
    reaches the app under test and every assertion below then inspects the
    stub instead of the endpoint.
    """

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def post(self, url, **kwargs):
            if captured is not None:
                captured["url"] = url
                captured["headers"] = kwargs.get("headers", {})
                captured["json"] = kwargs.get("json", {})
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
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)
    resp = await client.post("/stt/deepgram-token")
    assert resp.status_code in (401, 403)
    assert FAKE_PERMANENT_KEY not in resp.text


@pytest.mark.asyncio
async def test_rejects_a_garbage_token(client, monkeypatch):
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)
    resp = await client.post(
        "/stt/deepgram-token", headers={"Authorization": "Bearer not-a-real-token"}
    )
    assert resp.status_code in (401, 403)


# ── Configuration ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_missing_key_is_a_clean_503(client, auth_headers, monkeypatch):
    """Unset key must be a clear, actionable 503 - not a 500 traceback.

    The app treats this specific status as "voice is off, keep the text
    composer", so it has to stay distinguishable from a transient failure.
    """
    monkeypatch.delenv("DEEPGRAM_API_KEY", raising=False)
    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 503
    assert "not configured" in resp.json()["detail"].lower()


@pytest.mark.asyncio
async def test_empty_key_is_treated_as_missing(client, auth_headers, monkeypatch):
    monkeypatch.setenv("DEEPGRAM_API_KEY", "")
    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 503


# ── The happy path ───────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_returns_only_the_temporary_token(client, auth_headers, monkeypatch):
    captured = {}
    _patch_deepgram(
        monkeypatch,
        response=_FakeResponse(
            200, {"access_token": FAKE_TEMP_TOKEN, "expires_in": 300}
        ),
        captured=captured,
    )
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 200
    body = resp.json()

    assert body["access_token"] == FAKE_TEMP_TOKEN
    assert body["expires_in"] == 300
    # The one property this endpoint exists to guarantee.
    assert FAKE_PERMANENT_KEY not in resp.text

    # And the permanent key went UP to Deepgram under the Token scheme.
    assert captured["url"] == stt.DEEPGRAM_GRANT_URL
    assert captured["headers"]["Authorization"] == f"Token {FAKE_PERMANENT_KEY}"
    assert captured["json"]["ttl_seconds"] == stt.DEEPGRAM_TOKEN_TTL_SECONDS


@pytest.mark.asyncio
async def test_ttl_is_short_lived(client, auth_headers, monkeypatch):
    """A token that outlives its handshake is a credential, not a handshake.

    Deepgram caps TTL at 3600s; asking for anywhere near that would mean
    minting something worth stealing for a socket that opens in under a second.
    """
    assert 0 < stt.DEEPGRAM_TOKEN_TTL_SECONDS <= 600


# ── Upstream failures ────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_deepgram_unreachable_becomes_502(client, auth_headers, monkeypatch):
    _patch_deepgram(monkeypatch, raises=httpx.ConnectError("no route to host"))
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 502
    assert FAKE_PERMANENT_KEY not in resp.text


@pytest.mark.asyncio
async def test_deepgram_rejection_does_not_echo_its_body(
    client, auth_headers, monkeypatch
):
    """A 401 from Deepgram often quotes the credential it rejected.

    Forwarding resp.text to the client would put the permanent key in a
    response body, which is the exact leak this endpoint prevents.
    """
    leaky_body = f"Invalid credentials: {FAKE_PERMANENT_KEY}"
    _patch_deepgram(
        monkeypatch, response=_FakeResponse(401, {"err": leaky_body}, text=leaky_body)
    )
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 502
    assert FAKE_PERMANENT_KEY not in resp.text
    assert "Invalid credentials" not in resp.text


@pytest.mark.asyncio
async def test_non_json_upstream_body_is_handled(client, auth_headers, monkeypatch):
    _patch_deepgram(monkeypatch, response=_FakeResponse(200, None, text="<html>502</html>"))
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_missing_access_token_in_upstream_body_is_handled(
    client, auth_headers, monkeypatch
):
    """A 200 with the wrong shape must not become a 200 with no token.

    The app would otherwise open a WebSocket with an empty Authorization
    header and sit on "Connecting..." until it timed out.
    """
    _patch_deepgram(monkeypatch, response=_FakeResponse(200, {"expires_in": 300}))
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 502


@pytest.mark.asyncio
async def test_expires_in_defaults_when_upstream_omits_it(
    client, auth_headers, monkeypatch
):
    _patch_deepgram(
        monkeypatch, response=_FakeResponse(200, {"access_token": FAKE_TEMP_TOKEN})
    )
    monkeypatch.setenv("DEEPGRAM_API_KEY", FAKE_PERMANENT_KEY)

    resp = await client.post("/stt/deepgram-token", headers=auth_headers)
    assert resp.status_code == 200
    assert resp.json()["expires_in"] == stt.DEEPGRAM_TOKEN_TTL_SECONDS
