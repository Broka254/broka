"""
BROKA Platform - Event Catalog v1.0
════════════════════════════════════════════════════════════════════════════════
The authoritative list of every event type emitted by the Broka platform,
organised as DOMAIN.EVENT_NAME strings.

Every subsystem — Auth, Marketplace, Payments, Disputes, Reputation, Zeno —
emits and subscribes using these typed strings. Consistent naming enables:

  • Cross-service tracing  — same event_type in logs, spans, and dashboards
  • Easy audit             — grep for "PAYMENT.ESCROW_LOCKED" across all services
  • Replay                 — any event can be redelivered to rebuild read-models
  • Analytics              — event counts per type are dashboarded automatically
  • Schema evolution       — version field on the envelope allows safe changes

Standard envelope (every event carries this):
  {
    "id":            "uuid-v4",
    "type":          "PAYMENT.ESCROW_LOCKED",
    "aggregate":     "deal",
    "aggregate_id":  "deal_12345",
    "actor":         "user_abc",
    "payload":       { ... domain-specific fields ... },
    "timestamp":     "2026-06-27T12:00:00+00:00",
    "version":       1,
    "correlation_id": "trace-xyz",
    "causation_id":  "evt-id-that-triggered-this"
  }

Usage (emit):
    from api.core.event_catalog import EventType, emit

    await emit(
        EventType.PAYMENT_ESCROW_LOCKED,
        aggregate="deal",
        aggregate_id=deal.id,
        actor=buyer_id,
        payload={"amount": 5000, "mpesa_receipt": "QXC123"},
    )

Usage (subscribe):
    from api.core.event_catalog import subscribe_to, EventType, EventEnvelope

    @subscribe_to(EventType.PAYMENT_ESCROW_LOCKED)
    async def on_escrow_locked(envelope: EventEnvelope) -> None:
        ...
"""
from __future__ import annotations

import logging
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Callable, Coroutine, Dict, List, Optional

logger = logging.getLogger(__name__)

Handler = Callable[["EventEnvelope"], Coroutine[Any, Any, None]]


# ══════════════════════════════════════════════════════════════════════════════
# Event Type Catalog
# Naming: DOMAIN.VERB_NOUN  (past-tense events — "this happened")
# Add new types here. Never rename or remove existing ones.
# ══════════════════════════════════════════════════════════════════════════════

class EventType(str, Enum):

    # ── Authentication ────────────────────────────────────────────────────────
    AUTH_LOGIN              = "AUTH.LOGIN"
    AUTH_LOGOUT             = "AUTH.LOGOUT"
    AUTH_USER_REGISTERED    = "AUTH.USER_REGISTERED"
    AUTH_USER_VERIFIED      = "AUTH.USER_VERIFIED"
    AUTH_TOKEN_REFRESHED    = "AUTH.TOKEN_REFRESHED"
    AUTH_PASSWORD_RESET     = "AUTH.PASSWORD_RESET"

    # ── Marketplace / Listings ────────────────────────────────────────────────
    LISTING_CREATED         = "LISTING.CREATED"
    LISTING_UPDATED         = "LISTING.UPDATED"
    LISTING_SOLD            = "LISTING.SOLD"
    LISTING_EXPIRED         = "LISTING.EXPIRED"
    LISTING_FEATURED        = "LISTING.FEATURED"
    LISTING_INTEREST        = "LISTING.INTEREST_EXPRESSED"

    # ── Orders / Deals ────────────────────────────────────────────────────────
    ORDER_CREATED           = "ORDER.CREATED"
    ORDER_ACCEPTED          = "ORDER.ACCEPTED"
    ORDER_CANCELLED         = "ORDER.CANCELLED"
    ORDER_AGREED            = "ORDER.AGREED"
    ORDER_BID_PLACED        = "ORDER.BID_PLACED"

    # ── Payments ──────────────────────────────────────────────────────────────
    PAYMENT_AUTHORIZED      = "PAYMENT.AUTHORIZED"
    PAYMENT_ESCROW_LOCKED   = "PAYMENT.ESCROW_LOCKED"
    PAYMENT_RELEASED        = "PAYMENT.RELEASED"
    PAYMENT_REFUNDED        = "PAYMENT.REFUNDED"
    PAYMENT_MPESA_CALLBACK  = "PAYMENT.MPESA_CALLBACK"
    PAYMENT_FAILED          = "PAYMENT.FAILED"

    # ── Shipment ──────────────────────────────────────────────────────────────
    SHIPMENT_CREATED            = "SHIPMENT.CREATED"
    SHIPMENT_DISPATCHED         = "SHIPMENT.DISPATCHED"
    SHIPMENT_DELIVERY_CLAIMED   = "SHIPMENT.DELIVERY_CLAIMED"
    SHIPMENT_DELIVERED          = "SHIPMENT.DELIVERED"

    # ── Disputes ──────────────────────────────────────────────────────────────
    DISPUTE_OPENED                  = "DISPUTE.OPENED"
    DISPUTE_EVIDENCE_UPLOADED       = "DISPUTE.EVIDENCE_UPLOADED"
    DISPUTE_REPLACEMENT_REQUESTED   = "DISPUTE.REPLACEMENT_REQUESTED"
    DISPUTE_REFUND_APPROVED         = "DISPUTE.REFUND_APPROVED"
    DISPUTE_RESOLVED                = "DISPUTE.RESOLVED"
    DISPUTE_TIMER_FIRED             = "DISPUTE.TIMER_FIRED"

    # ── Reputation ────────────────────────────────────────────────────────────
    RATING_SUBMITTED            = "RATING.SUBMITTED"
    SELLER_REPUTATION_UPDATED   = "SELLER.REPUTATION_UPDATED"
    FRAUD_FLAGGED               = "FRAUD.FLAGGED"
    TRUST_SCORE_UPDATED         = "TRUST.SCORE_UPDATED"

    # ── Zeno (AI) ─────────────────────────────────────────────────────────────
    ZENO_IMAGE_ANALYZED         = "ZENO.IMAGE_ANALYZED"
    ZENO_RISK_SCORE_UPDATED     = "ZENO.RISK_SCORE_UPDATED"
    ZENO_RECOMMENDATION_READY   = "ZENO.RECOMMENDATION_READY"
    ZENO_DISPUTE_VERDICT        = "ZENO.DISPUTE_VERDICT"
    ZENO_TIMER_SCHEDULED        = "ZENO.TIMER_SCHEDULED"

    # ── System ────────────────────────────────────────────────────────────────
    SYSTEM_WORKER_STARTED   = "SYSTEM.WORKER_STARTED"
    SYSTEM_SWEEP_FIRED      = "SYSTEM.SWEEP_FIRED"
    SYSTEM_CIRCUIT_OPENED   = "SYSTEM.CIRCUIT_OPENED"
    SYSTEM_CIRCUIT_CLOSED   = "SYSTEM.CIRCUIT_CLOSED"


