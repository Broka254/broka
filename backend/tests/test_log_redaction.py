"""Ordinary logs must not become a second store of credentials or receipts."""
from __future__ import annotations

import logging

import pytest

from api.core import push_devices
from api.core.observability import LatencyLogMiddleware
from api.domains.payments import test_charge


@pytest.mark.asyncio
async def test_forgetting_a_device_does_not_log_its_token(monkeypatch, caplog):
    class Session:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        async def execute(self, *args, **kwargs):
            return None

        async def commit(self):
            return None

    monkeypatch.setattr(push_devices, "AsyncSessionLocal", Session)
    token = "FCM_CREDENTIAL_SECRET_987654"
    with caplog.at_level(logging.INFO, logger=push_devices.logger.name):
        await push_devices.forget(token)

    assert token not in caplog.text
    assert "987654" not in caplog.text
    assert "dead device token forgotten" in caplog.text


@pytest.mark.asyncio
async def test_test_charge_does_not_log_the_provider_receipt(caplog):
    receipt = "QK_PROVIDER_RECEIPT_123"
    with caplog.at_level(logging.INFO, logger=test_charge.logger.name):
        await test_charge.zetupay_settled(None, "payment-reference", receipt)

    assert receipt not in caplog.text
    assert "payment-reference" in caplog.text


@pytest.mark.asyncio
async def test_callback_secret_is_redacted_from_http_logs(caplog):
    secret = "daraja-callback-secret-value"

    async def app(scope, receive, send):
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    middleware = LatencyLogMiddleware(app)
    scope = {
        "type": "http", "method": "POST",
        "path": f"/mpesa/callback/{secret}", "headers": [],
    }
    with caplog.at_level(logging.INFO, logger="api.core.observability"):
        await middleware(scope, None, lambda message: _noop_send(message))

    assert secret not in caplog.text
    assert "/mpesa/callback/{secret}" in caplog.text


async def _noop_send(message):
    return None
