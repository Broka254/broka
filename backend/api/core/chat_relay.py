"""Chat socket frames across API processes (Redis Pub/Sub).

Why (2026-11-15): a chat socket lives in one process's
`media._thread_connections`, and Railway runs the API as two replicas.
Whatever a request on the other replica sent the thread - the delivered and
read receipts above all, but also messages, edits and typing - reached only
the sockets in its own process. A sender whose chat socket was on replica A
never heard the delivered receipt that the recipient's sync/ack posted to
replica B: their tick waited for the next 30-second read-status refresh, and
when the recipient opened the message inside that window the bubble went
from Sent straight to Seen. The server had logged MESSAGE_DELIVERED; the
sender's phone was simply never told.

One channel for every thread (`broka:chat:frames`). An envelope names the
thread key, the frame and whose sockets to leave out; each process hands it
to its own sockets for that thread and nothing else. The process that
published a frame has already delivered it locally and ignores its own
envelope. Best effort, like the frames themselves: Pub/Sub keeps nothing,
and a socket that was away when a receipt went out is sent the receipts as
they stand when it connects (media._current_receipt).

Without Redis (tests, one-process development) there is nothing to relay
to. Tests stand a `MemoryBus` in for Redis, with two relays on it acting as
two replicas. Never logs a frame: frames carry message words.
"""
from __future__ import annotations

import asyncio
import contextvars
import json
import logging
import os
import uuid
from typing import Awaitable, Callable, Optional

logger = logging.getLogger(__name__)

CHANNEL = "broka:chat:frames"
# A photo or a voice note travels as a data URI inside its message frame.
# Past this size a frame stays on its own replica: the other replica's
# phones get the message from its push and their next poll, as before,
# instead of megabytes going through Redis.
MAX_FRAME_BYTES = 1024 * 1024
# A direct message's request waits on its broadcast before it answers; a
# Redis that hangs must not hold the sender on "Sending".
PUBLISH_TIMEOUT_SECONDS = 1.0
# How long a listener waits before subscribing again after Redis dropped it.
RESUBSCRIBE_DELAYS_SECONDS = (1.0, 2.0, 5.0, 10.0)

# Unique per process, whatever the host is called: the id only tells a
# process its own envelopes, and two replicas sharing a hostname must still
# hear each other.
INSTANCE_ID = (f"{os.getenv('BROKA_INSTANCE_ID') or os.getenv('HOSTNAME') or 'inst'}"
               f"-{uuid.uuid4().hex[:8]}")

# (thread key, frame, uid whose sockets are left out) -> sent to this
# process's sockets for that thread.
Deliver = Callable[[str, dict, Optional[str]], Awaitable[object]]


class MemoryBus:
    """Redis Pub/Sub for tests: every relay on one bus hears every envelope."""

    def __init__(self):
        self.subscribers: list = []  # (instance_id, callback)

    def subscribe(self, instance_id: str, callback) -> None:
        if not any(i == instance_id for i, _ in self.subscribers):
            self.subscribers.append((instance_id, callback))

    def unsubscribe(self, instance_id: str) -> None:
        self.subscribers = [s for s in self.subscribers if s[0] != instance_id]

    async def publish(self, raw: str) -> None:
        for _, callback in list(self.subscribers):
            await callback(raw)


