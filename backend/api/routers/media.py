"""
BROKA - Media Router
Handles voice note and image uploads for negotiations.
Files are stored as base64 in the NegotiationMessage row itself (no external
object storage required). The Flutter client sends multipart/form-data with
the file bytes and the negotiation metadata; we persist and broadcast.

POST /media/upload
  Multipart body: listing_id, buyer_id (optional), role, content_type (audio|image), file
  Returns: MessageOut-compatible dict including media_url (data URI).

GET /media/ws/{listing_id}
  WebSocket endpoint for real-time message delivery.
  Clients connect with ?token=<jwt>. Any new message (text, voice, image)
  is broadcast to all connections for the same thread.
"""

import asyncio
import base64
import json
import logging
import uuid
from datetime import datetime as _dt
from typing import Dict, List, Optional

from fastapi import (
    APIRouter, Depends, File, Form, HTTPException,
    Query, UploadFile, WebSocket, WebSocketDisconnect,
)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db, NegotiationMessage, Listing, User
from api.security import get_current_user, decode_access_token

logger = logging.getLogger(__name__)
router = APIRouter()

# ── WebSocket connection registry ─────────────────────────────────────────────
# Key: "{listing_id}:{buyer_id}" (thread key).  Buyer_id is the buyer's UID.
# Seller connects using the buyer_id of the thread they are viewing.
# Maps each connection to the uid of the user who opened it, so a broadcast
# can exclude the sender's own socket - previously every broadcast went to
# every connection in the thread unconditionally, including the sender's own,
# so a message the sender just posted would echo straight back to them over
# the socket a moment after their optimistic bubble already showed it. That
# self-echo, not any client-side timing bug, was the real cause of messages
# visibly appearing twice.
_thread_connections: Dict[str, Dict[WebSocket, str]] = {}


def _thread_key(listing_id: str, buyer_id: str) -> str:
    return f"{listing_id}:{buyer_id}"


