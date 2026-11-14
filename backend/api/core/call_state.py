"""
BROKA - Call Session State
─────────────────────────────────────────────────────────────────────────────
Shared (Redis-backed when available) storage for call SIGNALING/SESSION
state - never audio, video, or media. Replaces the old in-memory-only
`_active_calls` dict in api/routers/calls.py, which was lost on every
Render restart and invisible to any second backend instance.

Same dual-implementation shape as api/core/rate_limit.py:
  • REDIS_URL set   → Redis-backed, survives restarts, multi-instance safe
  • REDIS_URL unset → in-process dict fallback (dev / single-instance only -
                       same restart/multi-instance limitation the old
                       _active_calls dict always had)

This module owns call METADATA only (who, what, when, state). It does NOT
own live WebSocket connection objects - those can't be serialized into
Redis and still live in api/routers/calls.py's per-process `_rooms` dict.
Relaying signaling messages between two peers connected to *different*
backend instances is a separate concern this module doesn't solve by
itself - see the note in api/routers/calls.py's module docstring.

Every change to a session is atomic (2026-11-14). The Redis store used to
read the whole session, change a field and write the whole session back,
and nothing stopped two of those crossing: a socket's teardown, a
heartbeat, an Accept or a ring acknowledgement that read a call while it
rang wrote "ringing" back over the cancellation that landed in between.
The call came back to life - the callee's phone rang for it, joined it and
answered it (HTTP 200) for a caller who had hung up seconds before. Now a
write is a compare-and-set (_CAS_SCRIPT) against exactly the session the
change was decided on, re-decided on the fresh session when another write
got there first; and a call that is over carries a marker of its own
(`broka:call:over:{room}`) that no write from any build can undo.
"""
from __future__ import annotations

import asyncio
import json
import logging
import random
import time
from dataclasses import dataclass, asdict, fields, replace
from enum import Enum
from typing import Callable, Optional, Union

logger = logging.getLogger(__name__)

_KEY_PREFIX = "broka:call:"

# Hard ceiling on a session existing at all *before it connects* -
# establishment/ringing/negotiation phase only, not the active-call
# lifetime. A backstop, not the primary UX timeout: the primary "ring for
# N seconds then show missed" pace is a client-side concern (WebRtcService
# / the VoIP screen own that timer, since only the client can give the
# caller responsive feedback); this just guarantees a session that never
# gets ANSWERED can't linger forever server-side.
#
# BUG FIX (V2 hardening, 2026-09-03): this used to be the TTL for the
# WHOLE session lifetime, including CONNECTED - so any call that stayed
# connected past ~2 minutes had its Redis session silently expire, and a
# WebSocket reconnect attempted after that point was rejected with
# "Call no longer exists" even though the call itself might still be
# perfectly healthy. See CONNECTED_SESSION_TTL_SECONDS below and
# update_state()'s renewal logic - a session is only ever created with
# this shorter TTL; the moment it reaches `connected` it's renewed to the
# much longer one.
ESTABLISHMENT_SESSION_TTL_SECONDS = 120
DEFAULT_SESSION_TTL_SECONDS = ESTABLISHMENT_SESSION_TTL_SECONDS  # back-compat alias

# Generous outer safety cap once a call is actually connected - NOT a
# target duration, just a bound past which something has clearly gone
# wrong (e.g. a client that vanished without ever reporting hangup).
# Renewed automatically on every transition INTO `connected` (see
# update_state() in both store backends below) - a stable, long call that
# never re-enters `connected` again could still hit this ceiling, which a
# heartbeat-driven renewal (not yet implemented) would close more
# precisely.
CONNECTED_SESSION_TTL_SECONDS = 4 * 3600

# How long an ENDED/DECLINED/MISSED/etc. (terminal) session is kept around
# after reaching that state, instead of being cleaned up immediately.
# POST /calls/log-result is called by the client right after hangup to
# record the call's outcome, and needs the session to still be there so it
# can verify the caller is a genuine participant and derive the
# authoritative buyer/caller-role/listing instead of trusting whatever the
# client sends (Section 16) - without this, a session reaching `ended`
# would otherwise keep whatever TTL was left over from
# CONNECTED_SESSION_TTL_SECONDS (up to 4 hours), which is both wasteful
# and beside the point once the call is actually over.
POST_CALL_GRACE_TTL_SECONDS = 180


# ── Call state machine ────────────────────────────────────────────────────────
# "idle" (pre-call, nothing initiated yet) is a client-only UI concept - no
# server-side session exists until /calls/initiate creates one, which starts
# straight at `initiating`.

class CallState(str, Enum):
    initiating   = "initiating"
    ringing      = "ringing"
    accepted     = "accepted"
    connecting   = "connecting"
    connected    = "connected"
    disconnected = "disconnected"
    failed       = "failed"
    declined     = "declined"
    ended        = "ended"
    missed       = "missed"
    expired      = "expired"


# Terminal states have no outgoing transitions - once here, always here.
_TERMINAL: set = {
    CallState.failed, CallState.declined, CallState.ended,
    CallState.missed, CallState.expired,
}

_ALLOWED_TRANSITIONS: dict = {
    CallState.initiating:   {CallState.ringing, CallState.missed, CallState.failed,
                              CallState.expired, CallState.ended, CallState.declined},
    CallState.ringing:      {CallState.accepted, CallState.declined, CallState.missed,
                              CallState.expired, CallState.ended, CallState.failed},
    CallState.accepted:     {CallState.connecting, CallState.failed, CallState.ended,
                              CallState.disconnected},
    CallState.connecting:   {CallState.connected, CallState.failed,
                              CallState.ended, CallState.disconnected},
    CallState.connected:    {CallState.disconnected, CallState.ended, CallState.failed},
    # A dropped connection can recover (see WebRtcService reconnection)
    # before it's finally torn down.
    #
    # BUG FIX (calling audit, 2026-09-14): `connecting` and `accepted` were
    # missing here, and that is exactly the path a genuine mid-call
    # reconnect takes. When one peer's socket drops, the WS handler's
    # finally-block moves the session to `disconnected`. The moment that
    # peer reconnects, call_signaling() re-runs its join logic: it calls
    # update_state(accepted) if the rejoiner is the callee, then
    # update_state(connecting) once room membership is back to 2. Both were
    # rejected outright from `disconnected`, so every reconnect logged two
    # spurious "rejected transition" warnings and left the session stuck at
    # `disconnected` until the client happened to report `connected` itself.
    # Adding them costs nothing (neither is terminal, neither can resurrect
    # an ended call - terminal sets stay empty below) and makes the server's
    # view of a recovering call actually track reality.
    CallState.disconnected: {CallState.connected, CallState.connecting,
                              CallState.accepted, CallState.ended, CallState.failed},
}
for _s in _TERMINAL:
    _ALLOWED_TRANSITIONS[_s] = set()

