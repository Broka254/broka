"""
BROKA v3.0 - Deal Status WebSocket Router
-----------------------------------------
Endpoint: GET /deal-ws/{deal_id}?token=<jwt>

Buyers and sellers connect here after a deal is created to receive
real-time status updates without polling.

Message format (server → client):
{
  "type":      "deal_status",
  "deal_id":   "abc-123",
  "status":    "paid" | "released" | "refunded" | "disputed" | "dispute_resolved" | "agreed",
  "timestamp": "2026-06-20T12:34:56.789Z",
  "detail":    "Optional human-readable note",
  "meta":      { "amount": 210000, ... }   // optional extra data
}

Ping / keepalive (client → server):
{ "type": "ping" }

Server replies:
{ "type": "pong", "deal_id": "abc-123" }

On connect, the server immediately sends the current deal status so the
client doesn't have to make a separate HTTP call.
"""
from __future__ import annotations

import json
import logging

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import AsyncSessionLocal, Deal
from api.security import decode_token
from api.core.deal_hub import deal_hub, DealStatusEvent

logger = logging.getLogger(__name__)
router = APIRouter()


async def _get_deal(deal_id: str) -> dict | None:
    """Fetch current deal state from DB (fire-and-forget DB session)."""
    try:
        async with AsyncSessionLocal() as db:
            r = await db.execute(select(Deal).where(Deal.id == deal_id))
            deal = r.scalar_one_or_none()
            if not deal:
                return None
            return {
                "id":         deal.id,
                "status":     deal.status.value,
                "buyer_id":   deal.buyer_id,
                "seller_id":  deal.seller_id,
                "agreed_price": deal.agreed_price,
                "commission": deal.commission,
            }
    except Exception as e:
        logger.error("[deal_ws] DB error: %s", e)
        return None


@router.websocket("/ws/{deal_id}")
async def deal_status_ws(
    deal_id:   str,
    websocket: WebSocket,
    token:     str = Query(...),
):
    """
    WebSocket endpoint for real-time deal status updates.

    Connect:
        wss://<host>/deal-ws/ws/<deal_id>?token=<jwt>
    """
    # ── Authenticate ──────────────────────────────────────────────────────────
    payload = decode_token(token)
    if not payload:
        await websocket.close(code=4001, reason="Invalid or expired token")
        return

    user_id = payload.get("sub")
    if not user_id:
        await websocket.close(code=4001, reason="Token missing subject")
        return

    # ── Validate deal access ──────────────────────────────────────────────────
    deal_data = await _get_deal(deal_id)
    if not deal_data:
        await websocket.close(code=4004, reason="Deal not found")
        return

    if user_id not in (deal_data["buyer_id"], deal_data["seller_id"]):
        await websocket.close(code=4003, reason="Access denied to this deal")
        return

    # ── Connect to hub ────────────────────────────────────────────────────────
    await deal_hub.connect(deal_id, websocket)

    try:
        # ── Send current status immediately on connect ────────────────────────
        init_event = DealStatusEvent(
            type="deal_status",
            deal_id=deal_id,
            status=deal_data["status"],
            detail="Connected — current status",
            meta={
                "agreed_price": deal_data["agreed_price"],
                "commission":   deal_data["commission"],
            },
        )
        await websocket.send_text(init_event.to_json())
        logger.info("[deal_ws] connected user=%s deal=%s status=%s",
                    user_id, deal_id, deal_data["status"])

        # ── Message loop ──────────────────────────────────────────────────────
        while True:
            raw = await websocket.receive_text()

            # Handle ping keepalive
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            if msg.get("type") == "ping":
                await websocket.send_text(json.dumps({
                    "type":    "pong",
                    "deal_id": deal_id,
                }))

            # Clients can also request a status refresh
            elif msg.get("type") == "refresh":
                fresh = await _get_deal(deal_id)
                if fresh:
                    refresh_event = DealStatusEvent(
                        type="deal_status",
                        deal_id=deal_id,
                        status=fresh["status"],
                        detail="Status refresh",
                    )
                    await websocket.send_text(refresh_event.to_json())

    except WebSocketDisconnect:
        logger.info("[deal_ws] disconnected user=%s deal=%s", user_id, deal_id)
    except Exception as e:
        logger.error("[deal_ws] error user=%s deal=%s: %s", user_id, deal_id, e)
    finally:
        await deal_hub.disconnect(deal_id, websocket)
