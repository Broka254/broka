"""
BROKA v4.0 - Durable Event Bus
─────────────────────────────────────────────────────────────────────────────
Two-tier event delivery:

  Tier 1 — Redis Streams (production, multi-instance safe, crash-durable)
    • Events survive process restarts / deployments.
    • Consumer groups allow multiple worker instances to share load.
    • Requires REDIS_URL env var.

  Tier 2 — In-process asyncio (dev / single-instance fallback)
    • Zero dependencies. Events lost on process exit.
    • Activates automatically when REDIS_URL is absent.

Same API regardless of tier:
    await publish(DealFinalized(deal_id="...", seller_id="...", amount=5000))

    @subscribe(DealFinalized)
    async def on_deal_finalized(event: DealFinalized) -> None: ...
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field, asdict
from datetime import datetime
from typing import Any, Callable, Coroutine, Dict, List, Type, TypeVar

logger = logging.getLogger(__name__)

E = TypeVar("E", bound="BrokaEvent")
Handler = Callable[[Any], Coroutine[Any, Any, None]]

_handlers: Dict[Type["BrokaEvent"], List[Handler]] = {}
_STREAM_PREFIX = "broka:events:"


def subscribe(event_type: Type[E]) -> Callable[[Handler], Handler]:
    """Decorator: register an async handler for an event type."""
    def decorator(fn: Handler) -> Handler:
        _handlers.setdefault(event_type, []).append(fn)
        return fn
    return decorator


async def _publish_redis(event: "BrokaEvent") -> None:
    try:
        from api.core.config import settings
        import redis.asyncio as aioredis
        client = aioredis.from_url(
            settings.redis_url,
            encoding="utf-8",
            decode_responses=True,
            socket_connect_timeout=2,
        )
        event_name = type(event).__name__
        payload = asdict(event)
        payload = {
            k: v.isoformat() if isinstance(v, datetime) else str(v)
            for k, v in payload.items()
        }
        payload["_event_type"] = event_name
        await client.xadd(
            f"{_STREAM_PREFIX}{event_name}",
            payload,
            maxlen=50_000,
            approximate=True,
        )
        await client.aclose()
    except Exception as exc:
        # No in-process fallback here any more: publish() now always
        # dispatches locally BEFORE calling this, so retrying it here
        # would deliver every event twice to every handler.
        logger.error("[events:redis] stream publish failed: %s", exc)


# Strong references to in-flight handler tasks. asyncio only holds a WEAK
# reference to a running task, so a task whose only reference is a local
# variable can be garbage-collected mid-execution - the exact footgun the
# asyncio docs warn about. The previous code did
# `tasks = [...]; _ = tasks`, which keeps the list alive precisely until
# the function returns and not one moment longer. Harmless while
# _handlers was empty; live the instant anyone registers a handler.
_inflight: set = set()


async def _publish_inprocess(event: "BrokaEvent") -> None:
    handlers = _handlers.get(type(event), [])
    for h in handlers:
        task = asyncio.create_task(_safe_call(h, event))
        _inflight.add(task)
        task.add_done_callback(_inflight.discard)


async def publish(event: "BrokaEvent") -> None:
    """
    Publish a domain event.
    Automatically uses Redis Streams when REDIS_URL is configured, otherwise in-process.

    Also bridges to the platform Event Catalog so that:
      • Catalog subscribers (Zeno, metrics, tracing) receive legacy events.
      • Redis Streams are written with the standardised envelope format.
    """
    # In-process handlers run on EVERY tier, then Redis is written as an
    # ADDITIONAL durable copy - deliberately matching what
    # api/core/event_catalog.py's emit() already does correctly.
    #
    # BUG FIX (implementation audit, spec §20, 2026-09-14): this used to be
    # `if redis_enabled: _publish_redis() else: _publish_inprocess()` - an
    # either/or. With Redis configured, no local handler ran at all, and
    # the stream it wrote to instead has no consumer (see `consume()`
    # below, which nothing in main.py or workers.py ever starts). So a
    # handler registered through this module's own documented API - the
    # `@subscribe(DealFinalized)` shown in the module docstring above -
    # worked perfectly in development, where REDIS_URL is unset, and then
    # silently did nothing in production.
    #
    # This is currently a LOADED TRAP RATHER THAN A LIVE FAULT, and the
    # distinction matters: grep shows zero real `@subscribe(...)` handlers
    # in the codebase (the only match is the docstring example), so nothing
    # is broken today. Every real subscriber uses @subscribe_to on the
    # catalog bus and is reached through _bridge_to_catalog() below, which
    # already ran unconditionally. The trap is that the next person to
    # follow this file's documentation gets a production-only silent
    # failure. Fixed at the mechanism rather than left to be discovered.
    await _publish_inprocess(event)

    try:
        from api.core.config import settings
        if settings.redis_enabled:
            await _publish_redis(event)
    except Exception as exc:
        # Redis being unavailable must not fail the caller - the in-process
        # dispatch above already happened, so the event was delivered.
        logger.warning("[events] redis publish failed (non-fatal): %s", exc)

    # ── Bridge to Event Catalog (best-effort; never breaks callers) ───────────
    try:
        await _bridge_to_catalog(event)
    except Exception as exc:
        logger.debug("[events] catalog bridge failed (non-fatal): %s", exc)


async def _bridge_to_catalog(event: "BrokaEvent") -> None:
    """
    Map a legacy BrokaEvent to the standardised Event Catalog envelope.
    This allows Zeno subscribers and metric counters to receive legacy events
    without requiring every call-site to be migrated at once.
    """
    from api.core.event_catalog import LEGACY_EVENT_MAP, emit as catalog_emit
    event_class_name = type(event).__name__
    catalog_type = LEGACY_EVENT_MAP.get(event_class_name)
    if catalog_type is None:
        return  # unmapped legacy event — no bridge needed

    from dataclasses import asdict
    raw = asdict(event)
    raw.pop("occurred_at", None)

    # Extract common fields where they exist in the dataclass
    aggregate_id = (
        raw.get("deal_id") or raw.get("listing_id") or
        raw.get("user_id") or raw.get("dispute_id") or
        raw.get("review_id") or ""
    )
    actor = raw.get("buyer_id") or raw.get("user_id") or "system"
    aggregate = (
        "deal"    if "deal_id"    in raw else
        "listing" if "listing_id" in raw else
        "user"    if "user_id"    in raw else
        "dispute" if "dispute_id" in raw else
        "event"
    )

    await catalog_emit(
        event_type=catalog_type,
        aggregate=aggregate,
        aggregate_id=aggregate_id,
        actor=actor,
        payload=raw,
    )


async def _safe_call(handler: Handler, event: "BrokaEvent") -> None:
    try:
        await handler(event)
    except Exception as exc:
        logger.error("[events] handler %s raised for event %s: %s",
                     handler.__name__, type(event).__name__, exc)


async def consume_redis_stream(
    event_type: Type[E],
    last_id: str = "$",
    group: str = "broka-workers",
) -> None:
    """Long-running Redis Stream consumer for a single event type."""
    from api.core.config import settings
    import redis.asyncio as aioredis

    stream_key = f"{_STREAM_PREFIX}{event_type.__name__}"
    client = aioredis.from_url(settings.redis_url, encoding="utf-8", decode_responses=True)

    try:
        await client.xgroup_create(stream_key, group, id="0", mkstream=True)
    except Exception:
        pass

    consumer_name = f"worker-{id(asyncio.get_event_loop())}"
    logger.info("[events:consumer] starting stream=%s group=%s", stream_key, group)

    try:
        while True:
            try:
                results = await client.xreadgroup(
                    group, consumer_name, {stream_key: ">"}, block=5000, count=10
                )
                for _, messages in results:
                    for msg_id, data in messages:
                        await _dispatch_stream_message(event_type, data)
                        await client.xack(stream_key, group, msg_id)
            except asyncio.CancelledError:
                break
            except Exception as exc:
                logger.error("[events:consumer] stream=%s error: %s", stream_key, exc)
                await asyncio.sleep(1)
    finally:
        await client.aclose()


async def _dispatch_stream_message(event_type: Type["BrokaEvent"], data: dict) -> None:
    data = dict(data)
    data.pop("_event_type", None)
    for k, v in data.items():
        if isinstance(v, str) and "T" in v and len(v) > 10:
            try:
                data[k] = datetime.fromisoformat(v)
            except ValueError:
                pass
    try:
        event = event_type(**data)
    except TypeError as e:
        logger.error("[events:consumer] reconstruct error %s: %s", event_type.__name__, e)
        return
    for h in _handlers.get(event_type, []):
        await _safe_call(h, event)


# ── Base Event ────────────────────────────────────────────────────────────────

@dataclass
class BrokaEvent:
    occurred_at: datetime = field(default_factory=datetime.utcnow)


# ── Domain Events ─────────────────────────────────────────────────────────────

@dataclass
class UserRegistered(BrokaEvent):
    user_id: str = ""
    email:   str = ""
    name:    str = ""


@dataclass
class UserLoggedIn(BrokaEvent):
    user_id: str = ""


@dataclass
class ListingCreated(BrokaEvent):
    listing_id: str   = ""
    seller_id:  str   = ""
    price:      float = 0.0
    category:   str   = ""


@dataclass
class InterestExpressed(BrokaEvent):
    listing_id:  str   = ""
    buyer_id:    str   = ""
    offer_price: float = 0.0


@dataclass
class DealFinalized(BrokaEvent):
    deal_id:      str   = ""
    listing_id:   str   = ""
    seller_id:    str   = ""
    buyer_id:     str   = ""
    agreed_price: float = 0.0
    commission:   float = 0.0


@dataclass
class EscrowFunded(BrokaEvent):
    deal_id:       str   = ""
    buyer_id:      str   = ""
    seller_id:     str   = ""
    amount:        float = 0.0
    mpesa_receipt: str   = ""


@dataclass
class EscrowReleased(BrokaEvent):
    deal_id:   str   = ""
    seller_id: str   = ""
    buyer_id:  str   = ""
    amount:    float = 0.0


@dataclass
class EscrowRefunded(BrokaEvent):
    deal_id:    str   = ""
    buyer_id:   str   = ""
    seller_id:  str   = ""
    amount:     float = 0.0
    dispute_id: str   = ""


@dataclass
class DisputeOpened(BrokaEvent):
    dispute_id: str = ""
    deal_id:    str = ""
    opener_id:  str = ""
    issue_type: str = ""


@dataclass
class DisputeResolved(BrokaEvent):
    dispute_id: str = ""
    deal_id:    str = ""
    resolution: str = ""   # "release" | "refund" | "split"
    admin_id:   str = ""


@dataclass
class ReviewSubmitted(BrokaEvent):
    review_id:   str = ""
    deal_id:     str = ""
    seller_id:   str = ""
    reviewer_id: str = ""
    rating:      int = 0


@dataclass
class UserVerified(BrokaEvent):
    user_id: str = ""
    tier:    str = ""


@dataclass
class BidPlaced(BrokaEvent):
    listing_id: str   = ""
    bidder_id:  str   = ""
    amount:     float = 0.0


@dataclass
class FraudFlagged(BrokaEvent):
    user_id:      str = ""
    reason:       str = ""
    trust_score:  int = 0
    triggered_by: str = ""


@dataclass
class MpesaCallbackReceived(BrokaEvent):
    checkout_request_id: str   = ""
    result_code:         int   = -1
    mpesa_receipt:       str   = ""
    amount:              float = 0.0


# ── E-Confirm marketplace escrow (Phase 13 of the integration) ────────────────
# Finer-grained than EscrowFunded/EscrowReleased above, which are still
# published exactly once each at the same two transition points they always
# were (agreed->paid, paid->released) so deal_hub_subscribers.py's existing
# ledger + WebSocket-broadcast handling keeps working unchanged for
# E-Confirm-funded deals too. These are additional, provider-specific
# observability events for anything watching this integration
# specifically — not currently subscribed to by anything, safe to publish
# freely (see events.py's _bridge_to_catalog: an unmapped legacy event is a
# deliberate no-op, not an error).

@dataclass
class EConfirmEscrowCreated(BrokaEvent):
    deal_id:                 str   = ""
    provider_transaction_id: str   = ""
    buyer_id:                str   = ""
    seller_id:               str   = ""
    amount:                  float = 0.0


@dataclass
class EConfirmFundingInitiated(BrokaEvent):
    deal_id:                 str = ""
    provider_transaction_id: str = ""
    payer_phone:             str = ""


@dataclass
class EConfirmEscrowFunded(BrokaEvent):
    deal_id:                 str   = ""
    provider_transaction_id: str   = ""
    buyer_id:                str   = ""
    seller_id:               str   = ""
    amount:                  float = 0.0


@dataclass
class EConfirmReleaseInitiated(BrokaEvent):
    deal_id:                 str = ""
    provider_transaction_id: str = ""
    seller_id:               str = ""


@dataclass
class EConfirmPayoutCompleted(BrokaEvent):
    deal_id:                 str   = ""
    provider_transaction_id: str   = ""
    seller_id:               str   = ""
    amount:                  float = 0.0


@dataclass
class EConfirmPayoutFailed(BrokaEvent):
    deal_id:                 str = ""
    provider_transaction_id: str = ""
    reason:                  str = ""


@dataclass
class EConfirmReconciliationRequired(BrokaEvent):
    deal_id:                 str = ""
    provider_transaction_id: str = ""
    reason:                  str = ""
