"""A call that is over stays over (2026-11-14).

Railway, room HfedVQp_gK_0pLMgzro5eg: the caller hung up at 15:05:14 and the
server recorded the call cancelled at 15:05:16 - yet at 15:05:38 the
callee's phone reported it ringing, at 15:05:52 it joined the room, and at
15:05:54 its Accept was answered 200. The Redis store changed a session by
reading all of it and writing all of it back, so any change that had read
the call while it rang - a socket leaving, a heartbeat, an Accept, a ring
acknowledgement - could write "ringing" back over the cancellation that
landed meanwhile.

These tests make that interleaving happen on purpose against real Redis
(tests/call_races.py holds one change's write between its read and its
write while another change lands). On the store before atomic writes every
one of them ends with the earlier state written back. The in-memory store
(one process, one lock) is checked for the same outcomes without the
interleaving, which it cannot have.
"""
import asyncio
import os
import time
import uuid

import pytest

from api.core import call_state
from api.core.call_state import CallState
from tests.call_races import gate, interleave

REDIS_URL = os.getenv("REDIS_URL", "")
_UNANSWERED = (CallState.initiating, CallState.ringing)


@pytest.fixture(params=["script", "watch"])
def redis_store(request, monkeypatch):
    """Both ways the Redis store compares-and-sets: the Lua script, and the
    WATCH/MULTI/EXEC it falls back to on a Redis that refuses scripts."""
    if not REDIS_URL:
        pytest.skip("REDIS_URL not set: the Redis store is what these race against")
    store = call_state._RedisCallStore(REDIS_URL)
    store._cas_mode = request.param
    monkeypatch.setattr(call_state, "_store", store)
    return store


@pytest.fixture(params=["redis-script", "redis-watch", "memory"])
def any_store(request, monkeypatch):
    if request.param.startswith("redis"):
        if not REDIS_URL:
            pytest.skip("REDIS_URL not set")
        store = call_state._RedisCallStore(REDIS_URL)
        store._cas_mode = request.param.split("-", 1)[1]
    else:
        store = call_state._InMemoryCallStore()
    monkeypatch.setattr(call_state, "_store", store)
    return store


async def _ringing() -> str:
    room = f"atomic-{uuid.uuid4().hex}"
    await call_state.create_session(room, "caller", "callee", "listing", "audio", "Caller")
    await call_state.update_state(room, CallState.ringing)
    return room


async def _connected() -> str:
    room = await _ringing()
    await call_state.mark_answered(room)
    await call_state.update_state(room, CallState.connecting)
    await call_state.update_state(room, CallState.connected)
    return room


# ── Nothing brings an ended call back ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_a_socket_leaving_cannot_bring_back_a_cancelled_call(redis_store, monkeypatch):
    """The incident's write: the caller's socket teardown had read the call
    ringing; the cancellation landed; the teardown wrote "ringing" back."""
    room = await _ringing()
    await call_state.set_participant_connected(room, "caller", True)  # its socket had joined
    held = gate(redis_store, room, matches=lambda s: s["state"] == "ringing",
                monkeypatch=monkeypatch)
    await interleave(
        held,
        slow=lambda: call_state.set_participant_connected(room, "caller", False),
        fast=lambda: call_state.update_state(room, CallState.missed),
    )
    session = await call_state.get_session(room)
    assert session.state == CallState.missed
    assert await call_state.get_pending_call("listing", "callee") is None, (
        "the callee's sweep must not find it ringing again")


@pytest.mark.asyncio
async def test_a_socket_joining_cannot_bring_back_a_cancelled_call(redis_store, monkeypatch):
    room = await _ringing()
    held = gate(redis_store, room, matches=lambda s: s["state"] == "ringing",
                monkeypatch=monkeypatch)
    joined, _ = await interleave(
        held,
        slow=lambda: call_state.set_participant_connected(room, "callee", True),
        fast=lambda: call_state.update_state(room, CallState.missed),
    )
    assert joined.state == CallState.missed, "the join is told the call is over"
    assert (await call_state.get_session(room)).state == CallState.missed


@pytest.mark.asyncio
async def test_a_heartbeat_cannot_bring_back_an_ended_call(redis_store, monkeypatch):
    """A heartbeat that read the call up gave it four more hours over the
    hang-up."""
    room = await _connected()
    held = gate(redis_store, room, matches=lambda s: s["state"] == "connected",
                monkeypatch=monkeypatch)
    await interleave(
        held,
        slow=lambda: call_state.renew_session(room),
        fast=lambda: call_state.update_state(room, CallState.ended),
    )
    session = await call_state.get_session(room)
    assert session.state == CallState.ended
    assert session.expires_at <= time.time() + call_state.POST_CALL_GRACE_TTL_SECONDS + 2, (
        "an ended call keeps its short grace window, not the connected TTL")


