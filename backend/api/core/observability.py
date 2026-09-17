"""
BROKA v3.0 - Observability Scaffold (issue #13 / #14)
───────────────────────────────────────────────────────
Initialises:
  • Sentry — error tracking and performance tracing (set SENTRY_DSN env var)
  • Structured JSON logging — machine-readable for Datadog / Loki / CloudWatch
  • Request ID middleware — traces a single request through all log lines
  • Prometheus metrics endpoint — /metrics (optional, via prometheus-fastapi-instrumentator)

Activation in main.py lifespan:
    from api.core.observability import init_observability
    init_observability(app)
"""
from __future__ import annotations

import logging
import os
import time
import uuid
from contextvars import ContextVar
from typing import Callable

from fastapi import FastAPI, Request, Response
from fastapi.routing import APIRoute

logger = logging.getLogger(__name__)

# Per-request ID available anywhere via request_id_var.get()
request_id_var: ContextVar[str] = ContextVar("request_id", default="-")


# ── Structured JSON logging ───────────────────────────────────────────────────

class _JsonFormatter(logging.Formatter):
    """Emits one JSON object per log record for log aggregation pipelines."""

    def format(self, record: logging.LogRecord) -> str:
        import json
        data = {
            "ts":      self.formatTime(record, "%Y-%m-%dT%H:%M:%S"),
            "level":   record.levelname,
            "logger":  record.name,
            "msg":     record.getMessage(),
            "rid":     request_id_var.get("-"),
        }
        if record.exc_info:
            data["exc"] = self.formatException(record.exc_info)
        return json.dumps(data)


def configure_logging(json_logs: bool = False) -> None:
    """
    Configure root logger.
    Set json_logs=True in production (or JSON_LOGS=true env var).
    """
    use_json = json_logs or os.getenv("JSON_LOGS", "false").lower() == "true"
    handler  = logging.StreamHandler()
    handler.setFormatter(_JsonFormatter() if use_json else logging.Formatter(
        "%(asctime)s %(levelname)-8s %(name)s  %(message)s",
    ))
    logging.basicConfig(level=logging.INFO, handlers=[handler], force=True)
    # Quiet noisy third-party loggers
    for noisy in ("httpx", "sqlalchemy.engine", "uvicorn.access"):
        logging.getLogger(noisy).setLevel(logging.WARNING)


# ── Request ID middleware ─────────────────────────────────────────────────────

class RequestIdMiddleware:
    """Injects X-Request-ID header and sets the ContextVar for all log lines."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            headers = dict(scope.get("headers", []))
            rid = headers.get(b"x-request-id", b"").decode() or str(uuid.uuid4())[:8]
            token = request_id_var.set(rid)

            async def send_with_header(message):
                if message["type"] == "http.response.start":
                    headers = list(message.get("headers", []))
                    headers.append((b"x-request-id", rid.encode()))
                    message = {**message, "headers": headers}
                await send(message)

            try:
                await self.app(scope, receive, send_with_header)
            finally:
                request_id_var.reset(token)
        else:
            await self.app(scope, receive, send)


# ── Latency logging middleware ────────────────────────────────────────────────

class LatencyLogMiddleware:
    """Logs method, path, status, and duration for every request."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start    = time.perf_counter()
        status   = [200]

        async def capture_status(message):
            if message["type"] == "http.response.start":
                status[0] = message.get("status", 200)
            await send(message)

        await self.app(scope, receive, capture_status)
        elapsed_ms = (time.perf_counter() - start) * 1000

        method = scope.get("method", "?")
        path   = scope.get("path", "/")
        logger.info(
            "[http] %s %s %d %.1fms rid=%s",
            method, path, status[0], elapsed_ms, request_id_var.get("-"),
        )


# ── Sentry ────────────────────────────────────────────────────────────────────

