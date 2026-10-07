"""
BROKA - Calls Router
  • WebSocket relay  : /calls/ws/{room_id}   (WebRTC signaling)
  • Register token   : POST /calls/register-token   (and /unregister-token on sign-out)
  • Initiate call    : POST /calls/initiate   (pushes every phone of the callee's, issues room_id + call_token)
  • Call token       : GET  /calls/{room_id}/token   (exchange for callee, e.g. after an FCM tap)
  • Alerted          : POST /calls/{room_id}/alerted   (a callee's phone is ringing -> caller sees "Ringing")
  • Pending call     : GET  /calls/pending/{listing_id}   (callee poll fallback)
  • Incoming call    : GET  /calls/incoming   (the same, on any listing, in one request)
  • TURN credentials : GET  /calls/turn-credentials  (Cloudflare Realtime TURN)

Call SESSION/AUTHORIZATION state (who's on a call, what state it's in) lives
in api/core/call_state.py - Redis-backed when available, so it survives a
backend restart and (for that piece) works across multiple instances. The
live WebSocket connection OBJECTS in `_rooms` below are necessarily still
per-process - a socket object can't be serialized into Redis. That means
cross-instance signaling RELAY (caller on instance A reaching a callee on
instance B) isn't handled yet; today's Render deployment is single-instance,
so this doesn't bite in practice, but it's a known gap if that changes -
would need a Redis pub/sub relay layered on top of _rooms, not a bigger
change to call_state.py itself.
"""

import asyncio
import contextvars
import json
import os
import logging
import secrets
from typing import Dict, Optional

from fastapi import APIRouter, WebSocket, WebSocketDisconnect, Depends, Query, HTTPException
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import or_, select
from sqlalchemy.exc import IntegrityError

from api.database import get_db, AsyncSessionLocal, User, Listing, NegotiationMessage
from api.security import get_current_user, create_call_token, decode_call_token
import httpx

from api.core.client_ip import client_ip as resolve_client_ip
from api.core.timeutil import parse_iso_to_naive_utc
from api.core.config import settings
from api.core import cloudflare_turn_client, call_state, push_devices
from api.core.cloudflare_turn_client import CloudflareTurnError
from api.core.call_state import CallState
from api.core.rate_limit import (
    call_initiate_limiter, turn_credential_limiter,
    call_ws_connect_limiter, call_ws_preauth_limiter,
)

logger = logging.getLogger(__name__)
router = APIRouter()


def _time_now() -> float:
    import time as _t
    return _t.time()

# How long (seconds) to wait for ANY inbound WS activity before proactively
# pinging, and how many consecutive missed pings before the connection is
# treated as dead and closed (Phase 5 - previously absent entirely, so a
# radio-dropped mobile connection was only ever caught by the underlying
# TCP stack's own timeout, which can be minutes). ~3 x 15s gives a
# reconnect a real chance to land before the socket is given up on, while
# still being far faster than TCP's own dead-peer detection.
WS_HEARTBEAT_INTERVAL_SECONDS = 15
WS_HEARTBEAT_MAX_MISSED = 3

# Largest signaling frame we'll accept. A full video SDP offer with a long
# candidate list is comfortably under 64KB; anything above this is either a
# broken client or someone using the relay as a message bus. Rejected per
# message (the connection survives), same as a malformed frame.
WS_MAX_FRAME_BYTES = 128 * 1024

# The only message types one peer may have relayed to the other. Everything
# else a client sends is either handled locally by the server ("pong",
# "state") or dropped.
#
# SECURITY FIX (calling audit, 2026-09-14): the relay used to forward ANY
# message verbatim, including types the server itself generates - so either
# participant could inject a fake {"type":"hangup"} / {"type":"busy"} /
# {"type":"ready"} at the other and end or confuse their call, and the
# client's own "join" announcement (which the server never reads) was
# pointlessly relayed to the peer on every connect. Server-authored control
# types now cannot be spoofed by a peer, because they simply aren't
# relayable.
# "video_state" carries one boolean: whether the sender's camera is
# currently sending. It is purely cosmetic on the receiving side (show the
# remote video surface vs. fall back to the avatar) and cannot influence
# any server-held call state, so relaying it is safe under the same
# reasoning as the SDP/ICE types - unlike "state" above, which is consumed
# server-side and therefore stays un-relayed and value-restricted.
#
# Without it, muting your own camera mid-call left the peer looking at a
# frozen last frame: disabling a track (track.enabled = false) keeps the
# transceiver alive and keeps sending, so no `ended` event ever reaches
# them and there is nothing else in the protocol that would tell them.
WS_RELAYABLE_TYPES = frozenset({"offer", "answer", "ice", "hangup", "video_state"})

# ── In-memory WebSocket registry (per-process - see module docstring) ──────────
# Keyed by user_id (not an anonymous Set) so a reconnecting participant can
# be identified and safely replace their own stale/ghost socket, rather
# than the room being incorrectly treated as "full" by a raw peer count
# that can't tell a genuine second participant from the same user's old,
# not-yet-detected-as-dead connection.
_rooms: Dict[str, Dict[str, WebSocket]] = {}

def _owns_room(room_id: str, room: Dict[str, WebSocket]) -> bool:
    """True when `room` is still the dict registered under `room_id`.

    A signaling handler captures its room dict once, at join, and tears it
    down much later in a `finally` that has awaited several times in
    between. In that window the room can be popped by the other
    participant's handler and a RECONNECT can create a brand new dict under
    the same key - so "my room is empty" and "the registry's room for this
    id is empty" are not the same statement. Acting on the first while
    meaning the second deletes a live call's socket registry: the two peers
    end up in dicts nothing can find each other through, and no offer,
    answer, ICE candidate or restart ever crosses again.

    Extracted rather than inlined so the invariant is testable directly -
    the handler it guards can only be reached through a real WebSocket.
    """
    return _rooms.get(room_id) is room


# ── Firebase Admin (optional - gracefully disabled if not configured) ──────────
_fcm_app = None

def _get_fcm():
    """Lazily initialize Firebase Admin from env var."""
    global _fcm_app
    if _fcm_app is not None:
        return _fcm_app
    raw = os.getenv("FIREBASE_SERVICE_ACCOUNT_JSON")
    if not raw:
        return None
    try:
        import json as _json
        import firebase_admin
        from firebase_admin import credentials
        if not firebase_admin._apps:
            cred       = credentials.Certificate(_json.loads(raw))
            _fcm_app   = firebase_admin.initialize_app(cred)
        else:
            _fcm_app   = firebase_admin.get_app()
        logger.info("[calls] Firebase Admin initialised")
    except Exception as e:
        logger.warning(f"[calls] Firebase Admin init failed: {e}")
        _fcm_app = None
    return _fcm_app


class FcmResult:
    """Outcome of one _send_fcm attempt.

    `unregistered` is kept distinct from a generic failure because it is the
    one failure the CALLER can act on: FCM is telling us this device token
    is permanently dead (app uninstalled, data cleared, token rotated), so
    it should be cleared from the DB rather than retried on every future
    call. Any other failure is transient and the token stays.
    """
    __slots__ = ("sent", "unregistered")

    def __init__(self, sent: bool, unregistered: bool = False):
        self.sent = sent
        self.unregistered = unregistered

    def __bool__(self) -> bool:
        return self.sent


# How long an incoming-call push stays worth delivering. FCM's default TTL
# is FOUR WEEKS: a phone that is off, out of coverage or in deep Doze when
# someone calls gets the push whenever it next reaches the network, and -
# because the client rings on receipt - rings for a call that ended hours
# ago. Matching the TTL to the ring window makes FCM discard it instead,
# which is what "this notification is only useful right now" means on the
# wire. Slightly longer than the 45s client ring timer so a push delivered
# at the edge of the window still has a call to join.
CALL_PUSH_TTL_SECONDS = 60

