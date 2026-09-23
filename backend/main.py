"""
BROKA - FastAPI Backend v6.0
Platform architecture: Event Catalog + Workflow Versioning + Distributed Tracing + Zeno Events.
Domain-module architecture + event bus + fraud engine + background workers.
Backward-compatible: legacy routers kept alongside new domain routers.
"""

import inspect
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from api.database import init_db
from api.core.config import settings, validate_startup
from api.core.workers import worker
from api.security import validate_secret_key
from api.core.observability import init_observability, _init_event_counter

# ── Distributed Tracing (init before routes so auto-instrumentation applies) ──
from api.core.tracing import init_tracing
init_tracing(service_name="broka-backend")

# ── Legacy routers (kept for backward compatibility) ─────────────────────────
from api.routers import (
    negotiate, auction, deal, mpesa,
    verify, featured, media, sms,
)
# Optional routers (may not exist in all deployments)
try:
    from api.routers import tts
    _has_tts = True
except ImportError:
    _has_tts = False

try:
    from api.routers import stt
    _has_stt = True
except ImportError:
    _has_stt = False

try:
    from api.routers import calls
    _has_calls = True
except ImportError:
    _has_calls = False

try:
    from api.routers import escrow as legacy_escrow
    _has_legacy_escrow = True
except ImportError:
    _has_legacy_escrow = False

# ── New v3.0 domain routers ───────────────────────────────────────────────────
# CANONICAL IMPLEMENTATIONS (verified during the Store hardening pass,
# 2026-09, by checking what's actually imported/mounted, not assumed):
#   Store    -> api/domains/stores/  (router.py = JSON API, web.py = public
#               HTML page). This is the ONLY Store implementation - no
#               legacy version exists to confuse it with.
#   Listings -> api/domains/listings/. api/routers/listings.py also exists
#               in this codebase but is dead code, never imported anywhere
#               below - see that file's own header for detail.
# Several other files under api/routers/ (admin.py, auth.py, disputes.py,
# reviews.py) are similarly dead, superseded by their api/domains/
# equivalents imported below - each is marked at its own file header
# rather than repeated here. api/routers/escrow.py is DIFFERENT: it's
# still intentionally mounted (as "legacy_escrow" below, at /escrow) IN
# ADDITION to api/domains/escrow/router.py (at /deal) - two live routers
# at two different prefixes, not a conflict, already self-labeled
# "Escrow (legacy)" in its own tag.
from api.domains.auth.router       import router as auth_router
from api.domains.listings.router   import router as listings_router
from api.domains.stores.router import router as stores_router
from api.domains.stores.web    import router as stores_web_router
from api.domains.showcase.router   import router as showcase_router, preview_router as showcase_preview_router
from api.domains.categories.router import router as categories_router
from api.domains.trending.router   import router as trending_router
from api.domains.traders.router    import router as traders_router
from api.domains.auctions.router   import router as auctions_router
from api.domains.auction_ws.router import router as auction_ws_router
from api.domains.buy_agent.router  import router as buy_agent_router
from api.domains.escrow.router     import router as escrow_router
from api.domains.disputes.router   import router as disputes_router
# v5.0 dispute engine — same router file, /disputes/v2/* endpoints auto-registered
from api.domains.reviews.router    import router as reviews_router
from api.domains.ai_broker.router  import router as ai_broker_router
from api.domains.admin.router      import router as admin_router
from api.domains.deal_ws.router    import router as deal_ws_router
from api.domains.auth.refresh_router import router as refresh_router
from api.domains.media.router      import router as media_assets_router