# Nobody has answered yet. The caller's socket heartbeat renews the session
# (renew_session), and used to stretch these to the 4-hour connected TTL:
# a call nobody answered stayed "ringing" on the server for hours if the
# no-answer watchdog missed it (a restart), and would now also hold both
# people "busy". A ringing call keeps its establishment TTL.
_UNANSWERED: set = {CallState.initiating, CallState.ringing}


def _renewed_expiry(session: "CallSession") -> Optional[float]:
    """Where the heartbeat moves a session's expiry, or None to leave it.

    An answered call that is not under way yet (`accepted`: one of the two
    has not joined) keeps the window answering gave it (_answer) - it is
    never renewed. It used to get the 4-hour connected TTL, and then the
    establishment window again from every heartbeat: a callee who answered
    a call whose caller had already given up (the caller's app timed out on
    POST /calls/initiate after the push had rung them - 2026-11-13) renewed
    it every 15 seconds from its own socket, so the call never ended and the
    callee sat on "Connecting…". `accepted` also counts as being on a call
    (calls.py _call_in_progress): calling the person back was refused.
    """
    if is_terminal(session.state) or session.state in _UNANSWERED:
        return None
    if session.state == CallState.accepted:
        return None
    return time.time() + CONNECTED_SESSION_TTL_SECONDS


def _answer(session: "CallSession") -> Optional["CallSession"]:
    """`session` answered, or None when there is nothing to write - the
    call is over (an Accept that lost the race with a hang-up is refused,
    never applied), or it is already answered with the window it needs.

    Moves a ringing call to `accepted`, and gives the callee the whole
    establishment window from this moment to join: it used to count from
    when the call was placed, so a call answered late in its ring left a
    phone starting BROKA from cold a few seconds to get there.
    """
    if is_terminal(session.state):
        return None
    changed = not session.answered
    session.answered = True
    if session.state in _UNANSWERED and is_valid_transition(session.state, CallState.accepted):
        session.state = CallState.accepted
        changed = True
    if session.state == CallState.accepted:
        window = time.time() + ESTABLISHMENT_SESSION_TTL_SECONDS
        if window > session.expires_at:
            session.expires_at = window
            changed = True
    return session if changed else None


def _moved(session: "CallSession", new_state: "CallState") -> "CallSession":
    """`session` in `new_state`, with the expiry that state keeps."""
    session.state = new_state
    if new_state == CallState.connected:
        session.ever_connected = True
        # BUG FIX (V2 hardening): a call that's actually connected can run
        # far longer than the establishment TTL it was created with -
        # renew generously here rather than let an active call's session
        # vanish out from under it. See CONNECTED_SESSION_TTL_SECONDS.
        session.expires_at = time.time() + CONNECTED_SESSION_TTL_SECONDS
    elif is_terminal(new_state):
        # See POST_CALL_GRACE_TTL_SECONDS - not whatever TTL was left
        # (hours, for a connected call), and not gone at once either, so
        # POST /calls/log-result can still find the session.
        session.expires_at = time.time() + POST_CALL_GRACE_TTL_SECONDS
    return session


def _transition_change(room_id: str, new_state: "CallState",
                       only_from: Optional[frozenset]) -> Callable:
    """The change update_state/transition make: `new_state` when the state
    machine allows it from where the call is (and, with `only_from`, only
    from those states). A call that is over is never changed - not even to
    the terminal state it is already in, which would only stretch its grace
    window."""
    def change(session: "CallSession") -> Optional["CallSession"]:
        if is_terminal(session.state):
            if session.state != new_state:
                logger.warning("[call_state] rejected transition room=%s %s→%s (call is over)",
                               room_id, session.state.value, new_state.value)
            return None
        if only_from is not None and session.state not in only_from:
            return None
        if not is_valid_transition(session.state, new_state):
            logger.warning("[call_state] rejected transition room=%s %s→%s",
                           room_id, session.state.value, new_state.value)
            return None
        # Same state again is still written: `connected` re-asserted renews
        # the connected TTL, as it always has.
        return _moved(session, new_state)
    return change


def _ending_change(target: Union["CallState", Callable[["CallSession"], "CallState"]]) -> Callable:
    """End the call: `target` (or what it picks from the latest session),
    or `ended` where the state machine doesn't allow `target` from where the
    call is - `accepted` can't become `missed`, and an answered call that
    never connected must still be over, not left "on a call". A call that is
    already over is left as it is."""
    def change(session: "CallSession") -> Optional["CallSession"]:
        if is_terminal(session.state):
            return None
        want = target(session) if callable(target) else target
        if not is_terminal(want) or not is_valid_transition(session.state, want):
            want = CallState.ended
        return _moved(session, want)
    return change


def _presence_change(user_id: str, connected: bool, joined: bool = False) -> Callable:
    """A participant's socket came or went - and, with `joined`, it joined
    the call (not a ringing phone waiting in the room). Nothing to write on
    a call that is over: its teardown used to write back the "ringing" it
    had read, over the hang-up that ended the call meanwhile."""
    def change(session: "CallSession") -> Optional["CallSession"]:
        if is_terminal(session.state):
            return None
        if user_id == session.caller_id:
            flag, milestone = "caller_connected", "caller_joined"
        elif user_id == session.callee_id:
            flag, milestone = "callee_connected", "callee_joined"
        else:
            return None
        changed = getattr(session, flag) != connected
        setattr(session, flag, connected)
        if joined and not getattr(session, milestone):
            setattr(session, milestone, True)
            changed = True
        return session if changed else None
    return change


