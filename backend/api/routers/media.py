"""
BROKA - Media Router
Handles voice note, image and document uploads for negotiations.
Voice notes and images are stored as base64 in the NegotiationMessage row
itself (no external object storage required); an image is first processed
like a listing photo (api/core/image_processing.py: validated, upright,
metadata stripped). A document is a ChatFile row the message names
(api/models/chat_file.py), fetched by the thread's two people only. The
Flutter client sends multipart/form-data with the file bytes and the
negotiation metadata; we persist and broadcast.

POST /media/upload
  Multipart body: listing_id, buyer_id (optional), role, content_type (audio|image|file), file
  Returns: MessageOut-compatible dict including media_url (a data URI, or
  /media/chat-files/{id} for a document) and file_name/file_size/file_mime.

GET /media/chat-files/{file_id}
  A chat document, for the buyer and seller of its thread only.

GET /media/ws/{listing_id}
  WebSocket endpoint for real-time message delivery.
  Clients connect with ?token=<jwt>. Any new message (text, voice, image)
  is broadcast to all connections for the same thread.
"""

import asyncio
import base64
import hashlib
import json
import logging
import re
import uuid
from datetime import datetime as _dt
from typing import Dict, List, Optional

from fastapi import (
    APIRouter, Depends, File, Form, HTTPException,
    Query, Response, UploadFile, WebSocket, WebSocketDisconnect,
)
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError

from api.core.chat_files import (
    MAX_FILE_BYTES, FileRejected, accept_document, content_disposition, file_fields,
)
from api.core.image_processing import ImageRejected, process_image
from api.core.rate_limit import chat_media_daily_limiter, chat_media_limiter
from api.database import get_db, NegotiationMessage, Listing, User
from api.models.chat_file import ChatFile
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


def _store_thread_key(store_id: str, buyer_id: str) -> str:
    return f"store:{store_id}:{buyer_id}"


# Keepalive for the chat socket. The server pings every interval; a socket
# that has sent nothing at all - not a ping, not a pong - for STALE seconds
# is dead in a way TCP hasn't noticed (a mobile radio drop sends no FIN) and
# is closed. The app pings on its own every 25s, so a live app never gets
# near it.
CHAT_WS_PING_SECONDS = 25
CHAT_WS_STALE_SECONDS = CHAT_WS_PING_SECONDS * 4


# Typing broadcasts are throttled per sender: a phone emits them while the
# user types, but the thread only hears about it at most every 2 seconds -
# otherwise every keystroke becomes a socket write to every other device.
_typing_last: Dict[str, float] = {}
TYPING_THROTTLE_SECONDS = 2.0


async def _broadcast_typing(key: str, sender_uid: str, sender_role: str, *, typing: bool) -> None:
    """Relay a typing state change to the other participant's devices only.

    Never stored: typing is presence, not a message, so it shares the
    receipt path's shape (role + thread) without touching the database."""
    import time as _time

    now = _time.monotonic()
    throttle_key = f"{key}:{sender_uid}"
    if typing:
        last = _typing_last.get(throttle_key, 0.0)
        if now - last < TYPING_THROTTLE_SECONDS:
            return
        _typing_last[throttle_key] = now
    else:
        _typing_last.pop(throttle_key, None)
    await _broadcast(
        key,
        {"type": "typing" if typing else "stop_typing", "role": sender_role},
        exclude_uid=sender_uid,
    )


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
                continue
            # Typing presence: relayed to the other side's devices only, never
            # stored. The sender's role comes from the authenticated socket,
            # never from the payload, and unknown payloads are ignored.
            if isinstance(msg, dict) and msg.get("type") in ("typing", "stop_typing"):
                try:
                    await _broadcast_typing(
                        key, uid, "seller" if is_seller else "buyer",
                        typing=(msg.get("type") == "typing"),
                    )
                except Exception:
                    pass
                continue
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


