"""
BROKA - Call State & Call-Token Endpoint Tests
Run: pytest backend/tests/test_call_state.py -v

Covers api/core/call_state.py directly (state machine transition rules,
session lifecycle, the pending-call secondary index, expiry) and two of
api/routers/calls.py's newer endpoints - GET /{room_id}/token and
GET /pending/{listing_id} - by calling the route functions directly with a
resolved `current` dict, the same pattern test_cloudflare_turn.py uses for
GET /turn-credentials. Neither endpoint needs DB access, so these stay
plain unit tests rather than going through the ASGI test client.

NOTE on what was actually verified here vs. only reviewed: the
TestCallState* classes below (call_state.py has zero third-party
dependencies on its in-memory path) were written AND actually executed in
the sandbox this hardening pass was built in - every assertion in them
passed against a real run, not just a syntax check. The TestCallToken*/
TestPendingCall* classes need fastapi/pydantic, which weren't installed
there, so - like test_cloudflare_turn.py - they were carefully reviewed
against the real calls.py code but not executed. Please run
`pytest backend/tests/test_call_state.py -v` yourself before trusting the
router-level classes specifically.

POST /calls/initiate is NOT covered here - it needs a real DB session for
the Listing/User lookups, which would need a much heavier fixture (see
test_auctions.py/test_auth.py's ASGI-transport-plus-SQLite pattern) to
test properly rather than the lightweight direct-call pattern used
elsewhere in this file. Its call_state-dependent logic (room_id
generation, call_token issuance) is exercised indirectly by the
TestCallState* classes below, just not through the endpoint itself.
"""
from unittest.mock import patch

import pytest
from fastapi import HTTPException

from api.core.call_state import (
    CallState, is_valid_transition, is_terminal,
    create_session, get_session, get_pending_call, update_state,
    set_participant_connected, end_session, sweep_expired,
)
from api.routers.calls import get_call_token, get_pending_call as pending_call_endpoint


@pytest.fixture(autouse=True)
async def _clean_room(request):
    """Each test picks its own unique room_id (see the room_id= params
    below) so tests don't collide with each other in the shared
    module-level in-memory store - no shared-state cleanup needed between
    tests the way _reset_breaker handles it in test_cloudflare_turn.py."""
    yield


# ── State machine ──────────────────────────────────────────────────────────────

class TestStateMachine:
    def test_every_spec_example_is_rejected(self):
        # The exact four examples the hardening spec calls out by name.
        assert not is_valid_transition(CallState.ended, CallState.connected)
        assert not is_valid_transition(CallState.declined, CallState.connected)
        assert not is_valid_transition(CallState.expired, CallState.accepted)
        assert not is_valid_transition(CallState.failed, CallState.connected)

    def test_happy_path_is_allowed(self):
        assert is_valid_transition(CallState.initiating, CallState.ringing)
        assert is_valid_transition(CallState.ringing, CallState.accepted)
        assert is_valid_transition(CallState.accepted, CallState.connecting)
        assert is_valid_transition(CallState.connecting, CallState.connected)
        assert is_valid_transition(CallState.connected, CallState.disconnected)
        assert is_valid_transition(CallState.disconnected, CallState.connected)  # recovery

    def test_same_state_is_always_a_noop_allow(self):
        for s in CallState:
            assert is_valid_transition(s, s)

    def test_every_terminal_state_has_zero_outgoing_transitions(self):
        terminal = [CallState.failed, CallState.declined, CallState.ended,
                    CallState.missed, CallState.expired]
        for t in terminal:
            assert is_terminal(t)
            for target in CallState:
                if target == t:
                    continue
                assert not is_valid_transition(t, target), f"{t} -> {target} should be rejected"

    def test_non_terminal_states_are_not_terminal(self):
        for s in (CallState.initiating, CallState.ringing, CallState.accepted,
                  CallState.connecting, CallState.connected, CallState.disconnected):
            assert not is_terminal(s)


# ── Session lifecycle ─────────────────────────────────────────────────────────

