"""Cross-replica signaling regression tests (Railway 2-replica fix).

Two hubs sharing one in-memory backend simulate two replicas sharing Redis.
"""
import time

import pytest

from api.core.call_signaling import CallSignalingHub, _MemoryBackend, PRESENCE_TTL_SECONDS
from api.core.call_state import CallState, create_session, update_state, mark_answered, get_session, end_session, is_valid_transition


def make_pair():
    backend = _MemoryBackend()
    a = CallSignalingHub(instance_id="replica-A", backend=backend)
    b = CallSignalingHub(instance_id="replica-B", backend=backend)
    return backend, a, b


class FakeSocket:
    def __init__(self):
        self.texts = []
        self.jsons = []

    async def send_text(self, raw):
        self.texts.append(raw)

    async def send_json(self, msg):
        self.jsons.append(msg)


@pytest.mark.asyncio
async def test_same_replica_room_ready():
    _, a, _ = make_pair()
    await a.register("r-same", "caller", "c1")
    await a.register("r-same", "callee", "c2")
    peers = await a.distributed_peers("r-same")
    assert set(peers) == {"caller", "callee"}


@pytest.mark.asyncio
async def test_cross_replica_signaling_and_no_echo_no_loop():
    _, a, b = make_pair()
    received_b, received_a = [], []
    b.set_handler(lambda env: received_b.append(env))
    a.set_handler(lambda env: received_a.append(env))
    # reset: constructors subscribed _dispatch which forwards to handler set later; memory publish uses hub callback list
    await a.register("r-x", "caller", "c1")
    await b.register("r-x", "callee", "c2")
    assert set(await a.distributed_peers("r-x")) == {"caller", "callee"}
    await a.publish_signal("r-x", "caller", "c1", '{"type":"offer","sdp":"x"}', "offer", "callee")
    assert len(received_b) == 1 and received_b[0]["msg_type"] == "offer"
    assert received_a == [], "origin replica must not get its own publish back"


@pytest.mark.asyncio
async def test_cross_replica_delivery_to_local_socket_via_calls_handler():
    from api.routers import calls
    backend, a, b = make_pair()
    # Wire b's remote delivery like calls.py does, against a local room dict
    callee_sock = FakeSocket()
    old = calls._rooms.get("r-deliver")
    calls._rooms["r-deliver"] = {"callee": callee_sock}
    b.set_handler(calls._deliver_remote)
    # calls._deliver_remote reads global _rooms; envelope room must match
    await b._dispatch({"room_id": "r-deliver", "kind": "signal", "sender": "caller", "target": "callee", "msg_type": "offer", "raw": '{"type":"offer"}'})
    assert callee_sock.texts == ['{"type":"offer"}']
    if old is None:
        calls._rooms.pop("r-deliver", None)
    else:
        calls._rooms["r-deliver"] = old


@pytest.mark.asyncio
async def test_answer_before_websocket_buffers_and_replays_in_order():
    _, a, b = make_pair()
    got = []
    b.set_handler(lambda env: got.append(env))
    # callee absent: ICE/offer published now must buffer, not vanish
    await a.publish_signal("r-buf", "caller", "c1", '{"type":"ice","n":1}', "ice", "callee")
    await a.publish_signal("r-buf", "caller", "c1", '{"type":"ice","n":2}', "ice", "callee")
    assert got == []
    await b.register("r-buf", "callee", "c9")
    drained = await b.drain_buffer("r-buf", "callee")
    assert [d["raw"] for d in drained] == ['{"type":"ice","n":1}', '{"type":"ice","n":2}']
    assert await b.drain_buffer("r-buf", "callee") == [], "replay once only"


@pytest.mark.asyncio
async def test_ice_ordering_preserved_in_buffer():
    _, a, _ = make_pair()
    for n in range(5):
        await a.publish_signal("r-ice", "caller", "c1", f"ice-{n}", "ice", "callee")
    drained = await a.drain_buffer("r-ice", "callee")
    assert [d["raw"] for d in drained] == [f"ice-{n}" for n in range(5)]


