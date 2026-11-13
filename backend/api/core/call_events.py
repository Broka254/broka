"""Structured call events in Render's logs (CALLING.md, 2026-11-13).

A call that failed used to leave Render with "SDP/ICE relayed" and nothing
else: everything the phones saw - ICE states, TURN, the peer connection,
why they gave up - stayed in logcat. Every event about a call, whether the
server saw it or a phone reported it, is now one line of the same shape:

  [call-event] event=ICE_CONNECTION_FAILED room=Qe3v... role=callee source=client
      ts=2026-11-13T12:33:05.412Z call_state=ringing ws=open ice_gathering=complete
      ice=failed pc=failed path=- reason=ice_failed relay_received=0

`ts` is the server's UTC time on receipt (milliseconds); a phone's own clock
is `client_ts`. In production the JSON log formatter also attaches the same
fields as an object (`call_event`), so any field can be filtered on.

What may appear: ids BROKA itself issues (room, user), state names, counts,
candidate types (host/srflx/relay/prflx) and protocols. Never a token, a
TURN credential, SDP or an IP address. A phone's strings are cleaned again
here - an exception text from the WebRTC stack can quote an SDP line, and a
client is not trusted to have cleaned it.
"""
from __future__ import annotations

import logging
import re
from datetime import datetime, timezone
from typing import Any, Mapping, Optional

logger = logging.getLogger("api.call_events")

# The fields every event carries, in this order; "-" when not known (the
# server can't see ICE, a phone can't see the other phone's socket).
STATE_FIELDS = ("call_state", "ws", "ice_gathering", "ice", "pc", "path", "reason", "error")

# Events the server emits.
SERVER_EVENTS = frozenset({
    "CALL_INITIATED", "CALL_SETUP_REPLAYED", "CALL_SETUP_CANCELLED",
    "CALL_PUSH_RESULT", "CALL_RINGING", "CALL_ACCEPTED", "CALL_HANGUP", "CALL_ENDED",
    "WEBSOCKET_CONNECTED", "WEBSOCKET_RECONNECTED", "WEBSOCKET_DISCONNECTED",
    "PEER_JOINED", "SDP_OFFER_RELAYED", "SDP_ANSWER_RELAYED",
    "WEBRTC_CONNECTED", "WEBRTC_DISCONNECTED", "WEBRTC_FAILED",
    "TURN_CREDENTIAL_REQUEST", "TURN_CREDENTIAL_ISSUED", "TURN_CREDENTIAL_FAILURE",
})

# Events a phone may report (the `diag` frame and POST /calls/{room}/events).
# An allowlist: a client can't fill the logs with names of its own choosing.
CLIENT_EVENTS = frozenset({
    "CALL_INITIATED", "CALL_ACCEPTED", "CALL_ENDED", "CALL_TIMEOUT",
    "LOCAL_MEDIA_READY", "LOCAL_MEDIA_FAILED",
    "WEBSOCKET_CONNECTED", "WEBSOCKET_DISCONNECTED", "WEBSOCKET_RECONNECTED",
    "WEBSOCKET_RECONNECT_SCHEDULED", "WEBSOCKET_TOKEN_REFRESHED",
    "PEER_JOINED", "PEER_SIGNALING_LOST", "PEER_SIGNALING_RESTORED",
    "SDP_OFFER_CREATED", "SDP_OFFER_SENT", "SDP_OFFER_RECEIVED",
    "SDP_ANSWER_CREATED", "SDP_ANSWER_SENT", "SDP_ANSWER_RECEIVED", "SDP_FAILED",
    "ICE_CANDIDATE_GATHERED", "ICE_CANDIDATE_RECEIVED", "ICE_CANDIDATE_FAILED",
    "ICE_GATHERING_COMPLETE", "ICE_CONNECTION_CHECKING", "ICE_CONNECTION_CONNECTED",
    "ICE_CONNECTION_COMPLETED", "ICE_CONNECTION_FAILED", "ICE_CONNECTION_DISCONNECTED",
    "ICE_CONNECTION_CLOSED", "ICE_CANDIDATE_PAIR_SELECTED", "ICE_RESTART_STARTED",
    "TURN_CREDENTIAL_REQUEST", "TURN_CREDENTIAL_RECEIVED", "TURN_CREDENTIAL_FAILURE",
    "TURN_NO_RELAY_CANDIDATES",
    "WEBRTC_CONNECTED", "WEBRTC_DISCONNECTED", "WEBRTC_FAILED",
    "PRECONNECT_STARTED", "PRECONNECT_USED", "PRECONNECT_ABANDONED",
})

# What else a phone may attach, and nothing more: scalars only.
CLIENT_EXTRA_FIELDS = frozenset({
    "seq", "client_ts", "epoch", "attempt", "max_attempts", "code", "close_reason",
    "candidate_type", "protocol", "relay_protocol", "queued", "stale",
    "local_type", "remote_type", "local_protocol", "remote_protocol",
    "host", "srflx", "prflx", "relay", "count", "received_relay",
    "turn", "turn_urls", "udp", "tcp", "tls", "ttl_s",
    "audio", "video", "restart", "offer_id", "standby", "held",
    "elapsed_ms", "ms", "outcome", "duration_s", "reconnects", "ice_restarts",
    "answered", "connected", "rtt_ms", "peer",
})