# ── Wire Event Catalog subscribers (must import after router imports) ─────────
# All six of these register on api.core.event_catalog's @subscribe_to, not the
# legacy api.core.events @subscribe bus - the legacy bus only invokes
# in-process handlers when REDIS_URL is unset, so anything still registered
# there would silently stop firing under Redis (the recommended production
# config). See each file's own header comment for the full explanation
# (redesign-guide audit, 2026-08-11 - deal_hub/auction_hub/push/
# trader_specialization/buy_agent were all found still on the legacy bus and
# migrated this pass; zeno_subscribers was already correct).
import api.core.deal_hub_subscribers  # noqa: F401  registers deal WS broadcasts
import api.core.auction_hub_subscribers  # noqa: F401  registers auction WS broadcasts
import api.core.push_subscribers      # noqa: F401  registers FCM push notifications
import api.core.zeno_subscribers                    # noqa: F401  Zeno reacts to platform events
import api.core.trader_specialization_subscribers   # noqa: F401  derives seller specializations from listings
import api.core.buy_agent_subscribers               # noqa: F401  matches new listings against standing buy requests


# ── Lifespan ──────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    # ── Startup validation ────────────────────────────────────────────────────
    validate_secret_key()   # fail fast if SECRET_KEY == default in production
    validate_startup()      # SQLite-in-prod guard + warn about missing Redis/Sentry
    await init_db()
    await worker.start()
    _init_event_counter()   # Prometheus event counter (no-op if prom not installed)
    from api.core.workers import start_periodic_sweep, stop_periodic_sweep
    await start_periodic_sweep()  # enforces AI-announced deal auto-resolution timers

    # Log registered workflow versions and event subscribers
    from api.core.workflow import all_versions, CURRENT_VERSION
    from api.core.event_catalog import handler_count
    logging.getLogger(__name__).info(
        "🚀 BROKA v6.0 started  workflow_versions=%s current=%s event_handlers=%s",
        all_versions(), CURRENT_VERSION, len(handler_count()),
    )
    yield
    # ── Shutdown ──────────────────────────────────────────────────────────────
    await stop_periodic_sweep()
    await worker.stop()
    logging.getLogger(__name__).info("🛑 BROKA v6.0 stopped")


# ── App ───────────────────────────────────────────────────────────────────────