def _note_change(flags: dict) -> Callable:
    """Sticky milestones (CallSession.caller_joined ...) set, on a call that
    is not over."""
    def change(session: "CallSession") -> Optional["CallSession"]:
        if is_terminal(session.state):
            return None
        changed = False
        for name, value in flags.items():
            if value and hasattr(session, name) and not getattr(session, name):
                setattr(session, name, True)
                changed = True
        return session if changed else None
    return change


def _renewal_change(session: "CallSession") -> Optional["CallSession"]:
    """The heartbeat's renewal (_renewed_expiry), never on a call that is
    over: the heartbeat that read a connected call just before its hang-up
    used to write "connected", four hours more, back over it."""
    expiry = _renewed_expiry(session)
    if expiry is None:
        return None
    session.expires_at = expiry
    return session


def _alert_change(session: "CallSession") -> Optional["CallSession"]:
    """A phone of the callee's rings with the call - only while nobody has
    answered and it is not over."""
    if session.state not in _UNANSWERED or session.callee_alerted:
        return None
    session.callee_alerted = True
    return session


# ── Atomic writes (Redis) ─────────────────────────────────────────────────────
# Compare-and-set: the session is written only if it is still exactly what
# the change was decided on (KEYS[1] == ARGV[1]); otherwise nothing is
# written and the change is decided again on the fresh session. A non-terminal
# write is refused outright once the call's "over" marker (KEYS[2]) exists,
# whatever the session says; a terminal write sets the marker in the same step.
#   KEYS: session key, over-marker key
#   ARGV: expected session JSON, new session JSON, session TTL (s),
#         terminal state name or "", marker TTL (s)
#   returns {1} written, {0} the session changed since it was read,
#           {-1} no such session, {-2} the call is over
_CAS_SCRIPT = """
local current = redis.call('GET', KEYS[1])
if not current then
  return {-1}
end
if current ~= ARGV[1] then
  return {0}
end
if ARGV[4] == '' and redis.call('EXISTS', KEYS[2]) == 1 then
  return {-2}
end
redis.call('SET', KEYS[1], ARGV[2], 'EX', tonumber(ARGV[3]))
if ARGV[4] ~= '' then
  redis.call('SET', KEYS[2], ARGV[4], 'EX', tonumber(ARGV[5]))
end
return {1}
"""
_CAS_WRITTEN = 1
_CAS_GONE = -1
# A two-person call sees a handful of writers at once at most (two sockets,
# their heartbeats, an Accept, a hang-up, the watchdog); each retry reads the
# winner's write. Past this many, something is wrong - logged, not written.
_CAS_ATTEMPTS = 12
# The "over" marker outlives the session it guards, so a late write from an
# older replica that re-creates the key still reads as over.
_OVER_MARKER_EXTRA_SECONDS = 60
# An `expired` session is kept this long once noticed, then left to Redis.
_EXPIRED_KEEP_SECONDS = 5


def is_valid_transition(current: CallState, new: CallState) -> bool:
    """ended→connected, declined→connected, expired→accepted, failed→
    connected etc. are all rejected here (every terminal state's
    transition set is empty). Same-state is always allowed - a duplicated
    signaling message re-asserting the current state is a no-op, not an
    error (see Section 8 duplicate-signaling handling in calls.py)."""
    if current == new:
        return True
    return new in _ALLOWED_TRANSITIONS.get(current, set())


def is_terminal(state: CallState) -> bool:
    return state in _TERMINAL


# ── Session record ────────────────────────────────────────────────────────────

@dataclass
class CallSession:
    room_id:      str
    caller_id:    str
    callee_id:    str    # the intended recipient - "seller_id" in BROKA's buyer-calls-seller model
    listing_id:   str
    call_type:    str    # "audio" | "video"
    caller_name:  str
    state:        CallState
    created_at:   float  # unix timestamp
    expires_at:   float  # hard TTL regardless of state - see DEFAULT_SESSION_TTL_SECONDS
    caller_connected: bool = False
    callee_connected: bool = False
    # A phone of the callee's has the call on screen (it acknowledged the
    # push, or found the call by polling) - what "Ringing" means on the
    # caller's screen. Until then the caller sees "Calling".
    callee_alerted: bool = False
    # The callee pressed Accept (POST /calls/{room}/answer) or joined the
    # call. Kept after the call ends: whoever reports the outcome, a call
    # that was answered is never recorded as missed (calls.py
    # _record_outcome) - the callee who answered from a closed app, and
    # whose phone then couldn't join in time, was told "Missed call".
    answered: bool = False
    # A phone reported its WebRTC connection up (the socket's `state`
    # frame). What tells a call that happened from one that was answered
    # and never connected - which used to be recorded as "completed" too
    # (calls.py _record_outcome, "failed_to_connect").
    ever_connected: bool = False
    # A store-general call has no listing. Its thread is keyed by the store
    # and buyer instead, exactly like the messages it produces; an empty
    # listing_id is deliberately distinct from a NULL legacy id so older
    # sessions keep deserialising unchanged.
    store_id: Optional[str] = None
    # How far the call got, for the record of how it ended (call_events
    # stage_of, on CALL_ENDED): each side's socket joined the call - a
    # ringing phone waiting in the room does not count - and an offer and an
    # answer were relayed between them. Sticky; never cleared.
    caller_joined: bool = False
    callee_joined: bool = False
    offer_relayed: bool = False
    answer_relayed: bool = False

    def to_json(self) -> str:
        d = asdict(self)
        d["state"] = self.state.value
        return json.dumps(d)

    @classmethod
    def from_json(cls, raw: str) -> "CallSession":
        d = json.loads(raw)
        d["state"] = CallState(d["state"])
        # Fields this build doesn't know (written by a newer one during a
        # deploy) are dropped rather than failing every read of the call.
        known = {f.name for f in fields(cls)}
        return cls(**{k: v for k, v in d.items() if k in known})

    @property
    def is_expired(self) -> bool:
        return time.time() >= self.expires_at

    def is_participant(self, user_id: str) -> bool:
        return user_id in (self.caller_id, self.callee_id)


