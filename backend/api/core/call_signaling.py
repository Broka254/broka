"""Distributed call signaling: Redis Pub/Sub relay + presence + buffering.

Why: live sockets live in calls.py's per-process `_rooms`. With 2 Railway
replicas, caller on A and callee on B each saw peers=1 and `ready` never
fired, so no SDP/ICE crossed and the caller sat on "They answered -
connecting". This module is the cross-replica layer: presence in Redis
hashes (leased, expiring), signals on per-room Pub/Sub channels, and a
short-lived buffer for signals sent while the recipient was absent.

Safety for the call lifecycle: clients only send offers after `ready`,
and `ready` is emitted only when distributed presence shows BOTH distinct
participants. So the offer cannot be published before the peer's replica
is subscribed. ICE trickle after that can still race a reconnect, hence
the buffer: a signal whose recipient is absent at publish time is kept
(120s, capped) and drained on join. Live signals go via Pub/Sub and are
never replayed from the buffer, so no duplicates.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import secrets
import time
import uuid
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

PRESENCE_TTL_SECONDS = 45
BUFFER_TTL_SECONDS = 120
BUFFER_MAX = 50

INSTANCE_ID = os.getenv("BROKA_INSTANCE_ID") or os.getenv("HOSTNAME") or f"inst-{uuid.uuid4().hex[:8]}"


def _presence_key(room_id: str) -> str:
    return f"broka:call:presence:{room_id}"


def _channel(room_id: str) -> str:
    return f"broka:call:signal:{room_id}"


def _buffer_key(room_id: str, user_id: str) -> str:
    return f"broka:call:buf:{room_id}:{user_id}"


# ── Shared in-memory backend (tests / no-Redis single-instance dev) ──────────
class _MemoryBackend:
    """One shared bus standing in for Redis in tests: two hub instances
    sharing one backend simulate two replicas sharing Redis."""

    def __init__(self):
        self.presence: dict = {}  # room -> {user: entry dict}
        self.buffers: dict = {}  # (room, user) -> [envelope]
        self.subscribers: list = []  # (instance_id, callback)

    async def register(self, room, user, instance, conn):
        self.presence.setdefault(room, {})[user] = {
            "instance": instance, "conn": conn, "exp": time.time() + PRESENCE_TTL_SECONDS,
        }

    async def unregister(self, room, user, conn) -> bool:
        entry = self.presence.get(room, {}).get(user)
        if entry is None or entry["conn"] != conn:
            return False
        del self.presence[room][user]
        return True

    async def renew(self, room, user, conn):
        entry = self.presence.get(room, {}).get(user)
        if entry and entry["conn"] == conn:
            entry["exp"] = time.time() + PRESENCE_TTL_SECONDS

    async def peers(self, room) -> dict:
        now = time.time()
        live = {u: e for u, e in self.presence.get(room, {}).items() if e["exp"] > now}
        if room in self.presence:
            self.presence[room] = live
        return dict(live)

    async def buffer_push(self, room, user, envelope):
        buf = self.buffers.setdefault((room, user), [])
        buf.append(envelope)
        del buf[:-BUFFER_MAX]

    async def buffer_drain(self, room, user) -> list:
        return self.buffers.pop((room, user), [])

    async def publish(self, room, envelope):
        for instance, cb in list(self.subscribers):
            if instance == envelope.get("origin_instance"):
                continue  # never echo to originator's replica
            await cb(envelope)

    def subscribe(self, instance, cb):
        self.subscribers.append((instance, cb))

    def unsubscribe(self, instance):
        self.subscribers = [s for s in self.subscribers if s[0] != instance]


_shared_memory = _MemoryBackend()


def reset_memory_backend() -> _MemoryBackend:
    global _shared_memory
    _shared_memory = _MemoryBackend()
    return _shared_memory


OnRemote = Callable[[dict], Awaitable[None]]


class CallSignalingHub:
    def __init__(self, instance_id: str = INSTANCE_ID, backend: Optional[_MemoryBackend] = None, redis_url: Optional[str] = None):
        self.instance_id = instance_id
        self._on_remote: Optional[OnRemote] = None
        self._redis_url = redis_url
        self._use_redis = backend is None and bool(redis_url)
        self._mem = backend if backend is not None else (None if self._use_redis else _shared_memory)
        self._client = None
        self._client_loop = None
        self._listener: Optional[asyncio.Task] = None
        self._subscribed = asyncio.Event()
        if not self._use_redis and self._mem is not None:
            self._mem.subscribe(self.instance_id, self._dispatch)

    def set_handler(self, cb: OnRemote):
        self._on_remote = cb

    async def _dispatch(self, envelope: dict):
        if self._on_remote is not None:
            result = self._on_remote(envelope)
            if asyncio.iscoroutine(result):
                await result

    async def _get_client(self):
        loop = asyncio.get_running_loop()
        if self._client is None or self._client_loop is not loop:
            import redis.asyncio as aioredis
            self._client = aioredis.from_url(self._redis_url, encoding="utf-8", decode_responses=True, socket_connect_timeout=2)
            self._client_loop = loop
        return self._client

    async def ensure_subscribed(self):
        """Subscription must exist before `ready` can be declared, else a
        signal published in the gap is silently lost (Pub/Sub keeps nothing)."""
        if not self._use_redis:
            return
        if self._listener is None or self._listener.done():
            self._subscribed.clear()
            self._listener = asyncio.create_task(self._listen())
        try:
            await asyncio.wait_for(self._subscribed.wait(), timeout=2.0)
        except asyncio.TimeoutError:
            logger.warning("[signaling] SUBSCRIBE_TIMEOUT instance=%s", self.instance_id)

    async def _listen(self):
        import redis.asyncio as aioredis
        client = aioredis.from_url(self._redis_url, encoding="utf-8", decode_responses=True, socket_connect_timeout=2)
        pubsub = client.pubsub()
        try:
            await pubsub.psubscribe("broka:call:signal:*")
            self._subscribed.set()
            logger.info("[signaling] SUBSCRIBED instance=%s pattern=broka:call:signal:*", self.instance_id)
            async for msg in pubsub.listen():
                if msg.get("type") != "pmessage":
                    continue
                try:
                    envelope = json.loads(msg["data"])
                except Exception:
                    continue
                if envelope.get("origin_instance") == self.instance_id:
                    continue
                await self._dispatch(envelope)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            logger.warning("[signaling] listener failed instance=%s err=%s", self.instance_id, type(exc).__name__)
        finally:
            try:
                await pubsub.aclose()
                await client.aclose()
            except Exception:
                pass

    async def register(self, room_id, user_id, connection_id):
        await self.ensure_subscribed()
        if self._use_redis:
            client = await self._get_client()
            entry = json.dumps({"instance": self.instance_id, "conn": connection_id, "exp": time.time() + PRESENCE_TTL_SECONDS})
            await client.hset(_presence_key(room_id), user_id, entry)
            await client.expire(_presence_key(room_id), PRESENCE_TTL_SECONDS * 3)
        else:
            await self._mem.register(room_id, user_id, self.instance_id, connection_id)
        logger.info("[signaling] PRESENCE_JOIN instance=%s room=%s user=%s conn=%s", self.instance_id, room_id, user_id, connection_id)

    async def unregister(self, room_id, user_id, connection_id) -> bool:
        """Only the owning connection can remove presence: a ghost socket's
        teardown must not delete its replacement's registration."""
        if self._use_redis:
            client = await self._get_client()
            raw = await client.hget(_presence_key(room_id), user_id)
            if not raw:
                return False
            try:
                entry = json.loads(raw)
            except Exception:
                return False
            if entry.get("conn") != connection_id:
                return False
            await client.hdel(_presence_key(room_id), user_id)
            logger.info("[signaling] PRESENCE_LEAVE instance=%s room=%s user=%s conn=%s", self.instance_id, room_id, user_id, connection_id)
            return True
        removed = await self._mem.unregister(room_id, user_id, connection_id)
        if removed:
            logger.info("[signaling] PRESENCE_LEAVE instance=%s room=%s user=%s conn=%s", self.instance_id, room_id, user_id, connection_id)
        return removed

    async def renew(self, room_id, user_id, connection_id):
        if self._use_redis:
            client = await self._get_client()
            raw = await client.hget(_presence_key(room_id), user_id)
            if not raw:
                return
            try:
                entry = json.loads(raw)
            except Exception:
                return
            if entry.get("conn") != connection_id:
                return
            entry["exp"] = time.time() + PRESENCE_TTL_SECONDS
            await client.hset(_presence_key(room_id), user_id, json.dumps(entry))
            await client.expire(_presence_key(room_id), PRESENCE_TTL_SECONDS * 3)
        else:
            await self._mem.renew(room_id, user_id, connection_id)

    async def distributed_peers(self, room_id) -> dict:
        """user_id -> presence entry, expired entries filtered (crash-safe)."""
        if self._use_redis:
            client = await self._get_client()
            raw = await client.hgetall(_presence_key(room_id))
            now = time.time()
            live = {}
            for user, val in (raw or {}).items():
                try:
                    entry = json.loads(val)
                except Exception:
                    continue
                if entry.get("exp", 0) > now:
                    live[user] = entry
                else:
                    await client.hdel(_presence_key(room_id), user)
                    logger.info("[signaling] PRESENCE_EXPIRED room=%s user=%s", room_id, user)
            return live
        return await self._mem.peers(room_id)

    async def publish_signal(self, room_id, sender_id, connection_id, raw: str, msg_type: str, recipient_id: Optional[str]):
        envelope = {
            "room_id": room_id,
            "kind": "signal", "origin_instance": self.instance_id, "origin_conn": connection_id,
            "sender": sender_id, "target": recipient_id, "msg_type": msg_type, "raw": raw,
            "msg_id": secrets.token_hex(8), "ts": time.time(),
        }
        # Buffer only when recipient absent distributed: live Pub/Sub
        # delivery covers present recipients, buffering them too would replay duplicates.
        if recipient_id:
            peers = await self.distributed_peers(room_id)
            if recipient_id not in peers:
                await self._buffer(room_id, recipient_id, envelope)
                logger.info("[signaling] SIGNAL_BUFFERED instance=%s room=%s sender=%s event=%s target=%s", self.instance_id, room_id, sender_id, msg_type, recipient_id)
                return envelope
        await self._publish(room_id, envelope)
        logger.info("[signaling] SIGNAL_PUBLISHED instance=%s room=%s sender=%s event=%s", self.instance_id, room_id, sender_id, msg_type)
        return envelope

    async def publish_control(self, room_id, target_user_id: Optional[str], message: dict, sender_id: str = "server"):
        envelope = {
            "room_id": room_id,
            "kind": "control", "origin_instance": self.instance_id, "origin_conn": "",
            "sender": sender_id, "target": target_user_id, "msg_type": message.get("type", "control"),
            "message": message, "msg_id": secrets.token_hex(8), "ts": time.time(),
        }
        await self._publish(room_id, envelope)
        logger.info("[signaling] CONTROL_PUBLISHED instance=%s room=%s event=%s target=%s", self.instance_id, room_id, envelope["msg_type"], target_user_id)
        return envelope

    async def _buffer(self, room_id, user_id, envelope):
        if self._use_redis:
            client = await self._get_client()
            key = _buffer_key(room_id, user_id)
            await client.rpush(key, json.dumps(envelope))
            await client.ltrim(key, -BUFFER_MAX, -1)
            await client.expire(key, BUFFER_TTL_SECONDS)
        else:
            await self._mem.buffer_push(room_id, user_id, envelope)

    async def drain_buffer(self, room_id, user_id) -> list:
        if self._use_redis:
            client = await self._get_client()
            key = _buffer_key(room_id, user_id)
            raw = await client.lrange(key, 0, -1)
            await client.delete(key)
            out = []
            for item in raw or []:
                try:
                    out.append(json.loads(item))
                except Exception:
                    continue
            return out
        return await self._mem.buffer_drain(room_id, user_id)

    async def _publish(self, room_id, envelope):
        if self._use_redis:
            client = await self._get_client()
            await client.publish(_channel(room_id), json.dumps(envelope))
        else:
            await self._mem.publish(room_id, envelope)

    async def close(self):
        if self._listener is not None:
            self._listener.cancel()
            self._listener = None
        if not self._use_redis and self._mem is not None:
            self._mem.unsubscribe(self.instance_id)


def _make_hub() -> CallSignalingHub:
    from api.core.config import settings
    if settings.redis_enabled:
        logger.info("[signaling] Using Redis Pub/Sub signaling instance=%s", INSTANCE_ID)
        return CallSignalingHub(redis_url=settings.redis_url)
    logger.info("[signaling] Using in-memory signaling (single-instance) instance=%s", INSTANCE_ID)
    return CallSignalingHub(backend=_shared_memory)


hub = _make_hub()