app = FastAPI(
    title="BROKA - AI Marketplace API",
    description="AI-powered peer-to-peer marketplace for East Africa.",
    version="6.0.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

# ── Observability (Sentry + request IDs + latency logging + Prometheus) ───────
init_observability(app)


# ── CORS ──────────────────────────────────────────────────────────────────────

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_credentials=settings.allow_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Global exception handler ──────────────────────────────────────────────────

@app.exception_handler(Exception)
async def generic_exception_handler(request: Request, exc: Exception):
    logging.getLogger(__name__).error("Unhandled exception: %s", exc, exc_info=True)
    return JSONResponse(
        status_code=500,
        content={"detail": "Internal server error. Our team has been notified."},
    )


# ── New v3.0 Domain Routers ───────────────────────────────────────────────────
app.include_router(auth_router,       prefix="/auth",       tags=["Auth v3"])
app.include_router(listings_router,   prefix="/listings",   tags=["Listings v3"])
app.include_router(stores_router,     prefix="/stores",     tags=["Stores"])
app.include_router(stores_web_router, prefix="/store",      tags=["Store Public Page"])
app.include_router(showcase_router,   prefix="/listings",   tags=["AI Showcase"])
app.include_router(showcase_preview_router, prefix="/showcase", tags=["AI Showcase"])
app.include_router(categories_router, prefix="/categories", tags=["Categories"])
app.include_router(trending_router,   prefix="/trending",   tags=["Trending"])
app.include_router(traders_router,    prefix="/traders",    tags=["Traders"])
app.include_router(auctions_router,   prefix="/auctions",   tags=["Auctions"])
app.include_router(auction_ws_router, prefix="/auction-ws", tags=["Auction WS"])
app.include_router(buy_agent_router,  prefix="/buy-agent-requests", tags=["Buy-Agent"])
app.include_router(escrow_router,     prefix="/deal",       tags=["Escrow/Deal v3"])
app.include_router(disputes_router,   prefix="/disputes",   tags=["Disputes v5"])
app.include_router(reviews_router,    prefix="/reviews",    tags=["Reviews v3"])
# NOTE: legacy negotiate.router is registered BEFORE ai_broker_router (both
# mount at /negotiate). FastAPI resolves path collisions by registration
# order, and both define POST /chat. The legacy free_chat() is the one
# Flutter actually needs - it supports image_base64 (Zeno's photo-analysis
# feature on product_screen.dart), per-surface system prompts (system_override
# "zeno" vs the default broker persona), and language - none of which the
# newer AIBrokerService.broker_chat() implements. With the domain router
# first (the previous order), every /negotiate/chat call silently got the
# generic broker persona with images dropped on the floor, even from
# zeno_screen.dart and seller_dashboard_screen.dart which explicitly ask for
# the Zeno persona. ai_broker_router's OTHER routes (/scam-check,
# /price-recommend, /dispute-analysis) don't collide with anything in
# negotiate.router, so they're unaffected by this ordering either way.
app.include_router(negotiate.router,  prefix="/negotiate",  tags=["Negotiate (legacy)"])
app.include_router(ai_broker_router,  prefix="/negotiate",  tags=["AI Broker v3"])
app.include_router(admin_router,      prefix="/admin",      tags=["Admin v3"])
app.include_router(deal_ws_router,    prefix="/deal-ws",    tags=["Deal WebSocket"])
app.include_router(refresh_router,    prefix="/auth",       tags=["Auth — Token Refresh"])


# ── Route-ordering guard (implementation audit, spec §22) ─────────────────────
def _resolve_route_endpoint(method: str, path: str):
    """Return the endpoint callable that would serve `method path`, or None.

    Asks the router the same question a real request asks it, via Starlette's
    own `route.matches(scope)` primitive, and descends into any mounted
    sub-router the match lands on.

    This deliberately does NOT compare `route.path` and `route.methods` by
    hand. The version of this guard shipped on 2026-09-14 did exactly that -
    it scanned `app.routes` for `path == "/negotiate/chat" and "POST" in
    route.methods` - and on the FastAPI/Starlette that CI actually resolves
    from the unpinned `fastapi>=0.115.0` in requirements.txt (0.141.1 /
    0.52.1) that scan matched nothing. The route was mounted and working the
    whole time; only the detection was wrong. Result: a RuntimeError at
    import of this module, which took out all 13 test files that do
    `from main import app` before a single test ran, and would have taken
    out production boot the same way.

    Route matching is the framework's job. Re-implementing it against
    attribute names the framework is free to rename is how a guard against a
    silent bug becomes a loud outage of its own.
    """
    from starlette.routing import Match

    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "root_path": "",
        "headers": [],
        "query_string": b"",
    }

    def _walk(routes, scope, depth=0):
        if depth > 6:                      # cycle/pathological-nesting guard
            return None
        for route in routes:
            try:
                matched, child_scope = route.matches(scope)
            except Exception:              # not a matchable route object
                continue
            if matched != Match.FULL:      # PARTIAL == path hit, method miss
                continue
            endpoint = getattr(route, "endpoint", None)
            if endpoint is not None:
                return endpoint
            # A Mount / sub-application: descend using the child scope
            # Starlette produced, which carries the remaining path.
            inner = getattr(route, "app", None)
            sub = getattr(route, "routes", None) or getattr(inner, "routes", None)
            if sub:
                found = _walk(sub, {**scope, **(child_scope or {})}, depth + 1)
                if found is not None:
                    return found
        return None

    return _walk(app.router.routes, scope)


def _iter_mounted_routes(routes=None, prefix: str = "", depth: int = 0):
    """Yield (full_path, route) for every endpoint-bearing route, flattened.

    Accumulates the prefix while descending so a route nested under a Mount
    reports the path a client would call, not its path relative to the mount.
    """
    if routes is None:
        routes = app.router.routes
    if depth > 6:
        return
    for route in routes:
        path = prefix + (getattr(route, "path", "") or "")
        if getattr(route, "endpoint", None) is not None:
            yield path, route
        inner = getattr(route, "app", None)
        sub = getattr(route, "routes", None) or getattr(inner, "routes", None)
        if sub:
            yield from _iter_mounted_routes(sub, path, depth + 1)


