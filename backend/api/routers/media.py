"""
BROKA - Media Router
Handles voice note and image uploads for negotiations.
Files are stored as base64 in the NegotiationMessage row itself (no external
object storage required); an image is first processed like a listing photo
(api/core/image_processing.py: validated, upright, metadata stripped). The
Flutter client sends multipart/form-data with the file bytes and the
negotiation metadata; we persist and broadcast.

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
from sqlalchemy.exc import IntegrityError

from api.core.image_processing import ImageRejected, process_image
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


# Keepalive for the chat socket. The server pings every interval; a socket
# that has sent nothing at all - not a ping, not a pong - for STALE seconds
# is dead in a way TCP hasn't noticed (a mobile radio drop sends no FIN) and
# is closed. The app pings on its own every 25s, so a live app never gets
# near it.
CHAT_WS_PING_SECONDS = 25
CHAT_WS_STALE_SECONDS = CHAT_WS_PING_SECONDS * 4


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
        # A seller whose app named no buyer is looking at the most recent
        # buyer's thread (/history's rule). Refusing the socket left exactly
        # that seller with no live chat and no receipts at all.
        from api.routers.negotiate import seller_default_buyer
        effective_buyer_id = await seller_default_buyer(db, listing_id)
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
        delivered_at = await _touch_watermark(
            db, listing_id, effective_buyer_id,
            "seller" if is_seller else "buyer",
            delivered=True, read=False,
        )
        await broadcast_receipt(
            listing_id, effective_buyer_id, "seller" if is_seller else "buyer",
            exclude_uid=uid, delivered_at=delivered_at, read_at=None,
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

    # BUG FIX: this loop was `wait_for(receive_text(), timeout=60)` inside a
    # try whose `except TimeoutError` sent one ping and then fell out of the
    # loop - so every chat socket closed itself after a minute in which
    # nobody typed. The app had no reconnect, and spent the rest of the
    # conversation on its 4-second history poll: messages late, no live
    # receipts, and the poll racing the app's own send, which is what drew
    # a sent message twice. Same shape as the call socket now (calls.py): a
    # plain receive that is never cancelled, and one task that pings and
    # closes a socket gone silent.
    loop = asyncio.get_running_loop()
    last_activity = loop.time()

    async def _heartbeat() -> None:
        while True:
            await asyncio.sleep(CHAT_WS_PING_SECONDS)
            if loop.time() - last_activity > CHAT_WS_STALE_SECONDS:
                logger.info("[media-ws] heartbeat timeout user=%s thread=%s", uid, key)
                try:
                    await websocket.close(code=4000, reason="Heartbeat timeout")
                except Exception:
                    pass
                return
            try:
                await websocket.send_json({"type": "ping"})
            except Exception:
                return

    heartbeat_task = asyncio.create_task(_heartbeat())
    try:
        while True:
            raw = await websocket.receive_text()
            last_activity = loop.time()
            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if isinstance(msg, dict) and msg.get("type") == "ping":
                await websocket.send_json({"type": "pong"})
    except WebSocketDisconnect:
        logger.info("[media-ws] %s disconnected from thread=%s", uid, key)
    except Exception as exc:
        # receive after a heartbeat close, or a send on a socket already gone.
        logger.info("[media-ws] %s left thread=%s (%s)", uid, key, type(exc).__name__)
    finally:
        heartbeat_task.cancel()
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
        # The sender's own id for the message (NegotiationMessage.client_msg_id):
        # how their app, on another device or after a reconnect, recognises
        # the copy it already shows.
        "client_msg_id": getattr(m, "client_msg_id", None),
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
    # The id the sender's app gave this voice note or photo before sending
    # it - see NegotiationMessage.client_msg_id.
    client_msg_id: Optional[str] = Form(default=None, max_length=64),
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

    client_msg_id = (client_msg_id or "").strip() or None
    if client_msg_id:
        # A resend of something that already arrived (the first attempt's
        # answer was lost to a timeout): hand back what was stored.
        earlier = await sent_with_client_id(db, authenticated_uid, client_msg_id)
        if earlier is not None:
            return _upload_response(earlier)

    max_bytes = (MAX_VOICE_MB if content_type == "audio" else MAX_IMAGE_MB) * 1024 * 1024
    file_bytes = await file.read()
    if len(file_bytes) > max_bytes:
        raise HTTPException(status_code=413,
            detail=f"File too large (max {MAX_VOICE_MB if content_type == 'audio' else MAX_IMAGE_MB} MB)")

    if content_type == "image":
        # Through the same processing as a listing photo: stored as sent,
        # a phone shot reached the other side of the chat with its EXIF -
        # GPS included, i.e. where the sender was standing - and any bytes
        # at all could be passed off as an image. The largest listing size
        # is kept; it is re-encoded from pixels, so upright and metadata-free.
        try:
            processed = await asyncio.to_thread(process_image, file_bytes)
        except ImageRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc))
        file_bytes = processed.variants["large"][0]
        mime = "image/webp"
    else:
        mime = file.content_type or "audio/mp4"

    # Build data URI
    b64  = base64.b64encode(file_bytes).decode()
    data_uri = f"data:{mime};base64,{b64}"

    effective_buyer_id: Optional[str] = (
        authenticated_uid if actual_role == "buyer" else buyer_id
    )
    if not effective_buyer_id:
        # As in /negotiate/direct-message: a NULL thread is every buyer's
        # thread, so a seller's photo without a buyer_id reached them all.
        from api.routers.negotiate import seller_default_buyer
        effective_buyer_id = await seller_default_buyer(db, listing_id)
        if not effective_buyer_id:
            raise HTTPException(status_code=400, detail="buyer_id required")

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
        client_msg_id=client_msg_id,
    )
    db.add(nm)
    try:
        await db.commit()
    except IntegrityError:
        # The same upload twice at once; the unique index let one in.
        await db.rollback()
        earlier = await sent_with_client_id(db, authenticated_uid, client_msg_id) if client_msg_id else None
        if earlier is not None:
            return _upload_response(earlier)
        raise
    await db.refresh(nm)

    # Broadcast to WebSocket clients in the thread (not back to the sender -
    # they already see their own voice note/image immediately client-side)
    key = _thread_key(listing_id, effective_buyer_id)
    payload = _msg_to_dict(nm, authenticated_uid, actual_role == "seller")
    await _broadcast(key, payload, exclude_uid=authenticated_uid)

    return _upload_response(nm)


async def sent_with_client_id(
    db: AsyncSession, sender_id: str, client_msg_id: str,
) -> Optional[NegotiationMessage]:
    """The message this sender already sent under this client id, if any
    (NegotiationMessage.client_msg_id). Shared with /negotiate/direct-message."""
    # visibility-ok: the sender's own message, looked up by their own id for it
    result = await db.execute(
        select(NegotiationMessage).where(
            NegotiationMessage.sender_id == sender_id,
            NegotiationMessage.client_msg_id == client_msg_id,
        )
    )
    return result.scalars().first()


def _upload_response(nm: NegotiationMessage) -> dict:
    return {
        "id":            nm.id,
        "role":          nm.role,
        "msg_type":      nm.msg_type,
        "media_url":     nm.media_url,
        "duration_secs": nm.duration_secs,
        "created_at":    (nm.created_at.isoformat() + "Z") if nm.created_at else "",
        "client_msg_id": nm.client_msg_id,
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


async def broadcast_receipt(
    listing_id: str,
    buyer_id:   str,
    role:       str,
    *,
    exclude_uid: str,
    delivered_at: Optional[_dt],
    read_at:      Optional[_dt],
) -> None:
    """Tell the thread's open sockets that [role]'s device received (and,
    with read_at, read) the thread up to these moments. The sender's chat
    turns the matching messages' ticks without waiting for its next
    read-status poll. Not sent back to the side whose ticks these are."""
    key = _thread_key(listing_id, buyer_id)
    if not _thread_connections.get(key):
        return

    def _iso(dt: Optional[_dt]) -> Optional[str]:
        return (dt.isoformat() + "Z") if dt else None

    await _broadcast(key, {
        "type":           "receipt",
        "role":           role,
        "last_delivered": _iso(delivered_at),
        "last_read":      _iso(read_at),
    }, exclude_uid=exclude_uid)
