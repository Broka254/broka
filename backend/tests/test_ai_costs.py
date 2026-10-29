"""AI cost capture: pricing math, provider hooks, derived fees.

Pins cost_ledger.ai_cost_minor (DeepSeek off-peak math, free-tier zero,
unpriced providers, unknown tokens), proves one representative hook per
call chain records exactly one row on success and none on failure, and
proves revenue.py derives collection fees without stored payment_fee rows.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from unittest.mock import AsyncMock, patch

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import func, select

from api.core.cost_ledger import ai_cost_minor, record_ai_cost
from api.database import AsyncSessionLocal, User, init_db, reset_engine
from api.models.listing_payment import ListingPayment
from api.models.platform_cost import CostKind, PlatformCost
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_ai_costs.db"
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


async def _admin_headers() -> dict:
    tag = uuid.uuid4().hex[:10]
    user = User(
        name="Admin",
        phone=f"+2547{tag}",
        email=f"{tag}@aicosts.test",
        password_hash="x",
        is_admin=True,
    )
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


async def _ai_rows() -> list:
    async with AsyncSessionLocal() as db:
        return (
            await db.execute(
                select(PlatformCost)
                .where(PlatformCost.kind == CostKind.AI)
                .order_by(PlatformCost.id)
            )
        ).scalars().all()


# ── Pricing math (pure function, no DB) ──────────────────────────────────────

def test_deepseek_prices_off_peak_and_stays_estimated():
    # 1M in + 1M out at $0.15/$0.60 = $0.75 × 129.5 × 100 minor.
    amount, estimated, meta = ai_cost_minor("deepseek", 1_000_000, 1_000_000)
    assert amount == round(0.75 * 129.5 * 100)
    assert estimated is True
    assert meta["input_tokens"] == 1_000_000
    assert meta["output_tokens"] == 1_000_000


def test_free_tier_providers_bill_zero_without_estimate():
    amount, estimated, meta = ai_cost_minor("groq", 5000, 300)
    assert amount == 0
    assert estimated is False
    assert meta["free_tier"] is True
    amount, estimated, _ = ai_cost_minor("openrouter", 5000, 300)
    assert (amount, estimated) == (0, False)


def test_unpriced_provider_keeps_tokens_and_flags_estimated():
    amount, estimated, meta = ai_cost_minor("gemini", 2000, 150)
    assert amount == 0
    assert estimated is True
    assert meta["unpriced"] is True
    assert meta["input_tokens"] == 2000
    assert meta["output_tokens"] == 150


def test_unknown_tokens_price_to_zero_with_flag():
    amount, estimated, meta = ai_cost_minor("deepseek", None, 150)
    assert amount == 0
    assert estimated is True
    assert meta["tokens_unknown"] is True


# ── Hook integration: one row per answered call, none on failure ─────────────

_DEEPSEEK_BODY = {
    "choices": [{"message": {"content": "hello"}}],
    "usage": {"prompt_tokens": 1000, "completion_tokens": 50},
}
_GEMINI_BODY = {
    "candidates": [{"content": {"parts": [{"text": "hi"}]}}],
    "usageMetadata": {"promptTokenCount": 700, "candidatesTokenCount": 30},
}


class _Resp:
    def __init__(self, body, status_code=200):
        self._body = body
        self.status_code = status_code
        self.text = "err"

    def json(self):
        return self._body

    def raise_for_status(self):
        if self.status_code != 200:
            raise ValueError(f"HTTP {self.status_code}")


def _mock_post(body, status_code=200):
    mock_post = AsyncMock(return_value=_Resp(body, status_code))

    class _Client:
        def __init__(self, *a, **k):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

        post = mock_post

    return patch("httpx.AsyncClient", _Client)


@pytest.mark.asyncio
async def test_negotiate_deepseek_hook_records_priced_row():
    from api.routers import negotiate

    before = len(await _ai_rows())
    with (
        patch.object(negotiate, "DEEPSEEK_API_KEY", "k"),
        _mock_post(_DEEPSEEK_BODY),
    ):
        text = await negotiate._call_deepseek(
            "sys", [{"role": "user", "content": "hi"}]
        )
    assert text == "hello"
    rows = await _ai_rows()
    assert len(rows) == before + 1
    row = rows[-1]
    assert row.provider == "deepseek"
    assert row.estimated is True
    # 1000 in × $0.15 + 50 out × $0.60 per 1M, × 129.5 × 100.
    assert row.amount_minor == round((0.00015 + 0.00003) * 129.5 * 100)
    assert row.meta["input_tokens"] == 1000
    assert row.meta["call_site"] == "negotiate_chat"


@pytest.mark.asyncio
async def test_negotiate_gemini_hook_records_unpriced_row_with_tokens():
    from api.routers import negotiate

    before = len(await _ai_rows())
    with (
        patch.object(negotiate, "GEMINI_API_KEY", "k"),
        _mock_post(_GEMINI_BODY),
    ):
        text = await negotiate._call_gemini(
            "sys", [{"role": "user", "content": "hi"}]
        )
    assert text == "hi"
    rows = await _ai_rows()
    assert len(rows) == before + 1
    row = rows[-1]
    assert row.provider == "gemini"
    assert row.amount_minor == 0
    assert row.estimated is True
    assert row.meta["unpriced"] is True
    assert row.meta["input_tokens"] == 700
    assert row.meta["output_tokens"] == 30


@pytest.mark.asyncio
async def test_failed_call_records_nothing():
    from api.routers import negotiate

    before = len(await _ai_rows())
    with (
        patch.object(negotiate, "GROQ_API_KEY", "k"),
        _mock_post({"error": "nope"}, status_code=500),
    ):
        with pytest.raises(ValueError):
            await negotiate._call_groq(
                "sys", [{"role": "user", "content": "hi"}]
            )
    assert len(await _ai_rows()) == before


@pytest.mark.asyncio
async def test_ai_broker_openrouter_hook_records_free_row():
    from api.domains.ai_broker import service as broker

    before = len(await _ai_rows())
    # _call_openrouter is an instance method using only self.openrouter_key.
    obj = object.__new__(broker.AIBrokerService)
    obj.openrouter_key = "k"
    body = {
        "choices": [{"message": {"content": "yo"}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5},
    }
    with _mock_post(body):
        text = await broker.AIBrokerService._call_openrouter(
            obj, [{"role": "user", "content": "hi"}]
        )
    assert text == "yo"
    rows = await _ai_rows()
    assert len(rows) == before + 1
    row = rows[-1]
    assert row.provider == "openrouter"
    assert row.amount_minor == 0
    assert row.estimated is False
    assert row.meta["free_tier"] is True
    assert row.meta["call_site"] == "ai_broker"


@pytest.mark.asyncio
async def test_accounting_failure_never_breaks_the_reply():
    from api.routers import negotiate

    with (
        patch.object(negotiate, "GROQ_API_KEY", "k"),
        _mock_post(
            {
                "choices": [{"message": {"content": "fine"}}],
                "usage": {"prompt_tokens": 1, "completion_tokens": 1},
            }
        ),
        patch(
            "api.core.cost_ledger.record_cost_detached",
            new=AsyncMock(side_effect=RuntimeError("db down")),
        ),
    ):
        # record_ai_cost swallows the failure; the reply still lands.
        text = await negotiate._call_groq(
            "sys", [{"role": "user", "content": "hi"}]
        )
    assert text == "fine"


# ── Derived collection fees ──────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_revenue_derives_fees_without_stored_rows(client):
    headers = await _admin_headers()
    tag = uuid.uuid4().hex[:10]
    now = datetime.utcnow()
    async with AsyncSessionLocal() as db:
        # Succeeded Daraja listing payment of KES 200 → M-Pesa band KES 3.
        db.add(
            ListingPayment(
                user_id=tag,
                listing_id=f"listing-{tag}",
                months=2,
                monthly_fee=100,
                listing_amount=200,
                amount=200,
                phone="+254700000001",
                status="success",
                provider="daraja",
                created_at=now - timedelta(days=1),
            )
        )
        # A stored payment_fee row must be IGNORED (derived figure rules).
        db.add(
            PlatformCost(
                kind=CostKind.PAYMENT_FEE,
                amount_minor=99999,
                currency="KES",
                provider="zetupay",
                estimated=True,
                created_at=now - timedelta(days=1),
            )
        )
        await db.commit()
    r = await client.get(
        "/admin/revenue",
        params={
            "from": (now - timedelta(days=7)).isoformat() + "Z",
            "to": (now + timedelta(days=1)).isoformat() + "Z",
            "bucket": "day",
        },
        headers=headers,
    )
    assert r.status_code == 200
    body = r.json()
    kinds = {k["key"]: k for k in body["costs"]["kinds"]}
    assert kinds["payment_fee"]["amount_minor"] == 300  # KES 3 band, not 99999
    assert kinds["payment_fee"]["count"] == 1
    assert kinds["payment_fee"]["estimated"] is False  # Daraja band ≤ 1000
    assert sum(p["costs_minor"] for p in body["series"]) >= 300
    assert any("derived" in n.lower() for n in body["notes"])
