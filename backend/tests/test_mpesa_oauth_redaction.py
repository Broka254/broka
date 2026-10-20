"""Daraja OAuth diagnostics must never become a credential leak.

The sandbox/prod OAuth response carries a bearer token, and a rejected
request can echo authentication details. Logs and public error responses
must contain only status/routing facts.
"""
import logging

import pytest
from fastapi import HTTPException


class _Response:
    def __init__(self, status_code: int, body: str, payload=None):
        self.status_code = status_code
        self.text = body
        self._payload = payload

    def json(self):
        if self._payload is None:
            raise ValueError("not json")
        return self._payload


class _Client:
    response = None

    def __init__(self, *args, **kwargs):
        pass

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def get(self, *args, **kwargs):
        return self.response


@pytest.fixture
def mpesa(monkeypatch):
    import api.routers.mpesa as module

    monkeypatch.setattr(module, "CONSUMER_KEY", "consumer-key-must-not-leak")
    monkeypatch.setattr(module, "CONSUMER_SECRET", "consumer-secret-must-not-leak")
    monkeypatch.setattr(module.httpx, "AsyncClient", _Client)
    return module


@pytest.mark.asyncio
async def test_successful_oauth_token_is_not_logged(mpesa, caplog):
    token = "oauth-access-token-must-not-leak"
    _Client.response = _Response(200, f'{{"access_token":"{token}"}}', {"access_token": token})
    caplog.set_level(logging.DEBUG, logger="api.routers.mpesa")

    assert await mpesa._get_access_token() == token

    assert token not in caplog.text
    assert "consumer-key-must-not-leak" not in caplog.text


@pytest.mark.asyncio
async def test_rejected_oauth_body_is_redacted_from_logs_and_response(mpesa, caplog):
    marker = "provider-body-must-not-leak"
    _Client.response = _Response(401, f'{{"errorMessage":"{marker}"}}', {"errorMessage": marker})
    caplog.set_level(logging.DEBUG, logger="api.routers.mpesa")

    with pytest.raises(HTTPException) as raised:
        await mpesa._get_access_token()

    assert raised.value.status_code == 502
    assert marker not in str(raised.value.detail)
    assert marker not in caplog.text
    assert "consumer-key-must-not-leak" not in caplog.text
    assert "consumer-secret-must-not-leak" not in caplog.text