# When the server decides an unanswered call was missed, if neither phone
# has said so by then. Both apps give up after 45 seconds of ringing and
# report it themselves (POST /log-result); this is for when neither can: the
# caller's app died or lost signal mid-ring, and the callee's app is closed
# with only a notification ringing. Before it, such a call left nothing
# behind - no missed-call notification, no card in the chat.
CALL_RING_TIMEOUT_SECONDS = 55


async def _send_fcm(
    token: str, title: str, body: str, data: dict, *,
    data_only: bool = False, ttl_seconds: Optional[int] = None,
    android_tag: Optional[str] = None, android_channel_id: Optional[str] = None,
    apns_thread_id: Optional[str] = None,
) -> FcmResult:
    """Send an FCM push notification. Returns an FcmResult (truthy on success).

    PERFORMANCE FIX (calling audit, 2026-09-14): firebase_admin's
    messaging.send() is SYNCHRONOUS, blocking network I/O - it opens an
    HTTPS request to Google and waits. Calling it directly from this async
    function blocked the whole event loop for the duration of that round
    trip, which on this single-process deployment meant every other
    in-flight request stalled with it: other users' API calls, and - much
    worse for this specific feature - the WebSocket heartbeat/relay loops
    of every call already in progress. A slow or hanging FCM request could
    therefore stutter or drop live calls that had nothing to do with it.
    Running it on a worker thread keeps the loop free.

    data_only=True omits the FCM 'notification' block entirely. A
    'notification' block gets auto-displayed by the OS using generic
    system styling whenever the app isn't in the foreground - for an
    incoming call that means bypassing our own rich notification
    (full-screen intent, ringtone, Accept/Decline actions) in favor of a
    plain banner. Data-only messages always reach the app's own message
    handlers instead (foreground/background/terminated), which build the
    real incoming-call notification themselves. Every other caller of
    this function (reminders/nudges via workers.py) is unaffected by this
    parameter's default.

    android_tag / android_channel_id shape the notification Android draws
    for a visible push. The tag is what lets the app's own notification for
    the same event replace this one instead of standing beside it: Android
    keys a notification on (tag, id), and FCM draws a tagged one with id 0
    (see NotificationService.missedCallTag in the app). apns_thread_id is
    iOS's equivalent grouping: a conversation's alerts stack together.
    """
    if not _get_fcm():
        logger.info("[calls] FCM not configured - skipping push")
        return FcmResult(False)
    try:
        from datetime import timedelta
        from firebase_admin import messaging

        # FIX (calling audit, 2026-09-18): the APNs half of this was
        # hardcoded to a BACKGROUND push regardless of `data_only`, with a
        # `sound` on it - a combination Apple does not honour. A background
        # push is a silent wake-up: it displays nothing. So every visible
        # notification this helper has ever sent to an iOS device (the deal
        # reminders and nudges in core/workers.py, which call it with
        # data_only=False) was delivered as a silent push and shown to
        # nobody. The push type now follows what the message actually is:
        # data-only -> background (the app draws its own UI, which is the
        # whole point of data_only for an incoming call), otherwise alert,
        # at the priority each type is allowed.
        if data_only:
            apns_headers = {"apns-push-type": "background", "apns-priority": "5"}
            aps = messaging.Aps(content_available=True)
        else:
            apns_headers = {"apns-push-type": "alert", "apns-priority": "10"}
            aps_kwargs = {}
            if apns_thread_id:
                aps_kwargs["thread_id"] = apns_thread_id
            aps = messaging.Aps(
                alert=messaging.ApsAlert(title=title, body=body),
                sound="default",
                **aps_kwargs,
            )
        if ttl_seconds is not None:
            # APNs wants an absolute unix expiry; FCM wants a duration.
            apns_headers["apns-expiration"] = str(int(_time_now()) + ttl_seconds)

        android_kwargs = {
            "priority": "high",
            "ttl": timedelta(seconds=ttl_seconds) if ttl_seconds is not None else None,
        }
        if not data_only and (android_tag or android_channel_id):
            android_kwargs["notification"] = messaging.AndroidNotification(
                tag=android_tag, channel_id=android_channel_id,
            )
        msg = messaging.Message(
            notification=None if data_only else messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in data.items()},
            token=token,
            android=messaging.AndroidConfig(**android_kwargs),
            apns=messaging.APNSConfig(
                headers=apns_headers,
                payload=messaging.APNSPayload(aps=aps),
            ),
        )
        await asyncio.to_thread(messaging.send, msg)
        return FcmResult(True)
    except Exception as e:
        unregistered = type(e).__name__ in (
            "UnregisteredError", "SenderIdMismatchError",
        )
        logger.warning("[calls] FCM send failed (%s): %s", type(e).__name__, e)
        return FcmResult(False, unregistered=unregistered)


async def _send_voip_push(token: str, data: dict) -> bool:
    """Send an APNs PushKit VoIP push (iOS incoming calls).

    Why this can't just be another FCM message: FCM cannot deliver to the
    PushKit `voip` topic. iOS only lets a VoIP push wake a terminated app
    for a call, it must be addressed to `<bundle-id>.voip`, and it needs its
    own APNs auth key - so it is a direct APNs HTTP/2 call, not something
    firebase_admin can route.

    Fails soft and loudly-in-logs-only, exactly like _send_fcm: a call whose
    push doesn't land still exists server-side and is still discoverable by
    the foreground poller. Never raises into the request path.
    """
    if not settings.apns_configured:
        logger.info("[calls] APNs VoIP not configured - skipping VoIP push")
        return False
    try:
        import time as _time
        # python-jose, the same JWT library BROKA's own auth already uses
        # (api/security.py) - NOT PyJWT, which isn't a dependency here.
        # ES256 support needs the `cryptography` backend, which python-jose
        # pulls in via python-jose[cryptography] in requirements.txt.
        from jose import jwt

        # APNs provider tokens are ES256-signed and valid for up to an hour;
        # Apple rate-limits regeneration, so reuse within the window.
        now = int(_time.time())
        global _apns_token_cache
        cached = _apns_token_cache
        if cached and now - cached[1] < 2400:
            provider_token = cached[0]
        else:
            provider_token = jwt.encode(
                {"iss": settings.apns_team_id, "iat": now},
                settings.apns_auth_key,
                algorithm="ES256",
                headers={"kid": settings.apns_key_id},
            )
            _apns_token_cache = (provider_token, now)

        host = ("https://api.push.apple.com" if settings.apns_use_production
                else "https://api.sandbox.push.apple.com")
        headers = {
            "authorization": f"bearer {provider_token}",
            "apns-topic": f"{settings.apns_bundle_id}.voip",
            "apns-push-type": "voip",
            "apns-priority": "10",
            "apns-expiration": "0",
        }
        async with httpx.AsyncClient(http2=True, timeout=10.0) as client:
            resp = await client.post(
                f"{host}/3/device/{token}",
                headers=headers,
                json={k: str(v) for k, v in data.items()},
            )
        if resp.status_code == 200:
            logger.info("[calls] VOIP_PUSH_SENT room=%s", data.get("roomId"))
            return True
        logger.warning("[calls] VoIP push rejected status=%s", resp.status_code)
        return False
    except Exception as e:
        logger.warning("[calls] VoIP push failed (%s): %s", type(e).__name__, e)
        return False


_apns_token_cache = None


# ── Schemas ───────────────────────────────────────────────────────────────────

class RegisterTokenRequest(BaseModel):
    fcm_token: str = Field(..., min_length=1, max_length=4096)
    # "fcm" (Android + iOS non-call notifications) or "apns_voip" (iOS
    # PushKit). Defaults to fcm so an older client that doesn't send this
    # keeps working unchanged.
    token_type: str = "fcm"
    platform: Optional[str] = Field(default=None, max_length=16)