# ══════════════════════════════════════════════════════════════════════════════
# Standard Event Envelope
# Every event, regardless of domain, is wrapped in this structure.
# Fields mirror CloudEvents spec for portability across logging / tracing tools.
# ══════════════════════════════════════════════════════════════════════════════

@dataclass
class EventEnvelope:
    """
    Canonical event container used by every subsystem.

    All fields except `payload` are indexable by log aggregators.
    `payload` holds domain-specific data and evolves per `version`.
    """
    id:             str             # Globally-unique event ID (UUIDv4)
    type:           EventType       # DOMAIN.VERB catalog string
    aggregate:      str             # Root entity type: "deal" | "listing" | "user" ...
    aggregate_id:   str             # UUID of the aggregate root
    actor:          str             # User ID who triggered event, or "system"
    payload:        Dict[str, Any]  # Domain-specific fields (schema versioned)
    timestamp:      datetime        = field(default_factory=lambda: datetime.now(timezone.utc))
    version:        int             = 1    # Payload schema version
    correlation_id: Optional[str]   = None  # Trace ID — propagated across services
    causation_id:   Optional[str]   = None  # ID of the event that caused this one

    def to_dict(self) -> dict:
        d = asdict(self)
        d["type"]      = self.type.value
        d["timestamp"] = self.timestamp.isoformat()
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "EventEnvelope":
        d = dict(d)
        d["type"] = EventType(d["type"])
        if isinstance(d.get("timestamp"), str):
            d["timestamp"] = datetime.fromisoformat(d["timestamp"])
        return cls(**d)


# ══════════════════════════════════════════════════════════════════════════════
# Subscription Registry
# ══════════════════════════════════════════════════════════════════════════════

_catalog_handlers: Dict[EventType, List[Handler]] = {}


def subscribe_to(event_type: EventType) -> Callable[[Handler], Handler]:
    """
    Decorator: register a catalog-level async event handler.

    @subscribe_to(EventType.PAYMENT_ESCROW_LOCKED)
    async def on_escrow_locked(envelope: EventEnvelope) -> None:
        ...
    """
    def decorator(fn: Handler) -> Handler:
        _catalog_handlers.setdefault(event_type, []).append(fn)
        return fn
    return decorator


def handler_count() -> Dict[str, int]:
    """Return subscriber counts per event type (for /ready or admin endpoints)."""
    return {et.value: len(hs) for et, hs in _catalog_handlers.items()}


# ══════════════════════════════════════════════════════════════════════════════
# emit() — the public API for publishing events
# ══════════════════════════════════════════════════════════════════════════════