_MAX_VALUE = 160
# "token=abc", "credential: xyz", "Bearer abc" - the secret after it goes.
_TOKENISH = re.compile(r"(?i)\b(token|credential|password|secret)\s*[=:]\s*\S+|\bbearer\s+\S+")
_IPV4 = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
_HEXRUN = re.compile(r"(?i)(?<![0-9a-f:])[0-9a-f:]{3,39}(?![0-9a-f:])")
# Where SDP starts in an exception text; everything from there is dropped.
_SDP_START = re.compile(r"(v=0|\ba=[a-z-]+:|\bcandidate:|\bm=audio|\bm=video|\bc=IN\b)")
_SAFE_NAME = re.compile(r"[A-Za-z0-9_.:-]{1,64}")


def _mask_ipv6(match: "re.Match[str]") -> str:
    """An IPv6 address has a "::" or three colons or more, and a digit -
    unlike "12:33:05", or a C++ name like "PeerConnection::Close"."""
    text = match.group(0)
    if ("::" in text or text.count(":") >= 3) and any(c.isdigit() for c in text):
        return "<ip>"
    return text


def utc_now() -> str:
    """UTC with milliseconds and a Z - unambiguous whatever the host's zone."""
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def clean(value: Any) -> Any:
    """A value safe to log: scalars stay, strings lose secrets, addresses,
    SDP and line breaks, and are cut to a sane length."""
    if value is None or isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value
    text = str(value)
    cut = _SDP_START.search(text)
    if cut:
        text = text[:cut.start()].rstrip() + " [sdp removed]"
    text = _TOKENISH.sub("[redacted]", text)
    text = _IPV4.sub("<ip>", text)
    text = _HEXRUN.sub(_mask_ipv6, text)
    text = " ".join(text.split())  # no newlines or tabs to break a log line
    if len(text) > _MAX_VALUE:
        text = text[:_MAX_VALUE - 1] + "…"
    return text


def _kv(value: Any) -> str:
    if value is None or value == "":
        return "-"
    if isinstance(value, bool):
        return "true" if value else "false"
    text = str(value)
    if any(c in text for c in ' "='):
        return '"' + text.replace('"', "'") + '"'
    return text


def emit(event: str, *, room: Optional[str], role: Optional[str] = None,
         user: Optional[str] = None, source: str = "server",
         level: int = logging.INFO, **fields: Any) -> dict:
    """Log one call event. Returns the fields it logged (for tests)."""
    record: dict = {
        "event": event,
        "room": room or "-",
        "role": role or "unknown",
        "source": source,
        "user": user,
        "ts": utc_now(),
    }
    for name in STATE_FIELDS:
        record[name] = clean(fields.pop(name, None))
    for name in sorted(fields):
        record[name] = clean(fields[name])
    line = " ".join(f"{k}={_kv(v)}" for k, v in record.items() if k != "user" or v)
    logger.log(level, "[call-event] %s", line, extra={"call_event": record})
    return record


def role_of(session, user_id: Optional[str]) -> str:
    """caller | callee | unknown - from the authoritative session, never
    from what a phone says about itself."""
    if session is None or not user_id:
        return "unknown"
    if user_id == session.caller_id:
        return "caller"
    if user_id == session.callee_id:
        return "callee"
    return "unknown"


def client_event(raw: Mapping[str, Any], *, room: str, role: str, user: Optional[str],
                 transport: str) -> Optional[dict]:
    """A phone's report, validated and logged - or None when it isn't one
    (unknown event name, wrong shape). `transport` is how it came: "ws" or
    "http"."""
    if not isinstance(raw, Mapping):
        return None
    event = raw.get("event")
    if not isinstance(event, str) or event not in CLIENT_EVENTS:
        return None
    fields: dict = {}
    for name in STATE_FIELDS:
        value = raw.get(name)
        if value is None or isinstance(value, (str, int, float, bool)):
            fields[name] = value
    for name in CLIENT_EXTRA_FIELDS:
        if name not in raw:
            continue
        value = raw[name]
        if value is None or isinstance(value, (str, int, float, bool)):
            fields[name] = value
    # A phone's state names are short identifiers; anything else is noise.
    for name in ("call_state", "ws", "ice_gathering", "ice", "pc", "path"):
        value = fields.get(name)
        if isinstance(value, str) and not _SAFE_NAME.fullmatch(value):
            fields[name] = None
    level = logging.WARNING if event in _CLIENT_WARNINGS else logging.INFO
    return emit(event, room=room, role=role, user=user, source="client",
                level=level, transport=transport, **fields)


# Reported failures stand out in Render's level filter.
_CLIENT_WARNINGS = frozenset({
    "WEBRTC_FAILED", "ICE_CONNECTION_FAILED", "TURN_CREDENTIAL_FAILURE",
    "TURN_NO_RELAY_CANDIDATES", "SDP_FAILED", "LOCAL_MEDIA_FAILED", "CALL_TIMEOUT",
    "ICE_CANDIDATE_FAILED",
})
