"""WebSocket route for live auction updates. Mirrors deal_ws/router.py's
auth pattern exactly (same decode_token helper, same close-code-on-
rejection convention)."""
from __future__ import annotations

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Query

from api.core.auction_hub import auction_hub
from api.security import decode_token

router = APIRouter()


@router.websocket("/ws/{listing_id}")
async def auction_ws(websocket: WebSocket, listing_id: str, token: str = Query(...)):
    user = decode_token(token)
    if not user:
        await websocket.close(code=4401)
        return
    await auction_hub.connect(listing_id, websocket)
    try:
        while True:
            await websocket.receive_text()  # client only pings; server pushes bid events
    except WebSocketDisconnect:
        pass
    finally:
        await auction_hub.disconnect(listing_id, websocket)