async def emit(
    event_type:     EventType,
    aggregate:      str,
    aggregate_id:   str,
    actor:          str                    = "system",
    payload:        Optional[Dict[str, Any]] = None,
    version:        int                    = 1,
    correlation_id: Optional[str]          = None,
    causation_id:   Optional[str]          = None,
) -> EventEnvelope:
    """
    Create and publish a standard event envelope.

    Steps:
      1. Build the envelope with a fresh UUID.
      2. Dispatch to all registered in-process handlers.
      3. Write to Redis Streams (durable delivery for worker processes).
      4. Increment Prometheus / in-memory event counter.
      5. Create an OTel span for traceability.
      6. Return the envelope so callers can chain causation IDs.
    """
    envelope = EventEnvelope(
        id=str(uuid.uuid4()),
        type=event_type,
        aggregate=aggregate,
        aggregate_id=aggregate_id,
        actor=actor,
        payload=payload or {},
        version=version,
        correlation_id=correlation_id,
        causation_id=causation_id,
    )

    with _trace_emit(envelope):
        # 1 — In-process handlers
        handlers = _catalog_handlers.get(event_type, [])
        for h in handlers:
            try:
                await h(envelope)
            except Exception as exc:
                logger.error(
                    "[event_catalog] handler %s raised for %s: %s",
                    h.__name__, event_type.value, exc,
                )

        # 2 — Redis Streams (durable; consumed by workers in separate processes)
        await _publish_to_stream(envelope)

        # 3 — Metrics
        _record_metric(event_type)

    logger.debug(
        "[event_catalog] emitted type=%s aggregate=%s/%s actor=%s id=%s",
        event_type.value, aggregate, aggregate_id, actor, envelope.id,
    )
    return envelope


# ══════════════════════════════════════════════════════════════════════════════
# Internal helpers
# ══════════════════════════════════════════════════════════════════════════════

async def _publish_to_stream(envelope: EventEnvelope) -> None:
    """Persist envelope to a per-domain Redis Stream for worker consumption."""
    try:
        from api.core.config import settings
        if not settings.redis_enabled:
            return
        import redis.asyncio as aioredis
        client = aioredis.from_url(
            settings.redis_url, encoding="utf-8",
            decode_responses=True, socket_connect_timeout=2,
        )
        domain     = envelope.type.value.split(".")[0].lower()
        stream_key = f"broka:catalog:{domain}"
        # Redis requires all values to be strings
        flat = {k: str(v) for k, v in envelope.to_dict().items()
                if v is not None}
        await client.xadd(stream_key, flat, maxlen=100_000, approximate=True)
        await client.aclose()
    except Exception as exc:
        logger.debug("[event_catalog] stream publish failed (non-fatal): %s", exc)


def _record_metric(event_type: EventType) -> None:
    """Increment the event counter if observability stack is initialised."""
    try:
        from api.core.observability import record_event_metric
        record_event_metric(event_type.value)
    except Exception:
        pass  # Metrics are best-effort; never break the caller


def _trace_emit(envelope: EventEnvelope):
    """Open an OTel span for the emit() call (no-op if tracing not installed)."""
    try:
        from api.core.tracing import trace_span, add_event_span_attributes
        ctx = trace_span(
            f"event.emit.{envelope.type.value}",
            {"event.type": envelope.type.value, "event.aggregate_id": envelope.aggregate_id},
        )
        # We can't easily add the span attrs inside a contextmanager
        # without entering, so we just return the manager directly.
        return ctx
    except Exception:
        return _NullContext()


class _NullContext:
    def __enter__(self):  return self
    def __exit__(self, *_): pass


# ══════════════════════════════════════════════════════════════════════════════
# Backward-compatibility bridge
# Maps legacy BrokaEvent class names → catalog EventType so code that still
# calls the old publish(EscrowFunded(...)) also emits a catalog envelope.
# ══════════════════════════════════════════════════════════════════════════════

LEGACY_EVENT_MAP: Dict[str, EventType] = {
    "UserRegistered":        EventType.AUTH_USER_REGISTERED,
    "UserLoggedIn":          EventType.AUTH_LOGIN,
    "UserVerified":          EventType.AUTH_USER_VERIFIED,
    "ListingCreated":        EventType.LISTING_CREATED,
    "InterestExpressed":     EventType.LISTING_INTEREST,
    "DealFinalized":         EventType.ORDER_AGREED,
    "EscrowFunded":          EventType.PAYMENT_ESCROW_LOCKED,
    "EscrowReleased":        EventType.PAYMENT_RELEASED,
    "EscrowRefunded":        EventType.PAYMENT_REFUNDED,
    "DisputeOpened":         EventType.DISPUTE_OPENED,
    "DisputeResolved":       EventType.DISPUTE_RESOLVED,
    "ReviewSubmitted":       EventType.RATING_SUBMITTED,
    "BidPlaced":             EventType.ORDER_BID_PLACED,
    "FraudFlagged":          EventType.FRAUD_FLAGGED,
    "MpesaCallbackReceived": EventType.PAYMENT_MPESA_CALLBACK,
}
