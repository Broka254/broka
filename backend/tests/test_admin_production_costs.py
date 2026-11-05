"""Admin production cost API: source separation, manual audit and idempotency."""
from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, AuditLog, User, init_db, reset_engine
from api.models.platform_cost import PlatformCost, PlatformCostManualEntry
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_admin_production_costs.db"
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


async def _user(*, admin: bool = False) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin" if admin else "User",
        phone=f"+2547{tag}",
        email=f"{tag}@production-costs.test",
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


@pytest.mark.asyncio
async def test_cost_read_is_admin_only_and_keeps_unpriced_usage_unpriced(client):
    admin = await _user(admin=True)
    ordinary = await _user()
    headers = _headers(admin)
    start = datetime(2026, 11, 5, 0, 0, 0)
    async with AsyncSessionLocal() as db:
        db.add_all([
            PlatformCost(
                kind="sms", amount_minor=29, currency="KES", provider="texin",
                estimated=False, meta={"units_used": 1}, created_at=start + timedelta(hours=2),
            ),
            PlatformCost(
                kind="ai", amount_minor=25, currency="KES", provider="deepseek",
                estimated=True, meta={"input_tokens": 100, "output_tokens": 50},
                created_at=start + timedelta(hours=3),
            ),
            PlatformCost(
                kind="ai", amount_minor=0, currency="KES", provider="unknown",
                estimated=True, meta={"unpriced": True, "tokens_unknown": True},
                created_at=start + timedelta(hours=4),
            ),
            PlatformCost(
                kind="sms", amount_minor=900, currency="KES", provider="texin",
                estimated=False, meta={"units_used": 3}, created_at=datetime(2026, 11, 6),
            ),
        ])
        await db.commit()

    denied = await client.get(
        "/admin/production-costs", params={"from": "2026-11-05", "to": "2026-11-06"},
        headers=_headers(ordinary),
    )
    assert denied.status_code == 403

    response = await client.get(
        "/admin/production-costs", params={"from": "2026-11-05", "to": "2026-11-06"},
        headers=headers,
    )
    assert response.status_code == 200, response.text
    body = response.json()
    services = {row["key"]: row for row in body["services"]}
    assert services["sms:KES"]["request_count"] == 1
    assert services["sms:KES"]["usage_count"] == 1
    assert services["sms:KES"]["provider_reported_minor"] == 29
    assert services["sms:KES"]["selected_cost_basis"] == "provider_reported"
    assert services["ai:KES"]["request_count"] == 2
    assert services["ai:KES"]["usage_estimate_minor"] == 25
    assert services["ai:KES"]["selected_cost_basis"] == "usage_estimate"
    assert any("unknown token/rate pricing" in note for note in services["ai:KES"]["notes"])
    assert services["email:KES"]["selected_cost_minor"] is None
    assert services["email:KES"]["selected_cost_basis"] == "unavailable"
    assert "instrumentation is not yet connected" in " ".join(services["email:KES"]["notes"])
    # The row exactly at the exclusive upper boundary is not included.
    assert services["sms:KES"]["provider_reported_minor"] == 29
    assert body["capabilities"]["manual_entries"] is True

    invalid = await client.get(
        "/admin/production-costs", params={"from": "2026-11-06", "to": "2026-11-06"},
        headers=headers,
    )
    assert invalid.status_code == 422


@pytest.mark.asyncio
async def test_manual_cost_entry_is_audited_idempotent_and_currency_scoped(client):
    admin = await _user(admin=True)
    headers = _headers(admin)
    headers["X-Idempotency-Key"] = "production-cost-" + uuid.uuid4().hex
    payload = {
        "service_key": "hosting:USD",
        "amount_minor": 1234,
        "currency": "USD",
        "occurred_on": "2026-11-05",
        "description": "Monthly hosting invoice",
        "reference": "INV-1001",
    }
    first = await client.post(
        "/admin/production-costs/manual-entries", json=payload, headers=headers,
    )
    assert first.status_code == 200, first.text
    entry_id = first.json()["id"]
    assert first.json()["created_by_label"] == "Admin"
    assert first.json()["amount_minor"] == 1234

    replay = await client.post(
        "/admin/production-costs/manual-entries", json=payload, headers=headers,
    )
    assert replay.status_code == 200
    assert replay.json()["id"] == entry_id

    conflicting = await client.post(
        "/admin/production-costs/manual-entries",
        json={**payload, "amount_minor": 9999}, headers=headers,
    )
    assert conflicting.status_code == 409

    async with AsyncSessionLocal() as db:
        rows = (await db.execute(
            select(PlatformCostManualEntry).where(PlatformCostManualEntry.idempotency_key == headers["X-Idempotency-Key"])
        )).scalars().all()
        audits = (await db.execute(
            select(AuditLog).where(
                AuditLog.action == "production_cost_manual_entry_created",
                AuditLog.resource_id == entry_id,
            )
        )).scalars().all()
    assert len(rows) == 1
    assert len(audits) == 1
    assert audits[0].actor_id == admin.id

    report = await client.get(
        "/admin/production-costs", params={"from": "2026-11-05", "to": "2026-11-06"},
        headers=_headers(admin),
    )
    assert report.status_code == 200
    body = report.json()
    hosting_usd = next(row for row in body["services"] if row["key"] == "hosting:USD")
    assert hosting_usd["manual_minor"] == 1234
    assert hosting_usd["selected_cost_minor"] == 1234
    assert hosting_usd["selected_cost_basis"] == "manual_entry"
    assert len(body["manual_entries"]) == 1


@pytest.mark.asyncio
async def test_manual_entry_requires_admin_and_idempotency_key(client):
    ordinary = await _user()
    payload = {
        "service_key": "other:KES",
        "amount_minor": 100,
        "currency": "KES",
        "occurred_on": "2026-11-05",
        "description": "Miscellaneous platform cost",
    }
    denied = await client.post(
        "/admin/production-costs/manual-entries", json=payload, headers=_headers(ordinary),
    )
    assert denied.status_code == 403

    admin = await _user(admin=True)
    missing_key = await client.post(
        "/admin/production-costs/manual-entries", json=payload, headers=_headers(admin),
    )
    assert missing_key.status_code == 422

    invalid_service = await client.post(
        "/admin/production-costs/manual-entries",
        json={**payload, "service_key": "escrow_principal:KES"},
        headers={**_headers(admin), "X-Idempotency-Key": "production-cost-invalid"},
    )
    assert invalid_service.status_code == 422