def _reply_preview_dict(m: NegotiationMessage) -> Optional[dict]:
    """Quote preview for socket/REST payloads. Only direct-chat rows carry a
    reference, so this never serialises a private Zeno turn."""
    import json as _json

    raw = getattr(m, "reply_snapshot", None)
    if raw:
        try:
            parsed = _json.loads(raw) if isinstance(raw, str) else raw
            if isinstance(parsed, dict):
                return parsed
        except Exception:
            pass
    return None


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
        "edited_at":    (m.edited_at.isoformat() + "Z") if getattr(m, "edited_at", None) else None,
        "deleted_at":   (m.deleted_at.isoformat() + "Z") if getattr(m, "deleted_at", None) else None,
        "deleted":      getattr(m, "deleted_at", None) is not None,
        "reply_to_message_id": getattr(m, "reply_to_message_id", None),
        "reply_preview": _reply_preview_dict(m),
        **file_fields(m),
    }



# ── Upload endpoint — voice notes, images and documents ───────────────────────

MAX_VOICE_MB = 5
MAX_IMAGE_MB = 10

# A voice note is stored with the type its upload declared, and that type
# rides to the other phone inside a data: URI. Only audio: a declared
# "text/html" or "image/svg+xml" was stored and relayed as a "voice note".
_AUDIO_TYPE_RE = re.compile(r"audio/[a-z0-9][a-z0-9.+-]{0,40}")

# What one voice note can last: the recorder's own limit is far below this.
MAX_VOICE_SECONDS = 3600


def _max_bytes(content_type: str) -> int:
    if content_type == "file":
        return MAX_FILE_BYTES
    return (MAX_VOICE_MB if content_type == "audio" else MAX_IMAGE_MB) * 1024 * 1024


