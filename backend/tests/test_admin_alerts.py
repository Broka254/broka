"""Admin alerts: event-driven creation, dedup, transitions, SSE smoke.

Every fix ships a test (AGENTS.md): these pin the alert lifecycle end to
end — emit creates, re-emit dedups, list filters count right, ack/resolve
are idempotent, manual create validates, unknowns 404, dispute resolution
auto-closes, and the SSE stream yields bytes.
"""
from __future__ import annotations

import asyncio
import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.core.event_catalog import EventType, emit
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.models.admin_alert import AdminAlert
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_alerts.db"
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
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as c:
        yield c


async def _user(*, admin: bool = False) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin" if admin else "User",
        phone=f"+2547{tag}",
        email=f"{tag}@alerts.test",
        password_hash="x",
        is_admin=admin,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _headers(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _open_count() -> int:
    async with AsyncSessionLocal() as db:
        rows = (
            await db.execute(
                select(AdminAlert).where(AdminAlert.status == "open")
            )
        ).scalars().all()
        return len(rows)


@pytest.mark.asyncio
async def test_event_creates_alert_and_dedups(client):
    admin = await _user(admin=True)
    before = await _open_count()
    await emit(
        EventType.DISPUTE_OPENED,
        aggregate="dispute",
        aggregate_id="disp-dedup-1",
        payload={
            "dispute_id": "disp-dedup-1",
            "deal_id": "deal-1",
            "opener_id": "user-1",
        },
    )
    await emit(  # second emit for the same dispute: still one open alert
        EventType.DISPUTE_OPENED,
        aggregate="dispute",
        aggregate_id="disp-dedup-1",
        payload={
            "dispute_id": "disp-dedup-1",
            "deal_id": "deal-1",
            "opener_id": "user-1",
        },
    )
    assert await _open_count() == before + 1
    r = await client.get("/admin/alerts", headers=_headers(admin))
    assert r.status_code == 200
    body = r.json()
    assert body["total"] >= 1 and body["unread"] >= 1
    match = [i for i in body["items"] if i["kind"] == "dispute_opened"]
    assert match and match[0]["href"] == "/disputes/disp-dedup-1"
    assert match[0]["meta"]["dispute_id"] == "disp-dedup-1"


@pytest.mark.asyncio
async def test_fraud_and_payment_events_create_alerts():
    before = await _open_count()
    await emit(
        EventType.FRAUD_FLAGGED,
        aggregate="user",
        aggregate_id="user-fraud-1",
        payload={"user_id": "user-fraud-1", "reason": "velocity"},
    )
    await emit(
        EventType.PAYMENT_FAILED,
        aggregate="payment",
        aggregate_id="ref-fail-1",
        payload={
            "reference": "ref-fail-1",
            "purpose": "listing_fee",
            "reason": "cancelled",
        },
    )
    assert await _open_count() == before + 2


@pytest.mark.asyncio
async def test_list_filters_and_unread(client):
    admin = await _user(admin=True)
    r = await client.get(
        "/admin/alerts?kind=fraud_flagged", headers=_headers(admin)
    )
    assert r.status_code == 200
    body = r.json()
    assert body["total"] >= 1
    assert all(i["kind"] == "fraud_flagged" for i in body["items"])
    # unread honours the kind filter
    r2 = await client.get(
        "/admin/alerts?kind=fraud_flagged&status=all",
        headers=_headers(admin),
    )
    assert r2.json()["unread"] == body["unread"]
    # bad status is a 422, not a silent empty page
    r3 = await client.get(
        "/admin/alerts?status=bogus", headers=_headers(admin)
    )
    assert r3.status_code == 422
    # non-admins cannot read
    ordinary = await _user()
    r4 = await client.get("/admin/alerts", headers=_headers(ordinary))
    assert r4.status_code == 403


@pytest.mark.asyncio
async def test_ack_resolve_idempotent(client):
    admin = await _user(admin=True)
    h = _headers(admin)
    created = await client.post(
        "/admin/alerts",
        json={"kind": "ops_note", "severity": "info", "title": "note"},
        headers=h,
    )
    assert created.status_code == 201
    alert_id = created.json()["id"]
    ack = await client.post(
        f"/admin/alerts/{alert_id}/acknowledge", json={}, headers=h
    )
    assert ack.status_code == 200
    assert ack.json()["status"] == "acknowledged"
    re_ack = await client.post(
        f"/admin/alerts/{alert_id}/acknowledge",
        json={"reason": "again"},
        headers=h,
    )
    assert re_ack.status_code == 200
    assert re_ack.json()["status"] == "acknowledged"
    resolved = await client.post(
        f"/admin/alerts/{alert_id}/resolve", json={}, headers=h
    )
    assert resolved.json()["status"] == "resolved"
    re_resolve = await client.post(
        f"/admin/alerts/{alert_id}/resolve", json={}, headers=h
    )
    assert re_resolve.status_code == 200
    assert re_resolve.json()["status"] == "resolved"
    # resolved alerts leave the default open list
    listed = await client.get("/admin/alerts", headers=h)
    assert all(i["id"] != alert_id for i in listed.json()["items"])


@pytest.mark.asyncio
async def test_manual_create_validation_and_404s(client):
    admin = await _user(admin=True)
    h = _headers(admin)
    bad = await client.post(
        "/admin/alerts",
        json={"kind": "x", "severity": "extreme", "title": "t"},
        headers=h,
    )
    assert bad.status_code == 422
    empty = await client.post(
        "/admin/alerts",
        json={"kind": "x", "severity": "info", "title": "  "},
        headers=h,
    )
    assert empty.status_code == 422
    assert (
        await client.post(
            "/admin/alerts/999999/acknowledge", json={}, headers=h
        )
    ).status_code == 404
    assert (
        await client.post(
            "/admin/alerts/999999/resolve", json={}, headers=h
        )
    ).status_code == 404
    ordinary = await _user()
    denied = await client.post(
        "/admin/alerts",
        json={"kind": "x", "severity": "info", "title": "t"},
        headers=_headers(ordinary),
    )
    assert denied.status_code == 403


@pytest.mark.asyncio
async def test_auto_resolve_on_dispute_resolved(client):
    admin = await _user(admin=True)
    h = _headers(admin)
    await emit(
        EventType.DISPUTE_OPENED,
        aggregate="dispute",
        aggregate_id="disp-auto-9",
        payload={"dispute_id": "disp-auto-9", "deal_id": "deal-9"},
    )
    opened = await client.get(
        "/admin/alerts?kind=dispute_opened&status=all", headers=h
    )
    row = next(
        i for i in opened.json()["items"] if i["meta"].get("dispute_id") == "disp-auto-9"
    )
    assert row["status"] == "open"
    await emit(
        EventType.DISPUTE_RESOLVED,
        aggregate="dispute",
        aggregate_id="disp-auto-9",
        payload={"dispute_id": "disp-auto-9", "resolution": "refund"},
    )
    reopened = await client.get(
        "/admin/alerts?kind=dispute_opened&status=all", headers=h
    )
    row2 = next(
        i
        for i in reopened.json()["items"]
        if i["meta"].get("dispute_id") == "disp-auto-9"
    )
    assert row2["status"] == "resolved"


@pytest.mark.asyncio
async def test_sse_smoke():
    # Drives the ASGI app directly with a scripted receive/send pair: the
    # stream only ends when the client disconnects, so neither an httpx
    # ASGITransport (buffers the whole response before returning) nor
    # Starlette's TestClient (portal thread vs the test loop's sqlite
    # engine) can read it. The scripted client captures response.start
    # plus the first stats frame, then sends http.disconnect; the
    # generator must observe it and end the response promptly.
    admin = await _user(admin=True)
    token = create_access_token({"sub": admin.id})
    received: list[dict] = []

    async def receive():
        # No awaits here: Request.is_disconnected() polls receive() inside
        # an already-cancelled scope, so any checkpoint would abort before
        # this message is ever observed. Awaiting this coroutine runs it
        # synchronously with no checkpoint.
        if len(received) >= 3:  # start + stats + ping captured
            return {"type": "http.disconnect"}
        return {"type": "http.request", "body": b"", "more_body": False}

    async def send(message):
        received.append(message)

    scope = {
        "type": "http",
        "asgi": {"version": "3.0", "spec_version": "2.5"},
        "http_version": "1.1",
        "method": "GET",
        "path": "/admin/alerts/stream",
        "raw_path": b"/admin/alerts/stream",
        "query_string": b"",
        "headers": [(b"authorization", f"Bearer {token}".encode())],
        "scheme": "http",
        "server": ("test", 80),
        "client": ("test", 50000),
    }
    await asyncio.wait_for(app(scope, receive, send), timeout=30)
    assert received[0]["type"] == "http.response.start"
    assert received[0]["status"] == 200
    headers = dict(received[0].get("headers", []))
    assert b"text/event-stream" in headers.get(b"content-type", b"")
    body = b"".join(
        m.get("body", b"")
        for m in received
        if m["type"] == "http.response.body"
    )
    assert b"event: stats" in body
    assert b"ping" in body
