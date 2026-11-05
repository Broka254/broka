"""Production cost tracking: usage, pricing history, manual overrides, API.

Run: pytest backend/tests/test_service_costs.py -q

The suite uses a real isolated SQLite database and the real FastAPI app, not
mocks of the cost layer: the point of these tests is that the numbers a
dashboard would read are the numbers the database actually holds.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.core.cost_ledger import ai_cost_minor, record_ai_cost
from api.core.sms import sms_gsm7_segments, sms_segments
from api.database import (
    AsyncSessionLocal,
    AuditLog,
    User,
    init_db,
    reset_engine,
)
from api.domains.service_costs import service as costs
from api.models.service_cost import (
    ServiceCatalog,
    ServiceCostAdjustment,
    ServiceUsageDaily,
    ServiceUsageEvent,
)
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_service_costs.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    mp.setenv("ENV", "test")
    mp.setenv("SERVICE_USAGE_ENABLED", "true")
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client(setup_db):
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


async def _user(*, admin: bool = False) -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin" if admin else "User",
        phone=f"+2547{tag}",
        email=f"{tag}@costs.test",
        password_hash="x",
        is_admin=admin,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


@pytest_asyncio.fixture(scope="module")
async def admin(setup_db) -> User:
    return await _user(admin=True)


@pytest_asyncio.fixture(scope="module")
async def ordinary(setup_db) -> User:
    return await _user(admin=False)


def _headers(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _record(**kwargs):
    """Record one usage event and return its id (None if deduplicated)."""
    async with AsyncSessionLocal() as db:
        row = await costs.record_usage_event(db, **kwargs)
        await db.commit()
        return row.id if row is not None else None


async def _report(start: datetime, end: datetime) -> dict:
    async with AsyncSessionLocal() as db:
        return await costs.services_report(db, start=start, end=end)


def _row(report: dict, service_key: str) -> dict:
    return next(r for r in report["services"] if r["service_key"] == service_key)


# ── SMS segments ────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_sms_is_counted_in_segments_not_messages():
    # 160 GSM-7 characters fit one segment; the 161st starts another. A
    # message must never be assumed to be one billable unit.
    assert sms_gsm7_segments("a" * 160) == 1
    assert sms_gsm7_segments("a" * 161) == 2
    # A provider that accepts Unicode bills UCS-2: 70 units per segment,
    # 67 per concatenated part. This is the count the usage event uses.
    assert sms_segments("你" * 71) == 2
    assert sms_segments("你" * 135) == 3
    # Pure GSM-7 still uses the 160/153 rules.
    assert sms_segments("a" * 161) == 2

    segments = sms_gsm7_segments("a" * 161)
    await _record(
        service_key="sms.texin",
        operation_type="sms.send",
        status="success",
        quantity=segments,
        provider_reference="TX-COST-1",
        operation_id="sms:texin:TX-COST-1",
        occurred_at=datetime(2026, 1, 15, 12, 0, 0),
        metadata={"segments": segments},
    )

    report = await _report(datetime(2026, 1, 1), datetime(2026, 2, 1))
    row = _row(report, "sms.texin")
    assert row["requests_success"] >= 1
    assert row["usage_quantity"] >= segments
    assert row["usage_unit"] == "sms_segment"
    # Seeded confirmed Texin rate: KES 0.29 x 2 = KES 0.58 = 58 minor.
    assert row["effective_cost_minor"] == row["usage_quantity"] * 29
    assert row["cost_source"] == "usage_estimate"
    assert row["currency"] == "KES"


@pytest.mark.asyncio
async def test_sms_fallback_cost_scales_by_provider_billing_unit():
    """AT bills per segment; Mobitech bills per message."""
    from types import SimpleNamespace
    from unittest.mock import AsyncMock, patch

    from api.core import cost_ledger

    with patch(
        "api.core.cost_ledger.record_cost_detached",
        new=AsyncMock(return_value=SimpleNamespace(amount_minor=160)),
    ) as detached:
        await cost_ledger.record_sms_cost(provider="africas_talking", segments=2)
    kwargs = detached.await_args.kwargs
    # KES 0.80 x 2 segments = KES 1.60 = 160 minor, not a flat 80.
    assert kwargs["amount_minor"] == 160
    assert kwargs["usage"]["quantity"] == 2
    assert kwargs["usage"]["estimated_cost_minor"] == 160
    assert kwargs["estimated"] is True

    with patch(
        "api.core.cost_ledger.record_cost_detached",
        new=AsyncMock(return_value=SimpleNamespace(amount_minor=35)),
    ) as detached:
        await cost_ledger.record_sms_cost(provider="mobitech", segments=3)
    kwargs = detached.await_args.kwargs
    # Mobitech is KES 0.35 per message whatever its length.
    assert kwargs["amount_minor"] == 35
    assert kwargs["usage"]["quantity"] == 1
    assert kwargs["usage"]["metadata"]["segments"] == 3


# ── AI ──────────────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_ai_tokens_are_aggregated_and_priced_from_real_usage():
    expected, estimated, meta = ai_cost_minor("deepseek", 1000, 500)
    assert expected > 0 and estimated and not meta.get("unpriced")

    # The provider instrumentation path: record_ai_cost must write a
    # catalogue event with the same token counts and amount, not just the
    # coarse PlatformCost row.
    await record_ai_cost(
        provider="deepseek",
        response_data={
            "usage": {"prompt_tokens": 1000, "completion_tokens": 500}
        },
        model="deepseek-v4-flash",
        call_site="test",
    )
    async with AsyncSessionLocal() as db:
        event = (
            await db.execute(
                select(ServiceUsageEvent)
                .join(ServiceCatalog, ServiceCatalog.id == ServiceUsageEvent.service_id)
                .where(ServiceCatalog.service_key == "ai.deepseek")
                .order_by(ServiceUsageEvent.id.desc())
                .limit(1)
            )
        ).scalar_one()
        assert event.input_tokens == 1000
        assert event.output_tokens == 500
        assert event.estimated_cost_minor == expected

    # A fixed-period success, an unpriced provider and a failure.
    await _record(
        service_key="ai.deepseek",
        operation_type="ai.chat",
        status="success",
        quantity=1,
        input_tokens=1000,
        output_tokens=500,
        estimated_cost_minor=expected,
        cost_basis="derived_rate",
        cost_confidence="estimated",
        currency="KES",
        operation_id="ai:deepseek:cost-test-1",
        occurred_at=datetime(2026, 4, 10, 9, 0, 0),
    )
    await _record(
        service_key="ai.gemini",
        operation_type="ai.chat",
        status="success",
        quantity=1,
        input_tokens=800,
        output_tokens=200,
        apply_pricing=False,
        estimated_cost_minor=None,
        cost_basis="unpriced",
        cost_confidence="unknown",
        operation_id="ai:gemini:cost-test-1",
        occurred_at=datetime(2026, 4, 10, 9, 5, 0),
    )
    await _record(
        service_key="ai.deepseek",
        operation_type="ai.chat",
        status="failed",
        quantity=1,
        apply_pricing=False,
        estimated_cost_minor=None,
        cost_basis="unpriced",
        cost_confidence="unknown",
        operation_id="ai:deepseek:cost-test-failed",
        occurred_at=datetime(2026, 4, 11, 9, 0, 0),
    )

    report = await _report(datetime(2026, 4, 1), datetime(2026, 5, 1))
    deepseek = _row(report, "ai.deepseek")
    assert deepseek["requests_total"] == 2
    assert deepseek["requests_success"] == 1
    assert deepseek["requests_failed"] == 1
    assert deepseek["total_tokens"] == 1500
    assert deepseek["effective_cost_minor"] == expected
    # DeepSeek peak pricing is twice off-peak; the dashboard's maximum is
    # therefore 2x the estimate, not an invented number.
    assert deepseek["maximum_estimated_cost_minor"] == expected * 2
    assert deepseek["cost_status"] == "partially_unpriced"

    gemini = _row(report, "ai.gemini")
    assert gemini["requests_total"] == 1
    assert gemini["total_tokens"] == 1000
    # Real tokens, no verified rate: NULL, never 0.
    assert gemini["effective_cost_minor"] is None
    assert gemini["cost_status"] == "unpriced"
    assert gemini["confidence"] == "unknown"


# ── Images / email / free services ──────────────────────────────────────────

@pytest.mark.asyncio
async def test_image_generation_email_and_missing_pricing():
    await _record(
        service_key="image.huggingface_fal",
        operation_type="image.generate",
        status="success",
        quantity=1,
        operation_id="hf:test-request-1",
        provider_reference="test-request-1",
        occurred_at=datetime(2026, 5, 5, 10, 0, 0),
    )
    await _record(
        service_key="image.huggingface_fal",
        operation_type="image.generate",
        status="failed",
        quantity=0,
        apply_pricing=False,
        estimated_cost_minor=None,
        cost_basis="unpriced",
        cost_confidence="unknown",
        operation_id="hf:test-request-2",
        occurred_at=datetime(2026, 5, 5, 10, 1, 0),
    )
    await costs.record_usage(
        service_key="email.resend",
        operation_type="email.send",
        status="success",
        quantity=1,
        provider_reference="email-test-1",
        operation_id="email:resend:cost-test-1",
        occurred_at=datetime(2026, 5, 5, 10, 2, 0),
    )

    report = await _report(datetime(2026, 5, 1), datetime(2026, 6, 1))
    image = _row(report, "image.huggingface_fal")
    assert image["requests_total"] == 2
    assert image["requests_success"] == 1
    assert image["requests_failed"] == 1
    assert image["usage_quantity"] == 1  # images generated, not attempts
    # HF reports a request id but no price. Missing pricing is explicit.
    assert image["effective_cost_minor"] is None
    assert image["priced_events"] == 0
    assert image["unpriced_events"] == 2

    email = _row(report, "email.resend")
    assert email["requests_success"] == 1
    # Resend's free plan is a known zero, not an unknown.
    assert email["effective_cost_minor"] == 0
    assert email["cost_status"] == "free"
    assert email["confidence"] == "exact"


@pytest.mark.asyncio
async def test_free_push_is_a_known_zero_including_failures():
    await costs.record_usage(
        service_key="push.fcm",
        operation_type="push.send",
        status="success",
        quantity=1,
        provider_reference="projects/x/messages/1",
        operation_id="fcm:projects/x/messages/1",
        occurred_at=datetime(2026, 5, 6, 10, 0, 0),
    )
    await costs.record_usage(
        service_key="push.fcm",
        operation_type="push.send",
        status="failed",
        quantity=1,
        apply_pricing=False,
        estimated_cost_minor=None,
        operation_id="fcm:failed-cost-test",
        occurred_at=datetime(2026, 5, 6, 10, 1, 0),
    )

    report = await _report(datetime(2026, 5, 1), datetime(2026, 6, 1))
    push = _row(report, "push.fcm")
    assert push["requests_total"] == 2
    assert push["requests_failed"] == 1
    assert push["effective_cost_minor"] == 0
    assert push["cost_status"] == "free"
    assert push["cost_source"] == "usage_estimate"


# ── Manual cost management ──────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_manual_override_retains_estimate_and_writes_an_audit_trail():
    await _record(
        service_key="sms.texin",
        operation_type="sms.send",
        status="success",
        quantity=2,
        operation_id="sms:texin:manual-test-1",
        occurred_at=datetime(2026, 6, 10, 10, 0, 0),
    )
    async with AsyncSessionLocal() as db:
        created = await costs.create_cost_entry(
            db,
            admin_id="test-admin",
            service_key="sms.texin",
            period_start=datetime(2026, 6, 1),
            period_end=datetime(2026, 7, 1),
            currency="KES",
            manually_entered_cost_minor=1500,
            notes="Provider invoice",
        )
    entry_id = created["entry"]["id"]

    report = await _report(datetime(2026, 6, 1), datetime(2026, 7, 1))
    sms = _row(report, "sms.texin")
    assert sms["effective_cost_minor"] == 1500
    assert sms["manually_entered_cost_minor"] == 1500
    # The usage-derived estimate is retained, not overwritten.
    assert sms["estimated_cost_minor"] == 58
    assert sms["cost_source"] == "manual"
    assert sms["requests_success"] == 1

    async with AsyncSessionLocal() as db:
        await costs.update_cost_entry(
            db,
            admin_id="test-admin",
            entry_id=entry_id,
            manually_entered_cost_minor=1200,
            reason="Provider invoice corrected",
        )

    report = await _report(datetime(2026, 6, 1), datetime(2026, 7, 1))
    sms = _row(report, "sms.texin")
    assert sms["effective_cost_minor"] == 1200
    assert sms["cost_source"] == "adjusted"
    assert sms["adjusted_cost_minor"] == 1200
    assert sms["estimated_cost_minor"] == 58
    assert sms["requests_success"] == 1  # usage was not deleted

    async with AsyncSessionLocal() as db:
        adjustment = (
            await db.execute(
                select(ServiceCostAdjustment)
                .where(ServiceCostAdjustment.entry_id == entry_id)
                .order_by(ServiceCostAdjustment.id.desc())
                .limit(1)
            )
        ).scalar_one()
        assert adjustment.original_estimate_minor == 58
        assert adjustment.adjusted_amount_minor == 1200
        assert adjustment.adjusted_by == "test-admin"

        audit = (
            await db.execute(
                select(AuditLog).where(
                    AuditLog.action == "service_cost_entry_updated",
                    AuditLog.resource_id == str(entry_id),
                )
            )
        ).scalar_one_or_none()
        assert audit is not None
        assert audit.actor_id == "test-admin"


# ── Historical pricing ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_price_changes_do_not_rewrite_past_events():
    await _record(
        service_key="sms.africas_talking",
        operation_type="sms.send",
        status="success",
        quantity=1,
        operation_id="sms:at:history-jan",
        occurred_at=datetime(2026, 1, 10, 10, 0, 0),
    )
    async with AsyncSessionLocal() as db:
        await costs.create_pricing(
            db,
            admin_id="test-admin",
            service_key="sms.africas_talking",
            pricing_unit="sms_segment",
            unit_price_minor=100,
            currency="KES",
            effective_from=datetime(2026, 2, 1),
            pricing_source="test invoice",
        )
    await _record(
        service_key="sms.africas_talking",
        operation_type="sms.send",
        status="success",
        quantity=1,
        operation_id="sms:at:history-feb",
        occurred_at=datetime(2026, 2, 10, 10, 0, 0),
    )

    async with AsyncSessionLocal() as db:
        rows = (
            await db.execute(
                select(ServiceUsageEvent)
                .join(ServiceCatalog, ServiceCatalog.id == ServiceUsageEvent.service_id)
                .where(
                    ServiceCatalog.service_key == "sms.africas_talking",
                    ServiceUsageEvent.operation_id.in_(
                        ["sms:at:history-jan", "sms:at:history-feb"]
                    ),
                )
                .order_by(ServiceUsageEvent.occurred_at)
            )
        ).scalars().all()
    assert [r.unit_price_minor for r in rows] == [80, 100]
    assert [r.estimated_cost_minor for r in rows] == [80, 100]

    january = _row(
        await _report(datetime(2026, 1, 1), datetime(2026, 2, 1)),
        "sms.africas_talking",
    )
    february = _row(
        await _report(datetime(2026, 2, 1), datetime(2026, 3, 1)),
        "sms.africas_talking",
    )
    assert january["effective_cost_minor"] == 80
    assert february["effective_cost_minor"] == 100


# ── Idempotency ─────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_duplicate_provider_operation_is_recorded_once():
    op = "email:resend:duplicate-test"
    first = await _record(
        service_key="email.resend",
        operation_type="email.send",
        status="success",
        quantity=1,
        provider_reference="dup-message",
        operation_id=op,
        occurred_at=datetime(2026, 7, 5, 10, 0, 0),
    )
    second = await _record(
        service_key="email.resend",
        operation_type="email.send",
        status="success",
        quantity=1,
        provider_reference="dup-message",
        operation_id=op,
        occurred_at=datetime(2026, 7, 5, 10, 0, 0),
    )
    assert first is not None
    assert second is None

    report = await _report(datetime(2026, 7, 1), datetime(2026, 8, 1))
    email = _row(report, "email.resend")
    assert email["requests_total"] == 1
    assert email["usage_quantity"] == 1


# ── Reporting boundaries ────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_reporting_period_is_half_open():
    await _record(
        service_key="push.fcm",
        operation_type="push.send",
        status="success",
        quantity=1,
        operation_id="fcm:boundary-start",
        occurred_at=datetime(2026, 8, 1, 0, 0, 0),
    )
    await _record(
        service_key="push.fcm",
        operation_type="push.send",
        status="success",
        quantity=1,
        operation_id="fcm:boundary-end",
        occurred_at=datetime(2026, 9, 1, 0, 0, 0),
    )
    august = _row(
        await _report(datetime(2026, 8, 1), datetime(2026, 9, 1)),
        "push.fcm",
    )
    # The instant at `to` belongs to the next period, exactly once.
    assert august["requests_total"] == 1


# ── Currency separation ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_currencies_are_reported_separately_never_summed():
    async with AsyncSessionLocal() as db:
        await costs.create_cost_entry(
            db,
            admin_id="test-admin",
            service_key="infra.vercel",
            period_start=datetime(2026, 10, 1),
            period_end=datetime(2026, 11, 1),
            currency="USD",
            actual_cost_minor=8500,
            invoice_reference="VERCEL-OCT",
        )
        await costs.create_cost_entry(
            db,
            admin_id="test-admin",
            service_key="infra.sentry",
            period_start=datetime(2026, 10, 1),
            period_end=datetime(2026, 11, 1),
            currency="KES",
            actual_cost_minor=500000,
            invoice_reference="SENTRY-OCT",
        )

    report = await _report(datetime(2026, 10, 1), datetime(2026, 11, 1))
    vercel = _row(report, "infra.vercel")
    sentry = _row(report, "infra.sentry")
    assert (vercel["effective_cost_minor"], vercel["currency"]) == (8500, "USD")
    assert (sentry["effective_cost_minor"], sentry["currency"]) == (500000, "KES")
    assert set(report["currencies"]) == {"KES", "USD"}
    by_currency = {row["currency"]: row for row in report["totals_by_currency"]}
    assert by_currency["USD"]["effective_cost_minor"] == 8500
    assert by_currency["KES"]["effective_cost_minor"] >= 500000


# ── Retention / rollups ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_rollup_preserves_totals_without_double_counting():
    old = datetime.utcnow() - timedelta(days=500)
    old = old.replace(microsecond=0)
    op = f"tts.edge:rollup:{uuid.uuid4().hex}"
    await _record(
        service_key="tts.edge",
        operation_type="tts.speak",
        status="success",
        quantity=1,
        operation_id=op,
        occurred_at=old,
    )

    async with AsyncSessionLocal() as db:
        archived = await costs.rollup_old_usage(db, now=datetime.utcnow())
    assert archived >= 1

    async with AsyncSessionLocal() as db:
        raw = (
            await db.execute(
                select(func.count(ServiceUsageEvent.id)).where(
                    ServiceUsageEvent.operation_id == op
                )
            )
        ).scalar_one()
        assert raw == 0
        daily = (
            await db.execute(
                select(ServiceUsageDaily).where(
                    ServiceUsageDaily.day == old.date()
                )
            )
        ).scalars().all()
        assert daily
        totals = await costs.usage_totals(
            db, old - timedelta(days=1), old + timedelta(days=2)
        )
    assert any(bucket["requests"] >= 1 for bucket in totals.values())


# ── Admin API ───────────────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_cost_endpoints_reject_non_admins(client, ordinary):
    response = await client.get(
        "/admin/revenue/costs/services", headers=_headers(ordinary)
    )
    assert response.status_code == 403
    response = await client.post(
        "/admin/revenue/costs/entries",
        headers=_headers(ordinary),
        json={
            "service_key": "infra.render_api",
            "period_start": "2026-09-01T00:00:00Z",
            "period_end": "2026-10-01T00:00:00Z",
            "currency": "KES",
            "actual_cost_minor": 100,
        },
    )
    assert response.status_code == 403
    assert (await client.get("/admin/revenue/costs/services")).status_code in (401, 403)


@pytest.mark.asyncio
async def test_cost_entry_api_validates_and_keeps_history(client, admin):
    headers = _headers(admin)
    payload = {
        "service_key": "infra.render_api",
        "period_start": "2026-09-01T00:00:00Z",
        "period_end": "2026-10-01T00:00:00Z",
        "currency": "KES",
        "actual_cost_minor": 5000000,
        "invoice_reference": "RENDER-SEP-2026",
        "notes": "September Render invoice",
    }
    created = await client.post(
        "/admin/revenue/costs/entries", headers=headers, json=payload
    )
    assert created.status_code == 201, created.text
    entry_id = created.json()["entry"]["id"]

    duplicate = await client.post(
        "/admin/revenue/costs/entries", headers=headers, json=payload
    )
    assert duplicate.status_code == 409
    assert "already exists" in duplicate.json()["detail"]

    bad_currency = dict(payload, currency="RUPIAH")
    assert (
        await client.post(
            "/admin/revenue/costs/entries", headers=headers, json=bad_currency
        )
    ).status_code == 422
    bad_period = dict(
        payload,
        period_start="2026-09-01T00:00:00Z",
        period_end="2026-09-01T00:00:00Z",
    )
    assert (
        await client.post(
            "/admin/revenue/costs/entries", headers=headers, json=bad_period
        )
    ).status_code == 422

    services = await client.get(
        "/admin/revenue/costs/services",
        headers=headers,
        params={"from": "2026-09-01", "to": "2026-10-01", "service_key": "infra.render_api"},
    )
    assert services.status_code == 200, services.text
    row = next(
        r for r in services.json()["services"] if r["service_key"] == "infra.render_api"
    )
    assert row["effective_cost_minor"] == 5000000
    assert row["cost_source"] == "invoice"
    assert row["confidence"] == "exact"

    patched = await client.patch(
        f"/admin/revenue/costs/entries/{entry_id}",
        headers=headers,
        json={"manually_entered_cost_minor": 4500000, "reason": "Invoice credit"},
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["entry"]["manually_entered_cost_minor"] == 4500000

    adjustments = await client.get(
        "/admin/revenue/costs/adjustments",
        headers=headers,
        params={"from": "2026-09-01", "to": "2026-10-02"},
    )
    assert adjustments.status_code == 200
    rows = adjustments.json()["adjustments"]
    assert any(r["adjusted_amount_minor"] == 4500000 for r in rows)

    missing = await client.patch(
        "/admin/revenue/costs/entries/999999",
        headers=headers,
        json={"manually_entered_cost_minor": 1},
    )
    assert missing.status_code == 404


@pytest.mark.asyncio
async def test_pricing_api_closes_old_prices_instead_of_rewriting(client, admin):
    headers = _headers(admin)
    created = await client.post(
        "/admin/revenue/costs/pricing",
        headers=headers,
        json={
            "service_key": "infra.vercel",
            "pricing_unit": "month",
            "unit_price_minor": 100000,
            "currency": "KES",
            "effective_from": "2026-12-01T00:00:00Z",
            "pricing_source": "Vercel Pro plan",
            "confidence": "exact",
        },
    )
    assert created.status_code == 201, created.text
    pricing_id = created.json()["pricing"]["id"]

    duplicate = await client.post(
        "/admin/revenue/costs/pricing",
        headers=headers,
        json={
            "service_key": "infra.vercel",
            "pricing_unit": "month",
            "unit_price_minor": 100000,
            "currency": "KES",
            "effective_from": "2026-12-01T00:00:00Z",
            "pricing_source": "duplicate",
        },
    )
    assert duplicate.status_code == 409

    future = await client.patch(
        f"/admin/revenue/costs/pricing/{pricing_id}",
        headers=headers,
        json={"unit_price_minor": 120000, "reason": "Plan changed"},
    )
    assert future.status_code == 200, future.text
    assert future.json()["pricing"]["unit_price_minor"] == 120000

    listed = await client.get(
        "/admin/revenue/costs/pricing",
        headers=headers,
        params={"service_key": "sms.texin"},
    )
    assert listed.status_code == 200
    active = [
        p for p in listed.json()["pricing"]
        if p["effective_until"] is None and p["unit_price_minor"] == 29
    ]
    assert active
    rewrite = await client.patch(
        f"/admin/revenue/costs/pricing/{active[0]['id']}",
        headers=headers,
        json={"unit_price_minor": 99},
    )
    # A price already in force cannot be edited: that would rewrite history.
    assert rewrite.status_code == 409


@pytest.mark.asyncio
async def test_summary_and_period_validation(client, admin):
    headers = _headers(admin)
    summary = await client.get(
        "/admin/revenue/costs/summary",
        headers=headers,
        params={"from": "2026-04-01", "to": "2026-05-01"},
    )
    assert summary.status_code == 200, summary.text
    body = summary.json()
    assert body["reporting_period"]["start"].startswith("2026-04-01")
    assert "totals_by_currency" in body
    assert "notes" in body

    same = await client.get(
        "/admin/revenue/costs/services",
        headers=headers,
        params={"from": "2026-04-01T00:00:00Z", "to": "2026-04-01T00:00:00Z"},
    )
    assert same.status_code == 422
