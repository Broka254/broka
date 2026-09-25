"""Who is really calling: api/core/client_ip.py, and what depends on it.

Per-IP rate limits (login, signup, OTP) and store visit counting key on the
caller's address. Behind Render the TCP peer is Render's proxy, shared by
every user, so keying on it made each limit one bucket for the whole
platform. And the store visit counter used to limit anonymous callers by a
visitor id they chose themselves, so a new id per request was never limited
and every request counted as a new visitor.

  * resolution  - storefront header only with the shared key; the edge
                  header; X-Forwarded-For counted from the right; the peer;
                  malformed values never trusted
  * limits      - login is limited per real caller, not per proxy
  * counting    - a script inventing visitor ids is limited and capped;
                  real visitors from different addresses are all counted;
                  the storefront's forwarded visitors count separately
  * diagnostics - admin only, and shows what was resolved and why
"""
import dataclasses
import itertools
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from starlette.requests import Request

from api.core import client_ip as client_ip_module
from api.core.client_ip import resolve
from api.core.config import settings
from api.core.rate_limit import RateLimiter
from api.database import AccountType, AsyncSessionLocal, SellerTier, User, init_db, reset_engine
from api.domains.stores import router as stores_router_module
from api.domains.stores import stats as store_stats
from api.security import create_access_token
from main import app

KEY = "s" * 40
BROWSER = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/129 Mobile Safari/537.36"


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_client_ip.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
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


@pytest.fixture(autouse=True)
def _forget_visitors():
    store_stats.seen.clear()
    yield
    store_stats.seen.clear()


def _configure(monkeypatch, **changes):
    monkeypatch.setattr(client_ip_module, "settings", dataclasses.replace(settings, **changes))


def _request(headers: dict, peer: str = "10.226.90.65") -> Request:
    scope = {
        "type": "http", "method": "GET", "path": "/", "query_string": b"",
        "headers": [(k.lower().encode(), v.encode()) for k, v in headers.items()],
        "client": (peer, 40000), "server": ("test", 80), "scheme": "http",
    }
    return Request(scope)


# ── Resolution ────────────────────────────────────────────────────────────────

