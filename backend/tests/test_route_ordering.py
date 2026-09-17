"""POST /negotiate/chat must be served by the legacy negotiate.free_chat.

Both api.routers.negotiate and api.domains.ai_broker.router define POST
/chat and both mount at /negotiate, so which one serves the endpoint is
decided purely by include_router order in main.py. Only the legacy one
accepts image_base64 (Zeno's photo analysis) and the "zeno" /
"zeno_seller_coach" personas, so if the other wins, Flutter silently loses
image upload and every Zeno surface falls back to the generic broker
persona - with no error anywhere.

WHY THESE TESTS ISSUE REAL REQUESTS
-----------------------------------
Two earlier attempts to assert this by inspecting route objects both
concluded the endpoint was missing, and both were checked into main.py as
an import-time `raise`. Each took out every test module that does
`from main import app` before a single test ran:

    scan app.routes by .path/.methods   -> 13 modules errored, 0/325 tests ran
    Starlette route.matches(scope)      -> 14 modules errored, 0/325 tests ran

The second one resolved FastAPI's own /openapi.json perfectly well and
still found nothing at /negotiate/chat, so the disagreement is specific to
how this FastAPI version exposes router-included routes - not something
worth a third guess.

These tests therefore ask the only question with an unambiguous answer:
send the request and see what comes back. No route objects, no internals,
nothing that a framework upgrade can quietly redefine.

The discriminator between the two handlers is authentication, and it needs
no network, no database and no AI call:

    negotiate.free_chat(data: ChatIn)            - no auth dependency
    ai_broker.broker_chat(body, Depends(get_current_user)) - requires auth

An unauthenticated POST with an empty body therefore returns 422 (body
validation) from the legacy handler and 401/403 from the broker one, and
404 from neither. The empty body matters: it fails validation before any
handler body executes, so nothing reaches an AI provider.
"""
import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

from main import app


CHAT_URL = "/negotiate/chat"


def _diagnostics() -> str:
    """Router inventory, attached to failures so one CI run explains itself."""
    try:
        from main import _router_inventory
        return "\n" + _router_inventory()
    except Exception as exc:                            # pragma: no cover
        return f"\n<inventory unavailable: {exc!r}>"


@pytest_asyncio.fixture(scope="module")
async def client():
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
    ) as ac:
        yield ac


async def test_chat_endpoint_is_registered(client):
    """The endpoint answers at all.

    This is the assertion the import-time guard kept getting wrong. A 404
    here means it was right and the route really is unmounted; anything
    else means the route is live and the introspection was at fault.
    """
    r = await client.post(CHAT_URL, json={})
    assert r.status_code != 404, (
        f"POST {CHAT_URL} returned 404 - negotiate.router is genuinely not "
        f"mounted, and Flutter's chat, image upload and Zeno persona are all "
        f"broken in production.{_diagnostics()}"
    )


async def test_chat_resolves_to_legacy_free_chat(client):
    """...and it is the legacy handler answering, not the broker one.

    422 == the no-auth legacy handler rejected an empty body.
    401/403 == the broker handler's auth dependency ran first, which means
    ai_broker_router won the collision.
    """
    r = await client.post(CHAT_URL, json={})
    assert r.status_code not in (401, 403), (
        f"POST {CHAT_URL} returned {r.status_code}, which only the "
        f"authenticated ai_broker handler produces. Mount negotiate.router "
        f"BEFORE ai_broker_router in main.py - only the legacy implementation "
        f"accepts image_base64 and the Zeno personas.{_diagnostics()}"
    )
    assert r.status_code == 422, (
        f"POST {CHAT_URL} with an empty body returned {r.status_code}, "
        f"expected 422 from ChatIn validation in negotiate.free_chat. "
        f"Body: {r.text[:300]}{_diagnostics()}"
    )


async def test_chat_schema_is_the_legacy_one(client):
    """Fingerprints the handler by its request model, without running it.

    `image_base64` exists on negotiate.ChatIn and not on ai_broker.ChatIn,
    and pydantic ignores unknown fields rather than rejecting them. So a
    wrong-typed image_base64 produces a validation error naming the field
    only if the legacy model is the one bound to this path.

    Deliberately invalid rather than a valid payload: validation fails
    before the handler body runs, so this never reaches Gemini/DeepSeek/
    OpenRouter. A test that calls a live AI provider is a test that fails
    on someone else's outage.
    """
    r = await client.post(CHAT_URL, json={"image_base64": 123})
    assert r.status_code == 422, (
        f"expected 422 from request-model validation, got {r.status_code}: "
        f"{r.text[:300]}{_diagnostics()}"
    )
    assert "image_base64" in r.text, (
        f"POST {CHAT_URL} validated an empty-content body without ever "
        f"mentioning image_base64, so the bound request model does not have "
        f"that field - this is ai_broker.ChatIn, not negotiate.ChatIn. Zeno "
        f"photo analysis would be silently dropped. Body: "
        f"{r.text[:300]}{_diagnostics()}"
    )


async def test_ai_broker_own_routes_still_reachable(client):
    """Registering negotiate.router first shadows /chat and nothing else.

    /scam-check exists only on ai_broker. It requires auth, so an
    unauthenticated call should be rejected - but not with a 404.
    """
    r = await client.post("/negotiate/scam-check", json={})
    assert r.status_code != 404, (
        f"POST /negotiate/scam-check returned 404 - ai_broker_router is not "
        f"mounted.{_diagnostics()}"
    )


def test_collision_still_exists():
    """Documents why any of this is needed.

    If ai_broker stops defining /chat, the collision is gone and the guard
    in main.py can be deleted rather than maintained.
    """
    from api.domains.ai_broker import router as ai_broker_mod

    paths = {getattr(r, "path", None) for r in ai_broker_mod.router.routes}
    assert "/chat" in paths, (
        "ai_broker router no longer defines /chat - the /negotiate/chat "
        "collision is gone and _check_route_ordering() in main.py can be "
        "removed along with this file"
    )