class UnregisterTokenRequest(BaseModel):
    fcm_token: str = Field(..., min_length=1, max_length=4096)


class CallAlertedRequest(BaseModel):
    # The callee's room-scoped call token, which the incoming-call push and
    # GET /calls/pending both carry. A phone acknowledging a call from a
    # closed app has nothing else: its access token is usually expired by
    # then, and renewing it from a background isolate would race the app's
    # own renewal for the same refresh token.
    call_token: str = Field(..., min_length=1, max_length=2048)

class InitiateCallRequest(BaseModel):
    listing_id:   str
    caller_name:  str
    listing_name: Optional[str] = ""
    call_type:    str = "audio"   # "audio" | "video"
    # Required when the SELLER is calling (current user == listing.seller_id).
    # A listing can have many buyer negotiation threads, so unlike the
    # buyer-calls-seller direction (callee is always listing.seller_id -
    # unambiguous), the backend can't infer which buyer to ring on its own.
    # Ignored when the buyer is calling.
    callee_id: Optional[str] = None


class LogCallRequest(BaseModel):
    # Required (Section 16, V2 hardening): identifies the call via its
    # authoritative session - kept around for POST_CALL_GRACE_TTL_SECONDS
    # after the call ends specifically so this lookup works. Every
    # legitimate call has one (server-generated at /initiate).
    room_id: str
    # outcome: "completed" (was answered, regardless of how it ended) |
    #          "missed" (callee never answered) | "declined" (callee rejected)
    outcome:        str
    duration_secs:  Optional[int] = None
    call_type:      str = "audio"   # "audio" | "video" - legacy field, see docstring below
    # Legacy/fallback fields - IGNORED whenever the session lookup above
    # succeeds (the normal case), which derives these authoritatively
    # instead of trusting the client. Kept only so a not-yet-updated
    # client doesn't get a 422 for a missing field; never trusted for
    # anything on their own.
    listing_id: Optional[str] = None
    buyer_id:   Optional[str] = None
    caller_role: Optional[str] = None


# ── Endpoints ─────────────────────────────────────────────────────────────────

@router.get("/turn-credentials")
async def get_turn_credentials(
    current: dict = Depends(get_current_user),
):
    """
    Short-lived Cloudflare Realtime TURN credentials for the ICE
    configuration WebRtcService passes into createPeerConnection() before
    starting a call. STUN-only ICE (the previous hardcoded-TURN setup)
    routinely fails silently on carrier-grade NAT - very common on Kenyan
    mobile data - which looks exactly like "call connects/rings but no
    audio flows"; a TURN relay is what still connects that case.

    No DB access needed - these credentials are Cloudflare-issued and
    ephemeral, never persisted on the BROKA side.
    """
    await turn_credential_limiter.check_and_record(current["id"])
    logger.info("[calls] TURN_CREDENTIAL_REQUESTED user=%s", current["id"])
    try:
        result = await cloudflare_turn_client.generate_ice_servers()
    except CloudflareTurnError as e:
        # Never leak Cloudflare's internal error detail (could include raw
        # response fragments) to the client - log it server-side only,
        # with the user id but no secrets. Neither the Cloudflare API
        # token nor any generated TURN credential ever reaches this log
        # line (see cloudflare_turn_client.py).
        logger.warning("[calls] TURN_CREDENTIAL_FAILED user=%s err=%s", current["id"], e)
        raise HTTPException(
            status_code=503,
            detail="Call relay is temporarily unavailable. Your call may still connect directly.",
        )

    logger.info(
        "[calls] TURN_CREDENTIAL_ISSUED user=%s expires_in=%s",
        current["id"], result["expires_in"],
    )
    return result