# ── What a change did ─────────────────────────────────────────────────────────
# Decided against the session as it was at the moment of the write, never
# against a copy read earlier: a caller acts on these, not on its own read.

@dataclass(frozen=True)
class Transition:
    # The call as it is now - after this change, or as it stood when the
    # change did not apply. None when there is no such call (any more).
    session: Optional[CallSession]
    # This change was written.
    applied: bool
    # The call as this change found it.
    before: Optional[CallSession] = None


@dataclass(frozen=True)
class AnswerResult:
    session: Optional[CallSession]
    # The answer stands: the call is answered and not over. False for a call
    # that ended first - its caller hung up, the ring ran out, it was
    # declined - which must answer 410, not 200.
    accepted: bool
    # This answer is the one that took the call out of ringing: the caller
    # and the callee's other phones are told once, however often it is sent.
    first: bool


@dataclass(frozen=True)
class AlertResult:
    session: Optional[CallSession]
    # The call still rings (nobody has answered it and it is not over).
    ringing: bool
    # This is the first acknowledgement: the caller is told once.
    first: bool


# ── Redis-backed store (multi-instance safe, survives restarts) ──────────────

class _RedisCallStore:
    def __init__(self, redis_url: str):
        self._redis_url = redis_url
        self._client = None
        self._client_loop = None

    async def _get_client(self):
        # _store (below) is a module-level singleton created once at import
        # time, so it outlives any single event loop. A cached client's
        # connections are bound to whatever loop was running when they were
        # opened - reusing them from a different loop (e.g. pytest-asyncio's
        # function-scoped event loop, which hands every test a fresh loop)
        # surfaces as "Task ... got Future ... attached to a different loop"
        # immediately, then "Event loop is closed" once the original loop
        # has been torn down. Recreating the client whenever the running
        # loop has changed since it was built fixes that with no effect on
        # production, which runs continuously in one event loop and so
        # never takes this branch after the first call.
        loop = asyncio.get_running_loop()
        if self._client is None or self._client_loop is not loop:
            import redis.asyncio as aioredis
            self._client = aioredis.from_url(
                self._redis_url, encoding="utf-8", decode_responses=True,
                socket_connect_timeout=2,
            )
            self._client_loop = loop
        return self._client

    def _key(self, room_id: str) -> str:
        return f"{_KEY_PREFIX}{room_id}"

    def _alerted_key(self, room_id: str) -> str:
        return f"{_KEY_PREFIX}alerted:{room_id}"

    def _over_key(self, room_id: str) -> str:
        return f"{_KEY_PREFIX}over:{room_id}"

    async def create(self, session: CallSession, ttl_seconds: int = DEFAULT_SESSION_TTL_SECONDS) -> None:
        client = await self._get_client()
        # Redis's EX requires a positive integer - callers may legitimately
        # pass 0 to mean "already/immediately expired" (e.g. tests
        # simulating an expired session), which Redis itself rejects with
        # ResponseError: invalid expire time in 'set' command. Clamp to 1
        # here the same way _write() and set_pending() below already do.
        # The logical expiry callers actually rely on is session.expires_at
        # (computed independently by create_session() before this ever
        # runs) - this clamp only keeps the Redis key alive for a beat so
        # the lazy-expiry check in get() has something to read.
        #
        # A new call starts clean: no ring acknowledgement or "over" marker
        # left by an earlier session under the same id (only tests reuse
        # one - production ids are random).
        pipe = client.pipeline(transaction=True)
        pipe.set(self._key(session.room_id), session.to_json(), ex=max(ttl_seconds, 1))
        pipe.delete(self._alerted_key(session.room_id), self._over_key(session.room_id))
        await pipe.execute()

    def _decode(self, room_id: str, raw: str, alerted, over) -> Optional[CallSession]:
        try:
            session = CallSession.from_json(raw)
        except Exception as e:
            logger.warning("[call_state] corrupt session room=%s err=%s", room_id, e)
            return None
        # The ring acknowledgement is kept in a key of its own as well
        # (mark_callee_alerted). Writes are atomic now, but a replica still
        # on the previous build during a deploy writes the whole session it
        # read back, and could put callee_alerted back to false - and a
        # caller whose socket joined afterwards was never told the phone
        # was ringing.
        if alerted and not session.callee_alerted:
            session.callee_alerted = True
        # Likewise the end of the call: whatever the session says, a call
        # with an "over" marker is over. The marker is written in the same
        # atomic step as the terminal state, and only ever with it.
        if over and not is_terminal(session.state):
            logger.warning("[call_state] CALL_RESURRECTION_BLOCKED room=%s session_state=%s over=%s",
                           room_id, session.state.value, over)
            try:
                session.state = CallState(over)
            except ValueError:
                session.state = CallState.ended
        return session

    async def _read(self, room_id: str):
        """(raw, session) as stored now - (None, None) when there is no call."""
        client = await self._get_client()
        raw, alerted, over = await client.mget(
            self._key(room_id), self._alerted_key(room_id), self._over_key(room_id))
        if not raw:
            return None, None
        return raw, self._decode(room_id, raw, alerted, over)

    async def get(self, room_id: str) -> Optional[CallSession]:
        raw, session = await self._read(room_id)
        if session is None:
            return None
        # Lazy expiry: Redis's own TTL will eventually reclaim the key, but
        # a session can be logically expired (past expires_at) slightly
        # before Redis actually evicts it - callers need `expired` to read
        # back consistently the moment it's due, not whenever Redis gets to it.
        if session.is_expired and not is_terminal(session.state):
            return (await self._mutate(room_id, lambda s: None)).session
        return session

    async def _write(self, session: CallSession, ttl_seconds: int) -> None:
        """A blind whole-session write - what every change used to be, and
        what an older replica still does during a deploy. Nothing here calls
        it to change a call (tests use it to stand in for such a write)."""
        client = await self._get_client()
        await client.set(self._key(session.room_id), session.to_json(), ex=max(ttl_seconds, 1))

    # How the compare-and-set runs: the Lua script (one round trip), or -
    # on a Redis that refuses scripts - WATCH/MULTI/EXEC, which is as atomic
    # and takes a few more.
    _cas_mode = "script"

    async def _cas(self, room_id: str, expected_raw: str, new: CallSession, ttl: int) -> int:
        ttl = max(int(ttl), 1)
        over_state = new.state.value if is_terminal(new.state) else ""
        over_ttl = max(ttl, POST_CALL_GRACE_TTL_SECONDS) + _OVER_MARKER_EXTRA_SECONDS
        if self._cas_mode == "script":
            from redis.exceptions import NoScriptError, ResponseError
            client = await self._get_client()
            script = getattr(self, "_cas_script", None)
            if script is None or getattr(self, "_cas_script_client", None) is not client:
                script = client.register_script(_CAS_SCRIPT)
                self._cas_script, self._cas_script_client = script, client
            try:
                result = await script(
                    keys=[self._key(room_id), self._over_key(room_id)],
                    args=[expected_raw, new.to_json(), ttl, over_state, over_ttl],
                )
                return int(result[0]) if result else 0
            except NoScriptError:
                raise
            except ResponseError as exc:
                # Scripting switched off or not offered by this Redis: the
                # same compare-and-set with WATCH, from now on.
                logger.warning("[call_state] CAS_SCRIPT_UNAVAILABLE err=%s - using WATCH/MULTI/EXEC",
                               type(exc).__name__)
                self._cas_mode = "watch"
        return await self._cas_watch(room_id, expected_raw, new.to_json(), ttl, over_state, over_ttl)

    async def _cas_watch(self, room_id: str, expected_raw: str, new_raw: str, ttl: int,
                         over_state: str, over_ttl: int) -> int:
        from redis.exceptions import WatchError
        client = await self._get_client()
        key, over_key = self._key(room_id), self._over_key(room_id)
        async with client.pipeline(transaction=True) as pipe:
            try:
                await pipe.watch(key, over_key)
                current = await pipe.get(key)
                if current is None:
                    return _CAS_GONE
                if current != expected_raw:
                    return 0
                if not over_state and await pipe.exists(over_key):
                    return -2
                pipe.multi()
                pipe.set(key, new_raw, ex=ttl)
                if over_state:
                    pipe.set(over_key, over_state, ex=over_ttl)
                await pipe.execute()
                return _CAS_WRITTEN
            except WatchError:
                return 0

    async def _mutate(self, room_id: str, change: Callable) -> Transition:
        """Apply `change` to the call as it is right now, atomically.

        `change(session)` gets a copy and returns the session to write, or
        None to leave the call as it is. The write only lands if the session
        is still exactly what `change` was given; if another write got there
        first - a hang-up, a heartbeat, another phone's Accept - `change`
        decides again on what that write left. So no change is ever made to
        a call that has moved on since it was read, and nothing written can
        take a call that is over back to an earlier state.
        """
        before = None
        for attempt in range(_CAS_ATTEMPTS):
            raw, session = await self._read(room_id)
            if session is None:
                return Transition(None, False, before)
            before = replace(session)
            # A call past its expiry is `expired` before anything else is
            # decided about it, and is stored as such.
            lapsed = session.is_expired and not is_terminal(session.state)
            if lapsed:
                session.state = CallState.expired
            new = change(replace(session))
            if new is None and not lapsed:
                return Transition(session, False, before)
            write = new if new is not None else session
            if write.state == CallState.expired and write.is_expired:
                ttl = _EXPIRED_KEEP_SECONDS  # let it fall out of Redis shortly after
            else:
                ttl = max(int(write.expires_at - time.time()), 1)
            code = await self._cas(room_id, raw, write, ttl)
            if code == _CAS_WRITTEN:
                if lapsed:
                    logger.info("[call_state] CALL_TIMEOUT room=%s (was %s)",
                                room_id, before.state.value)
                return Transition(write, new is not None, before)
            if code == _CAS_GONE:
                return Transition(None, False, before)
            # Another write landed between the read and this one (or the
            # call is over): decide again on what is there now.
            await asyncio.sleep(random.uniform(0.002, 0.015) * (attempt + 1))
        logger.warning("[call_state] CAS_CONFLICT room=%s attempts=%d - change not applied",
                       room_id, _CAS_ATTEMPTS)
        raw, session = await self._read(room_id)
        return Transition(session, False, before)

    async def update_state(self, room_id: str, new_state: CallState) -> Optional[CallSession]:
        return (await self.transition(room_id, new_state)).session

    async def transition(self, room_id: str, new_state: CallState,
                         only_from: Optional[frozenset] = None) -> Transition:
        return await self._mutate(room_id, _transition_change(room_id, new_state, only_from))

    async def end_call(self, room_id: str, target) -> Transition:
        return await self._mutate(room_id, _ending_change(target))

    async def set_participant_connected(self, room_id: str, user_id: str, connected: bool,
                                        joined: bool = False) -> Optional[CallSession]:
        return (await self._mutate(room_id, _presence_change(user_id, connected, joined))).session

    async def note(self, room_id: str, flags: dict) -> Transition:
        return await self._mutate(room_id, _note_change(flags))

    async def renew(self, room_id: str) -> Optional[CallSession]:
        return (await self._mutate(room_id, _renewal_change)).session

    async def mark_answered(self, room_id: str) -> Transition:
        return await self._mutate(room_id, _answer)

    async def mark_callee_alerted(self, room_id: str) -> Transition:
        moved = await self._mutate(room_id, _alert_change)
        if moved.applied and moved.session is not None:
            # And in a key of its own, which a replica still on the build
            # before atomic writes cannot put back (see _decode).
            client = await self._get_client()
            remaining = max(int(moved.session.expires_at - time.time()), 1)
            await client.set(self._alerted_key(room_id), "1", ex=max(remaining, 60))
        return moved

    # Calls still ringing, scored by when they stop being worth ringing (see
    # call_state.add_ringing). A sorted set rather than a key per call so
    # the watchdog finds every due call in one read - and in Redis, so a
    # restart in the middle of a ring doesn't lose it.
    _RINGING_KEY = f"{_KEY_PREFIX}ringing"

    async def add_ringing(self, room_id: str, deadline: float) -> None:
        client = await self._get_client()
        await client.zadd(self._RINGING_KEY, {room_id: deadline})

    async def pop_due_ringing(self, now: float) -> list:
        client = await self._get_client()
        due = await client.zrangebyscore(self._RINGING_KEY, "-inf", now)
        if not due:
            return []
        # ZREM reports what it removed, so of two instances racing for the
        # same call only one gets it.
        mine = []
        for room_id in due:
            if await client.zrem(self._RINGING_KEY, room_id):
                mine.append(room_id)
        return mine

    def _pending_key(self, listing_id: str, callee_id: str) -> str:
        return f"{_KEY_PREFIX}pending:{listing_id}:{callee_id}"

    async def set_pending(self, listing_id: str, callee_id: str, room_id: str, ttl_seconds: int) -> None:
        client = await self._get_client()
        await client.set(self._pending_key(listing_id, callee_id), room_id, ex=max(ttl_seconds, 1))

    async def get_pending(self, listing_id: str, callee_id: str) -> Optional[str]:
        client = await self._get_client()
        return await client.get(self._pending_key(listing_id, callee_id))

    async def clear_pending(self, listing_id: str, callee_id: str) -> None:
        client = await self._get_client()
        await client.delete(self._pending_key(listing_id, callee_id))

    async def delete(self, room_id: str) -> None:
        client = await self._get_client()
        session = await self.get(room_id)
        await client.delete(self._key(room_id), self._alerted_key(room_id), self._over_key(room_id))
        if session is not None:
            await self.clear_pending(_session_thread_key(session), session.callee_id)

    async def sweep_expired(self) -> int:
        # Redis's own key TTL already reclaims these - nothing to do here.
        # Present only so callers can treat both backends identically.
        return 0

    async def mark_result_logged(self, room_id: str) -> bool:
        """Atomic check-and-set (Section 16 idempotency): returns True the
        FIRST time this is called for a given room_id, False on every call
        after that. Uses Redis's native SET NX so two near-simultaneous
        POST /calls/log-result requests for the same call can't both win -
        exactly the "prevent duplicate terminal results" requirement."""
        client = await self._get_client()
        key = f"{_KEY_PREFIX}logged:{room_id}"
        won = await client.set(key, "1", nx=True, ex=POST_CALL_GRACE_TTL_SECONDS)
        return bool(won)