def _router_inventory() -> str:
    """Human-readable dump of what the app reports it has mounted.

    Exists because two successive versions of the route guard disagreed with
    reality and neither failure message said what the router actually
    contained. Any future disagreement should print its own evidence rather
    than cost a CI round-trip to diagnose.
    """
    try:
        rows = list(_iter_mounted_routes())
    except Exception as exc:                            # pragma: no cover
        return f"<inventory unavailable: {exc!r}>"

    classes = sorted({type(r).__name__ for _, r in rows})
    top = getattr(getattr(app, "router", None), "routes", [])
    negotiate_paths = sorted(
        f"{sorted(str(getattr(m, 'value', m)).upper() for m in (getattr(r, 'methods', None) or ()))} "
        f"{p} -> {getattr(getattr(r, 'endpoint', None), '__module__', '?')}"
        f".{getattr(getattr(r, 'endpoint', None), '__qualname__', '?')}"
        for p, r in rows if p.startswith("/negotiate")
    )
    return (
        f"discoverable endpoints={len(rows)} "
        f"top-level app.router.routes={len(top)} "
        f"route classes={classes}\n  /negotiate/*:\n    "
        + ("\n    ".join(negotiate_paths) if negotiate_paths else "(none discoverable)")
    )


def _check_route_ordering() -> None:
    """Report, at import, whether POST /negotiate/chat resolves as intended.

    POST /negotiate/chat is defined by BOTH negotiate.router (legacy) and
    ai_broker_router. Starlette resolves a duplicate path by first match, so
    which implementation serves it is decided purely by the order of the two
    include_router calls above - and only the legacy one supports image
    attachments (Zeno's photo analysis) and the "zeno" personas. If the other
    one wins, Flutter silently loses both, with no error anywhere.

    LOGS ONLY. It does not raise, and it must never be changed back into
    something that does.

    It used to raise, on the reasoning that a misrouted endpoint should stop
    the process before serving a request. That reasoning was wrong about the
    balance of risk, and the cost was paid twice:

      2026-09-15 06:44  hand-rolled scan of app.routes by `path`/`methods`
                        matched nothing -> RuntimeError at import -> all 13
                        test modules that do `from main import app` errored
                        during collection, 0 of 325 tests ran.
      2026-09-15 07:01  replacement using Starlette's own route.matches()
                        ALSO resolved nothing for this path (while resolving
                        FastAPI's own /openapi.json fine) -> same outcome,
                        14 modules.

    Two outages, no true positives, and a test suite that has still never
    executed. Whatever the introspection disagreement turns out to be, an
    import-time raise makes every unrelated failure invisible behind it and
    would do the same to a production deploy. The property is worth
    asserting; it is not worth asserting *here*.

    `tests/test_route_ordering.py` now asserts it against ground truth - an
    actual request through the ASGI app - where a failure is one red test
    instead of a dead process.
    """
    log = logging.getLogger(__name__)

    try:
        from api.routers.negotiate import free_chat as _expected
        winner = _resolve_route_endpoint("POST", "/negotiate/chat")
    except Exception as exc:
        log.warning("[route-guard] check skipped (%s)", exc)
        return

    if winner is None:
        log.warning(
            "[route-guard] POST /negotiate/chat did not resolve by "
            "introspection. This does NOT mean the endpoint is down - the "
            "same check has twice been wrong about a route that was serving "
            "traffic. tests/test_route_ordering.py settles it by issuing a "
            "real request. Inventory:\n%s",
            _router_inventory(),
        )
        return

    if inspect.unwrap(winner) is not inspect.unwrap(_expected):
        log.error(
            "[route-guard] POST /negotiate/chat resolves to %s.%s, expected "
            "api.routers.negotiate.free_chat. Mount negotiate.router BEFORE "
            "ai_broker_router - only the legacy implementation supports image "
            "attachments and the Zeno persona.",
            getattr(winner, "__module__", "?"),
            getattr(winner, "__qualname__", winner),
        )
        return

    log.info("[route-guard] POST /negotiate/chat -> api.routers.negotiate.free_chat ✓")


_check_route_ordering()