@pytest.mark.asyncio
async def test_an_accept_that_loses_to_a_hang_up_is_refused(redis_store, monkeypatch):
    room = await _ringing()
    held = gate(redis_store, room, matches=lambda s: s.get("answered") is True,
                monkeypatch=monkeypatch)
    answer, _ = await interleave(
        held,
        slow=lambda: call_state.mark_answered(room),
        fast=lambda: call_state.update_state(room, CallState.missed),
    )
    assert answer.accepted is False and answer.first is False
    session = await call_state.get_session(room)
    assert session.state == CallState.missed
    assert session.answered is False, "a refused answer changes nothing"


@pytest.mark.asyncio
async def test_a_hang_up_that_loses_to_an_accept_does_not_cancel_it(redis_store, monkeypatch):
    """The other order: Accept landed first. "Cancel it if nobody answered"
    must see the answer, never write `missed` over `accepted`."""
    room = await _ringing()
    held = gate(redis_store, room, matches=lambda s: s["state"] == "missed",
                monkeypatch=monkeypatch)
    cancel, answer = await interleave(
        held,
        slow=lambda: call_state.transition(room, CallState.missed, only_from=_UNANSWERED),
        fast=lambda: call_state.mark_answered(room),
    )
    assert answer.accepted and answer.first
    assert cancel.applied is False
    assert cancel.session.state == CallState.accepted


@pytest.mark.asyncio
async def test_a_ring_acknowledgement_after_a_hang_up_says_it_no_longer_rings(redis_store,
                                                                              monkeypatch):
    room = await _ringing()
    held = gate(redis_store, room, matches=lambda s: s.get("callee_alerted") is True,
                monkeypatch=monkeypatch)
    alert, _ = await interleave(
        held,
        slow=lambda: call_state.mark_callee_alerted(room),
        fast=lambda: call_state.update_state(room, CallState.missed),
    )
    assert alert.ringing is False and alert.first is False
    session = await call_state.get_session(room)
    assert session.state == CallState.missed and session.callee_alerted is False


@pytest.mark.asyncio
async def test_two_writes_crossing_both_land(redis_store, monkeypatch):
    """Not only terminal states: a field one change wrote is never lost to
    another change that read the session before it."""
    room = await _ringing()
    held = gate(redis_store, room, matches=lambda s: s.get("caller_connected") is True,
                monkeypatch=monkeypatch)
    await interleave(
        held,
        slow=lambda: call_state.set_participant_connected(room, "caller", True),
        fast=lambda: call_state.mark_callee_alerted(room),
    )
    session = await call_state.get_session(room)
    assert session.caller_connected is True
    assert session.callee_alerted is True


@pytest.mark.asyncio
async def test_a_blind_write_from_an_older_replica_cannot_reopen_the_call(redis_store):
    """During a deploy a replica still on the previous build writes back the
    whole session it read. The call's "over" marker outranks it."""
    room = await _ringing()
    stale = await redis_store.get(room)
    await call_state.update_state(room, CallState.missed)
    await redis_store._write(stale, ttl_seconds=60)  # "ringing", written blind
    session = await call_state.get_session(room)
    assert session.state == CallState.missed
    assert await call_state.get_incoming_call("callee") is None
    assert (await call_state.mark_answered(room)).accepted is False


@pytest.mark.asyncio
async def test_a_redis_without_scripts_still_gets_atomic_writes(monkeypatch):
    """A managed Redis can refuse EVAL. Calls must not stop working: the
    store moves to WATCH/MULTI/EXEC, as atomic, and says so once."""
    if not REDIS_URL:
        pytest.skip("REDIS_URL not set")
    from redis.exceptions import ResponseError

    store = call_state._RedisCallStore(REDIS_URL)
    monkeypatch.setattr(call_state, "_store", store)
    room = await _ringing()
    real_get_client = store._get_client

    class NoScripts:
        def __init__(self, real):
            self._real = real

        def __getattr__(self, name):
            return getattr(self._real, name)

        async def evalsha(self, *args, **kwargs):
            raise ResponseError("ERR unknown command 'evalsha'")

        def register_script(self, script):
            from redis.commands.core import AsyncScript
            return AsyncScript(self, script)

    async def no_scripts():
        return NoScripts(await real_get_client())

    store._get_client = no_scripts
    answer = await call_state.mark_answered(room)
    assert answer.accepted and answer.first
    assert store._cas_mode == "watch"
    await call_state.update_state(room, CallState.ended)
    assert (await call_state.mark_answered(room)).accepted is False


