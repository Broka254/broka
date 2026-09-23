"""
BROKA v3.0 - Rate Limiter (issue #3 fixed — Redis-backed for multi-instance)
─────────────────────────────────────────────────────────────────────────────
• When REDIS_URL is set: uses Redis sorted-set sliding window (multi-instance safe)
• Without REDIS_URL:     falls back to in-process deque (single-instance, dev only)

The factory function _make_limiter() picks the right implementation at import
time so all callers (routers) require zero changes.
"""
from __future__ import annotations

import asyncio
import logging
import time
import uuid
from collections import defaultdict, deque
from fastapi import HTTPException, status

logger = logging.getLogger(__name__)


# ── Redis sliding-window (multi-instance safe) ────────────────────────────────

class RedisRateLimiter:
    def __init__(self, name: str, limit: int, window_seconds: int, redis_url: str):
        self.name           = name
        self.limit          = limit
        self.window         = window_seconds
        self._redis_url     = redis_url
        self._client        = None
        self._client_loop   = None
        # Used only while Redis is unreachable. It is per-process, so across
        # N instances the effective limit is up to N x limit - still bounded,
        # which is the point: failing OPEN would drop brute-force protection
        # on login and OTP entirely for the length of any Redis blip.
        self._fallback      = RateLimiter(name, limit, window_seconds)

    async def _get_client(self):
        # Same event-loop hazard as api/core/call_state.py's
        # _RedisCallStore._get_client() (this class is the "same
        # dual-implementation shape" its module docstring points to) - a
        # cached client's connections are bound to whatever loop was
        # running when they were opened, so a limiter instance that outlives
        # a single event loop (e.g. under pytest-asyncio's function-scoped
        # loops) needs to rebuild the client when the running loop has
        # changed, not reuse one bound to a foreign or closed loop.
        loop = asyncio.get_running_loop()
        if self._client is None or self._client_loop is not loop:
            import redis.asyncio as aioredis
            self._client = aioredis.from_url(
                self._redis_url,
                encoding="utf-8",
                decode_responses=True,
                socket_connect_timeout=2,
            )
            self._client_loop = loop
        return self._client

    async def check_and_record(self, identifier: str) -> None:
        key = f"broka:rl:{self.name}:{identifier}"
        try:
            client = await self._get_client()
            now    = time.time()
            cutoff = now - self.window
            # Unique per request. The member used to be str(now) alone, and
            # two requests landing on the same clock value collapsed into one
            # sorted-set entry - counted once.
            member = f"{now}:{uuid.uuid4().hex[:12]}"

            # Add THEN count, in one MULTI/EXEC: every concurrent request
            # sees a count that includes itself, so exactly `limit` of them
            # pass. (Counting first and adding after let a burst all read
            # the same pre-burst count.)
            pipe = client.pipeline(transaction=True)
            pipe.zremrangebyscore(key, "-inf", cutoff)
            pipe.zadd(key, {member: now})
            pipe.zcard(key)
            pipe.expire(key, self.window + 1)
            results = await pipe.execute()
            count = results[2]
        except Exception as e:
            logger.error(
                "[rate_limit] Redis error name=%s - using the in-process limiter: %s",
                self.name, e,
            )
            await self._fallback.check_and_record(identifier)
            return

        if count > self.limit:
            # A REJECTED request must not occupy the window. It used to stay
            # in the set, so a client retrying through its 429s kept
            # extending its own lockout indefinitely instead of recovering
            # once the window had passed - unlike the in-memory limiter,
            # which only ever records requests it lets through.
            try:
                await client.zrem(key, member)
            except Exception as e:
                logger.warning("[rate_limit] could not un-record a rejected request: %s", e)
            logger.warning("[rate_limit] redis hit name=%s id=%s", self.name, identifier)
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"Too many {self.name} attempts. Limit: {self.limit} per {self.window}s.",
                headers={"Retry-After": str(self.window)},
            )


# ── In-process sliding window (single-instance fallback) ─────────────────────

class RateLimiter:
    """
    Sliding window rate limiter (in-process).
    Resets on restart. Works correctly only on a single process.
    """

    def __init__(self, key: str, limit: int, window_seconds: int):
        self.key    = key
        self.limit  = limit
        self.window = window_seconds
        self._store: dict[str, deque[float]] = defaultdict(deque)
        self._lock  = asyncio.Lock()

    def _store_key(self, user_id: str) -> str:
        return f"{self.key}:{user_id}"

    async def check_and_record(self, identifier: str) -> None:
        sk = self._store_key(identifier)
        async with self._lock:
            now    = time.monotonic()
            q      = self._store[sk]
            cutoff = now - self.window
            while q and q[0] < cutoff:
                q.popleft()
            if len(q) >= self.limit:
                logger.warning("[rate_limit] memory hit name=%s id=%s", self.key, identifier)
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=f"Too many {self.key} attempts. Limit: {self.limit} per {self.window}s.",
                    headers={"Retry-After": str(self.window)},
                )
            q.append(now)


