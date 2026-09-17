"""
BROKA Platform - Distributed Tracing
════════════════════════════════════════════════════════════════════════════════
OpenTelemetry-based distributed tracing. Spans propagate from HTTP requests
through event handlers through database queries.

Degrades gracefully when opentelemetry packages are not installed —
all code continues to work, spans just become no-ops.

Exporters:
  OTLP (Jaeger / Grafana Tempo / Grafana Cloud)
    → set OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
  Console
    → set OTEL_CONSOLE_EXPORT=true   (dev / debugging)

Install:
    pip install opentelemetry-sdk \
                opentelemetry-instrumentation-fastapi \
                opentelemetry-instrumentation-sqlalchemy \
                opentelemetry-exporter-otlp-proto-grpc

Usage:
    from api.core.tracing import trace_span

    async def fund_escrow(deal_id: str, amount: float):
        with trace_span("escrow.fund", {"deal.id": deal_id, "amount": amount}) as span:
            result = await do_real_work()
            span.set_attribute("result.status", "ok")
            return result

Event spans:
    add_event_span_attributes(span, envelope)
    → attaches event.type, event.aggregate_id, event.correlation_id

Propagation across services:
    headers = extract_trace_headers()   # call on the sending side
    inject_trace_headers(headers)       # call on the receiving side
"""
from __future__ import annotations

import logging
import os
from contextlib import contextmanager
from typing import Any, Dict, Generator, Optional

logger = logging.getLogger(__name__)

# ── Module-level state ────────────────────────────────────────────────────────
_tracer       = None
_otel_enabled = False


# ══════════════════════════════════════════════════════════════════════════════
# Initialisation (called once from main.py)
# ══════════════════════════════════════════════════════════════════════════════

def init_tracing(service_name: str = "broka-backend") -> None:
    """
    Initialise OpenTelemetry tracing.

    Call once from main.py BEFORE lifespan starts and BEFORE adding routes
    so that framework instrumentation wrappers apply to all routes.
    """
    global _tracer, _otel_enabled

    try:
        from opentelemetry import trace
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
        from opentelemetry.sdk.resources import Resource, SERVICE_NAME

        resource = Resource.create({SERVICE_NAME: service_name})
        provider = TracerProvider(resource=resource)

        # ── Console exporter (dev) ─────────────────────────────────────────
        if os.getenv("OTEL_CONSOLE_EXPORT", "false").lower() == "true":
            provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
            logger.info("[tracing] Console span exporter enabled")

        # ── OTLP exporter (production → Jaeger / Tempo / Grafana Cloud) ───
        otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
        if otlp_endpoint:
            try:
                from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
                otlp = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
                provider.add_span_processor(BatchSpanProcessor(otlp))
                logger.info("[tracing] OTLP exporter → %s", otlp_endpoint)
            except ImportError:
                logger.warning(
                    "[tracing] opentelemetry-exporter-otlp-proto-grpc not installed — "
                    "OTLP export disabled. Install with: "
                    "pip install opentelemetry-exporter-otlp-proto-grpc"
                )

        trace.set_tracer_provider(provider)
        _tracer       = trace.get_tracer(service_name, schema_url="https://opentelemetry.io/schemas/1.11.0")
        _otel_enabled = True

        # ── FastAPI auto-instrumentation ───────────────────────────────────
        try:
            from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
            FastAPIInstrumentor().instrument()
            logger.info("[tracing] FastAPI auto-instrumented")
        except ImportError:
            logger.debug("[tracing] FastAPI instrumentor not installed — skipping")

        # ── SQLAlchemy auto-instrumentation ────────────────────────────────
        try:
            from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
            SQLAlchemyInstrumentor().instrument()
            logger.info("[tracing] SQLAlchemy auto-instrumented")
        except ImportError:
            logger.debug("[tracing] SQLAlchemy instrumentor not installed — skipping")

        logger.info("[tracing] ✓ Distributed tracing initialised  service=%s", service_name)

    except ImportError:
        logger.info(
            "[tracing] opentelemetry-sdk not installed — tracing disabled. "
            "Install with: pip install opentelemetry-sdk"
        )


# ══════════════════════════════════════════════════════════════════════════════
# Public tracer access
# ══════════════════════════════════════════════════════════════════════════════

def get_tracer():
    """Return the configured tracer, or a no-op tracer if OTel is unavailable."""
    if _otel_enabled and _tracer:
        return _tracer
    return _NoOpTracer()


@contextmanager
def trace_span(
    name:       str,
    attributes: Optional[Dict[str, Any]] = None,
) -> Generator:
    """
    Context manager that creates a named span.
    Falls back to a no-op if OTel is not installed.

    Usage:
        with trace_span("escrow.fund", {"deal.id": deal_id}) as span:
            result = await do_work()
            span.set_attribute("result.ok", True)
    """
    tracer = get_tracer()
    with tracer.start_as_current_span(name) as span:
        if attributes and _otel_enabled:
            for k, v in attributes.items():
                try:
                    span.set_attribute(str(k), str(v))
                except Exception:
                    pass
        yield span


def add_event_span_attributes(span, envelope) -> None:
    """
    Attach standard EventEnvelope fields to an active OTel span.
    Used by event_catalog.emit() so every event has consistent attributes.
    """
    if not _otel_enabled:
        return
    try:
        span.set_attribute("event.id",           envelope.id)
        span.set_attribute("event.type",          envelope.type.value)
        span.set_attribute("event.aggregate",     envelope.aggregate)
        span.set_attribute("event.aggregate_id",  envelope.aggregate_id)
        span.set_attribute("event.actor",         envelope.actor)
        span.set_attribute("event.version",       str(envelope.version))
        if envelope.correlation_id:
            span.set_attribute("event.correlation_id", envelope.correlation_id)
        if envelope.causation_id:
            span.set_attribute("event.causation_id",   envelope.causation_id)
    except Exception:
        pass


def extract_trace_headers() -> Dict[str, str]:
    """
    Extract W3C trace context headers from the current span context.
    Use on the outbound side when calling another service.
    Returns empty dict if tracing is unavailable.
    """
    if not _otel_enabled:
        return {}
    try:
        from opentelemetry import propagate
        headers: Dict[str, str] = {}
        propagate.inject(headers)
        return headers
    except Exception:
        return {}


def inject_trace_headers(headers: Dict[str, str]) -> None:
    """
    Inject W3C trace context from incoming headers into the current context.
    Call on the receiving side of a cross-service call.
    """
    if not _otel_enabled:
        return
    try:
        from opentelemetry import propagate
        propagate.extract(headers)
    except Exception:
        pass


# ══════════════════════════════════════════════════════════════════════════════
# No-op stubs (used when OTel packages are absent)
# ══════════════════════════════════════════════════════════════════════════════

class _NoOpSpan:
    def set_attribute(self, *a, **kw):  pass
    def add_event(self, *a, **kw):      pass
    def set_status(self, *a, **kw):     pass
    def record_exception(self, *a, **kw): pass
    def __enter__(self):                return self
    def __exit__(self, *a):             pass


class _NoOpTracer:
    @contextmanager
    def start_as_current_span(self, name: str, **kw) -> Generator:
        yield _NoOpSpan()