@router.post("/register-token")
async def register_token(
    payload: RegisterTokenRequest,
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """Store a device push token so this user gets calls and messages on it.

    Two transports, two kinds. Android (and iOS non-call notifications)
    use FCM. iOS calling additionally needs a PushKit VoIP token: only a
    VoIP push can wake a terminated app for a call, and it is delivered
    over APNs against a different token.

    BUG FIX (notifications review, 2026-10-07): `current` is the dict
    get_current_user returns, and this wrote `current.fcm_token` as if it
    were the User row. Every registration raised AttributeError - a 500 the
    app swallowed - so no phone's token was ever stored, and no call or
    message could reach a phone whose app was closed.

    Each phone is now its own row (api/models/push_device.py): a user signed
    in on two phones gets pushes on both, and a phone that changes hands
    stops getting the previous account's.

    `push_enabled` tells the app whether the server can push at all, so it
    knows whether it can stop polling while in the background.
    """
    if payload.token_type not in push_devices.KINDS:
        raise HTTPException(status_code=400, detail="Unknown token_type")
    await push_devices.register(
        db, current["id"], payload.fcm_token,
        kind=payload.token_type, platform=payload.platform,
    )
    try:
        await db.commit()
    except IntegrityError:
        # The same phone registering twice at once (a token refresh racing
        # a sign-in): the other request created the row, so this one moves it.
        await db.rollback()
        await push_devices.register(
            db, current["id"], payload.fcm_token,
            kind=payload.token_type, platform=payload.platform,
        )
        await db.commit()
    logger.info("[calls] PUSH_TOKEN_REGISTERED user=%s type=%s",
                current["id"], payload.token_type)
    return {
        "status": "ok",
        "token_type": payload.token_type,
        "push_enabled": _get_fcm() is not None,
    }


@router.post("/unregister-token")
async def unregister_token(
    payload: UnregisterTokenRequest,
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """Sign-out on one phone: it stops getting this user's calls, messages
    and alerts. Without it a signed-out phone went on ringing for the
    account that had left it."""
    await push_devices.unregister(db, current["id"], payload.fcm_token)
    await db.commit()
    logger.info("[calls] PUSH_TOKEN_UNREGISTERED user=%s", current["id"])
    return {"status": "ok"}


@router.post("/initiate")
async def initiate_call(
    payload: InitiateCallRequest,
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """
    Called by whichever party is placing the call - buyer or seller -
    BEFORE navigating to the VoIP screen. Generates a fresh, unguessable
    room_id server-side (never client-supplied - a client-chosen id can't
    be trusted as the actual authorization boundary), creates the call
    session in call_state.py, and sends the callee an FCM push with enough
    data to open the VoIP screen as the callee.

    BUG FIX (forensic audit, 2026-09-03): this used to unconditionally
    resolve the callee as listing.seller_id and the caller as current user
    - correct for buyer-calls-seller, but it meant a SELLER trying to call
    a buyer back tripped the self-call guard below (current user ==
    listing.seller_id == the "callee" it had just resolved), so
    seller-initiated calls always failed with 400 and the buyer never saw
    anything. call_state.py's caller_id/callee_id were already generic
    (not buyer_id/seller_id) from the start, so only this resolution logic
    needed fixing, not the session store itself.

    Returns a short-lived call_token scoped to this room_id so the caller's
    WebSocket connection never needs their normal long-lived access token
    in the URL. The callee gets their own call_token from GET
    /calls/pending/{listing_id} (poll path) or GET /calls/{room_id}/token
    (e.g. answering straight from the FCM notification).
    """
    await call_initiate_limiter.check_and_record(current["id"])

    # Resolve the listing
    result  = await db.execute(select(Listing).where(Listing.id == payload.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    # Determine caller/callee explicitly - do NOT assume the seller is
    # always the callee (Phase 4). Whichever side owns the listing is
    # calling OUT; the other side is whoever they're negotiating with.
    if current["id"] == listing.seller_id:
        # Seller calling a specific buyer from one of this listing's
        # negotiation threads - can't be inferred from listing_id alone.
        if not payload.callee_id:
            raise HTTPException(status_code=400,
                                 detail="callee_id is required when the seller initiates a call")
        result = await db.execute(select(User).where(User.id == payload.callee_id))
        callee = result.scalar_one_or_none()
        if not callee:
            raise HTTPException(status_code=404, detail="Buyer not found")
        # A valid user id alone isn't enough authorization to ring them -
        # without this, any seller could call any registered user by
        # supplying an arbitrary callee_id, regardless of whether that
        # person has ever engaged with this listing (Phase 12: arbitrary
        # listing/buyer association). Require an actual prior message on
        # this listing/buyer thread, the same relationship check already
        # used to scope chat history elsewhere (see negotiate.py/media.py).
        # visibility-ok: selects ids only, existence check that a thread exists
        thread_check = await db.execute(
            select(NegotiationMessage.id)
            .where(
                NegotiationMessage.listing_id == payload.listing_id,
                NegotiationMessage.buyer_id == payload.callee_id,
            )
            .limit(1)
        )
        if thread_check.scalar_one_or_none() is None:
            raise HTTPException(
                status_code=403,
                detail="No existing conversation with this buyer on this listing",
            )
        buyer_id_for_thread = callee.id
    else:
        # Buyer calling the listing's seller - the unambiguous, common case.
        result = await db.execute(select(User).where(User.id == listing.seller_id))
        callee = result.scalar_one_or_none()
        if not callee:
            raise HTTPException(status_code=404, detail="Seller not found")
        buyer_id_for_thread = current["id"]

    if callee.id == current["id"]:
        raise HTTPException(status_code=400, detail="You can't call yourself")

    room_id = secrets.token_urlsafe(16)  # unguessable - see call_state.py; matches create_refresh_token()'s sizing
    await call_state.create_session(
        room_id=room_id, caller_id=current["id"], callee_id=callee.id,
        listing_id=payload.listing_id, call_type=payload.call_type,
        caller_name=payload.caller_name,
    )
    await call_state.update_state(room_id, CallState.ringing)
    # The no-answer watchdog looks at it again once nobody could still be
    # waiting for it (see ring_watchdog_tick).
    await call_state.add_ringing(room_id, _time_now() + CALL_RING_TIMEOUT_SECONDS)
    call_token = create_call_token(current["id"], room_id)

    logger.info(
        "[calls] CALL_INITIATED room=%s caller=%s callee=%s type=%s",
        room_id, current["id"], callee.id, payload.call_type,
    )
    logger.info("[calls] CALL_RINGING room=%s", room_id)

    fcm_tokens = await push_devices.tokens_for(db, callee.id, "fcm")
    voip_tokens = await push_devices.tokens_for(db, callee.id, "apns_voip")
    if not fcm_tokens and not voip_tokens:
        # Callee has no push route on any transport. The call still goes
        # ahead - the foreground poller can still find it if their app is
        # open - and if nobody answers, the missed call waits in the chat.
        logger.info("[calls] CALL_NO_PUSH_ROUTE room=%s callee=%s", room_id, callee.id)
        return {"status": "no_token", "message": "Callee has no push token yet",
                "room_id": room_id, "call_token": call_token}

    call_data = {
        "type":        "incoming_call",
        "roomId":      room_id,
        "callerName":  payload.caller_name,
        "callerId":    current["id"],
        "listingName": payload.listing_name or listing.name,
        "listingId":   payload.listing_id,
        "buyerId":     buyer_id_for_thread,  # explicit, not assumed - see fix note above
        "callType":    payload.call_type,
        # The callee's own token for this one room: the phone acknowledges
        # the ring with it (POST /calls/{room_id}/alerted) even from a closed
        # app whose access token has long expired.
        "callToken":   create_call_token(callee.id, room_id),
    }

    for voip_token in voip_tokens:
        # iOS: a PushKit VoIP push is the ONLY thing that reliably wakes a
        # terminated app for a call, and AppDelegate.swift must report it to
        # CallKit the moment it arrives. Sent in addition to (not instead
        # of) FCM, since a user can be signed in on both platforms.
        await _send_voip_push(token=voip_token, data=call_data)

    if not fcm_tokens:
        return {"status": "sent_voip", "room_id": room_id, "call_token": call_token}

    is_video = payload.call_type == "video"
    # Every phone the callee is signed in on rings at once, like WhatsApp;
    # whichever answers or declines takes it, and the others get call_over
    # (_push_ring_over) - or, unanswered, the missed-call push - and stop.
    # Dead tokens are forgotten by push_user.
    pushed = await push_devices.push_user(
        callee.id, db=db,
        title=f"{'📹' if is_video else '📞'} Incoming {'video ' if is_video else ''}call from {payload.caller_name}",
        body=f"About: {payload.listing_name or listing.name}",
        data=call_data,
        data_only=True,
        # An incoming call is the definitive "only useful right now"
        # notification - see CALL_PUSH_TTL_SECONDS.
        ttl_seconds=CALL_PUSH_TTL_SECONDS,
    )

    return {"status": "sent" if pushed else "fcm_disabled",
            "room_id": room_id, "call_token": call_token}


@router.get("/{room_id}/token")
async def get_call_token(
    room_id: str,
    current: dict = Depends(get_current_user),
):
    """
    Exchanges the caller's normal (long-lived) auth for a call_token scoped
    to this one room_id - for the callee, who doesn't get one from
    /initiate (they didn't call it). Used when answering straight from the
    FCM-triggered incoming-call UI, without necessarily having gone through
    GET /pending/{listing_id} first (that path already returns a
    call_token directly, since it does this same check anyway).
    """
    session = await call_state.get_session(room_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Call not found or no longer active")
    if not session.is_participant(current["id"]):
        raise HTTPException(status_code=403, detail="You're not a participant on this call")
    if call_state.is_terminal(session.state):
        raise HTTPException(status_code=410, detail="This call has already ended")
    return {"call_token": create_call_token(current["id"], room_id)}


@router.post("/{room_id}/alerted")
async def call_alerted(room_id: str, payload: CallAlertedRequest):
    """A phone of the callee's is ringing with this call.

    What turns the caller's "Calling..." into "Ringing...", as WhatsApp
    does. The caller's screen used to decide that from the callee's
    presence instead - "They were last seen offline - they may not pick
    up" - which said nothing about whether their phone had the call: a
    closed app is "offline" and rings perfectly well from a push.

    Authorized by the callee's room-scoped call token rather than an access
    token: the phone sends this from a closed app, straight from the push.
    A call that is already over answers 410, so a push that arrived late
    stops ringing at once.
    """
    claims = decode_call_token(payload.call_token)
    if not claims or claims.get("room_id") != room_id:
        raise HTTPException(status_code=401, detail="Invalid call token")
    session = await call_state.get_session(room_id)
    if session is None:
        raise HTTPException(status_code=404, detail="Call not found or no longer active")
    if claims.get("sub") != session.callee_id:
        raise HTTPException(status_code=403, detail="Only the person called can report ringing")
    if call_state.is_terminal(session.state) or session.state not in (
        CallState.initiating, CallState.ringing,
    ):
        # Answered (on this phone or another), declined, missed or ended.
        raise HTTPException(status_code=410, detail="This call is no longer ringing")
    first = not session.callee_alerted
    await call_state.mark_callee_alerted(room_id)
    if first:
        logger.info("[calls] CALLEE_ALERTED room=%s", room_id)
        await _tell_caller_ringing(room_id, session.caller_id)
    return {"status": "ringing"}


# Fire-and-forget pushes started from a request or socket. The event loop
# keeps only a weak reference to a task, so one nobody holds can be
# collected before it finishes.
_background: set = set()


def _spawn(coro) -> None:
    # A fresh context: a task inheriting a request's is cancelled with it
    # (see api/core/message_push.py schedule).
    task = asyncio.create_task(coro, context=contextvars.Context())
    _background.add(task)
    task.add_done_callback(_background.discard)


async def _tell_caller_ringing(room_id: str, caller_id: str) -> None:
    """Server-authored, never relayed: a participant cannot forge it."""
    room = _rooms.get(room_id)
    ws = room.get(caller_id) if room else None
    if ws is None:
        return
    try:
        await ws.send_json({"type": "callee_ringing"})
    except Exception:
        pass


@router.post("/log-result")
async def log_call_result(
    payload: LogCallRequest,
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """
    Record the outcome of a finished call as a chat-thread card, visible to
    BOTH buyer and seller.

    SECURITY FIX (Section 16, V2 hardening): listing_id/buyer_id/
    caller_role used to come straight from the client with no
    verification - any authenticated user could have logged a fake call
    result for any listing/buyer pair, logged a call they weren't on, or
    logged a duplicate/conflicting result for a real one. Now: the
    authoritative call_state.py session (kept around briefly after the
    call ends specifically for this - see POST_CALL_GRACE_TTL_SECONDS) is
    looked up by room_id, the caller must actually be a participant, and
    listing_id/buyer_id/caller_role/call_type are ALL derived from that
    session rather than trusted from the request body.
    mark_result_logged() makes this idempotent - a second attempt for the
    same room_id is rejected outright, so a result can't be duplicated or
    overwritten once recorded.

    Also updates the authoritative call_state.py session to the matching
    terminal state (Section 14) - declined/missed/ended - which the state
    machine already supports (see call_state.py's transition table) but
    previously had no caller wiring it up for this specific path (a
    decline/missed call never joins the WebSocket, so nothing else in the
    system was transitioning the session for those two outcomes).
    """
    if payload.outcome not in ("completed", "missed", "declined", "cancelled"):
        raise HTTPException(status_code=400, detail="Invalid outcome")

    session = await call_state.get_session(payload.room_id)
    if session is None:
        raise HTTPException(
            status_code=404,
            detail="Call session not found - it may have expired, or its result may already be recorded",
        )
    if not session.is_participant(current["id"]):
        raise HTTPException(status_code=403, detail="You're not a participant on this call")

    if not await call_state.mark_result_logged(payload.room_id):
        raise HTTPException(status_code=409, detail="This call's result has already been recorded")

    result  = await db.execute(select(Listing).where(Listing.id == session.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    await _record_outcome(
        db, session, listing, payload.outcome,
        logged_by=current["id"], duration_secs=payload.duration_secs,
    )
    return {"status": "logged", "outcome": payload.outcome}


_OUTCOME_TO_STATE = {
    "declined":  CallState.declined,
    "missed":    CallState.missed,
    # "cancelled" (caller hung up before the callee ever answered) is a
    # distinct outcome for call-history purposes, but reuses the
    # existing `missed` CallState - both are "ringing ended with no
    # answer" at the state-machine level; only who ended it differs,
    # which the outcome label alone already captures.
    "cancelled": CallState.missed,
    "completed": CallState.ended,
}


async def _record_outcome(
    db: AsyncSession, session, listing, outcome: str,
    *, logged_by: Optional[str], duration_secs: Optional[int] = None,
) -> None:
    """Everything that follows a call's outcome, once mark_result_logged()
    has made this the one record of it: the session's terminal state, the
    caller told if they're still waiting, the call card in the thread, and
    the callee's notifications - a missed call announced, a ring stopped on
    their other phones.

    `logged_by` is the participant who reported it, or None when the
    no-answer watchdog decided it (ring_watchdog_tick).
    """
    # Derived, not trusted - whichever of caller/callee ISN'T the listing's
    # seller is the buyer for chat-thread-scoping purposes, regardless of
    # which direction this particular call went (Section 13 symmetry).
    buyer_id    = session.callee_id if session.caller_id == listing.seller_id else session.caller_id
    caller_role = "seller" if session.caller_id == listing.seller_id else "buyer"
    reporter    = logged_by or session.caller_id
    reporter_is_seller = reporter == listing.seller_id

    if not call_state.is_terminal(session.state):
        await call_state.update_state(session.room_id, _OUTCOME_TO_STATE[outcome])

    hangup_reason = {"declined": "declined"}.get(outcome)
    if logged_by is None and outcome == "missed":
        hangup_reason = "no_answer"
    if hangup_reason:
        # The caller's WS connection is very likely still open and waiting
        # (they navigate to the call screen and connect immediately on
        # placing the call) - nothing else tells them the callee declined
        # until their own ~45s ring timer gives up client-side. Notify
        # directly if we can reach them, reusing the existing 'hangup'
        # message type the client already handles - no new protocol needed.
        room = _rooms.get(session.room_id)
        if room:
            caller_ws = room.get(session.caller_id)
            if caller_ws is not None:
                try:
                    await caller_ws.send_json({"type": "hangup", "reason": hangup_reason})
                except Exception:
                    pass

    # Taxonomy alignment (Section 33) - "missed" is what a client-side ring
    # timeout (VoipCallScreen's 45s timer / WebRtcService's own 30s
    # connect timeout) actually reports back as, so it's logged under the
    # same CALL_TIMEOUT event rather than a separate one.
    _event = {"declined": "CALL_DECLINED", "missed": "CALL_TIMEOUT",
              "cancelled": "CALL_CANCELLED", "completed": "CALL_ENDED"}
    logger.info("[calls] %s room=%s listing=%s buyer=%s outcome=%s by=%s",
                _event.get(outcome, "CALL_RESULT"), session.room_id, session.listing_id,
                buyer_id, outcome, logged_by or "server")

    call_msg = NegotiationMessage(
        listing_id=session.listing_id,
        sender_id=reporter,
        role=caller_role,
        recipient_role=None,
        content=outcome,
        buyer_id=buyer_id,
        via_ai=False,
        msg_type="call",
        duration_secs=duration_secs,
        call_type=session.call_type,
    )
    db.add(call_msg)
    await db.commit()
    await db.refresh(call_msg)

    # Broadcast so the other party sees it instantly if they're online.
    try:
        from api.routers.media import broadcast_text_message
        await broadcast_text_message(
            session.listing_id, buyer_id,
            call_msg, logged_by or "server", reporter_is_seller,
        )
    except Exception:
        pass

    if outcome in ("missed", "cancelled"):
        # Both are a call the callee never picked up - "cancelled" only says
        # the caller gave up first. Never a reason to fail the request.
        try:
            await _push_missed_call(db, session, listing, buyer_id)
        except Exception as exc:
            logger.warning("[calls] missed-call push failed room=%s: %s", session.room_id, exc)
    elif outcome == "declined":
        # Declined on one phone: the callee's other phones are still ringing.
        await _push_ring_over(session)


async def _push_ring_over(session) -> None:
    """Stop the ring on the callee's other phones once one of them has
    answered or declined. Only worth a push when there IS another phone -
    the one that acted has already taken its own notification down."""
    try:
        async with AsyncSessionLocal() as own:
            tokens = await push_devices.tokens_for(own, session.callee_id)
        if len(tokens) < 2:
            return
        await push_devices.push_user(
            session.callee_id, title="", body="",
            data={"type": "call_over", "roomId": session.room_id},
            data_only=True, ttl_seconds=CALL_PUSH_TTL_SECONDS,
        )
    except Exception as exc:
        logger.warning("[calls] ring-over push failed room=%s: %s", session.room_id, exc)


# A missed call stays worth telling the callee about for a day; past that, a
# phone that was off gets the call card in the chat instead of a stale alert.
MISSED_CALL_PUSH_TTL_SECONDS = 24 * 3600


async def _push_missed_call(db: AsyncSession, session, listing, buyer_id: str) -> None:
    """Tell the callee, by push, that they missed a call.

    There was no such push. The only missed-call notice was the app's own
    inbox poller noticing the call card - which runs only while the app is
    alive, so a call missed with BROKA closed (the usual way to miss one)
    left nothing on the phone at all, and the ringing notification the
    incoming-call push had posted simply timed out. This is a visible
    notification, not data-only: Android shows it from a closed app without
    the app running. Its roomId lets the app take down that call's ringing
    notification when it is still up.
    """
    is_video = session.call_type == "video"
    callee_role = "seller" if session.callee_id == listing.seller_id else "buyer"
    who = (session.caller_name or "").strip() or "Someone"
    await push_devices.push_user(
        session.callee_id, db=db,
        title=f"Missed {'video ' if is_video else ''}call from {who}",
        body=f"About: {listing.name}",
        data={
            "type":      "missed_call",
            "roomId":    session.room_id,
            "listingId": session.listing_id,
            "buyerId":   buyer_id,
            "myRole":    callee_role,
            "callType":  session.call_type,
            "callerName": who,
            "listingName": listing.name,
        },
        ttl_seconds=MISSED_CALL_PUSH_TTL_SECONDS,
        # One notification per thread's missed calls, shared with the app's
        # own (NotificationService.missedCallTag), on its Messages channel.
        android_tag=f"missed_{session.listing_id}_{buyer_id}",
        android_channel_id="broka_messages",
    )


# ── Call history ──────────────────────────────────────────────────────────────

CALL_HISTORY_MAX_LIMIT = 100


@router.get("/history")
async def get_call_history(
    limit:  int           = Query(default=50, ge=1, le=CALL_HISTORY_MAX_LIMIT),
    before: Optional[str] = Query(default=None),
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """The signed-in user's calls, newest first - the app's Call history.

    Read from the call cards log-result already writes into each thread
    (msg_type "call"), so a call is in the history exactly when it is in
    the chat; there is no second record to drift from the first. Only
    threads the user is in: their own as a buyer (buyer_id) and every
    buyer's on their listings as the seller. A NULL buyer_id belongs to no
    thread (log-result always derives one) and is never shown.

    Direction is the viewer's, from the caller's role stored on the card
    (`role`) - not from `sender_id`, which is whichever side happened to
    log the result first, the callee as often as the caller.

    The other person's name and photo come once per person in `people`,
    not once per call: a photo is an inline base64 image, and fifty calls
    with the same buyer would otherwise carry it fifty times.

    `before` pages backwards: pass the previous page's `next_before`.
    """
    uid = current["id"]
    q = (
        select(NegotiationMessage, Listing)
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(
            NegotiationMessage.msg_type == "call",
            # A call card is written to both sides (log-result); never a
            # copy addressed to one of them.
            NegotiationMessage.recipient_role.is_(None),
            NegotiationMessage.buyer_id.isnot(None),
            or_(NegotiationMessage.buyer_id == uid, Listing.seller_id == uid),
        )
    )
    if before:
        try:
            cursor = parse_iso_to_naive_utc(before)
        except ValueError:
            raise HTTPException(status_code=422, detail="before must be an ISO 8601 time")
        q = q.where(NegotiationMessage.created_at < cursor)
    rows = (await db.execute(
        q.order_by(NegotiationMessage.created_at.desc(), NegotiationMessage.id.desc())
         .limit(limit + 1)
    )).all()
    more = len(rows) > limit
    rows = rows[:limit]

    calls = []
    people_ids: set = set()
    for msg, listing in rows:
        my_role = "seller" if listing.seller_id == uid else "buyer"
        peer_id = msg.buyer_id if my_role == "seller" else listing.seller_id
        people_ids.add(peer_id)
        outcome = (msg.content or "").strip().lower()
        outgoing = msg.role == my_role
        calls.append({
            "id":            msg.id,
            "listing_id":    listing.id,
            "listing_name":  listing.name,
            "buyer_id":      msg.buyer_id,
            "my_role":       my_role,
            "peer_id":       peer_id,
            "direction":     "outgoing" if outgoing else "incoming",
            "outcome":       outcome,
            # The callee never picked up. "cancelled" only says the caller
            # gave up first - to the person called it is still a missed call.
            "missed":        (not outgoing) and outcome in ("missed", "cancelled"),
            "call_type":     msg.call_type or "audio",
            "duration_secs": msg.duration_secs,
            "created_at":    (msg.created_at.isoformat() + "Z") if msg.created_at else None,
        })

    people = {}
    if people_ids:
        from api.core.presence import online_status
        users = (await db.execute(select(User).where(User.id.in_(people_ids)))).scalars().all()
        for u in users:
            is_on, last_seen = online_status(u.last_seen)
            people[u.id] = {
                "name":      u.name,
                "photo":     u.profile_photo,
                "is_online": is_on,
                "last_seen": last_seen,
            }

    return {
        "calls":       calls,
        "people":      people,
        "next_before": calls[-1]["created_at"] if more and calls else None,
    }


# ── WebSocket relay ────────────────────────────────────────────────────────────

@router.websocket("/ws/{room_id}")
async def call_signaling(
    websocket: WebSocket,
    room_id:   str,
    token:     str = Query(default=""),
):
    # This carries live WebRTC SDP/ICE signaling for a call - it must only
    # ever be joined by the two people actually on that call. `token` here
    # is a short-lived call_token (api/security.py's create_call_token,
    # scoped to exactly this room_id) - not the normal long-lived access
    # token, which used to sit in this URL where it could end up in proxy/
    # server access logs. Authorization is re-checked fresh against
    # call_state (Redis-backed) rather than falling back to "any valid JWT
    # gets in" if session state is momentarily missing - a call that can't
    # be verified should fail closed, not open.
    # IP-keyed, checked before token decode - see call_ws_preauth_limiter's
    # doc comment in rate_limit.py for why this can't wait until we have a
    # uid to key on.
    client_ip = resolve_client_ip(websocket)
    try:
        await call_ws_preauth_limiter.check_and_record(f"ip:{client_ip}")
    except HTTPException:
        await websocket.close(code=4008, reason="Too many connection attempts")
        return

    payload = decode_call_token(token)
    if not payload or payload.get("room_id") != room_id:
        await websocket.close(code=4001, reason="Unauthorized")
        return
    uid = payload["sub"]

    try:
        await call_ws_connect_limiter.check_and_record(uid)
    except HTTPException:
        await websocket.close(code=4008, reason="Too many connection attempts")
        return

    session = await call_state.get_session(room_id)
    if session is None:
        await websocket.close(code=4004, reason="Call no longer exists")
        return
    if not session.is_participant(uid):
        await websocket.close(code=4003, reason="Not a party to this call")
        return
    if call_state.is_terminal(session.state):
        await websocket.close(code=4004, reason="Call already ended")
        return

    await websocket.accept()

    room = _rooms.setdefault(room_id, {})

    stale = room.get(uid)
    if stale is not None:
        # Same user reconnecting - their previous socket is either already
        # dead (network drop) or about to be superseded by this one either
        # way. Close it best-effort and take over its slot, rather than
        # this new, legitimate connection getting rejected as "room full"
        # by a stale entry that hasn't been cleaned up yet.
        try:
            await stale.close(code=4009, reason="Replaced by a newer connection")
        except Exception:
            pass
        logger.info("[calls] GHOST_SOCKET_REPLACED room=%s user=%s", room_id, uid)
    elif len(room) >= 2:
        # Room already has two DIFFERENT participants - genuinely full.
        await websocket.send_json({"type": "busy", "message": "Room is full"})
        await websocket.close()
        return

    # Whether the peer was already sitting in this room waiting for us -
    # i.e. this join is a RECONNECT into a call that's still up, not the
    # normal first join. Captured before we insert ourselves.
    rejoining_live_call = len(room) == 1 and stale is None

    room[uid] = websocket
    await call_state.set_participant_connected(room_id, uid, True)
    if uid == session.callee_id:
        # Only the callee's join means "accepted" - the caller's own join
        # (they're always first) just means they're waiting.
        await call_state.update_state(room_id, CallState.accepted)
        logger.info("[calls] CALL_ACCEPTED room=%s user=%s", room_id, uid)
    logger.info("[calls] user=%s joined room=%s peers=%d", uid, room_id, len(room))
    if uid == session.caller_id:
        # The callee's phone may have acknowledged the ring before the
        # caller's socket existed (the push often beats the caller's own
        # media setup). Re-read: the ack can land between the read above
        # and this socket being registered, and would then reach no one.
        latest = await call_state.get_session(room_id)
        if latest is not None and latest.callee_alerted:
            try:
                await websocket.send_json({"type": "callee_ringing"})
            except Exception:
                pass
    elif session.state in (CallState.initiating, CallState.ringing):
        # Answered here: the callee's other phones stop ringing. Off the
        # join path - the call must not wait on FCM.
        _spawn(_push_ring_over(session))

    # Notify both peers when room is ready for SDP exchange
    if len(room) == 2:
        await call_state.update_state(room_id, CallState.connecting)
        logger.info("[calls] WEBRTC_CONNECTING room=%s", room_id)
        if rejoining_live_call:
            # Tell the peer who stayed up that their partner is back, so it
            # can leave its own recovery hold immediately instead of waiting
            # out a timeout. Paired with the "peer_state disconnected"
            # message sent from the finally-block below - see its comment
            # for why a transient drop must not be reported as a hangup.
            for peer_uid, peer in list(room.items()):
                if peer_uid == uid:
                    continue
                try:
                    await peer.send_json({"type": "peer_state", "state": "reconnected"})
                except Exception:
                    pass
            logger.info("[calls] PEER_REJOINED room=%s user=%s", room_id, uid)
        for peer in list(room.values()):
            try:
                await peer.send_json({"type": "ready", "room_id": room_id})
            except Exception:
                pass

    # ── Heartbeat ─────────────────────────────────────────────────────────────
    # ROBUSTNESS FIX (calling audit, 2026-09-14): this used to wrap every
    # receive in asyncio.wait_for(..., timeout=15), which CANCELS the
    # in-flight websocket.receive_text() on each timeout. Cancelling a
    # Starlette receive mid-flight is not a documented-safe operation - it
    # can abandon a frame the ASGI server had already handed over - and it
    # meant spawning and tearing down a timeout task every 15s for every
    # participant on every live call, purely to send a ping. The receive
    # loop below is now a plain, never-cancelled receive; a single
    # background task owns pinging and staleness detection, keyed off a
    # timestamp the receive loop refreshes.
    last_activity = asyncio.get_running_loop().time()
    stale_after = WS_HEARTBEAT_INTERVAL_SECONDS * (WS_HEARTBEAT_MAX_MISSED + 1)

    async def _heartbeat() -> None:
        while True:
            await asyncio.sleep(WS_HEARTBEAT_INTERVAL_SECONDS)
            idle = asyncio.get_running_loop().time() - last_activity
            if idle > stale_after:
                # Nothing at all - not even a pong - for several intervals.
                # The socket is dead in a way TCP hasn't noticed yet (a
                # mobile radio drop produces no FIN/RST). Closing it makes
                # the receive below raise, which unwinds normally through
                # the same finally-block as any other disconnect.
                logger.info("[calls] HEARTBEAT_TIMEOUT room=%s user=%s", room_id, uid)
                try:
                    await websocket.close(code=4000, reason="Heartbeat timeout")
                except Exception:
                    pass
                return
            try:
                await websocket.send_json({"type": "ping"})
            except Exception:
                return
            # A socket that's actively pinging belongs to a call that's
            # actually running - push the session's expiry back out so a
            # long call can't have its server-side session vanish under it.
            # See call_state.renew_session()'s doc comment.
            try:
                await call_state.renew_session(room_id)
            except Exception:
                pass

    heartbeat_task = asyncio.create_task(_heartbeat())

    try:
        while True:
            raw = await websocket.receive_text()
            last_activity = asyncio.get_running_loop().time()

            if len(raw) > WS_MAX_FRAME_BYTES:
                logger.warning("[calls] OVERSIZED_MESSAGE room=%s user=%s bytes=%d",
                                room_id, uid, len(raw))
                continue

            try:
                msg = json.loads(raw)
                if not isinstance(msg, dict):
                    raise ValueError("signaling message must be a JSON object")
            except (ValueError, TypeError) as e:
                # Reject just this one message and keep the connection -
                # a malformed frame from a buggy/adversarial client
                # shouldn't take down the whole signaling loop (Phase 5).
                logger.warning("[calls] MALFORMED_MESSAGE room=%s user=%s err=%s", room_id, uid, e)
                continue
            msg_type = msg.get("type")

            if msg_type == "pong":
                # Answers our own heartbeat ping above - nothing to relay,
                # already counted as activity by the timestamp refresh above.
                continue

            # Client-reported WebRTC peer-connection state (Sections 5, 33) -
            # only the client can observe this about its own RTCPeerConnection,
            # so it's the one channel where we trust client-asserted state.
            # Deliberately NOT relayed to the other peer (each side already
            # gets this from its own onConnectionState callback) and
            # deliberately restricted to exactly these 3 values - the client
            # can't use this to claim e.g. "accepted" or "ended", which stay
            # server-authoritative (driven by room membership/hangup above).
            if msg_type == "state":
                reported = msg.get("state")
                if reported in ("connected", "disconnected", "failed"):
                    await call_state.update_state(room_id, CallState(reported))
                    logger.info("[calls] WEBRTC_%s room=%s user=%s",
                                reported.upper(), room_id, uid)
                continue

            if msg_type not in WS_RELAYABLE_TYPES:
                # Not a signaling message and not something we handle above
                # (e.g. the client's own "join" announcement, which the
                # server never reads). Dropping it rather than relaying it
                # is what stops a peer from forging server control messages
                # - see WS_RELAYABLE_TYPES.
                continue

            for peer_uid, peer in list(room.items()):
                if peer_uid == uid:
                    continue
                try:
                    await peer.send_text(raw)
                except Exception:
                    pass

            if msg_type == "hangup":
                # An explicit hangup is final. Mark the session terminal
                # right here rather than leaving it to the finally-block's
                # "room is empty" branch: until that happens the pending
                # index still resolves, so a callee polling
                # GET /calls/pending/{listing_id} in the window between the
                # caller hanging up and the last socket closing would get a
                # freshly-ringing call for a call that's already over.
                current = await call_state.get_session(room_id)
                if current and not call_state.is_terminal(current.state):
                    await call_state.update_state(room_id, CallState.ended)
                break

    except WebSocketDisconnect:
        logger.info("[calls] user=%s disconnected from room=%s", uid, room_id)
    except RuntimeError as e:
        # Starlette raises RuntimeError (not WebSocketDisconnect) when a
        # receive is attempted on a socket the heartbeat task closed under
        # us. That's an expected shutdown path, not an error worth a stack
        # trace - the finally-block below still runs and cleans up properly.
        logger.info("[calls] socket closed room=%s user=%s (%s)", room_id, uid, e)
    finally:
        heartbeat_task.cancel()
        # Only remove OUR OWN entry, and only if it still points to THIS
        # specific connection - a ghost socket being closed above (see the
        # admission block) wakes up its own handler here, and by then a
        # NEWER connection may have already taken over room[uid]. Blindly
        # popping by key would delete the newer socket out from under the
        # call that's actually still active.
        if room.get(uid) is websocket:
            del room[uid]
            await call_state.set_participant_connected(room_id, uid, False)
        # RACE FIX (calling audit, 2026-09-18): `room` is this handler's
        # captured reference to the dict that WAS registered under room_id.
        # Between the removal above (which awaits) and this check, a peer
        # can reconnect - and if another handler already popped room_id in
        # that window, that reconnect created a BRAND NEW dict under the
        # same key. Popping unconditionally then deleted the live call's
        # registry out from under it: the two peers each end up in a dict
        # nothing else can find, so no offer, answer, ICE candidate or
        # restart ever reaches the other side again, and the state machine
        # gets told the call ended. The identity check makes both the pop
        # and the terminal transition apply only to the room this handler
        # is actually tearing down.
        if not room and _owns_room(room_id, room):
            _rooms.pop(room_id, None)
            current_session = await call_state.get_session(room_id)
            if current_session and not call_state.is_terminal(current_session.state):
                await call_state.update_state(room_id, CallState.ended)
            logger.info("[calls] CALL_ENDED room=%s", room_id)
            # Deliberately NOT calling end_session() (immediate delete)
            # here - update_state() above already shortened this session's
            # TTL to POST_CALL_GRACE_TTL_SECONDS as soon as it hit a
            # terminal state, which gives POST /calls/log-result (called
            # by the client right after hangup) a real window to look the
            # session up and derive authoritative caller/callee/listing
            # info instead of trusting client-supplied values (Section 16).
            # It'll expire on its own shortly either way.
        else:
            # One side dropped but the other is still here. Skip this
            # entirely if we're the STALE socket being replaced
            # (room.get(uid) is not websocket, i.e. we already lost the
            # check above) - the call is still healthy, just handed off to
            # a newer connection, not actually disconnected.
            #
            # BUG FIX (calling audit, 2026-09-14): this used to send the
            # surviving peer {"type": "hangup", "reason":
            # "peer_disconnected"}. The client's 'hangup' handler tears the
            # call down immediately and unconditionally - so ANY transient
            # signaling drop on one side (a lift doorway, a Wi-Fi/cell
            # handoff, a backgrounded app) ended the call on the other side
            # within milliseconds. That silently defeated every piece of
            # recovery machinery on both ends: the dropping peer's bounded
            # WebSocket reconnect, its offer/answer resend-on-'ready', and
            # the ICE-restart path all had nothing left to reconnect TO,
            # because the survivor had already hung up and gone home.
            #
            # A transient drop now gets its own message type. "hangup" goes
            # back to meaning what its name says - somebody deliberately
            # ended this call - and the survivor holds the call in a
            # recovery state instead, until either the peer rejoins (the
            # "reconnected" message sent at join above) or its own bounded
            # timer gives up.
            if (room.get(uid) is None or room.get(uid) is websocket) \
                    and _owns_room(room_id, room):
                current_session = await call_state.get_session(room_id)
                if current_session and not call_state.is_terminal(current_session.state):
                    await call_state.update_state(room_id, CallState.disconnected)
                    logger.info("[calls] WEBRTC_DISCONNECTED room=%s user=%s", room_id, uid)
                for peer in list(room.values()):
                    try:
                        await peer.send_json({
                            "type": "peer_state",
                            "state": "disconnected",
                        })
                    except Exception:
                        pass


@router.get("/incoming")
async def get_incoming_call(
    db:      AsyncSession = Depends(get_db),
    current: dict         = Depends(get_current_user),
):
    """The call ringing for the signed-in user right now, on any listing.

    The app's foreground sweep used to ask GET /pending/{listing_id} once
    per chat thread every seven seconds - forty requests for someone with
    forty conversations, to learn there was no call. This answers the same
    question in one lookup (call_state.get_incoming_call), with the same
    shape as /pending plus the listing and thread the call is about.
    """
    session = await call_state.get_incoming_call(current["id"])
    if session is None or session.caller_id == current["id"]:
        return {"has_call": False}
    listing = (await db.execute(
        select(Listing.seller_id, Listing.name).where(Listing.id == session.listing_id)
    )).one_or_none()
    seller_id = listing.seller_id if listing else None
    return {
        "has_call":    True,
        "room_id":     session.room_id,
        "listing_id":  session.listing_id,
        "listing_name": listing.name if listing else "",
        # The thread the call belongs to. A buyer can call a seller they
        # have never messaged, so the app may have no thread to read it from.
        "buyer_id":    session.callee_id if session.caller_id == seller_id else session.caller_id,
        "caller_name": session.caller_name,
        "caller_id":   session.caller_id,
        "call_type":   session.call_type,
        "call_token":  create_call_token(current["id"], session.room_id),
    }


async def ring_watchdog_tick(now: Optional[float] = None) -> int:
    """Settle every call whose ring deadline has passed with nobody having
    answered or reported it. Returns how many were recorded as missed.

    Normally a phone reports the outcome first (log-result), and this finds
    the call already settled and does nothing. It matters when no phone
    can: then the callee gets the missed-call notification and both sides
    the call card, exactly as if the caller's app had hung up.
    """
    settled = 0
    for room_id in await call_state.pop_due_ringing(now):
        try:
            session = await call_state.get_session(room_id)
            if session is None:
                continue
            # `expired` is how get_session reports a session that outlived
            # its TTL still ringing - unanswered all the same.
            if session.state not in (CallState.initiating, CallState.ringing, CallState.expired):
                continue
            if not await call_state.mark_result_logged(room_id):
                continue
            async with AsyncSessionLocal() as db:
                listing = (await db.execute(
                    select(Listing).where(Listing.id == session.listing_id)
                )).scalar_one_or_none()
                if listing is None:
                    continue
                await _record_outcome(db, session, listing, "missed", logged_by=None)
            settled += 1
        except Exception as exc:
            logger.warning("[calls] ring watchdog failed room=%s: %s", room_id, exc)
    return settled


RING_WATCHDOG_INTERVAL_SECONDS = 5
_ring_watchdog_task: Optional[asyncio.Task] = None


async def _ring_watchdog_loop() -> None:
    while True:
        await asyncio.sleep(RING_WATCHDOG_INTERVAL_SECONDS)
        try:
            await ring_watchdog_tick()
        except Exception as exc:
            logger.warning("[calls] ring watchdog tick failed: %s", exc)


def start_ring_watchdog() -> None:
    """Started from main.py's lifespan. One cheap read every few seconds:
    the due calls, if any, from call_state's ringing index."""
    global _ring_watchdog_task
    if _ring_watchdog_task is None or _ring_watchdog_task.done():
        _ring_watchdog_task = asyncio.create_task(_ring_watchdog_loop())


async def stop_ring_watchdog() -> None:
    global _ring_watchdog_task
    task, _ring_watchdog_task = _ring_watchdog_task, None
    if task is not None:
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass


@router.get("/pending/{listing_id}")
async def get_pending_call(
    listing_id: str,
    current: dict = Depends(get_current_user),
):
    """
    Seller polls this to detect incoming calls. call_state.get_pending_call
    does an O(1) lookup keyed by (listing_id, this user's id) rather than
    scanning every active call - this is called repeatedly while a call
    rings, so it needs to stay cheap. Also issues the callee's call_token
    directly here, since this path already does the full authorization
    check anyway - saves a round trip to GET /{room_id}/token.
    """
    session = await call_state.get_pending_call(listing_id, current["id"])
    if session is None:
        return {"has_call": False}

    # Caller polling their own listing's pending-call state (e.g. a seller
    # who is also testing their own listing) must never see their own
    # outgoing call reflected back as "incoming".
    if session.caller_id == current["id"]:
        return {"has_call": False}

    return {
        "has_call":    True,
        "room_id":     session.room_id,
        "caller_name": session.caller_name,
        "caller_id":   session.caller_id,  # explicit, replaces parsing buyer_id out of room_id client-side
        "call_type":   session.call_type,
        "call_token":  create_call_token(current["id"], session.room_id),
    }