# ── The same outcomes on either store ─────────────────────────────────────────

@pytest.mark.asyncio
async def test_no_change_reopens_a_call_that_is_over(any_store):
    for over in (CallState.missed, CallState.declined, CallState.ended,
                 CallState.failed):
        room = await _ringing()
        await call_state.update_state(room, over)
        await call_state.set_participant_connected(room, "callee", True)
        await call_state.renew_session(room)
        alert = await call_state.mark_callee_alerted(room)
        answer = await call_state.mark_answered(room)
        for state in CallState:
            await call_state.update_state(room, state)
        session = await call_state.get_session(room)
        assert session.state == over, f"{over.value} became {session.state.value}"
        assert not alert.ringing and not answer.accepted
        assert session.callee_connected is False and session.answered is False


@pytest.mark.asyncio
async def test_answering_twice_tells_the_caller_once(any_store):
    room = await _ringing()
    first = await call_state.mark_answered(room)
    again = await call_state.mark_answered(room)
    assert (first.accepted, first.first) == (True, True)
    assert (again.accepted, again.first) == (True, False), "idempotent, and not a second 'first'"
    assert again.session.state == CallState.accepted


@pytest.mark.asyncio
async def test_answering_a_call_already_under_way_is_not_refused(any_store):
    """Answered on this phone (or another) and joined: a repeated Accept is
    the same answer, not a call that ended."""
    room = await _connected()
    answer = await call_state.mark_answered(room)
    assert answer.accepted and not answer.first
    assert answer.session.state == CallState.connected


@pytest.mark.asyncio
async def test_a_ring_is_acknowledged_once_and_only_while_it_rings(any_store):
    room = await _ringing()
    first = await call_state.mark_callee_alerted(room)
    again = await call_state.mark_callee_alerted(room)
    assert (first.ringing, first.first) == (True, True)
    assert (again.ringing, again.first) == (True, False)
    await call_state.mark_answered(room)
    late = await call_state.mark_callee_alerted(room)
    assert late.ringing is False, "answered: it no longer rings anywhere"


@pytest.mark.asyncio
async def test_ending_moves_to_the_outcome_or_to_ended(any_store):
    room = await _ringing()
    ended = await call_state.end_call(room, CallState.missed)
    assert ended.applied and ended.session.state == CallState.missed
    again = await call_state.end_call(room, CallState.declined)
    assert not again.applied and again.session.state == CallState.missed, "first outcome stands"

    answered = await _ringing()
    await call_state.mark_answered(answered)
    # `accepted` can't become `missed`; it is over all the same.
    moved = await call_state.end_call(answered, CallState.missed)
    assert moved.session.state == CallState.ended

    picked = await _ringing()
    moved = await call_state.end_call(
        picked, lambda s: CallState.failed if s.answered else CallState.missed)
    assert moved.session.state == CallState.missed


@pytest.mark.asyncio
async def test_milestones_stick_and_never_touch_a_call_that_is_over(any_store):
    room = await _ringing()
    await call_state.set_participant_connected(room, "caller", True, joined=True)
    await call_state.set_participant_connected(room, "callee", True)  # ringing in the room
    await call_state.note(room, offer_relayed=True)
    session = await call_state.get_session(room)
    assert (session.caller_joined, session.callee_joined, session.offer_relayed) == (
        True, False, True)
    await call_state.set_participant_connected(room, "caller", False)
    assert (await call_state.get_session(room)).caller_joined is True, "sticky"
    await call_state.update_state(room, CallState.missed)
    await call_state.note(room, answer_relayed=True)
    assert (await call_state.get_session(room)).answer_relayed is False


@pytest.mark.asyncio
async def test_concurrent_changes_all_land_exactly_once(any_store):
    """Many changes at once on one call, as the WS handler, heartbeats and
    HTTP requests make them: one answer is first, the flags all stick, and
    the call ends once."""
    room = await _ringing()
    results = await asyncio.gather(
        call_state.set_participant_connected(room, "caller", True),
        call_state.mark_callee_alerted(room),
        call_state.set_participant_connected(room, "callee", True),
        *(call_state.mark_answered(room) for _ in range(5)),
    )
    answers = results[3:]
    assert sum(1 for a in answers if a.first) == 1
    assert all(a.accepted for a in answers)
    session = await call_state.get_session(room)
    assert session.caller_connected and session.callee_connected and session.answered
    ends = await asyncio.gather(*(call_state.end_call(room, CallState.ended) for _ in range(5)))
    assert sum(1 for e in ends if e.applied) == 1
    assert (await call_state.get_session(room)).state == CallState.ended