async def _broadcast(key: str, payload: dict, exclude_uid: Optional[str] = None) -> None:
    """Broadcast a JSON message to WebSocket clients in a thread, skipping
    any connection owned by exclude_uid - normally the message's own sender,
    who already sees it immediately via their own optimistic UI update and
    would otherwise get it a second time when it echoed back over the
    socket."""
    dead: List[WebSocket] = []
    for ws, owner_uid in list(_thread_connections.get(key, {}).items()):
        if exclude_uid is not None and owner_uid == exclude_uid:
            continue
        try:
            await ws.send_json(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _thread_connections.get(key, {}).pop(ws, None)


# ── WebSocket — real-time chat ─────────────────────────────────────────────────

@router.websocket("/ws/{listing_id}")
async def negotiate_ws(
    listing_id: str,
    websocket:  WebSocket,
    token:      str = Query(...),
    buyer_id:   Optional[str] = Query(default=None),
    db:         AsyncSession = Depends(get_db),
):
    """
    Real-time WebSocket for a negotiation thread.

    Connect:
      wss://<host>/media/ws/<listing_id>?token=<jwt>[&buyer_id=<uid>]

    The buyer connects with no buyer_id (their own UID is inferred from JWT).
    The seller connects with buyer_id=<uid> to join a specific buyer's thread.

    Server pushes JSON messages of the form:
      {"type": "message", "role": "buyer"|"seller"|"broker",
       "content": "...", "msg_type": "text"|"voice"|"image",
       "media_url": "...", "duration_secs": null, "via_ai": false,
       "sender_id": "...", "created_at": "..."}

    Clients may also send {"type": "ping"} → server replies {"type": "pong"}.
    """
    # Authenticate via JWT query param
    try:
        # Access tokens only: a refresh, call or verify token is signed with
        # the same key but must never open someone's chat thread. See
        # security.decode_access_token.
        payload = decode_access_token(token)
        if payload is None:
            await websocket.close(code=4001, reason="Invalid or expired token")
            return
        uid = payload["sub"]
    except Exception as e:
        logger.warning("[media-ws] auth exception for listing=%s: %s", listing_id, e)
        await websocket.close(code=4001, reason="Unauthorized")
        return

    # Determine thread scope
    result = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        logger.warning("[media-ws] listing not found: %s", listing_id)
        await websocket.close(code=4004, reason="Listing not found")
        return

    is_seller = (uid == listing.seller_id)
    effective_buyer_id = buyer_id if is_seller else uid
    if not effective_buyer_id:
        logger.warning("[media-ws] missing buyer_id for seller=%s listing=%s", uid, listing_id)
        await websocket.close(code=4003, reason="buyer_id required for seller")
        return

    key = _thread_key(listing_id, effective_buyer_id)

    # BUG FIX (communications audit, 2026-09-14): the connection used to be
    # registered in _thread_connections BEFORE accept(). Any broadcast landing
    # in that window called send_json() on a socket the ASGI server had not
    # yet completed the handshake for, which raises - and the raise happens
    # inside _broadcast's per-socket try, so the socket was silently binned
    # as dead. The peer's very first message could therefore vanish for a
    # client that had only just opened the thread, which reads to the user as
    # "the message didn't send". Accept first, then publish.
    await websocket.accept()
    _thread_connections.setdefault(key, {})[websocket] = uid
    logger.info("[media-ws] %s joined thread=%s is_seller=%s", uid, key, is_seller)

    # A live chat socket is the strongest delivery signal there is: this
    # user's device is connected to this exact thread right now. Record it so
    # the other side's ticks advance without waiting for a poll.
    try:
        from api.routers.negotiate import _touch_watermark
        await _touch_watermark(
            db, listing_id, effective_buyer_id,
            "seller" if is_seller else "buyer",
            delivered=True, read=False,
        )
    except Exception as exc:
        # Never fail a chat connection over a receipt.
        logger.warning("[media-ws] delivery watermark failed: %s", exc)

    # Send recent history on connect
    # visibility-ok: direct-chat socket; broker rows are dropped in the loop below
    hist_result = await db.execute(
        select(NegotiationMessage)
        .where(
            NegotiationMessage.listing_id == listing_id,
            NegotiationMessage.buyer_id == effective_buyer_id,
        )
        .order_by(NegotiationMessage.created_at.desc())
        .limit(50)
    )
    recent = list(reversed(hist_result.scalars().all()))
    # This socket backs the DIRECT buyer<->seller chat only. Zeno (broker)
    # replies and any message either party sent through the AI screen
    # (via_ai=True) belong to their own private AI thread and must never be
    # dumped into this channel - mirrors the same rule the REST history
    # endpoint and negotiation_screen.dart's polling path both enforce.
    for m in recent:
        if m.role == "broker" or bool(getattr(m, "via_ai", False)):
            continue
        try:
            await websocket.send_json(_msg_to_dict(m, uid, is_seller))
        except Exception:
            break

    try:
        while True:
            raw = await asyncio.wait_for(websocket.receive_text(), timeout=60)
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if msg.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    except asyncio.TimeoutError:
        # Send keepalive ping
        try:
            await websocket.send_json({"type": "ping"})
        except Exception:
            pass
    except WebSocketDisconnect:
        logger.info("[media-ws] %s disconnected from thread=%s", uid, key)
    finally:
        _thread_connections.get(key, {}).pop(websocket, None)
        if not _thread_connections.get(key):
            _thread_connections.pop(key, None)


def _msg_to_dict(m: NegotiationMessage, uid: str, is_seller: bool) -> dict:
    return {
        "type":         "message",
        "id":           m.id,
        "role":         m.role,
        "sender_id":    m.sender_id,
        "content":      m.content or "",
        "msg_type":     m.msg_type or "text",
        "media_url":    m.media_url or "",
        "duration_secs": m.duration_secs,
        "call_type":    getattr(m, "call_type", None),
        "via_ai":       bool(m.via_ai),
        "created_at":   (m.created_at.isoformat() + "Z") if m.created_at else "",
    }


# ── Upload endpoint — voice notes and images ──────────────────────────────────

MAX_VOICE_MB = 5
MAX_IMAGE_MB = 10


@router.post("/upload")
async def upload_media(
    listing_id:    str       = Form(...),
    sender_role:   str       = Form(...),
    sender_id:     str       = Form(...),
    content_type:  str       = Form(...),   # "audio" | "image"
    buyer_id:      Optional[str] = Form(default=None),
    duration_secs: Optional[int] = Form(default=None),
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Upload a voice note or image into a negotiation thread.
    File is stored as a base64 data URI in NegotiationMessage.media_url.
    After saving, the message is broadcast via WebSocket to all thread participants.
    """
    authenticated_uid = current_user["id"]
    if sender_id != authenticated_uid:
        raise HTTPException(status_code=403, detail="sender_id mismatch")

    result = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    actual_role = "seller" if authenticated_uid == listing.seller_id else "buyer"
    if sender_role != actual_role:
        raise HTTPException(status_code=403,
            detail=f"Role mismatch: you are the {actual_role}")

    # Validate content type
    if content_type not in ("audio", "image"):
        raise HTTPException(status_code=400, detail="content_type must be 'audio' or 'image'")

    max_bytes = (MAX_VOICE_MB if content_type == "audio" else MAX_IMAGE_MB) * 1024 * 1024
    file_bytes = await file.read()
    if len(file_bytes) > max_bytes:
        raise HTTPException(status_code=413,
            detail=f"File too large (max {MAX_VOICE_MB if content_type == 'audio' else MAX_IMAGE_MB} MB)")

    # Build data URI
    mime = file.content_type or ("audio/mp4" if content_type == "audio" else "image/jpeg")
    b64  = base64.b64encode(file_bytes).decode()
    data_uri = f"data:{mime};base64,{b64}"

    effective_buyer_id: Optional[str] = (
        authenticated_uid if actual_role == "buyer" else buyer_id
    )

    msg_type = "voice" if content_type == "audio" else "image"
    nm = NegotiationMessage(
        listing_id=listing_id,
        sender_id=authenticated_uid,
        role=actual_role,
        recipient_role="seller" if actual_role == "buyer" else "buyer",
        content=None,
        buyer_id=effective_buyer_id,
        via_ai=False,
        msg_type=msg_type,
        media_url=data_uri,
        duration_secs=duration_secs if content_type == "audio" else None,
    )
    db.add(nm)
    await db.commit()
    await db.refresh(nm)

    # Broadcast to WebSocket clients in the thread (not back to the sender -
    # they already see their own voice note/image immediately client-side)
    if effective_buyer_id:
        key = _thread_key(listing_id, effective_buyer_id)
        payload = _msg_to_dict(nm, authenticated_uid, actual_role == "seller")
        await _broadcast(key, payload, exclude_uid=authenticated_uid)

    return {
        "id":            nm.id,
        "role":          nm.role,
        "msg_type":      nm.msg_type,
        "media_url":     nm.media_url,
        "duration_secs": nm.duration_secs,
        "created_at":    (nm.created_at.isoformat() + "Z") if nm.created_at else "",
    }


# ── Expose broadcast helper for negotiate.py to call ─────────────────────────

async def broadcast_text_message(
    listing_id: str,
    buyer_id:   str,
    msg:        NegotiationMessage,
    uid:        str,
    is_seller:  bool,
) -> None:
    """Called by negotiate.py after saving a text message so WS clients update
    instantly. Excludes the sender's own connection(s) - see _broadcast."""
    key = _thread_key(listing_id, buyer_id)
    if key in _thread_connections and _thread_connections[key]:
        await _broadcast(key, _msg_to_dict(msg, uid, is_seller), exclude_uid=uid)
