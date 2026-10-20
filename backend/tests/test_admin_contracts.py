"""Contracts used by the external administrative dashboard.

The dashboard previously called /admin/ops-snapshot, /admin/health/services
and /admin/stores and received 404s. These tests pin the mounted router,
authorization and the top-level response shape so a rename or an unmounted
legacy implementation fails CI rather than production.
"""
from __future__ import annotations

import uuid

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, AuditLog, User, init_db, reset_engine
from api.models.store import Store
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_contracts.db"
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


def _headers(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _user(*, admin: bool = False) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin" if admin else "User",
        phone=f"+2547{tag}",
        email=f"{tag}@admin.test",
        password_hash="x",
        is_admin=admin,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


@pytest.mark.asyncio
@pytest.mark.parametrize("path", [
    "/admin/summary", "/admin/ops-snapshot", "/admin/health/services", "/admin/stores",
])
async def test_dashboard_reads_require_admin(client, path):
    ordinary = await _user()
    response = await client.get(path, headers=_headers(ordinary))
    assert response.status_code == 403


@pytest.mark.asyncio
async def test_ops_snapshot_has_stable_aggregate_shape(client):
    admin = await _user(admin=True)
    response = await client.get("/admin/ops-snapshot", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "generated_at", "users", "listings", "stores", "deals",
        "payments", "disputes", "jobs",
    }
    assert {"total", "flagged", "admins"} <= set(body["users"])
    assert {"total", "by_status"} <= set(body["deals"])
    assert {"total", "by_status", "pending_callbacks"} <= set(body["payments"])
    assert body["payments"]["pending_callbacks"] >= 0


@pytest.mark.asyncio
async def test_summary_has_the_contract_the_dashboard_reads(client):
    admin = await _user(admin=True)
    response = await client.get("/admin/summary", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert set(body) == {
        "users", "listings", "deals", "commission_earned_kes",
        "disputes", "flagged_users",
    }
    assert all(isinstance(body[name], int) for name in (
        "users", "listings", "deals", "disputes", "flagged_users",
    ))
    assert isinstance(body["commission_earned_kes"], (int, float))


@pytest.mark.asyncio
async def test_service_health_reports_schema_without_secret_values(client):
    admin = await _user(admin=True)
    response = await client.get("/admin/health/services", headers=_headers(admin))
    assert response.status_code == 200
    body = response.json()
    assert body["services"]["database"]["ok"] is True
    assert body["services"]["database"]["schema_ok"] is True
    # Only configuration states are exposed, never the values themselves.
    serialized = response.text
    assert "password" not in serialized.lower()
    assert "secret_key" not in serialized.lower()


@pytest.mark.asyncio
async def test_admin_stores_is_bounded_and_excludes_deleted_by_default(client):
    admin = await _user(admin=True)
    owner = await _user()
    async with AsyncSessionLocal() as db:
        db.add_all([
            Store(owner_id=owner.id, name="Visible", slug=f"visible-{uuid.uuid4().hex[:8]}"),
            Store(
                owner_id=owner.id, name="Deleted", slug=f"deleted-{uuid.uuid4().hex[:8]}",
                deleted_at=__import__("datetime").datetime.utcnow(),
            ),
        ])
        await db.commit()

    response = await client.get("/admin/stores?limit=10", headers=_headers(admin))
    assert response.status_code == 200
    names = {row["name"] for row in response.json()}
    assert "Visible" in names and "Deleted" not in names
    assert (await client.get("/admin/stores?limit=201", headers=_headers(admin))).status_code == 422


@pytest.mark.asyncio
@pytest.mark.parametrize("path,maximum", [
    ("/admin/users", 200),
    ("/admin/audit-logs", 500),
    ("/admin/fraud-events", 200),
    ("/admin/transactions", 200),
])
async def test_every_admin_list_rejects_an_unbounded_limit(client, path, maximum):
    admin = await _user(admin=True)
    headers = _headers(admin)
    assert (await client.get(f"{path}?limit={maximum + 1}", headers=headers)).status_code == 422
    assert (await client.get(f"{path}?limit=1", headers=headers)).status_code == 200


@pytest.mark.asyncio
async def test_privileged_user_mutation_is_audited_and_flag_is_idempotent(client):
    admin = await _user(admin=True)
    target = await _user()
    headers = _headers(admin)

    first = await client.post(
        f"/admin/users/{target.id}/flag", json={"reason": "confirmed fraud"}, headers=headers,
    )
    second = await client.post(f"/admin/users/{target.id}/flag", headers=headers)
    assert first.status_code == second.status_code == 200
    assert first.json()["trust_score"] == second.json()["trust_score"]

    async with AsyncSessionLocal() as db:
        audits = (await db.execute(
            select(AuditLog).where(
                AuditLog.action == "user_flagged",
                AuditLog.resource_id == target.id,
            )
        )).scalars().all()
        stored = (await db.execute(select(User).where(User.id == target.id))).scalar_one()
    assert len(audits) == 2
    assert all(row.actor_id == admin.id for row in audits)
    assert stored.trust_score == 70