@router.post("/upload")
async def upload_media(
    listing_id:    Optional[str] = Form(default=None),
    store_id:      Optional[str] = Form(default=None),
    sender_role:   str       = Form(...),
    sender_id:     str       = Form(...),
    content_type:  str       = Form(...),   # "audio" | "image" | "file"
    buyer_id:      Optional[str] = Form(default=None),
    duration_secs: Optional[int] = Form(default=None),
    # The id the sender's app gave this voice note or photo before sending
    # it - see NegotiationMessage.client_msg_id.
    client_msg_id: Optional[str] = Form(default=None, max_length=64),
    # Optional quote-reply reference (multipart field, same rules as text).
    reply_to_message_id: Optional[str] = Form(default=None, max_length=64),
    # Optional caption for an image or a document, shown with it.
    caption: Optional[str] = Form(default=None, max_length=2000),
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """
    Upload a voice note, image or document into a negotiation thread.
    A voice note or photo is stored as a base64 data URI in
    NegotiationMessage.media_url; a document as a ChatFile row the message
    names (api/models/chat_file.py). After saving, the message is broadcast
    via WebSocket to all thread participants.
    """
    authenticated_uid = current_user["id"]
    if sender_id != authenticated_uid:
        raise HTTPException(status_code=403, detail="sender_id mismatch")
    if bool(listing_id) == bool(store_id):
        raise HTTPException(status_code=400, detail="listing_id or store_id required")
    # Keyed by the signed-in user. Nothing limited this: every upload is
    # decoded (a photo), stored and pushed to the other side.
    await chat_media_limiter.check_and_record(authenticated_uid)
    await chat_media_daily_limiter.check_and_record(authenticated_uid)

    listing = None
    store = None
    if store_id:
        from api.models.store import Store
        store = (await db.execute(
            select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
        )).scalar_one_or_none()
        if not store:
            raise HTTPException(status_code=404, detail="Store not found")
        actual_role = "seller" if authenticated_uid == store.owner_id else "buyer"
    else:
        result = await db.execute(select(Listing).where(Listing.id == listing_id))
        listing = result.scalar_one_or_none()
        if not listing:
            raise HTTPException(status_code=404, detail="Listing not found")
        actual_role = "seller" if authenticated_uid == listing.seller_id else "buyer"
    if sender_role != actual_role:
        raise HTTPException(status_code=403,
            detail=f"Role mismatch: you are the {actual_role}")

    # Unlike a listing's seller, a store owner cannot be mapped to one
    # implicit buyer: every shopper's thread is separate. Falling back to
    # the latest one here would deliver a reply or photo to whichever buyer
    # happened to write last, so require the thread the owner is answering.
    if store_id and actual_role == "seller" and not buyer_id:
        raise HTTPException(
            status_code=400,
            detail="buyer_id is required for a store reply",
        )
    if store_id and actual_role == "seller":
        from api.routers.negotiate import _store_buyer_started_thread
        if not await _store_buyer_started_thread(db, store_id, buyer_id):
            raise HTTPException(
                status_code=403,
                detail="No existing conversation with this buyer",
            )

    # Validate content type
    if content_type not in ("audio", "image", "file"):
        raise HTTPException(status_code=400,
            detail="content_type must be 'audio', 'image' or 'file'")

    client_msg_id = (client_msg_id or "").strip() or None
    if client_msg_id:
        # A resend of something that already arrived (the first attempt's
        # answer was lost to a timeout): hand back what was stored.
        earlier = await sent_with_client_id(db, authenticated_uid, client_msg_id)
        if earlier is not None:
            return _upload_response(earlier)

    max_bytes = _max_bytes(content_type)
    # Read one byte past the limit and no more: a whole upload read to
    # learn it was too big held up to the 32 MB body cap in memory first.
    file_bytes = await file.read(max_bytes + 1)
    if len(file_bytes) > max_bytes:
        raise HTTPException(status_code=413,
            detail=f"File too large (max {max_bytes // (1024 * 1024)} MB)")

    effective_buyer_id: Optional[str] = (
        authenticated_uid if actual_role == "buyer" else buyer_id
    )
    if not effective_buyer_id:
        # As in /negotiate/direct-message: a NULL thread is every buyer's
        # thread, so a seller's photo without a buyer_id reached them all.
        if store_id:
            from api.routers.negotiate import _store_default_buyer
            effective_buyer_id = await _store_default_buyer(db, store_id)
        else:
            from api.routers.negotiate import seller_default_buyer
            effective_buyer_id = await seller_default_buyer(db, listing_id)
        if not effective_buyer_id:
            raise HTTPException(status_code=400, detail="buyer_id required")

    chat_file: Optional[ChatFile] = None
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
        b64 = base64.b64encode(processed.variants["large"][0]).decode()
        media_url = f"data:image/webp;base64,{b64}"
    elif content_type == "audio":
        mime = (file.content_type or "audio/mp4").split(";", 1)[0].strip().lower()
        if not _AUDIO_TYPE_RE.fullmatch(mime):
            raise HTTPException(status_code=415, detail="A voice note must be audio")
        b64 = base64.b64encode(file_bytes).decode()
        media_url = f"data:{mime};base64,{b64}"
    else:
        try:
            file_name, file_mime = accept_document(file.filename or "", file_bytes)
        except FileRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc))
        chat_file = ChatFile(
            id=str(uuid.uuid4()),
            uploader_id=authenticated_uid,
            listing_id=listing_id,
            store_id=store_id,
            buyer_id=effective_buyer_id,
            file_name=file_name,
            mime_type=file_mime,
            size_bytes=len(file_bytes),
            sha256=hashlib.sha256(file_bytes).hexdigest(),
            data=file_bytes,
        )
        media_url = chat_file_url(chat_file.id)

    # Listing threads only: a photo to a seller arms the availability
    # reminder. Store threads have no single listing to chase.
    if actual_role == "buyer" and listing is not None:
        from api.core.interest_arming import arm_availability_nudge
        await arm_availability_nudge(
            db, listing_id, authenticated_uid, seller_id=listing.seller_id,
        )

    from api.routers.negotiate import (
        _audit_off_platform_solicitation,
        _reply_snapshot_json,
        _validate_reply_reference,
    )

    _ref, _preview = await _validate_reply_reference(
        db, (reply_to_message_id or "").strip() or None,
        listing_id=listing_id, buyer_id=effective_buyer_id, store_id=store_id,
    )
    msg_type = {"audio": "voice", "image": "image", "file": "file"}[content_type]
    text = ((caption or "").strip() or None) if content_type != "audio" else None
    nm = NegotiationMessage(
        listing_id=listing_id,
        store_id=store_id,
        sender_id=authenticated_uid,
        role=actual_role,
        recipient_role="seller" if actual_role == "buyer" else "buyer",
        content=text,
        buyer_id=effective_buyer_id,
        via_ai=False,
        msg_type=msg_type,
        media_url=media_url,
        duration_secs=(max(0, min(duration_secs, MAX_VOICE_SECONDS))
                       if content_type == "audio" and duration_secs is not None else None),
        client_msg_id=client_msg_id,
        reply_to_message_id=((reply_to_message_id or "").strip() or None),
        reply_snapshot=_reply_snapshot_json(_preview),
        file_name=chat_file.file_name if chat_file else None,
        file_size=chat_file.size_bytes if chat_file else None,
        file_mime=chat_file.mime_type if chat_file else None,
    )
    if chat_file is not None:
        db.add(chat_file)
    db.add(nm)
    try:
        await db.flush()
        if text:
            # A caption is typed text like any message, and was the one
            # thing a user typed that the contact-leak scan never saw.
            await _audit_off_platform_solicitation(
                db, sender_id=authenticated_uid, message_id=nm.id,
                listing_id=listing_id or f"store:{store_id}",
                role=actual_role, content=text,
            )
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
    key = _store_thread_key(store_id, effective_buyer_id) if store_id else _thread_key(listing_id, effective_buyer_id)
    payload = _msg_to_dict(nm, authenticated_uid, actual_role == "seller")
    await _broadcast(key, payload, exclude_uid=authenticated_uid)

    return _upload_response(nm)


