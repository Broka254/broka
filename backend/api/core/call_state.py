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
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from dataclasses import dataclass, asdict, fields
from enum import Enum
from typing import Optional

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

    An answered call whose callee hasn't joined yet (`accepted`) gets the
    establishment window again, from now - not the 4-hour connected TTL it
    used to get. A call answered from a closed app that then never connected
    stayed `accepted` for four hours, and `accepted` counts as being on a
    call (calls.py _call_in_progress): calling the person back answered
    "You're already on a call."
    """
    if is_terminal(session.state) or session.state in _UNANSWERED:
        return None
    if session.state == CallState.accepted:
        return time.time() + ESTABLISHMENT_SESSION_TTL_SECONDS
    return time.time() + CONNECTED_SESSION_TTL_SECONDS


def _answer(session: "CallSession") -> bool:
    """Mark `session` answered in place. False when it is already over.

    Moves a ringing call to `accepted`, and gives the callee the whole
    establishment window from this moment to join: it used to count from
    when the call was placed, so a call answered late in its ring left a
    phone starting BROKA from cold a few seconds to get there.
    """
    if is_terminal(session.state):
        return False
    session.answered = True
    if session.state in _UNANSWERED and is_valid_transition(session.state, CallState.accepted):
        session.state = CallState.accepted
    if session.state == CallState.accepted:
        session.expires_at = max(session.expires_at,
                                 time.time() + ESTABLISHMENT_SESSION_TTL_SECONDS)
    return True


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
        await client.set(self._key(session.room_id), session.to_json(), ex=max(ttl_seconds, 1))

    async def get(self, room_id: str) -> Optional[CallSession]:
        client = await self._get_client()
        raw = await client.get(self._key(room_id))
        if not raw:
            return None
        try:
            session = CallSession.from_json(raw)
        except Exception as e:
            logger.warning("[call_state] corrupt session room=%s err=%s", room_id, e)
            return None
        # Lazy expiry: Redis's own TTL will eventually reclaim the key, but
        # a session can be logically expired (past expires_at) slightly
        # before Redis actually evicts it - callers need `expired` to read
        # back consistently the moment it's due, not whenever Redis gets to it.
        if session.is_expired and session.state not in _TERMINAL:
            prior_state = session.state.value
            session.state = CallState.expired
            logger.info("[call_state] CALL_TIMEOUT room=%s (was %s)", room_id, prior_state)
            await self._write(session, ttl_seconds=5)  # let it fall out of Redis shortly after
        return session

    async def _write(self, session: CallSession, ttl_seconds: int) -> None:
        client = await self._get_client()
        await client.set(self._key(session.room_id), session.to_json(), ex=max(ttl_seconds, 1))

    async def update_state(self, room_id: str, new_state: CallState) -> Optional[CallSession]:
        """Read-validate-write. Not distributed-locked (WATCH/MULTI/EXEC) -
        for BROKA's 2-participant calls a genuine conflicting-transition
        race (as opposed to a harmless duplicate same-state message,
        already a no-op above) is rare enough that the added complexity
        isn't justified for an MVP; is_valid_transition() still rejects any
        transition that reaches an invalid target even if two requests
        interleave, it just doesn't guarantee which of two *simultaneous
        valid* transitions wins. Worth revisiting if usage ever shows this
        mattering in practice."""
        session = await self.get(room_id)
        if session is None:
            return None
        if not is_valid_transition(session.state, new_state):
            logger.warning("[call_state] rejected transition room=%s %s→%s",
                            room_id, session.state.value, new_state.value)
            return session
        session.state = new_state
        if new_state == CallState.connected:
            # BUG FIX (V2 hardening): a call that's actually connected can
            # run far longer than the establishment TTL it was created
            # with - renew generously here rather than let an active
            # call's session vanish out from under it. See
            # CONNECTED_SESSION_TTL_SECONDS's doc comment above.
            session.expires_at = time.time() + CONNECTED_SESSION_TTL_SECONDS
            remaining = CONNECTED_SESSION_TTL_SECONDS
        elif is_terminal(new_state):
            # See POST_CALL_GRACE_TTL_SECONDS's doc comment - don't just
            # keep whatever TTL was left (could be hours, from
            # CONNECTED_SESSION_TTL_SECONDS), but don't vanish immediately
            # either, so /calls/log-result can still find this session.
            session.expires_at = time.time() + POST_CALL_GRACE_TTL_SECONDS
            remaining = POST_CALL_GRACE_TTL_SECONDS
        else:
            remaining = max(int(session.expires_at - time.time()), 1)
        await self._write(session, ttl_seconds=remaining)
        return session

    async def set_participant_connected(self, room_id: str, user_id: str, connected: bool) -> Optional[CallSession]:
        session = await self.get(room_id)
        if session is None:
            return None
        if user_id == session.caller_id:
            session.caller_connected = connected
        elif user_id == session.callee_id:
            session.callee_connected = connected
        else:
            return session
        remaining = max(int(session.expires_at - time.time()), 1)
        await self._write(session, ttl_seconds=remaining)
        return session

    async def renew(self, room_id: str) -> Optional[CallSession]:
        session = await self.get(room_id)
        if session is None:
            return None
        expiry = _renewed_expiry(session)
        if expiry is None:
            return session
        session.expires_at = expiry
        await self._write(session, ttl_seconds=max(int(expiry - time.time()), 1))
        return session

    async def mark_answered(self, room_id: str) -> Optional[CallSession]:
        session = await self.get(room_id)
        if session is None or not _answer(session):
            return session
        await self._write(session, ttl_seconds=max(int(session.expires_at - time.time()), 1))
        return session

    async def mark_callee_alerted(self, room_id: str) -> Optional[CallSession]:
        session = await self.get(room_id)
        if session is None or session.callee_alerted or is_terminal(session.state):
            return session
        session.callee_alerted = True
        remaining = max(int(session.expires_at - time.time()), 1)
        await self._write(session, ttl_seconds=remaining)
        return session

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
        await client.delete(self._key(room_id))
        if session is not None:
            await self.clear_pending(session.listing_id, session.callee_id)

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
            if session.is_expired and session.state not in _TERMINAL:
                logger.info("[call_state] CALL_TIMEOUT room=%s (was %s)", room_id, session.state.value)
                session.state = CallState.expired
            return session

    async def update_state(self, room_id: str, new_state: CallState) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is None:
                return None
            if session.is_expired and session.state not in _TERMINAL:
                logger.info("[call_state] CALL_TIMEOUT room=%s (was %s)", room_id, session.state.value)
                session.state = CallState.expired
            if not is_valid_transition(session.state, new_state):
                logger.warning("[call_state] rejected transition room=%s %s→%s",
                                room_id, session.state.value, new_state.value)
                return session
            session.state = new_state
            if new_state == CallState.connected:
                # Same fix as _RedisCallStore.update_state() above - see
                # its comment. The in-memory backend has no Redis-native
                # TTL, but session.expires_at is what sweep_expired() and
                # the lazy-expiry check in get() both key off, so renewing
                # it here has the identical effect.
                session.expires_at = time.time() + CONNECTED_SESSION_TTL_SECONDS
            elif is_terminal(new_state):
                session.expires_at = time.time() + POST_CALL_GRACE_TTL_SECONDS
            return session

    async def set_participant_connected(self, room_id: str, user_id: str, connected: bool) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is None:
                return None
            if user_id == session.caller_id:
                session.caller_connected = connected
            elif user_id == session.callee_id:
                session.callee_connected = connected
            return session

    async def renew(self, room_id: str) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is None:
                return None
            expiry = _renewed_expiry(session)
            if expiry is not None:
                session.expires_at = expiry
            return session

    async def mark_answered(self, room_id: str) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is not None:
                _answer(session)
            return session

    async def mark_callee_alerted(self, room_id: str) -> Optional[CallSession]:
        async with self._lock:
            session = self._store.get(room_id)
            if session is not None and not is_terminal(session.state):
                session.callee_alerted = True
            return session

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
                self._pending.pop(self._pending_key(session.listing_id, session.callee_id), None)

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
                    self._pending.pop(self._pending_key(session.listing_id, session.callee_id), None)
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
) -> CallSession:
    session = CallSession(
        room_id=room_id, caller_id=caller_id, callee_id=callee_id,
        listing_id=listing_id, call_type=call_type, caller_name=caller_name,
        state=CallState.initiating,
        created_at=time.time(), expires_at=time.time() + ttl_seconds,
    )
    await _store.create(session, ttl_seconds=ttl_seconds)
    # Secondary index so GET /calls/pending/{listing_id} - polled repeatedly
    # while a call rings - is a single direct lookup keyed by (listing_id,
    # callee_id) instead of a scan over every active call session.
    await _store.set_pending(listing_id, callee_id, room_id, ttl_seconds=ttl_seconds)
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


async def mark_callee_alerted(room_id: str) -> Optional[CallSession]:
    """A phone of the callee's is showing the call. Idempotent; a no-op on
    a call that is over."""
    return await _store.mark_callee_alerted(room_id)


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
    return await _store.update_state(room_id, new_state)


async def set_participant_connected(room_id: str, user_id: str, connected: bool) -> Optional[CallSession]:
    return await _store.set_participant_connected(room_id, user_id, connected)


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


async def mark_answered(room_id: str) -> Optional[CallSession]:
    """The callee answered: a ringing call becomes `accepted`, the session
    remembers it was answered, and the callee has the establishment window
    from now to join. Idempotent; a no-op on a call that is over."""
    return await _store.mark_answered(room_id)


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