# ── Factory ───────────────────────────────────────────────────────────────────

def _make_limiter(name: str, limit: int, window_seconds: int):
    from api.core.config import settings
    if settings.redis_enabled:
        logger.info("[rate_limit] Using Redis limiter for '%s'", name)
        return RedisRateLimiter(name, limit, window_seconds, settings.redis_url)
    logger.info("[rate_limit] Using in-memory limiter for '%s' (set REDIS_URL for multi-instance)", name)
    return RateLimiter(name, limit, window_seconds)


# ── Pre-configured limiters ───────────────────────────────────────────────────
# Production limits are intentionally strict (anti-abuse). Under CI/test, many
# test files issue register/login calls from the same loopback IP within one
# run, so we widen these specific named limiters' thresholds to avoid false
# 429s — the limiter classes themselves are untouched and still fully
# exercised by test_fraud.py::TestRateLimiter.
from api.core.config import settings as _settings

if _settings.is_test:
    login_limiter    = _make_limiter("login",    limit=1000, window_seconds=60)
    register_limiter = _make_limiter("register", limit=1000, window_seconds=300)
    message_limiter  = _make_limiter("message",  limit=1000, window_seconds=60)
    otp_request_limiter = _make_limiter("otp_request", limit=1000, window_seconds=300)
    otp_verify_limiter  = _make_limiter("otp_verify",  limit=1000, window_seconds=300)
    stt_token_limiter      = _make_limiter("stt_token",      limit=1000, window_seconds=60)
    stt_transcribe_limiter = _make_limiter("stt_transcribe", limit=1000, window_seconds=60)
else:
    login_limiter    = _make_limiter("login",    limit=5,  window_seconds=60)
    register_limiter = _make_limiter("register", limit=3,  window_seconds=300)
    message_limiter  = _make_limiter("message",  limit=30, window_seconds=60)
    otp_request_limiter = _make_limiter("otp_request", limit=3, window_seconds=300)   # per phone: 3 SMS / 5 min
    otp_verify_limiter  = _make_limiter("otp_verify",  limit=5, window_seconds=300)   # per phone: 5 attempts / 5 min
    # Speech-to-text (api/routers/stt.py), keyed by authenticated user.
    # Every token mint opens a PAID streaming session on BROKA's Deepgram or
    # AssemblyAI account - and a Deepgram socket keeps streaming after its
    # token expires - while every /stt/transcribe is a paid Whisper call on
    # up to 25 MB of audio. A voice session normally mints one token, two on
    # a failover; 12/min leaves room for reconnects on a flaky network and
    # none for scripted minting. Same reasoning as turn_credential_limiter.
    stt_token_limiter      = _make_limiter("stt_token",      limit=12, window_seconds=60)
    stt_transcribe_limiter = _make_limiter("stt_transcribe", limit=10, window_seconds=60)
offer_limiter    = _make_limiter("offer",    limit=10, window_seconds=60)
dispute_limiter  = _make_limiter("dispute",  limit=3,  window_seconds=3600)
stk_limiter      = _make_limiter("stk_push", limit=3,  window_seconds=60)
ai_chat_limiter  = _make_limiter("ai_chat",  limit=20, window_seconds=60)

# Zeno-drafted SMS to the other party in a thread
# (POST /negotiate/zeno-action/draft-sms with send=true). Stricter than
# plain messaging for two reasons: every send costs real money on the SMS
# channel, and it lands on someone's phone where it cannot be recalled.
# Keyed by the authenticated sender. 5/hour is generous for a legitimate
# "I texted them and they didn't see the app notification" case and far
# too low to be useful for harassment.
zeno_sms_limiter = _make_limiter("zeno_sms", limit=5, window_seconds=3600)

# VoIP calling (api/routers/calls.py) - all keyed by authenticated user id,
# not IP, since every call endpoint already requires a valid access token
# (unlike login/OTP above, which are necessarily pre-auth and need IP too).
# call_initiate rings someone's phone and sends a real FCM push per call,
# so it's a bit stricter than plain messages; turn_credential guards
# against a user racking up unnecessary Cloudflare API calls (each one
# costs a real request against BROKA's Cloudflare TURN allowance) without
# being so tight that a flaky-network retry gets punished.
call_initiate_limiter      = _make_limiter("call_initiate",      limit=10, window_seconds=60)
turn_credential_limiter    = _make_limiter("turn_credential",    limit=20, window_seconds=60)
call_ws_connect_limiter    = _make_limiter("call_ws_connect",    limit=20, window_seconds=60)
# IP-keyed and checked BEFORE token decode (unlike call_ws_connect_limiter
# above, which only ever sees successfully-authenticated attempts) - a
# flood of garbage/expired tokens at the WS endpoint would otherwise never
# be rate-limited at all, since there's no uid to key on until decode
# succeeds. Generous limit: a single IP can legitimately represent many
# users behind carrier-grade NAT, common on Kenyan mobile data.
call_ws_preauth_limiter    = _make_limiter("call_ws_preauth",    limit=30, window_seconds=60)