def chat_file_url(file_id: str) -> str:
    """Where a chat document is fetched from: a path on this API, sent with
    the app's own sign-in (never a public storage URL)."""
    return f"/media/chat-files/{file_id}"


@router.get("/chat-files/{file_id}")
async def download_chat_file(
    file_id: str,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """A document shared in a direct chat, for the two people in that chat.

    Anyone else gets 404 - not 403, which would confirm the file exists.
    Sent as an attachment, with its type pinned (nosniff) and a sandbox
    policy, so nothing ever renders one as a page."""
    row = (await db.execute(
        select(ChatFile).where(ChatFile.id == file_id)
    )).scalar_one_or_none()
    uid = current_user["id"]
    allowed = row is not None and uid in (row.buyer_id, row.uploader_id)
    if row is not None and not allowed:
        # The thread's seller: the listing's, or the store's owner.
        if row.store_id:
            from api.models.store import Store
            owner = (await db.execute(
                select(Store.owner_id).where(Store.id == row.store_id)
            )).scalar_one_or_none()
            allowed = owner == uid
        elif row.listing_id:
            seller = (await db.execute(
                select(Listing.seller_id).where(Listing.id == row.listing_id)
            )).scalar_one_or_none()
            allowed = seller == uid
    if not allowed:
        raise HTTPException(status_code=404, detail="File not found")
    return Response(
        content=row.data,
        media_type=row.mime_type,
        headers={
            "Content-Disposition": content_disposition(row.file_name),
            "X-Content-Type-Options": "nosniff",
            "Content-Security-Policy": "sandbox",
            # The file never changes; only these two may have it.
            "Cache-Control": "private, max-age=86400",
        },
    )


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
        "content":       nm.content or "",
        "msg_type":      nm.msg_type,
        "media_url":     nm.media_url,
        "duration_secs": nm.duration_secs,
        "created_at":    (nm.created_at.isoformat() + "Z") if nm.created_at else "",
        "client_msg_id": nm.client_msg_id,
        "edited_at":     (nm.edited_at.isoformat() + "Z") if getattr(nm, "edited_at", None) else None,
        "deleted_at":    (nm.deleted_at.isoformat() + "Z") if getattr(nm, "deleted_at", None) else None,
        "deleted":       getattr(nm, "deleted_at", None) is not None,
        "reply_to_message_id": getattr(nm, "reply_to_message_id", None),
        "reply_preview": _reply_preview_dict(nm),
        **file_fields(nm),
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


async def broadcast_message_update(
    listing_id: str, buyer_id: str, payload: dict,
) -> None:
    """Tell every open copy of a thread that a message changed.

    Sent to the sender's other devices too, not excluded like a new
    message: the phone that made the change has already updated its own
    copy, but the same account on a tablet and the other party both need
    the edit/delete event to stop showing words that no longer exist.
    """
    key = _thread_key(listing_id, buyer_id)
    if _thread_connections.get(key):
        await _broadcast(key, payload)


async def broadcast_store_text_message(
    store_id: str, buyer_id: str, msg: NegotiationMessage, uid: str, is_seller: bool,
) -> None:
    key = _store_thread_key(store_id, buyer_id)
    if key in _thread_connections and _thread_connections[key]:
        await _broadcast(key, _msg_to_dict(msg, uid, is_seller), exclude_uid=uid)


async def broadcast_store_message_update(store_id: str, buyer_id: str, payload: dict) -> None:
    key = _store_thread_key(store_id, buyer_id)
    if _thread_connections.get(key):
        await _broadcast(key, payload)


async def broadcast_store_receipt(
    store_id: str, buyer_id: str, role: str, *,
    exclude_uid: str, delivered_at: Optional[_dt], read_at: Optional[_dt],
) -> None:
    key = _store_thread_key(store_id, buyer_id)
    if not _thread_connections.get(key):
        return

    def _iso(dt: Optional[_dt]) -> Optional[str]:
        return (dt.isoformat() + "Z") if dt else None

    await _broadcast(key, {
        "type": "receipt", "role": role,
        "last_delivered": _iso(delivered_at), "last_read": _iso(read_at),
    }, exclude_uid=exclude_uid)


@router.websocket("/ws/store/{store_id}")
async def store_ws(
    store_id: str,
    websocket: WebSocket,
    token: str = Query(...),
    buyer_id: Optional[str] = Query(default=None),
    db: AsyncSession = Depends(get_db),
):
    """Real-time socket for a store-general thread. Same payloads as the
    listing socket; store threads carry no Zeno/broker rows."""
    try:
        payload = decode_access_token(token)
        if payload is None:
            await websocket.close(code=4001, reason="Invalid or expired token")
            return
        uid = payload["sub"]
    except Exception as e:
        logger.warning("[media-ws] store auth exception store=%s: %s", store_id, e)
        await websocket.close(code=4001, reason="Unauthorized")
        return
    from api.models.store import Store
    store = (await db.execute(
        select(Store).where(Store.id == store_id, Store.deleted_at.is_(None))
    )).scalar_one_or_none()
    if not store:
        await websocket.close(code=4004, reason="Store not found")
        return
    is_seller = (uid == store.owner_id)
    effective_buyer_id = buyer_id if is_seller else uid
    if not effective_buyer_id:
        from api.routers.negotiate import _store_default_buyer
        effective_buyer_id = await _store_default_buyer(db, store_id)
    if not effective_buyer_id:
        await websocket.close(code=4003, reason="buyer_id required for seller")
        return
    key = _store_thread_key(store_id, effective_buyer_id)
    await websocket.accept()
    _thread_connections.setdefault(key, {})[websocket] = uid
    try:
        from api.routers.negotiate import _touch_watermark
        delivered_at = await _touch_watermark(
            db, None, effective_buyer_id, "seller" if is_seller else "buyer",
            delivered=True, read=False, store_id=store_id,
        )
        await broadcast_store_receipt(
            store_id, effective_buyer_id, "seller" if is_seller else "buyer",
            exclude_uid=uid, delivered_at=delivered_at, read_at=None,
        )
    except Exception as exc:
        logger.warning("[media-ws] store delivery watermark failed: %s", exc)
    # visibility-ok: direct store socket; via_ai/broker rows dropped below
    hist_result = await db.execute(
        select(NegotiationMessage)
        .where(NegotiationMessage.store_id == store_id,
               NegotiationMessage.buyer_id == effective_buyer_id)
        .order_by(NegotiationMessage.created_at.desc()).limit(50)
    )
    for m in reversed(list(hist_result.scalars().all())):
        if m.role == "broker" or bool(getattr(m, "via_ai", False)):
            continue
        try:
            await websocket.send_json(_msg_to_dict(m, uid, is_seller))
        except Exception:
            break
    loop = asyncio.get_running_loop()
    last_activity = loop.time()

    async def _heartbeat() -> None:
        while True:
            await asyncio.sleep(CHAT_WS_PING_SECONDS)
            if loop.time() - last_activity > CHAT_WS_STALE_SECONDS:
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
                continue
            if isinstance(msg, dict) and msg.get("type") in ("typing", "stop_typing"):
                try:
                    await _broadcast_typing(key, uid, "seller" if is_seller else "buyer",
                                            typing=(msg.get("type") == "typing"))
                except Exception:
                    pass
                continue
    except WebSocketDisconnect:
        pass
    except Exception as exc:
        logger.info("[media-ws] %s left store thread=%s (%s)", uid, key, type(exc).__name__)
    finally:
        heartbeat_task.cancel()
        _thread_connections.get(key, {}).pop(websocket, None)
        if not _thread_connections.get(key):
            _thread_connections.pop(key, None)


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
