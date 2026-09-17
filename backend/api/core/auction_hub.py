"""Real-time auction hub — same connect/disconnect/broadcast-by-id shape
as deal_hub.py, keyed by listing_id instead of deal_id (Ch.6). A separate
hub, not a merge — deals and auctions have different watchers and event
shapes.

Mirrors deal_hub.py's actual implementation (class-based singleton,
asyncio.Lock-protected connection set, typed broadcast event) rather than
a plain module-level function sketch, since the source spec's own
instruction is to match that file's shape exactly, and the real file is
class-based, not function-based.
"""
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, asdict
from fastapi import WebSocket


@dataclass
class BidUpdateEvent:
    type: str
    listing_id: str
    bidder_id: str
    amount: float

    def to_json(self) -> str:
        return json.dumps(asdict(self))


class AuctionHub:
    def __init__(self) -> None:
        self._connections: dict[str, set[WebSocket]] = {}
        self._lock = asyncio.Lock()

    async def connect(self, listing_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        async with self._lock:
            self._connections.setdefault(listing_id, set()).add(websocket)

    async def disconnect(self, listing_id: str, websocket: WebSocket) -> None:
        async with self._lock:
            conns = self._connections.get(listing_id)
            if conns:
                conns.discard(websocket)
                if not conns:
                    self._connections.pop(listing_id, None)

    async def broadcast(self, listing_id: str, event: BidUpdateEvent) -> None:
        async with self._lock:
            targets = list(self._connections.get(listing_id, set()))
        dead = []
        for ws in targets:
            try:
                await ws.send_text(event.to_json())
            except Exception:
                dead.append(ws)
        if dead:
            async with self._lock:
                conns = self._connections.get(listing_id)
                if conns:
                    for ws in dead:
                        conns.discard(ws)
                    if not conns:
                        self._connections.pop(listing_id, None)


auction_hub = AuctionHub()