# ── In-process store (dev / single-instance fallback) ────────────────────────

class _InMemoryCallStore:
    def __init__(self):
        self._store: dict = {}
        self._pending: dict = {}
        self._logged: dict = {}  # room_id -> unix timestamp marked, for mark_result_logged()
        self._ringing: dict = {}  # room_id -> ring deadline, for pop_due_ringing()
        self._lock = asyncio.Lock()

    async def create(self, session: CallSession, ttl_seconds: int = DEFAULT_SESSION_TTL_SECONDS) -> None:
        async with self._lock:
            self._store[session.room_id] = session

    async def get(self, room_id: str) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is None:
                return None
            self._lapse_if_due(room_id, session)
            return session

    @staticmethod
    def _lapse_if_due(room_id: str, session: CallSession) -> None:
        if session.is_expired and session.state not in _TERMINAL:
            logger.info("[call_state] CALL_TIMEOUT room=%s (was %s)", room_id, session.state.value)
            session.state = CallState.expired

    async def _mutate(self, room_id: str, change: Callable) -> Transition:
        """The Redis store's _mutate, under this process's lock - the only
        concurrency a single-process store has. The stored object is
        updated in place, as it always was: callers holding it see it move."""
        async with self._lock:
            session = self._store.get(room_id)
            if session is None:
                return Transition(None, False, None)
            before = replace(session)
            self._lapse_if_due(room_id, session)
            new = change(replace(session))
            if new is None:
                return Transition(session, False, before)
            for f in fields(CallSession):
                setattr(session, f.name, getattr(new, f.name))
            return Transition(session, True, before)

    async def update_state(self, room_id: str, new_state: CallState) -> Optional[CallSession]:
        return (await self.transition(room_id, new_state)).session

    async def transition(self, room_id: str, new_state: CallState,
                         only_from: Optional[frozenset] = None) -> Transition:
        return await self._mutate(room_id, _transition_change(room_id, new_state, only_from))

    async def end_call(self, room_id: str, target) -> Transition:
        return await self._mutate(room_id, _ending_change(target))

    async def set_participant_connected(self, room_id: str, user_id: str, connected: bool,
                                        joined: bool = False) -> Optional[CallSession]:
        return (await self._mutate(room_id, _presence_change(user_id, connected, joined))).session

    async def note(self, room_id: str, flags: dict) -> Transition:
        return await self._mutate(room_id, _note_change(flags))

    async def renew(self, room_id: str) -> Optional[CallSession]:
        # As the Redis store's renew does: a session past its expiry reads
        # as expired, never renewed back to life (_lapse_if_due first).
        return (await self._mutate(room_id, _renewal_change)).session

    async def mark_answered(self, room_id: str) -> Transition:
        return await self._mutate(room_id, _answer)

    async def mark_callee_alerted(self, room_id: str) -> Transition:
        return await self._mutate(room_id, _alert_change)

    async def add_ringing(self, room_id: str, deadline: float) -> None:
        async with self._lock:
            self._ringing[room_id] = deadline

    async def pop_due_ringing(self, now: float) -> list:
        async with self._lock:
            due = [r for r, d in self._ringing.items() if d <= now]
            for room_id in due:
                self._ringing.pop(room_id, None)
            return due

    def _pending_key(self, listing_id: str, callee_id: str) -> str:
        return f"{listing_id}:{callee_id}"

    async def set_pending(self, listing_id: str, callee_id: str, room_id: str, ttl_seconds: int) -> None:
        async with self._lock:
            self._pending[self._pending_key(listing_id, callee_id)] = room_id

    async def get_pending(self, listing_id: str, callee_id: str) -> Optional[str]:
        async with self._lock:
            return self._pending.get(self._pending_key(listing_id, callee_id))

    async def clear_pending(self, listing_id: str, callee_id: str) -> None:
        async with self._lock:
            self._pending.pop(self._pending_key(listing_id, callee_id), None)

    async def delete(self, room_id: str) -> None:
        async with self._lock:
            session = self._store.pop(room_id, None)
            if session is not None:
                self._pending.pop(
                    self._pending_key(_session_thread_key(session), session.callee_id),
                    None,
                )

    async def sweep_expired(self) -> int:
        """No Redis TTL here - something has to actively reclaim expired
        sessions, or a crashed/vanished client's call lingers forever.
        Called from the existing periodic sweep loop (api/core/workers.py)
        as a backstop; NOT the primary ring/connect timeout, which is
        client-driven for responsiveness (see DEFAULT_SESSION_TTL_SECONDS)."""
        removed = 0
        async with self._lock:
            for room_id, session in list(self._store.items()):
                if session.is_expired:
                    self._store.pop(room_id, None)
                    self._pending.pop(
                        self._pending_key(_session_thread_key(session), session.callee_id),
                        None,
                    )
                    removed += 1
            # _logged entries have no TTL of their own here (unlike Redis's
            # native EX) - reclaim anything past the grace window so this
            # dict doesn't grow forever on a long-running dev process.
            cutoff = time.time() - POST_CALL_GRACE_TTL_SECONDS
            for room_id, marked_at in list(self._logged.items()):
                if marked_at < cutoff:
                    self._logged.pop(room_id, None)
        return removed

    async def mark_result_logged(self, room_id: str) -> bool:
        """Same contract as _RedisCallStore.mark_result_logged() - see its
        docstring. Race-safe here too: the lock makes check-and-set atomic
        with respect to other coroutines in this same process (the only
        concurrency this backend ever has, being single-instance)."""
        async with self._lock:
            if room_id in self._logged:
                return False
            self._logged[room_id] = time.time()
            return True