class TestSessionLifecycle:
    @pytest.mark.asyncio
    async def test_create_starts_at_initiating(self):
        s = await create_session(room_id="t-create-1", caller_id="u1", callee_id="u2",
                                  listing_id="l1", call_type="audio", caller_name="Alice")
        assert s.state == CallState.initiating
        assert s.caller_id == "u1" and s.callee_id == "u2"

    @pytest.mark.asyncio
    async def test_get_round_trips(self):
        await create_session(room_id="t-get-1", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="video", caller_name="Alice")
        got = await get_session("t-get-1")
        assert got is not None and got.call_type == "video" and got.caller_name == "Alice"

    @pytest.mark.asyncio
    async def test_get_missing_room_returns_none(self):
        assert await get_session("does-not-exist-xyz") is None

    @pytest.mark.asyncio
    async def test_invalid_transition_is_rejected_and_state_unchanged(self):
        await create_session(room_id="t-invalid-1", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await update_state("t-invalid-1", CallState.ringing)
        # ringing -> connected skips accepted/connecting - invalid
        result = await update_state("t-invalid-1", CallState.connected)
        assert result.state == CallState.ringing  # unchanged, not silently accepted

    @pytest.mark.asyncio
    async def test_full_happy_path_reaches_connected(self):
        room = "t-happy-1"
        await create_session(room_id=room, caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await update_state(room, CallState.ringing)
        await update_state(room, CallState.accepted)
        await update_state(room, CallState.connecting)
        result = await update_state(room, CallState.connected)
        assert result.state == CallState.connected

    @pytest.mark.asyncio
    async def test_terminal_state_cannot_be_escaped(self):
        room = "t-terminal-1"
        await create_session(room_id=room, caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await update_state(room, CallState.ringing)
        await update_state(room, CallState.declined)
        stuck = await update_state(room, CallState.connected)
        assert stuck.state == CallState.declined  # still stuck, not resurrected

    @pytest.mark.asyncio
    async def test_participant_connected_flags(self):
        room = "t-participant-1"
        await create_session(room_id=room, caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        result = await set_participant_connected(room, "u2", True)
        assert result.callee_connected is True and result.caller_connected is False

    @pytest.mark.asyncio
    async def test_is_participant(self):
        s = await create_session(room_id="t-isp-1", caller_id="u1", callee_id="u2",
                                  listing_id="l1", call_type="audio", caller_name="Alice")
        assert s.is_participant("u1") and s.is_participant("u2")
        assert not s.is_participant("u3")

    @pytest.mark.asyncio
    async def test_end_session_removes_it(self):
        await create_session(room_id="t-end-1", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await end_session("t-end-1")
        assert await get_session("t-end-1") is None


# ── Pending-call index ────────────────────────────────────────────────────────

class TestPendingIndex:
    @pytest.mark.asyncio
    async def test_pending_finds_the_call(self):
        await create_session(room_id="t-pend-1", caller_id="buyer1", callee_id="seller1",
                              listing_id="listingA", call_type="audio", caller_name="Buyer")
        found = await get_pending_call("listingA", "seller1")
        assert found is not None and found.room_id == "t-pend-1"

    @pytest.mark.asyncio
    async def test_caller_never_sees_their_own_call_as_pending(self):
        await create_session(room_id="t-pend-2", caller_id="buyer2", callee_id="seller2",
                              listing_id="listingB", call_type="audio", caller_name="Buyer")
        assert await get_pending_call("listingB", "buyer2") is None

    @pytest.mark.asyncio
    async def test_wrong_listing_returns_nothing(self):
        await create_session(room_id="t-pend-3", caller_id="buyer3", callee_id="seller3",
                              listing_id="listingC", call_type="audio", caller_name="Buyer")
        assert await get_pending_call("other-listing", "seller3") is None

    @pytest.mark.asyncio
    async def test_clears_once_past_ringing(self):
        room = "t-pend-4"
        await create_session(room_id=room, caller_id="buyer4", callee_id="seller4",
                              listing_id="listingD", call_type="audio", caller_name="Buyer")
        await update_state(room, CallState.ringing)
        await update_state(room, CallState.accepted)
        assert await get_pending_call("listingD", "seller4") is None

    @pytest.mark.asyncio
    async def test_clears_on_end_session(self):
        await create_session(room_id="t-pend-5", caller_id="buyer5", callee_id="seller5",
                              listing_id="listingE", call_type="audio", caller_name="Buyer")
        await end_session("t-pend-5")
        assert await get_pending_call("listingE", "seller5") is None


# ── Expiry ─────────────────────────────────────────────────────────────────────

class TestExpiry:
    @pytest.mark.asyncio
    async def test_connected_session_survives_past_establishment_ttl(self):
        """The core V2-hardening bug fix: a call connected for longer than
        ESTABLISHMENT_SESSION_TTL_SECONDS (120s) must NOT have its session
        vanish out from under it - previously the TTL was fixed at
        creation and never renewed, so a WS reconnect attempted on a call
        that had been running for >2 minutes was rejected with "Call no
        longer exists" even though the call itself was healthy. Uses a
        deliberately short ttl_seconds=1 standing in for the real 120s so
        the test doesn't need to actually wait 2 minutes."""
        import time as time_module
        import asyncio
        from api.core.call_state import CONNECTED_SESSION_TTL_SECONDS, ESTABLISHMENT_SESSION_TTL_SECONDS
        room = "t-longcall-1"
        await create_session(room_id=room, caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="A",
                              ttl_seconds=1)
        await update_state(room, CallState.ringing)
        await update_state(room, CallState.accepted)
        await update_state(room, CallState.connecting)
        connected = await update_state(room, CallState.connected)
        assert connected.state == CallState.connected
        assert connected.expires_at > time_module.time() + ESTABLISHMENT_SESSION_TTL_SECONDS

        await asyncio.sleep(1.2)  # past the ORIGINAL 1s establishment TTL

        still_there = await get_session(room)
        assert still_there is not None and still_there.state == CallState.connected

        # A reconnect-style lookup (what the WS handler does on every
        # message, including a client re-reporting its state after
        # reconnecting) must still succeed past this point.
        reconnect_check = await update_state(room, CallState.connected)
        assert reconnect_check.state == CallState.connected

    @pytest.mark.asyncio
    async def test_past_ttl_session_reports_expired_on_read(self):
        import asyncio
        await create_session(room_id="t-exp-1", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice",
                              ttl_seconds=0)
        await asyncio.sleep(0.05)
        got = await get_session("t-exp-1")
        assert got is not None and got.state == CallState.expired

    @pytest.mark.asyncio
    async def test_sweep_removes_expired_sessions(self):
        import asyncio
        from api.core.call_state import _store, _RedisCallStore
        await create_session(room_id="t-exp-2", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice",
                              ttl_seconds=0)
        await asyncio.sleep(0.05)
        removed = await sweep_expired()
        if isinstance(_store, _RedisCallStore):
            # sweep_expired() is an intentional no-op on the Redis backend
            # (see its docstring in call_state.py) - actual reclamation is
            # Redis's own key TTL, which this fast unit test has no way to
            # wait out. What's guaranteed on this backend, and what's worth
            # checking here, is that the lazy-expiry read path still reports
            # the session as expired rather than silently handing back a
            # live one.
            got = await get_session("t-exp-2")
            assert got is not None and got.state == CallState.expired
        else:
            assert removed >= 1
            assert await get_session("t-exp-2") is None


# ── GET /calls/{room_id}/token ───────────────────────────────────────────────
# Router function called directly (bypassing FastAPI's Depends() wiring),
# same pattern as test_cloudflare_turn.py's TestTurnCredentialsEndpoint.

class TestGetCallToken:
    @pytest.mark.asyncio
    async def test_participant_gets_a_token(self):
        await create_session(room_id="t-tok-1", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        result = await get_call_token(room_id="t-tok-1", current={"id": "u2"})
        assert "call_token" in result and isinstance(result["call_token"], str)

    @pytest.mark.asyncio
    async def test_non_participant_is_rejected(self):
        await create_session(room_id="t-tok-2", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        with pytest.raises(HTTPException) as exc_info:
            await get_call_token(room_id="t-tok-2", current={"id": "intruder"})
        assert exc_info.value.status_code == 403

    @pytest.mark.asyncio
    async def test_missing_room_is_404(self):
        with pytest.raises(HTTPException) as exc_info:
            await get_call_token(room_id="never-existed-xyz", current={"id": "u1"})
        assert exc_info.value.status_code == 404

    @pytest.mark.asyncio
    async def test_ended_call_is_410(self):
        await create_session(room_id="t-tok-3", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await end_session("t-tok-3")
        # end_session removes it entirely, so this actually hits the 404
        # path, not 410 - a still-present-but-terminal session (e.g. a
        # 'declined' one that hasn't been cleaned up yet) is what 410
        # covers; simulate that case explicitly instead:
        await create_session(room_id="t-tok-3b", caller_id="u1", callee_id="u2",
                              listing_id="l1", call_type="audio", caller_name="Alice")
        await update_state("t-tok-3b", CallState.ringing)
        await update_state("t-tok-3b", CallState.declined)
        with pytest.raises(HTTPException) as exc_info:
            await get_call_token(room_id="t-tok-3b", current={"id": "u1"})
        assert exc_info.value.status_code == 410


# ── GET /calls/pending/{listing_id} ─────────────────────────────────────────

class TestPendingCallEndpoint:
    @pytest.mark.asyncio
    async def test_callee_sees_incoming_call_with_token(self):
        await create_session(room_id="t-ep-1", caller_id="buyerA", callee_id="sellerA",
                              listing_id="listingX", call_type="video", caller_name="Buyer A")
        result = await pending_call_endpoint(listing_id="listingX", current={"id": "sellerA"})
        assert result["has_call"] is True
        assert result["room_id"] == "t-ep-1"
        assert result["caller_id"] == "buyerA"
        assert result["call_type"] == "video"
        assert "call_token" in result

    @pytest.mark.asyncio
    async def test_no_pending_call_returns_false(self):
        result = await pending_call_endpoint(listing_id="listing-with-nothing", current={"id": "someone"})
        assert result == {"has_call": False}

    @pytest.mark.asyncio
    async def test_caller_polling_their_own_listing_sees_nothing(self):
        await create_session(room_id="t-ep-2", caller_id="buyerB", callee_id="sellerB",
                              listing_id="listingY", call_type="audio", caller_name="Buyer B")
        result = await pending_call_endpoint(listing_id="listingY", current={"id": "buyerB"})
        assert result == {"has_call": False}
