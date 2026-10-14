"""
BROKA v3.0 - Deal Status WebSocket Hub
---------------------------------------
Maintains a registry of WebSocket connections keyed by deal_id.
When escrow service fires an event (funded, released, refunded, disputed),
the hub broadcasts a typed status update to every client watching that deal.

Usage in a route:
    await deal_hub.connect(deal_id, websocket)
    deal_hub.disconnect(deal_id, websocket)
    await deal_hub.broadcast(deal_id, DealStatusEvent(...))

Broadcasts from domain events (wired in events.py subscribers):
    EscrowFunded     → status: "paid"
    EscrowReleased   → status: "released"
    EscrowRefunded   → status: "refunded"
    DisputeOpened    → status: "disputed"
    DisputeResolved  → status: "dispute_resolved"
    DealFinalized    → status: "agreed"
"""
from __future__ import annotations

import asyncio
import json
import logging
from dataclasses import dataclass, field, asdict
from datetime import datetime
from typing import Dict, Optional, Set

from fastapi import WebSocket, WebSocketDisconnect

logger = logging.getLogger(__name__)


# ── Event payload ─────────────────────────────────────────────────────────────

@dataclass
class DealStatusEvent:
    """Typed event sent over the WebSocket to Flutter clients."""
    type: str                              # "deal_status" always
    deal_id: str
    status: str                            # agreed|paid|released|refunded|disputed|dispute_resolved
    timestamp: str = field(
        default_factory=lambda: datetime.utcnow().isoformat() + "Z"
    )
    detail: Optional[str] = None           # human-readable note
    meta: Optional[dict] = None            # extra payload (amounts, etc.)

    def to_json(self) -> str:
        d = asdict(self)
        d["type"] = "deal_status"
        return json.dumps(d)


# ── Connection Manager ────────────────────────────────────────────────────────

class DealHub:
    """
    Thread-safe (asyncio) WebSocket connection registry for deal status streams.

    Clients subscribe to a deal_id; the hub fan-outs status events to all
    WebSocket connections watching that deal (buyer + seller can both be
    connected simultaneously).
    """

    def __init__(self):
        # deal_id → set of active WebSocket connections
        self._rooms: Dict[str, Set[WebSocket]] = {}
        self._lock = asyncio.Lock()

    async def connect(self, deal_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            if deal_id not in self._rooms:
                self._rooms[deal_id] = set()
            self._rooms[deal_id].add(websocket)
        logger.info("[deal_hub] connected   deal=%s  clients=%d",
                    deal_id, len(self._rooms[deal_id]))

    async def disconnect(self, deal_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            room = self._rooms.get(deal_id, set())
            room.discard(websocket)
            if not room:
                self._rooms.pop(deal_id, None)
        logger.info("[deal_hub] disconnected deal=%s", deal_id)

    async def broadcast(self, deal_id: str, event: DealStatusEvent) -> None:
        """Send event to every client watching this deal. Dead sockets are cleaned up."""
        room = self._rooms.get(deal_id, set())
        if not room:
            return
        payload = event.to_json()
        dead: list[WebSocket] = []
        for ws in list(room):
            try:
                await ws.send_text(payload)
            except Exception:
                dead.append(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    self._rooms.get(deal_id, set()).discard(ws)
        logger.info("[deal_hub] broadcast  deal=%s  status=%s  clients=%d",
                    deal_id, event.status, len(room) - len(dead))

    async def broadcast_raw(self, deal_id: str, payload: dict) -> None:
        """Broadcast a raw dict (e.g. ping/ack messages)."""
        event = DealStatusEvent(
            type="deal_status",
            deal_id=deal_id,
            status=payload.get("status", "update"),
            detail=payload.get("detail"),
            meta=payload.get("meta"),
        )
        await self.broadcast(deal_id, event)

    def connection_count(self, deal_id: str) -> int:
        return len(self._rooms.get(deal_id, set()))

    def total_connections(self) -> int:
        return sum(len(v) for v in self._rooms.values())


# Singleton — imported by routers + event subscribers
deal_hub = DealHub()