# ── Factory ───────────────────────────────────────────────────────────────────

def _make_store():
    from api.core.config import settings
    if settings.redis_enabled:
        logger.info("[call_state] Using Redis-backed call session store")
        return _RedisCallStore(settings.redis_url)
    logger.info("[call_state] Using in-memory call session store (set REDIS_URL for restart/multi-instance safety)")
    return _InMemoryCallStore()


_store = _make_store()


# ── Public API ────────────────────────────────────────────────────────────────

async def create_session(
    room_id: str, caller_id: str, callee_id: str, listing_id: str,
    call_type: str, caller_name: str,
    ttl_seconds: int = DEFAULT_SESSION_TTL_SECONDS,
    store_id: Optional[str] = None,
) -> CallSession:
    session = CallSession(
        room_id=room_id, caller_id=caller_id, callee_id=callee_id,
        listing_id=listing_id, call_type=call_type, caller_name=caller_name,
        store_id=store_id,
        state=CallState.initiating,
        created_at=time.time(), expires_at=time.time() + ttl_seconds,
    )
    await _store.create(session, ttl_seconds=ttl_seconds)
    # Secondary index so GET /calls/pending/{listing_id} - polled repeatedly
    # while a call rings - is a single direct lookup keyed by (listing_id,
    # callee_id) instead of a scan over every active call session.
    await _store.set_pending(
        _session_thread_key(session), callee_id, room_id, ttl_seconds=ttl_seconds)
    # And one keyed by the callee alone, for GET /calls/incoming: the app
    # used to ask /pending once per chat thread on every 7-second sweep, so
    # someone with 40 conversations made 40 requests to learn they had no
    # call. A person takes one call at a time, so the latest is the one.
    await _store.set_pending(_ANY_LISTING, callee_id, room_id, ttl_seconds=ttl_seconds)
    # And the caller's newest outgoing call, so /calls/initiate can tell a
    # redial (or a call placed while an earlier one still rings) from a
    # first call - see calls.py _call_in_progress.
    await _store.set_pending(_OUTGOING, caller_id, room_id, ttl_seconds=ttl_seconds)
    return session