@pytest.mark.asyncio
async def test_reconnect_and_ghost_socket_replacement():
    _, a, b = make_pair()
    await a.register("r-ghost", "caller", "old-conn")
    await b.register("r-ghost", "callee", "c2")
    # new socket for same user on same replica replaces old
    await a.register("r-ghost", "caller", "new-conn")
    assert set(await a.distributed_peers("r-ghost")) == {"caller", "callee"}, "same user twice counts once"
    # old socket teardown must not remove new presence
    assert await a.unregister("r-ghost", "caller", "old-conn") is False
    assert "caller" in await a.distributed_peers("r-ghost")
    # genuine disconnect of current socket does remove
    assert await a.unregister("r-ghost", "caller", "new-conn") is True
    assert "caller" not in await a.distributed_peers("r-ghost")


@pytest.mark.asyncio
async def test_replica_failure_stale_presence_expires():
    backend, a, b = make_pair()
    await a.register("r-crash", "caller", "c1")
    await b.register("r-crash", "callee", "c2")
    # simulate replica A crash: no unregister, lease lapses
    backend.presence["r-crash"]["caller"]["exp"] = time.time() - 1
    peers = await b.distributed_peers("r-crash")
    assert set(peers) == {"callee"}
    # room recovers when caller rejoins on surviving replica
    await b.register("r-crash", "caller", "c3")
    assert set(await b.distributed_peers("r-crash")) == {"caller", "callee"}


@pytest.mark.asyncio
async def test_room_isolation():
    _, a, b = make_pair()
    got = []
    b.set_handler(lambda env: got.append(env))
    await a.publish_signal("room-1", "caller", "c1", "offer-1", "offer", "callee")
    # handler receives envelope; isolation is by room_id routing in delivery
    assert all(e["room_id"] == "room-1" for e in got)
    assert not any(e["room_id"] == "room-2" for e in got)


@pytest.mark.asyncio
async def test_authorization_intruder_is_not_participant():
    await create_session("r-auth", "caller", "callee", "listing-1", "audio", "Bob")
    s = await get_session("r-auth")
    assert s.is_participant("caller") and s.is_participant("callee")
    assert not s.is_participant("intruder")
    await end_session("r-auth")


@pytest.mark.asyncio
async def test_duplicate_answer_and_state_events_idempotent():
    await create_session("r-dup", "caller", "callee", "listing-1", "audio", "Bob")
    await update_state("r-dup", CallState.ringing)
    await mark_answered("r-dup")
    await mark_answered("r-dup")
    s = await get_session("r-dup")
    assert s.state == CallState.accepted and s.answered is True
    same = await update_state("r-dup", CallState.accepted)
    assert same.state == CallState.accepted
    await end_session("r-dup")


def test_connected_never_regresses_via_state_machine():
    # calls.py guards rejoin transitions; the machine itself has no connected->connecting/accepted edge
    assert not is_valid_transition(CallState.connected, CallState.connecting)
    assert not is_valid_transition(CallState.connected, CallState.accepted)
    assert is_valid_transition(CallState.disconnected, CallState.connecting)


@pytest.mark.asyncio
async def test_failure_is_terminal_not_endless_connecting():
    await create_session("r-fail", "caller", "callee", "listing-1", "audio", "Bob")
    await update_state("r-fail", CallState.ringing)
    await update_state("r-fail", CallState.accepted)
    await update_state("r-fail", CallState.connecting)
    failed = await update_state("r-fail", CallState.failed)
    assert failed.state == CallState.failed
    still = await update_state("r-fail", CallState.connecting)
    assert still.state == CallState.failed, "failed call must not resurrect to connecting"
    await end_session("r-fail")


@pytest.mark.asyncio
async def test_distributed_readiness_counts_distinct_participants():
    _, a, b = make_pair()
    await a.register("r-ready", "caller", "c1")
    await a.register("r-ready", "caller", "c1b")  # duplicate connection, same user
    peers = await a.distributed_peers("r-ready")
    assert len({u for u in peers if u in ("caller", "callee")}) == 1
    await b.register("r-ready", "callee", "c2")
    peers = await a.distributed_peers("r-ready")
    assert len({u for u in peers if u in ("caller", "callee")}) == 2