def _init_sentry(dsn: str, env: str) -> None:
    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.sqlalchemy import SqlalchemyIntegration

        sentry_sdk.init(
            dsn=dsn,
            environment=env,
            traces_sample_rate=0.1,    # 10% of requests traced
            profiles_sample_rate=0.05,
            integrations=[
                FastApiIntegration(transaction_style="endpoint"),
                SqlalchemyIntegration(),
            ],
            send_default_pii=False,    # GDPR: no PII in Sentry
        )
        logger.info("[observability] Sentry initialised  env=%s", env)
    except ImportError:
        logger.info("[observability] sentry-sdk not installed — skipping Sentry init. "
                    "Install with: pip install sentry-sdk[fastapi]")


# ── Prometheus metrics ────────────────────────────────────────────────────────

def _init_prometheus(app: FastAPI) -> None:
    # TEMPORARILY DISABLED (2026-06-21): prometheus-fastapi-instrumentator 7.0.2's
    # request-routing middleware crashes on every request with current
    # FastAPI/Starlette ('_IncludedRouter' object has no attribute 'path').
    # Re-enable once upstream publishes a compatible release.
    logger.info("[observability] Prometheus metrics temporarily disabled "
                "(pending upstream fix for Starlette compatibility)")
    return
    try:
        from prometheus_fastapi_instrumentator import Instrumentator
        Instrumentator().instrument(app).expose(app, endpoint="/metrics", include_in_schema=False)
        logger.info("[observability] Prometheus metrics exposed at /metrics")
    except ImportError:
        logger.info("[observability] prometheus-fastapi-instrumentator not installed — "
                    "metrics endpoint disabled. Install with: pip install prometheus-fastapi-instrumentator")


# ── Public initialiser ────────────────────────────────────────────────────────

def init_observability(app: FastAPI) -> None:
    """
    Call once from main.py before adding routes.
    Wires all observability middleware and optional integrations.
    """
    from api.core.config import settings

    # Structured logging
    configure_logging(json_logs=settings.is_production)

    # Request tracing middleware (LIFO — outermost first)
    app.add_middleware(LatencyLogMiddleware)
    app.add_middleware(RequestIdMiddleware)

    # Sentry
    if settings.sentry_dsn:
        _init_sentry(settings.sentry_dsn, settings.env)
    else:
        logger.info("[observability] SENTRY_DSN not set — Sentry disabled")

    # Prometheus
    _init_prometheus(app)

    logger.info("[observability] ✓ Observability stack initialised")


# ── Event Metrics ─────────────────────────────────────────────────────────────
# In-memory counter used when Prometheus isn't available.
# Cleared on restart — use Redis / Prometheus for persistence in production.

import threading as _threading
_event_counts: dict = {}
_event_counts_lock = _threading.Lock()

_prom_event_counter = None


def _init_event_counter() -> None:
    """Try to create a Prometheus counter for event types."""
    global _prom_event_counter
    try:
        from prometheus_client import Counter
        _prom_event_counter = Counter(
            "broka_events_total",
            "Total platform events emitted, by type",
            ["event_type"],
        )
        logger.info("[observability] Prometheus event counter initialised")
    except Exception:
        pass  # Prometheus not installed — fall back to in-memory dict


def record_event_metric(event_type_value: str) -> None:
    """
    Increment the event counter for event_type_value (e.g. "PAYMENT.ESCROW_LOCKED").
    Called by event_catalog.emit() automatically — no need to call manually.
    """
    # In-memory fallback (always runs)
    with _event_counts_lock:
        _event_counts[event_type_value] = _event_counts.get(event_type_value, 0) + 1

    # Prometheus (if available)
    if _prom_event_counter:
        try:
            _prom_event_counter.labels(event_type=event_type_value).inc()
        except Exception:
            pass


def get_event_metrics() -> dict:
    """
    Return in-memory event counts.
    Exposed by GET /admin/event-metrics or /metrics (Prometheus).
    """
    with _event_counts_lock:
        return dict(sorted(_event_counts.items()))