# ── Legacy Routers (preserved for Flutter compatibility) ──────────────────────
# negotiate.router is registered above (see note near ai_broker_router) so its
# /chat implementation wins the path collision instead of being shadowed.
app.include_router(auction.router,    prefix="/auction",    tags=["Auction"])
app.include_router(mpesa.router,      prefix="/mpesa",      tags=["M-Pesa"])
app.include_router(verify.router,     prefix="/verify",     tags=["Verification"])
app.include_router(featured.router,   prefix="/featured",   tags=["Featured"])
app.include_router(sms.router,        prefix="/sms",        tags=["SMS"])
app.include_router(media.router,      prefix="/media",      tags=["Media/WebSocket"])
app.include_router(media_assets_router, prefix="/media",    tags=["Images"])

if _has_tts:
    app.include_router(tts.router,    prefix="/tts",        tags=["TTS"])
if _has_stt:
    app.include_router(stt.router,    prefix="/stt",        tags=["STT"])
if _has_calls:
    app.include_router(calls.router,  prefix="/calls",      tags=["Calls"])
if _has_legacy_escrow:
    app.include_router(legacy_escrow.router, prefix="/escrow", tags=["Escrow (legacy)"])


# ── Health ────────────────────────────────────────────────────────────────────

@app.get("/", tags=["Health"])
async def root():
    return {
        "status":  "online",
        "service": "BROKA API",
        "version": "6.0.0",
        "features": [
            "domain_modules",
            "event_catalog",        # NEW v6: DOMAIN.EVENT_NAME catalog
            "workflow_versioning",  # NEW v6: rules locked at deal creation
            "distributed_tracing",  # NEW v6: OpenTelemetry spans
            "zeno_event_reactions", # NEW v6: Zeno subscribes to events
            "event_bus",
            "fraud_engine",
            "trust_scores",
            "audit_logs",
            "rate_limiting",
            "background_workers",
            "ai_broker_v3",
            "scam_detection",
            "price_recommendations",
            "deal_status_websocket",
            "dispute_engine_v5",
            "store_layer_v1",       # NEW v6.1: business/store identity above Listing
        ],
    }


@app.get("/health", tags=["Health"])
async def health():
    """Basic liveness probe — returns 200 if the process is alive."""
    return {"status": "healthy", "version": "6.0.0"}


@app.get("/ready", tags=["Health"])
async def ready():
    """
    Readiness probe — checks DB connectivity.
    Returns 200 when ready to serve traffic, 503 if not.
    Used by load balancers (Render, Kubernetes) to gate traffic.
    """
    from fastapi.responses import JSONResponse
    from sqlalchemy import text
    try:
        async with __import__("api.database", fromlist=["AsyncSessionLocal"]).AsyncSessionLocal() as db:
            await db.execute(text("SELECT 1"))
        db_ok = True
    except Exception as e:
        logging.getLogger(__name__).error("[ready] DB check failed: %s", e)
        db_ok = False

    redis_ok = True
    if settings.redis_enabled:
        try:
            import redis.asyncio as aioredis
            r = aioredis.from_url(settings.redis_url, socket_connect_timeout=2)
            await r.ping()
            await r.aclose()
        except Exception as e:
            logging.getLogger(__name__).warning("[ready] Redis check failed: %s", e)
            redis_ok = False

    from api.core.workflow import CURRENT_VERSION, all_versions
    from api.core.event_catalog import handler_count

    status_code = 200 if db_ok else 503
    return JSONResponse(
        status_code=status_code,
        content={
            "status":           "ready" if db_ok else "not_ready",
            "db":               "ok" if db_ok else "error",
            "redis":            "ok" if redis_ok else "error" if settings.redis_enabled else "not_configured",
            "version":          "6.0.0",
            "workflow_current": CURRENT_VERSION,
            "workflow_all":     all_versions(),
            "event_handlers":   handler_count(),
        },
    )


@app.get("/live", tags=["Health"])
async def live():
    """Kubernetes liveness probe — always returns 200 if the process is running."""
    return {"alive": True}