# The listing slots of the per-user indexes above. Not real listing ids.
_ANY_LISTING = "*"
_OUTGOING = ">"


def _client_call_slot(client_call_id: str) -> str:
    return f"client:{client_call_id}"


async def remember_client_call(caller_id: str, client_call_id: str, room_id: str) -> None:
    """The call a caller's app placed under its own id for the attempt
    (POST /calls/initiate's client_call_id), for as long as it could still
    be joined. A retry of a request whose answer never reached the phone -
    a timeout, a dropped connection - finds the call it already placed
    instead of placing a second one; a cancel of a setup the app gave up on
    finds the call to end."""
    await _store.set_pending(_client_call_slot(client_call_id), caller_id, room_id,
                             ttl_seconds=ESTABLISHMENT_SESSION_TTL_SECONDS)


async def room_for_client_call(caller_id: str, client_call_id: str) -> Optional[str]:
    return await _store.get_pending(_client_call_slot(client_call_id), caller_id)


def _session_thread_key(session: CallSession) -> str:
    """The pending-index key for a call's conversation.

    Store-general calls have no listing, so their thread is named the same
    way the app and message push name it: ``store:<id>``. Keeping the
    store prefix matters because a listing id and a store id are separate
    namespaces and must never share a pending-call slot.
    """
    store_id = getattr(session, "store_id", None)
    return f"store:{store_id}" if store_id else session.listing_id


async def _pointed_session(slot: str, user_id: str) -> Optional[CallSession]:
    room_id = await _store.get_pending(slot, user_id)
    if not room_id:
        return None
    return await _store.get(room_id)


async def latest_incoming(user_id: str) -> Optional[CallSession]:
    """The newest call placed TO this user, in whatever state it is now."""
    return await _pointed_session(_ANY_LISTING, user_id)


async def latest_outgoing(user_id: str) -> Optional[CallSession]:
    """The newest call placed BY this user, in whatever state it is now."""
    return await _pointed_session(_OUTGOING, user_id)


