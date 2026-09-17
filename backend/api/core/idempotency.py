"""
BROKA v4.0 - Idempotency Key Middleware
─────────────────────────────────────────────────────────────────────────────
Prevents double-charges and duplicate state mutations on retried requests.

How it works:
  1. Client sends  X-Idempotency-Key: <uuid>  header with every write request.
  2. Middleware checks Redis for a cached response under that key.
  3. If found → return cached response immediately (no handler invoked).
  4. If not found → run handler, cache response for 24 hours, return result.

Without Redis, idempotency degrades gracefully (fail-open). Safe for dev,
MUST have Redis in production for any financial endpoint.

Usage in a route:
    from api.core.idempotency import idempotency_guard
    ...
    async def fund_escrow(
        idempotency_result = Depends(idempotency_guard), ...
    ):
        if idempotency_result.cached:
            return idempotency_result.response
        result = await do_real_work()
        await idempotency_result.store(result)
        return result
"""
from __future__ import annotations

import json
import logging
from typing import Any, Optional

from fastapi import Header

logger = logging.getLogger(__name__)

_TTL_SECONDS = 86_400   # 24 hours
_KEY_PREFIX  = "broka:idempotency:"


class IdempotencyResult:
    def __init__(self, key: Optional[str], cached: bool, response: Any, redis_client=None):
        self.key      = key
        self.cached   = cached
        self.response = response
        self._client  = redis_client

    async def store(self, response: Any) -> None:
        """Persist the response so future retries get the same result."""
        if not self.key or not self._client:
            return
        try:
            await self._client.setex(
                f"{_KEY_PREFIX}{self.key}",
                _TTL_SECONDS,
                json.dumps(response, default=str),
            )
        except Exception as exc:
            logger.warning("[idempotency] failed to store key=%s: %s", self.key, exc)
        finally:
            await self._client.aclose()


async def idempotency_guard(
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
) -> IdempotencyResult:
    """
    FastAPI dependency. Checks/stores idempotency keys via Redis.
    Returns an IdempotencyResult — caller decides whether to replay or proceed.
    """
    if not x_idempotency_key:
        return IdempotencyResult(key=None, cached=False, response=None)

    try:
        from api.core.config import settings
        if not settings.redis_enabled:
            return IdempotencyResult(key=x_idempotency_key, cached=False, response=None)

        import redis.asyncio as aioredis
        client = aioredis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=2,
        )
        cached_raw = await client.get(f"{_KEY_PREFIX}{x_idempotency_key}")

        if cached_raw:
            logger.info("[idempotency] cache HIT key=%s", x_idempotency_key)
            await client.aclose()
            return IdempotencyResult(
                key=x_idempotency_key,
                cached=True,
                response=json.loads(cached_raw),
            )

        logger.debug("[idempotency] cache MISS key=%s", x_idempotency_key)
        return IdempotencyResult(
            key=x_idempotency_key,
            cached=False,
            response=None,
            redis_client=client,
        )

    except Exception as exc:
        logger.error("[idempotency] Redis error (fail-open): %s", exc)
        return IdempotencyResult(key=x_idempotency_key, cached=False, response=None)
