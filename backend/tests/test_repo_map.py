"""scripts/graphify.py - the repository map CI keeps up to date (graphify.md).

It is read by people and by coding agents, so it has to be right and it has
to be stable: the same source must give the same map byte for byte, or CI
would commit a new one on every push.
"""
import importlib.util
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "graphify.py"


@pytest.fixture(scope="module")
def graphify():
    spec = importlib.util.spec_from_file_location("graphify", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    # Registered first: its dataclasses look their module up by name.
    sys.modules["graphify"] = module
    spec.loader.exec_module(module)
    yield module
    sys.modules.pop("graphify", None)


@pytest.fixture(scope="module")
def endpoints(graphify):
    return {(e.method, e.path): e for e in graphify.backend_endpoints() if not e.shadowed}


def test_the_map_is_deterministic(graphify):
    assert graphify.render() == graphify.render()


def test_endpoints_come_from_what_main_py_mounts(endpoints):
    assert endpoints[("POST", "/auth/login")].auth == "public"
    assert endpoints[("POST", "/deal/{deal_id}/fund")].auth == "user"
    assert endpoints[("GET", "/admin/diagnostics/client-ip")].auth == "admin"
    assert endpoints[("POST", "/stores/{store_id}/visit")].auth == "optional"
    assert endpoints[("WS", "/calls/ws/{room_id}")].auth == "token"
    # api/routers/listings.py exists but is never mounted: none of its
    # handlers may appear.
    assert not any(e.source.startswith("backend/api/routers/listings.py") for e in endpoints.values())


def test_a_route_registered_twice_is_marked_shadowed(graphify):
    chat = [e for e in graphify.backend_endpoints() if (e.method, e.path) == ("POST", "/negotiate/chat")]
    served = [e for e in chat if not e.shadowed]
    assert len(served) == 1 and served[0].handler == "free_chat"      # see test_route_ordering.py
    assert all(e.shadowed for e in chat if e.handler != "free_chat")


def test_the_other_sections_find_what_they_describe(graphify):
    tables = {table for table, _, _ in graphify.backend_models()}
    assert {"users", "listings", "deals", "stores", "media_assets", "audit_logs"} <= tables
    assert "STOREFRONT_API_KEY" in graphify.environment_variables()
    assert ("/auth", "AuthScreen") in graphify.app_routes()
    assert any(url == "/store/:name" for url, _, _ in graphify.web_routes())
    assert any(job == "backend-test" for _, job, _ in graphify.ci_jobs())