async def get_incoming_call(callee_id: str) -> Optional[CallSession]:
    """The call ringing for this user right now, on any listing - or None.
    Same liveness rule as get_pending_call."""
    return await get_pending_call(_ANY_LISTING, callee_id)


async def mark_callee_alerted(room_id: str) -> AlertResult:
    """A phone of the callee's is showing the call. Recorded only while the
    call still rings - decided on the session as it is at the moment of the
    write, so a late acknowledgement for a call that has just been answered,
    cancelled or missed is told so (`ringing` false: 410 at /alerted).
    Idempotent: `first` once per call."""
    moved = await _store.mark_callee_alerted(room_id)
    session = moved.session
    ringing = session is not None and session.state in _UNANSWERED
    return AlertResult(session=session, ringing=ringing, first=moved.applied)


async def add_ringing(room_id: str, deadline: float) -> None:
    """Hand a ringing call to the no-answer watchdog (api/routers/calls.py
    ring_watchdog_tick), which looks at it again at `deadline`."""
    await _store.add_ringing(room_id, deadline)


async def pop_due_ringing(now: Optional[float] = None) -> list:
    """Room ids whose ring deadline has passed, each returned once."""
    return await _store.pop_due_ringing(time.time() if now is None else now)


async def get_session(room_id: str) -> Optional[CallSession]:
    return await _store.get(room_id)


async def get_pending_call(listing_id: str, callee_id: str) -> Optional[CallSession]:
    """O(1) lookup for GET /calls/pending/{listing_id} - no scan over active
    sessions. Returns None if there's no pending call, the session already
    ended, or it's not actually still ringing/initiating (e.g. the caller
    already hung up but the index hasn't been cleared yet)."""
    room_id = await _store.get_pending(listing_id, callee_id)
    if not room_id:
        return None
    session = await _store.get(room_id)
    if session is None or session.state not in (CallState.initiating, CallState.ringing):
        return None
    return session


async def update_state(room_id: str, new_state: CallState) -> Optional[CallSession]:
    """Move the call to `new_state` if the state machine allows it from
    where the call is at the moment of the write. Returns the session as it
    is afterwards - unchanged when the move was refused. Never touches a
    call that is over."""
    return await _store.update_state(room_id, new_state)


async def transition(room_id: str, new_state: CallState, *,
                     only_from=None) -> Transition:
    """update_state, saying whether it was this call that moved it. With
    `only_from`, only from those states: "cancel it if nobody has answered
    yet" can't cancel a call answered a moment ago."""
    return await _store.transition(
        room_id, new_state, frozenset(only_from) if only_from is not None else None)


async def end_call(room_id: str,
                   target: Union[CallState, Callable[[CallSession], CallState]]) -> Transition:
    """End the call in one atomic step: `target` - or the state `target(session)`
    picks from the call as it is at that moment - or `ended` where the
    state machine doesn't allow it from there. A call already over is left
    as it is (`applied` false)."""
    return await _store.end_call(room_id, target)


async def set_participant_connected(room_id: str, user_id: str, connected: bool, *,
                                    joined: bool = False) -> Optional[CallSession]:
    """A participant's socket is in the room (or has left it); `joined` when
    it joined the call itself rather than waiting in it while it rings.
    Returns the session as it is at that moment - None when it is gone - and
    never changes a call that is over."""
    return await _store.set_participant_connected(room_id, user_id, connected, joined)


async def note(room_id: str, **flags: bool) -> None:
    """Record how far a call got (CallSession.offer_relayed, ...): sticky
    flags, set once, never on a call that is over. Best effort - a
    milestone missed is a log line poorer, never a call worse."""
    try:
        await _store.note(room_id, flags)
    except Exception as exc:
        logger.debug("[call_state] milestone not recorded room=%s: %s", room_id, type(exc).__name__)


async def renew_session(room_id: str) -> Optional[CallSession]:
    """Push a live session's expiry back out to CONNECTED_SESSION_TTL_SECONDS.

    Closes the gap CONNECTED_SESSION_TTL_SECONDS' own doc comment flagged:
    the TTL was only ever extended on a transition INTO `connected`, so a
    call that connected once and then simply stayed up (never re-entering
    `connected`) still counted down against a fixed ceiling from that one
    moment. Called from the WebSocket heartbeat in api/routers/calls.py, so
    any call with a live signaling socket keeps its session alive for as
    long as it's actually running. A no-op on a terminal session, so it can
    never resurrect or extend a call that's already over.
    """
    return await _store.renew(room_id)


async def mark_answered(room_id: str) -> AnswerResult:
    """The callee answered: a ringing call becomes `accepted`, the session
    remembers it was answered, and the callee has the establishment window
    from now to join.

    Authoritative, decided on the session at the moment of the write: an
    answer to a call that is over (the caller hung up first, the ring ran
    out, another phone declined) is refused - `accepted` false - and changes
    nothing. Idempotent: answering again keeps `accepted` true with `first`
    false, so the caller and the other phones are told once."""
    moved = await _store.mark_answered(room_id)
    session = moved.session
    if session is None:
        return AnswerResult(session=None, accepted=False, first=False)
    accepted = session.answered and not is_terminal(session.state)
    # The write that answered a call still ringing: exactly one, however
    # many cross.
    before = moved.before
    first = (moved.applied and before is not None and not before.answered
             and before.state in _UNANSWERED)
    return AnswerResult(session=session, accepted=accepted, first=first)


async def end_session(room_id: str) -> None:
    await _store.delete(room_id)


async def mark_result_logged(room_id: str) -> bool:
    """POST /calls/log-result idempotency (Section 16): call once per
    logging attempt. True the first time for a given room_id - proceed and
    write the result. False on any call after that - a duplicate, reject
    it rather than writing a second terminal record."""
    return await _store.mark_result_logged(room_id)


async def sweep_expired() -> int:
    """Backstop cleanup for the in-memory fallback (no-op, by design, on
    the Redis backend - see _RedisCallStore.sweep_expired). Wired into the
    existing periodic sweep loop in api/core/workers.py."""
    return await _store.sweep_expired()
