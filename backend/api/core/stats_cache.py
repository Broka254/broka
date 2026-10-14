"""
BROKA - Generic Stats Cache
─────────────────────────────────────────────────────────────────────────────
Small Redis-backed cache for periodically-computed aggregate stats (e.g. the
platform-wide dispute-summary numbers from Volume 2 §2.3). Same fail-open
pattern as domains/ai_broker/service.py's _cache_get/_cache_set: if Redis
isn't configured or is briefly unavailable, callers get None back rather
than an exception, and are expected to fall back to a sane default.

Exists as its own module (rather than living inside workers.py or
disputes/router.py) so both can import it without importing each other -
workers.py writes the cache on a schedule, disputes/router.py reads it on
each request.
"""
from __future__ import annotations

import json
import logging
from typing import Any, Optional

from api.core.config import settings

logger = logging.getLogger(__name__)


async def cache_get_json(key: str) -> Optional[dict]:
    """Read a JSON value. Returns None on any failure (no Redis, timeout, miss)."""
    try:
        if not settings.redis_enabled:
            return None
        import redis.asyncio as aioredis
        client = aioredis.from_url(settings.redis_url, decode_responses=True, socket_connect_timeout=1)
        raw = await client.get(key)
        await client.aclose()
        return json.loads(raw) if raw else None
    except Exception as exc:
        logger.warning("[stats_cache] get failed for %s: %s", key, exc)
        return None


async def cache_set_json(key: str, value: dict, ttl_seconds: int) -> None:
    """Write a JSON value with a TTL. Silently no-ops on any failure."""
    try:
        if not settings.redis_enabled:
            return
        import redis.asyncio as aioredis
        client = aioredis.from_url(settings.redis_url, decode_responses=True, socket_connect_timeout=1)
        await client.setex(key, ttl_seconds, json.dumps(value))
        await client.aclose()
    except Exception as exc:
        logger.warning("[stats_cache] set failed for %s: %s", key, exc)


# ── Well-known keys ──────────────────────────────────────────────────────────
DISPUTE_SUMMARY_KEY = "broka:stats:dispute_summary"
