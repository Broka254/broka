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
        try:
            client  = await self._get_client()
            key     = f"broka:rl:{self.name}:{identifier}"
            now     = time.time()
            cutoff  = now - self.window

            pipe = client.pipeline()
            pipe.zremrangebyscore(key, "-inf", cutoff)
            pipe.zcard(key)
            pipe.zadd(key, {f"{now}": now})
            pipe.expire(key, self.window + 1)
            results = await pipe.execute()

            count = results[1]   # count BEFORE adding current request
            if count >= self.limit:
                logger.warning("[rate_limit] redis hit name=%s id=%s", self.name, identifier)
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail=f"Too many {self.name} attempts. Limit: {self.limit} per {self.window}s.",
                    headers={"Retry-After": str(self.window)},
                )
        except HTTPException:
            raise
        except Exception as e:
            # Redis unavailable — fail open (log + allow request through)
            logger.error("[rate_limit] Redis error (fail-open): %s", e)


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
else:
    login_limiter    = _make_limiter("login",    limit=5,  window_seconds=60)
    register_limiter = _make_limiter("register", limit=3,  window_seconds=300)
    message_limiter  = _make_limiter("message",  limit=30, window_seconds=60)
    otp_request_limiter = _make_limiter("otp_request", limit=3, window_seconds=300)   # per phone: 3 SMS / 5 min
    otp_verify_limiter  = _make_limiter("otp_verify",  limit=5, window_seconds=300)   # per phone: 5 attempts / 5 min
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