class TestResolution:
    def test_the_peer_when_nothing_is_configured(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="", trusted_proxy_hops=0, storefront_api_key="")
        assert resolve(_request({"cf-connecting-ip": "41.90.1.2", "x-forwarded-for": "1.1.1.1"})) == (
            "10.226.90.65", "peer")

    def test_the_edge_header_when_configured(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip", trusted_proxy_hops=0)
        assert resolve(_request({"cf-connecting-ip": "41.90.1.2"})) == ("41.90.1.2", "header")

    def test_a_malformed_edge_header_falls_back_to_the_peer(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip", trusted_proxy_hops=0)
        assert resolve(_request({"cf-connecting-ip": "evil, 1.2.3.4"}))[1] == "peer"

    def test_forwarded_for_is_read_from_the_right(self, monkeypatch):
        """Render's real chain: client, Cloudflare, Render's proxy. Anything
        further left was written by the caller and could say anything."""
        _configure(monkeypatch, client_ip_header="", trusted_proxy_hops=3)
        chain = "6.6.6.6, 81.97.145.24, 172.71.195.123, 10.226.90.65"   # 6.6.6.6 is forged
        assert resolve(_request({"x-forwarded-for": chain})) == ("81.97.145.24", "forwarded-for")

    def test_a_short_forwarded_for_chain_isnt_trusted(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="", trusted_proxy_hops=3)
        assert resolve(_request({"x-forwarded-for": "1.2.3.4"}))[1] == "peer"

    def test_the_storefront_header_needs_the_key(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip", storefront_api_key=KEY)
        forwarded = {"cf-connecting-ip": "76.76.21.9", "x-broka-client-ip": "41.90.1.2"}
        assert resolve(_request(forwarded)) == ("76.76.21.9", "header")              # no key
        wrong = {**forwarded, "x-broka-storefront-key": "t" * 40}
        assert resolve(_request(wrong)) == ("76.76.21.9", "header")                  # wrong key
        right = {**forwarded, "x-broka-storefront-key": KEY}
        assert resolve(_request(right)) == ("41.90.1.2", "storefront")

    def test_the_storefront_header_is_ignored_when_no_key_is_configured(self, monkeypatch):
        _configure(monkeypatch, client_ip_header="", storefront_api_key="")
        req = _request({"x-broka-client-ip": "41.90.1.2", "x-broka-storefront-key": ""})
        assert resolve(req)[1] == "peer"

    @pytest.mark.parametrize("value,expected", [
        ("41.90.1.2", "41.90.1.2"),
        ("41.90.1.2:51234", "41.90.1.2"),
        ("2c0f:fe38:2400::1", "2c0f:fe38:2400::1"),
        ("[2c0f:fe38:2400::1]:443", "2c0f:fe38:2400::1"),
    ])
    def test_address_forms(self, monkeypatch, value, expected):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        assert resolve(_request({"cf-connecting-ip": value}))[0] == expected

    def test_render_defaults_to_cloudflares_header(self, monkeypatch):
        from api.core.config import _client_ip_header_default
        monkeypatch.delenv("CLIENT_IP_HEADER", raising=False)
        monkeypatch.setenv("RENDER", "true")
        assert _client_ip_header_default() == "cf-connecting-ip"
        monkeypatch.setenv("CLIENT_IP_HEADER", "none")
        assert _client_ip_header_default() == ""
        monkeypatch.delenv("CLIENT_IP_HEADER")
        monkeypatch.delenv("RENDER")
        assert _client_ip_header_default() == ""


# ── Limits ────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestLoginLimit:
    async def test_login_is_limited_per_caller_not_per_proxy(self, client, monkeypatch):
        from api.domains.auth import router as auth_router
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        monkeypatch.setattr(auth_router, "login_limiter", RateLimiter("login", 2, 60))

        async def login(ip: str) -> int:
            r = await client.post(
                "/auth/login", headers={"cf-connecting-ip": ip},
                json={"phone": f"07{uuid.uuid4().int % 10**8:08d}", "password": "x" * 8},
            )
            return r.status_code

        first = [await login("41.90.1.2") for _ in range(3)]
        assert first[:2] != [429, 429] and first[2] == 429
        # Someone else, through the same proxy, is not locked out.
        assert await login("41.90.7.7") != 429


# ── Store visit and share counting ────────────────────────────────────────────

_n = itertools.count(1)


async def _store(client) -> tuple[str, dict]:
    owner = User(
        name="Owner", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x",
        account_type=AccountType.buyer_seller, seller_tier=SellerTier.long_term,
    )
    async with AsyncSessionLocal() as db:
        db.add(owner)
        await db.commit()
        await db.refresh(owner)
    headers = {"Authorization": f"Bearer {create_access_token({'sub': owner.id})}"}
    r = await client.post("/stores", headers=headers, json={"name": f"Shop {next(_n)}"})
    assert r.status_code == 201, r.text
    return r.json()["id"], headers


async def _visits(client, store_id, headers) -> int:
    r = await client.get(f"/stores/{store_id}/stats", headers=headers)
    return r.json()["visits"]["total"]


def _visit(client, store_id, *, visitor=None, ip="41.90.1.2", extra=None):
    body = {"surface": "web", **({"visitor": visitor} if visitor else {})}
    headers = {"user-agent": BROWSER, "cf-connecting-ip": ip, **(extra or {})}
    return client.post(f"/stores/{store_id}/visit", json=body, headers=headers)


@pytest.mark.asyncio
class TestStoreCounting:
    async def test_inventing_visitor_ids_is_rate_limited(self, client, monkeypatch):
        """The limiter used to be keyed on the visitor id itself."""
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        monkeypatch.setattr(stores_router_module, "store_counter_limiter", RateLimiter("sc", 5, 60))
        store_id, _ = await _store(client)
        statuses = [(await _visit(client, store_id, visitor=uuid.uuid4().hex)).status_code
                    for _ in range(8)]
        assert statuses[:5] == [202] * 5 and statuses[5:] == [429] * 3

    async def test_one_address_brings_at_most_the_cap_of_new_visitors(self, client, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        store_id, owner = await _store(client)
        cap = store_stats.MAX_VISITORS_PER_CLIENT
        for _ in range(cap + 15):
            await _visit(client, store_id, visitor=uuid.uuid4().hex)
        assert await _visits(client, store_id, owner) == cap

    async def test_visitors_from_different_addresses_all_count(self, client, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        store_id, owner = await _store(client)
        for i in range(5):
            r = await _visit(client, store_id, visitor=uuid.uuid4().hex, ip=f"41.90.2.{i}")
            assert r.json() == {"counted": True}
        assert await _visits(client, store_id, owner) == 5

    async def test_a_returning_visitor_doesnt_use_up_the_cap(self, client, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        store_id, owner = await _store(client)
        for _ in range(store_stats.MAX_VISITORS_PER_CLIENT + 5):
            await _visit(client, store_id, visitor="same-browser-1")
        assert await _visits(client, store_id, owner) == 1
        r = await _visit(client, store_id, visitor="another-browser")
        assert r.json() == {"counted": True}

    async def test_the_storefront_forwards_each_visitor_separately(self, client, monkeypatch):
        """Everything the storefront forwards reaches the API from Vercel. With
        the key, each forwarded visitor is its own client; without it they
        all share Vercel's address and its cap."""
        _configure(monkeypatch, client_ip_header="cf-connecting-ip", storefront_api_key=KEY)
        store_id, owner = await _store(client)
        cap = store_stats.MAX_VISITORS_PER_CLIENT
        for i in range(cap + 5):
            await _visit(client, store_id, visitor=uuid.uuid4().hex, ip="76.76.21.9", extra={
                "x-broka-storefront-key": KEY, "x-broka-client-ip": f"41.90.3.{i}",
            })
        assert await _visits(client, store_id, owner) == cap + 5

        other_id, other_owner = await _store(client)
        for i in range(cap + 5):
            await _visit(client, other_id, visitor=uuid.uuid4().hex, ip="76.76.21.9", extra={
                "x-broka-client-ip": f"41.90.4.{i}",                     # no key
            })
        assert await _visits(client, other_id, other_owner) == cap

    async def test_shares_are_capped_per_caller(self, client, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        store_id, owner = await _store(client)
        cap = store_stats.MAX_SHARES_PER_CLIENT
        results = [
            (await client.post(f"/stores/{store_id}/share", json={"channel": "whatsapp"},
                               headers={"cf-connecting-ip": "41.90.5.5"})).json()["counted"]
            for _ in range(cap + 3)
        ]
        assert results.count(True) == cap and results[-1] is False
        stats = (await client.get(f"/stores/{store_id}/stats", headers=owner)).json()
        assert stats["shares"]["total"] == cap


# ── Diagnostics ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
class TestDiagnostics:
    async def test_admin_only_and_explains_itself(self, client, monkeypatch):
        _configure(monkeypatch, client_ip_header="cf-connecting-ip")
        user = User(name="U", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x")
        admin = User(name="A", phone=f"+2547{uuid.uuid4().hex[:8]}", password_hash="x", is_admin=True)
        async with AsyncSessionLocal() as db:
            db.add_all([user, admin])
            await db.commit()
        as_user = {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}
        as_admin = {"Authorization": f"Bearer {create_access_token({'sub': admin.id})}"}
        path = "/admin/diagnostics/client-ip"

        assert (await client.get(path)).status_code == 401
        assert (await client.get(path, headers=as_user)).status_code == 403
        r = await client.get(path, headers={**as_admin, "cf-connecting-ip": "41.90.9.9"})
        assert r.status_code == 200
        body = r.json()
        assert body["resolved"] == "41.90.9.9" and body["source"] == "header"
        assert body["headers"]["cf-connecting-ip"] == "41.90.9.9"
