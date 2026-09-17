"""
BROKA - Deal Status WebSocket Tests (v3.0)
Tests hub broadcast, reconnection-safe message format, and auth rejection.
Run: pytest backend/tests/test_deal_ws.py -v
"""

import pytest
import pytest_asyncio
import asyncio
import json
from httpx import AsyncClient, ASGITransport

from main import app
from api.database import init_db, reset_engine
from api.core.deal_hub import deal_hub, DealStatusEvent


@pytest.fixture(scope="module", autouse=True)
def set_test_db(tmp_path_factory):
    db_path = tmp_path_factory.mktemp("data") / "test_ws.db"
    mp = pytest.MonkeyPatch()
    mp.setenv("DATABASE_URL", f"sqlite+aiosqlite:///{db_path}")
    # See api/database.py:reset_engine - the engine is built once at
    # first import, so DATABASE_URL must be re-applied here or this
    # module silently shares the db every other test module is using.
    reset_engine()
    yield
    mp.undo()


@pytest_asyncio.fixture(scope="module", autouse=True)
async def setup_db():
    await init_db()


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def _verified_token(client, phone: str) -> str:
    """Runs otp/request -> otp/verify, returns a phone_verify_token.

    v6.1 registration is phone-first: register requires a verified-phone
    token instead of a bare phone number (see test_auth.py).
    """
    req = await client.post("/auth/otp/request", json={"phone": phone})
    code = req.json()["debug_code"]
    verify = await client.post("/auth/otp/verify", json={"phone": phone, "code": code})
    return verify.json()["phone_verify_token"]


@pytest_asyncio.fixture(scope="module")
async def seller_token(client):
    phone = "0700555666"
    verify_token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": "WS Seller", "email": "wsseller@test.ke",
        "password": "WsSeller123!",
        "lat": -1.3, "lng": 36.8,
    })
    resp = await client.post("/auth/login", json={
        "phone": phone, "password": "WsSeller123!",
    })
    return resp.json()["access_token"]


@pytest_asyncio.fixture(scope="module")
async def buyer_token(client):
    phone = "0700333444"
    verify_token = await _verified_token(client, phone)
    await client.post("/auth/register", json={
        "phone_verify_token": verify_token,
        "name": "WS Buyer", "email": "wsbuyer@test.ke",
        "password": "WsBuyer123!",
        "lat": -1.3, "lng": 36.8,
    })
    resp = await client.post("/auth/login", json={
        "phone": phone, "password": "WsBuyer123!",
    })
    return resp.json()["access_token"]


class TestDealHub:
    """Unit tests for the DealHub in-process broadcast."""

    @pytest.mark.asyncio
    async def test_broadcast_to_connected_clients(self):
        """Connected mock WebSocket should receive broadcast."""
        received = []

        class MockWs:
            async def accept(self): pass
            async def send_text(self, text): received.append(text)

        ws1 = MockWs()
        deal_id = "test-deal-hub-001"
        await deal_hub.connect(deal_id, ws1)

        event = DealStatusEvent(
            type="deal_status",
            deal_id=deal_id,
            status="paid",
            detail="Test broadcast",
        )
        await deal_hub.broadcast(deal_id, event)

        assert len(received) == 1
        payload = json.loads(received[0])
        assert payload["status"]  == "paid"
        assert payload["deal_id"] == deal_id
        assert payload["type"]    == "deal_status"
        assert "timestamp" in payload

        await deal_hub.disconnect(deal_id, ws1)

    @pytest.mark.asyncio
    async def test_no_broadcast_to_disconnected(self):
        """After disconnect, no messages should be received."""
        received = []

        class MockWs:
            async def accept(self): pass
            async def send_text(self, text): received.append(text)

        ws = MockWs()
        deal_id = "test-deal-hub-002"
        await deal_hub.connect(deal_id, ws)
        await deal_hub.disconnect(deal_id, ws)

        event = DealStatusEvent(
            type="deal_status", deal_id=deal_id, status="released"
        )
        await deal_hub.broadcast(deal_id, event)
        assert len(received) == 0

    @pytest.mark.asyncio
    async def test_multi_client_broadcast(self):
        """Multiple clients on same deal all receive the broadcast."""
        received_1, received_2 = [], []

        class MockWs1:
            async def accept(self): pass
            async def send_text(self, text): received_1.append(text)

        class MockWs2:
            async def accept(self): pass
            async def send_text(self, text): received_2.append(text)

        deal_id = "test-deal-hub-003"
        ws1, ws2 = MockWs1(), MockWs2()
        await deal_hub.connect(deal_id, ws1)
        await deal_hub.connect(deal_id, ws2)
        assert deal_hub.connection_count(deal_id) == 2

        event = DealStatusEvent(
            type="deal_status", deal_id=deal_id, status="disputed"
        )
        await deal_hub.broadcast(deal_id, event)

        assert len(received_1) == 1
        assert len(received_2) == 1
        assert json.loads(received_1[0])["status"] == "disputed"
        assert json.loads(received_2[0])["status"] == "disputed"

        await deal_hub.disconnect(deal_id, ws1)
        await deal_hub.disconnect(deal_id, ws2)

    @pytest.mark.asyncio
    async def test_dead_client_removed(self):
        """Clients that raise on send_text are auto-removed."""
        class DeadWs:
            async def accept(self): pass
            async def send_text(self, text):
                raise RuntimeError("Connection closed")

        deal_id = "test-deal-hub-004"
        ws = DeadWs()
        await deal_hub.connect(deal_id, ws)
        assert deal_hub.connection_count(deal_id) == 1

        event = DealStatusEvent(
            type="deal_status", deal_id=deal_id, status="released"
        )
        await deal_hub.broadcast(deal_id, event)

        # Dead socket should have been cleaned up
        assert deal_hub.connection_count(deal_id) == 0


class TestDealStatusEvent:
    def test_event_serialisation(self):
        e = DealStatusEvent(
            type="deal_status",
            deal_id="deal-abc",
            status="paid",
            detail="Funds held",
            meta={"amount": 50000},
        )
        raw = e.to_json()
        parsed = json.loads(raw)
        assert parsed["type"]    == "deal_status"
        assert parsed["deal_id"] == "deal-abc"
        assert parsed["status"]  == "paid"
        assert parsed["detail"]  == "Funds held"
        assert parsed["meta"]["amount"] == 50000
        assert "timestamp" in parsed

    def test_event_has_timestamp(self):
        e = DealStatusEvent(type="deal_status", deal_id="x", status="agreed")
        assert "T" in e.timestamp or "Z" in e.timestamp


class TestDealWsEndpoint:
    """Integration test: WS endpoint rejects invalid tokens."""

    @pytest.mark.asyncio
    async def test_ws_rejects_invalid_token(self, client):
        with pytest.raises(Exception):
            async with client.websocket_connect(
                "/deal-ws/ws/fake-deal-id?token=not-a-real-token"
            ) as ws:
                await ws.receive_text()

    @pytest.mark.asyncio
    async def test_ws_rejects_missing_token(self, client):
        with pytest.raises(Exception):
            async with client.websocket_connect(
                "/deal-ws/ws/fake-deal-id"
            ) as ws:
                await ws.receive_text()
