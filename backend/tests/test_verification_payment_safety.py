"""Verification payments: durable initiation, amount checks and replay safety."""
from __future__ import annotations

import asyncio
import uuid

import httpx
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select

from api.database import AsyncSessionLocal, MpesaStatus, User, VerificationPayment, init_db, reset_engine
from api.security import create_access_token
from main import app


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_verification_safety.db"
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


async def _user() -> User:
    tag = uuid.uuid4().hex[:10]
    user = User(name="Verify", phone=f"+2547{tag}", email=f"{tag}@verify.test", password_hash="x")
    async with AsyncSessionLocal() as db:
        db.add(user)
        await db.commit()
        await db.refresh(user)
    return user


def _headers(user: User) -> dict:
    return {"Authorization": f"Bearer {create_access_token({'sub': user.id})}"}


def _callback(checkout: str, amount: float = 299, code: int = 0, receipt: str | None = None) -> dict:
    return {"Body": {"stkCallback": {
        "CheckoutRequestID": checkout, "ResultCode": code, "ResultDesc": "ok",
        "CallbackMetadata": {"Item": [
            {"Name": "Amount", "Value": amount},
            {"Name": "MpesaReceiptNumber", "Value": receipt or f"V{uuid.uuid4().hex[:10].upper()}"},
        ]},
    }}}


class _FixedClient:
    checkout = "ws_CO_verify_fixed"
    calls = 0

    def __init__(self, *a, **kw):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc):
        return False

    async def post(self, *a, **kw):
        type(self).calls += 1

        class _Resp:
            status_code = 200

            @staticmethod
            def json():
                return {
                    "ResponseCode": "0",
                    "CheckoutRequestID": _FixedClient.checkout,
                    "MerchantRequestID": "merchant",
                    "CustomerMessage": "Check your phone",
                }

        return _Resp()


class _TimeoutClient(_FixedClient):
    async def post(self, *a, **kw):
        type(self).calls += 1
        raise httpx.TimeoutException("ambiguous")


@pytest.mark.asyncio
async def test_daraja_timeout_keeps_a_blocking_intent(client, monkeypatch):
    user = await _user()
    _TimeoutClient.calls = 0

    async def token():
        return "tok"

    monkeypatch.setattr("api.routers.verify._get_token", token)
    monkeypatch.setattr("api.routers.verify.httpx.AsyncClient", _TimeoutClient)
    monkeypatch.setattr("api.routers.verify.stk_limiter.check_and_record", lambda *_: asyncio.sleep(0))

    body = {"tier": "basic", "phone_number": "0711111111"}
    first = await client.post("/verify/purchase", json=body, headers=_headers(user))
    second = await client.post("/verify/purchase", json=body, headers=_headers(user))
    assert first.status_code == 503
    assert second.status_code == 409
    assert _TimeoutClient.calls == 1
    async with AsyncSessionLocal() as db:
        rows = (await db.execute(select(VerificationPayment).where(
            VerificationPayment.user_id == user.id))).scalars().all()
    assert len(rows) == 1
    assert rows[0].status == MpesaStatus.pending
    assert rows[0].checkout_request_id is None
    assert rows[0].active_intent == f"verify:{user.id}"


@pytest.mark.asyncio
async def test_same_idempotency_key_does_not_send_a_second_prompt(client, monkeypatch):
    user = await _user()
    _FixedClient.checkout = f"ws_CO_{uuid.uuid4().hex[:10]}"
    _FixedClient.calls = 0

    async def token():
        return "tok"

    monkeypatch.setattr("api.routers.verify._get_token", token)
    monkeypatch.setattr("api.routers.verify.httpx.AsyncClient", _FixedClient)
    monkeypatch.setattr("api.routers.verify.stk_limiter.check_and_record", lambda *_: asyncio.sleep(0))

    headers = {**_headers(user), "X-Idempotency-Key": "verify-once"}
    body = {"tier": "basic", "phone_number": "0711111111"}
    first = await client.post("/verify/purchase", json=body, headers=headers)
    second = await client.post("/verify/purchase", json=body, headers=headers)
    assert first.status_code == second.status_code == 200
    assert first.json()["checkout_request_id"] == second.json()["checkout_request_id"]
    assert _FixedClient.calls == 1


@pytest.mark.asyncio
async def test_wrong_amount_does_not_grant_the_badge(client):
    user = await _user()
    checkout = f"ws_CO_{uuid.uuid4().hex[:10]}"
    async with AsyncSessionLocal() as db:
        db.add(VerificationPayment(
            user_id=user.id, tier="basic", phone="254711111111", amount=299,
            checkout_request_id=checkout, status=MpesaStatus.pending,
            active_intent=f"verify:{user.id}",
        ))
        await db.commit()

    assert (await client.post(
        "/verify/callback", json=_callback(checkout, amount=1),
    )).status_code == 200
    async with AsyncSessionLocal() as db:
        payment = (await db.execute(select(VerificationPayment).where(
            VerificationPayment.checkout_request_id == checkout))).scalar_one()
        stored = (await db.execute(select(User).where(User.id == user.id))).scalar_one()
    assert payment.status == MpesaStatus.failed
    assert payment.active_intent is None
    assert stored.is_verified is False


@pytest.mark.asyncio
async def test_duplicate_success_and_late_failure_cannot_revert_the_badge(client):
    user = await _user()
    checkout = f"ws_CO_{uuid.uuid4().hex[:10]}"
    receipt = f"V{uuid.uuid4().hex[:10].upper()}"
    async with AsyncSessionLocal() as db:
        db.add(VerificationPayment(
            user_id=user.id, tier="basic", phone="254711111111", amount=299,
            checkout_request_id=checkout, status=MpesaStatus.pending,
            active_intent=f"verify:{user.id}",
        ))
        await db.commit()

    success = _callback(checkout, receipt=receipt)
    assert (await client.post("/verify/callback", json=success)).status_code == 200
    assert (await client.post("/verify/callback", json=success)).status_code == 200
    assert (await client.post(
        "/verify/callback", json=_callback(checkout, code=1032, receipt=receipt),
    )).status_code == 200
    async with AsyncSessionLocal() as db:
        payment = (await db.execute(select(VerificationPayment).where(
            VerificationPayment.checkout_request_id == checkout))).scalar_one()
        stored = (await db.execute(select(User).where(User.id == user.id))).scalar_one()
    assert payment.status == MpesaStatus.success
    assert payment.active_intent is None
    assert stored.is_verified is True


@pytest.mark.asyncio
async def test_incomplete_callback_is_rejected_without_changing_payment(client):
    user = await _user()
    checkout = f"ws_CO_{uuid.uuid4().hex[:10]}"
    async with AsyncSessionLocal() as db:
        db.add(VerificationPayment(
            user_id=user.id, tier="basic", phone="254711111111", amount=299,
            checkout_request_id=checkout, status=MpesaStatus.pending,
        ))
        await db.commit()
    body = {"Body": {"stkCallback": {"CheckoutRequestID": checkout}}}
    assert (await client.post("/verify/callback", json=body)).status_code == 400
    async with AsyncSessionLocal() as db:
        payment = (await db.execute(select(VerificationPayment).where(
            VerificationPayment.checkout_request_id == checkout))).scalar_one()
    assert payment.status == MpesaStatus.pending