class ChatRelay:
    def __init__(self, *, instance_id: str = INSTANCE_ID, redis_url: Optional[str] = None,
                 bus: Optional[MemoryBus] = None):
        self.instance_id = instance_id
        self._redis_url = redis_url if bus is None else None
        self._bus = bus
        self._deliver: Optional[Deliver] = None
        self._client = None
        self._client_loop = None
        self._listener: Optional[asyncio.Task] = None
        self._listener_loop = None

    @property
    def enabled(self) -> bool:
        return self._bus is not None or bool(self._redis_url)

    def set_deliver(self, deliver: Deliver) -> None:
        self._deliver = deliver

    def ensure_listening(self) -> None:
        """This process has a chat socket: frames other processes publish
        must reach it. Called on every socket connect, and never waits for
        Redis - a socket that connects while the subscription is still being
        made is sent the receipts as they stand anyway (media._current_receipt)."""
        if self._bus is not None:
            self._bus.subscribe(self.instance_id, self._on_raw)
            return
        if not self._redis_url:
            return
        loop = asyncio.get_running_loop()
        if (self._listener is None or self._listener.done()
                or self._listener_loop is not loop):
            self._listener_loop = loop
            # A context of its own: it outlives the socket that started it.
            self._listener = loop.create_task(self._listen(), context=contextvars.Context())

    async def publish(self, key: str, frame: dict, exclude_uid: Optional[str] = None) -> bool:
        """Send `frame` to the thread's sockets in every other process.
        Never raises; False when nothing was published."""
        if not self.enabled:
            return False
        try:
            raw = json.dumps({"origin": self.instance_id, "key": key,
                              "exclude": exclude_uid, "frame": frame},
                             separators=(",", ":"), default=str)
        except (TypeError, ValueError) as exc:
            logger.warning("[chat-relay] CHAT_RELAY_SKIPPED instance=%s key=%s type=%s "
                           "reason=unserializable err=%s", self.instance_id, key,
                           frame.get("type"), type(exc).__name__)
            return False
        if len(raw) > MAX_FRAME_BYTES:
            logger.info("[chat-relay] CHAT_RELAY_SKIPPED instance=%s key=%s type=%s "
                        "reason=too_large bytes=%d", self.instance_id, key,
                        frame.get("type"), len(raw))
            return False
        try:
            if self._bus is not None:
                await self._bus.publish(raw)
            else:
                client = await self._get_client()
                await asyncio.wait_for(client.publish(CHANNEL, raw),
                                       timeout=PUBLISH_TIMEOUT_SECONDS)
            return True
        except Exception as exc:
            logger.warning("[chat-relay] CHAT_RELAY_PUBLISH_FAILED instance=%s key=%s type=%s "
                           "err=%s", self.instance_id, key, frame.get("type"),
                           type(exc).__name__)
            return False

    async def _on_raw(self, raw) -> None:
        try:
            envelope = json.loads(raw)
        except (TypeError, ValueError):
            return
        if not isinstance(envelope, dict) or envelope.get("origin") == self.instance_id:
            return
        key, frame = envelope.get("key"), envelope.get("frame")
        exclude = envelope.get("exclude")
        if not isinstance(key, str) or not isinstance(frame, dict):
            return
        deliver = self._deliver
        if deliver is None:
            return
        try:
            await deliver(key, frame, exclude if isinstance(exclude, str) else None)
        except Exception as exc:
            logger.warning("[chat-relay] CHAT_RELAY_DELIVER_FAILED instance=%s key=%s type=%s "
                           "err=%s", self.instance_id, key, frame.get("type"),
                           type(exc).__name__)

    async def _get_client(self):
        loop = asyncio.get_running_loop()
        if self._client is None or self._client_loop is not loop:
            import redis.asyncio as aioredis
            self._client = aioredis.from_url(self._redis_url, encoding="utf-8",
                                             decode_responses=True, socket_connect_timeout=2)
            self._client_loop = loop
        return self._client

    async def _listen(self) -> None:
        """Subscribed for as long as the process runs: a dropped Redis
        connection is subscribed again, after a short wait."""
        import redis.asyncio as aioredis
        failures = 0
        while True:
            client = aioredis.from_url(self._redis_url, encoding="utf-8",
                                       decode_responses=True, socket_connect_timeout=2)
            pubsub = client.pubsub()
            try:
                await pubsub.subscribe(CHANNEL)
                failures = 0
                logger.info("[chat-relay] CHAT_RELAY_SUBSCRIBED instance=%s channel=%s",
                            self.instance_id, CHANNEL)
                async for msg in pubsub.listen():
                    if msg.get("type") != "message":
                        continue
                    await self._on_raw(msg.get("data"))
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("[chat-relay] CHAT_RELAY_LISTENER_FAILED instance=%s err=%s",
                               self.instance_id, type(exc).__name__)
            finally:
                try:
                    await pubsub.aclose()
                    await client.aclose()
                except Exception:
                    pass
            delay = RESUBSCRIBE_DELAYS_SECONDS[min(failures, len(RESUBSCRIBE_DELAYS_SECONDS) - 1)]
            failures += 1
            await asyncio.sleep(delay)

    async def close(self) -> None:
        if self._listener is not None:
            self._listener.cancel()
            self._listener = None
        if self._bus is not None:
            self._bus.unsubscribe(self.instance_id)


def _make_relay() -> ChatRelay:
    from api.core.config import settings
    if settings.redis_enabled:
        return ChatRelay(redis_url=settings.redis_url)
    return ChatRelay()


relay = _make_relay()
