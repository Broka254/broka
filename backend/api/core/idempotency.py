"""
BROKA v4.0 - Idempotency Key Middleware
─────────────────────────────────────────────────────────────────────────────
Prevents double-charges and duplicate state mutations on retried requests.

How it works:
  1. Client sends  X-Idempotency-Key: <uuid>  header with every write request.
  2. The guard atomically RESERVES the key in Redis (SET NX) with an
     "in flight" marker before the handler runs.
  3. Key already holds a stored response -> replay it (no handler invoked).
     Key is reserved by a request still running -> 409, retry shortly.
  4. Otherwise this request owns the key: the handler runs, and the route
     either store()s the response (24 h) or release()s the key on failure.

Step 2 is what makes a double TAP safe, not just a sequential retry. The
guard used to GET, find nothing, and let the handler run - so two requests
arriving together both missed and both executed.

Releasing matters too: without it a request that failed cleanly (a rejected
phone number, say) would pin its key as "in flight" and turn the user's
corrected retry into a 409 until the reservation expired. idempotency_guard
is a yield-dependency so that happens however the request ends - including
a request body that fails validation, which FastAPI reports only AFTER the
dependencies have run, so no handler code would ever get the chance.

Keys are scoped. The client's key is combined with who sent it (the
signed-in user) and what it was sent to (method and path) before it names
anything in Redis. They used to be one global namespace: a key reused
within 24 hours - by another user, or for another deal - was answered with
the EARLIER request's stored response, and the handler never ran. For
POST /deal/{id}/fund that meant another deal's payment reply and no STK
push at all.

Without Redis, idempotency degrades gracefully (fail-open). Money endpoints
must not depend on this alone - the escrow fund path also claims its attempt
in the database (EscrowService._claim_funding_attempt), which holds whether
or not Redis is up.

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

import hashlib
import json
import logging
from typing import Any, AsyncIterator, Optional

from fastapi import Depends, Header, HTTPException, Request, status

from api.security import get_current_user_optional

logger = logging.getLogger(__name__)

_TTL_SECONDS = 86_400   # 24 hours
_KEY_PREFIX  = "broka:idempotency:"

# The reservation's lifetime while its request runs. Long enough for the
# slowest money call (a provider round-trip plus retries), short enough that
# a process that dies mid-request frees the key on its own.
_IN_FLIGHT_TTL_SECONDS = 120
_IN_FLIGHT = "__broka_in_flight__"

# A client key is an opaque token (the app would send a UUID). Anything
# longer than this is refused rather than hashed, so a key can't be used
# to make the server hash megabytes.
_MAX_KEY_LENGTH = 200


def redis_key(client_key: str, scope: str = "") -> str:
    """The Redis key for `client_key` sent in `scope` (user, method and
    path - see request_scope). Hashed, so its length is fixed and nothing
    the client sent appears in Redis verbatim."""
    digest = hashlib.sha256(f"{scope}\n{client_key}".encode()).hexdigest()
    return f"{_KEY_PREFIX}{digest}"


def request_scope(request: Request, current_user: Optional[dict]) -> str:
    """Who sent a request and what to: the scope an idempotency key is
    unique within. The same key from another user, or for another path
    (another deal's /fund), is a different key."""
    who = f"user:{current_user['id']}" if current_user else "anonymous"
    return f"{who}\n{request.method}\n{request.url.path}"


class IdempotencyResult:
    def __init__(
        self, key: Optional[str], cached: bool, response: Any, redis_client=None,
        redis_key: Optional[str] = None,
    ):
        self.key      = key
        self.cached   = cached
        self.response = response
        self._client  = redis_client
        # Unscoped when not given - only the unit tests construct results
        # directly; reserve_idempotency_key always passes the scoped key.
        self._rkey    = redis_key or (f"{_KEY_PREFIX}{key}" if key else None)

    async def store(self, response: Any) -> None:
        """Persist the response so future retries get the same result."""
        if not self.key or not self._client:
            return
        try:
            await self._client.setex(
                self._rkey,
                _TTL_SECONDS,
                json.dumps(response, default=str),
            )
        except Exception as exc:
            logger.warning("[idempotency] failed to store key=%s: %s", self.key, exc)
        finally:
            await self._close()

    async def release(self) -> None:
        """Give up this request's reservation, so a retry can run.

        Deletes the key only while it still holds OUR in-flight marker - a
        stored response, or somebody else's reservation after ours expired,
        is left alone.
        """
        if not self.key or not self._client:
            return
        try:
            if await self._client.get(self._rkey) == _IN_FLIGHT:
                await self._client.delete(self._rkey)
        except Exception as exc:
            logger.warning("[idempotency] failed to release key=%s: %s", self.key, exc)
        finally:
            await self._close()

    @property
    def holds_reservation(self) -> bool:
        """True until store() or release() has settled this request's key."""
        return self._client is not None

    async def _close(self) -> None:
        client, self._client = self._client, None
        if client is not None:
            try:
                await client.aclose()
            except Exception:
                pass


async def idempotency_guard(
    request: Request,
    x_idempotency_key: Optional[str] = Header(None, alias="X-Idempotency-Key"),
    current_user: Optional[dict] = Depends(get_current_user_optional),
) -> AsyncIterator[IdempotencyResult]:
    """
    FastAPI dependency. Reserves/replays idempotency keys via Redis, scoped
    to the signed-in user, the method and the path (request_scope).
    Yields an IdempotencyResult — caller decides whether to replay or proceed.
    Raises 409 while another request holding the same key is still running.

    Whatever becomes of the request, a reservation it still holds when it
    ends is released - so only a response the route store()d survives it.
    """
    result = await reserve_idempotency_key(
        x_idempotency_key, scope=request_scope(request, current_user),
    )
    try:
        yield result
    finally:
        if result.holds_reservation:
            await result.release()


async def reserve_idempotency_key(
    x_idempotency_key: Optional[str], scope: str = "",
) -> IdempotencyResult:
    """The reservation itself (see idempotency_guard). Raises 409 while the
    key is held by a request that is still running, and 400 for a key too
    long to be a real one."""
    if not x_idempotency_key:
        return IdempotencyResult(key=None, cached=False, response=None)
    if len(x_idempotency_key) > _MAX_KEY_LENGTH:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"X-Idempotency-Key must be at most {_MAX_KEY_LENGTH} characters.",
        )

    client = None
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
        rkey = redis_key(x_idempotency_key, scope)

        # Two rounds: the key can expire between a failed SET NX and the GET
        # that follows it, in which case the second SET NX simply wins.
        for _ in range(2):
            if await client.set(rkey, _IN_FLIGHT, nx=True, ex=_IN_FLIGHT_TTL_SECONDS):
                logger.debug("[idempotency] reserved key=%s", x_idempotency_key)
                return IdempotencyResult(
                    key=x_idempotency_key,
                    cached=False,
                    response=None,
                    redis_client=client,
                    redis_key=rkey,
                )

            existing = await client.get(rkey)
            if existing is None:
                continue
            if existing == _IN_FLIGHT:
                await client.aclose()
                client = None
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail="This request is already being processed. Please wait a moment.",
                    headers={"Retry-After": "2"},
                )
            logger.info("[idempotency] cache HIT key=%s", x_idempotency_key)
            await client.aclose()
            return IdempotencyResult(
                key=x_idempotency_key,
                cached=True,
                response=json.loads(existing),
            )

        # Reserved and expired twice in a row: Redis is misbehaving. Proceed
        # without a guarantee rather than refuse the request.
        logger.error("[idempotency] could not reserve key=%s - proceeding unguarded", x_idempotency_key)
        await client.aclose()
        return IdempotencyResult(key=x_idempotency_key, cached=False, response=None)

    except HTTPException:
        raise
    except Exception as exc:
        logger.error("[idempotency] Redis error (fail-open): %s", exc)
        if client is not None:
            try:
                await client.aclose()
            except Exception:
                pass
        return IdempotencyResult(key=x_idempotency_key, cached=False, response=None)
