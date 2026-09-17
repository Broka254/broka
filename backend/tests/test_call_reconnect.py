"""
Regression tests for the calling audit (2026-09-14).

Covers the two call_state.py changes that make a mid-call reconnect work,
plus the heartbeat-driven TTL renewal that keeps a long call's session
alive. Everything here is about the SERVER's view of a call that drops and
comes back - the client-side half of the same fix lives in
flutter_app/lib/services/webrtc_service.dart (see CALLING.md).

These are deliberately separate from test_call_state.py so the original
state-machine invariants there keep asserting the contract they were
written for, untouched.
"""
import time

import pytest

from api.core.call_state import (
    CallState, is_valid_transition, is_terminal,
    create_session, get_session, update_state, renew_session,
    get_pending_call, end_session,
    CONNECTED_SESSION_TTL_SECONDS,
)


class TestReconnectTransitions:
    """A peer whose signaling socket drops and reconnects walks the session
    back through `accepted` and `connecting`. Both were missing from
    `disconnected`'s transition set, so every reconnect logged two rejected
    transitions and left the session stuck at `disconnected`."""

    def test_disconnected_allows_callee_rejoin(self):
        # calls.py calls update_state(accepted) when the CALLEE rejoins.
        assert is_valid_transition(CallState.disconnected, CallState.accepted)

    def test_disconnected_allows_room_ready_again(self):
        # ...then update_state(connecting) once membership is back to 2.
        assert is_valid_transition(CallState.disconnected, CallState.connecting)

    def test_disconnected_still_allows_direct_recovery(self):
        assert is_valid_transition(CallState.disconnected, CallState.connected)

    def test_accepted_can_drop_before_connecting(self):
        # A socket can die in the window between answering and the peer
        # connection coming up.
        assert is_valid_transition(CallState.accepted, CallState.disconnected)

    def test_reconnect_additions_cannot_resurrect_a_terminal_call(self):
        # The whole point of the guard: widening `disconnected` must not
        # have opened a back door out of any terminal state.
        for terminal in (CallState.ended, CallState.declined, CallState.missed,
                         CallState.expired, CallState.failed):
            assert is_terminal(terminal)
            for target in (CallState.accepted, CallState.connecting,
                           CallState.connected, CallState.disconnected):
                assert not is_valid_transition(terminal, target)


@pytest.mark.asyncio
class TestFullReconnectSequence:
    async def test_call_survives_a_mid_call_drop_and_rejoin(self):
        await create_session("rc-1", "caller", "callee", "listing-1", "audio", "Bob")
        for state in (CallState.ringing, CallState.accepted,
                      CallState.connecting, CallState.connected):
            await update_state("rc-1", state)

        # Peer's socket closes -> calls.py's finally-block.
        dropped = await update_state("rc-1", CallState.disconnected)
        assert dropped.state == CallState.disconnected

        # Peer reconnects: exactly the two calls call_signaling() makes.
        rejoined = await update_state("rc-1", CallState.accepted)
        assert rejoined.state == CallState.accepted
        ready = await update_state("rc-1", CallState.connecting)
        assert ready.state == CallState.connecting

        # Client reports its peer connection is healthy again.
        recovered = await update_state("rc-1", CallState.connected)
        assert recovered.state == CallState.connected
        await end_session("rc-1")

    async def test_a_dropped_call_can_still_be_ended_normally(self):
        await create_session("rc-2", "caller", "callee", "listing-2", "audio", "Bob")
        await update_state("rc-2", CallState.ringing)
        await update_state("rc-2", CallState.accepted)
        await update_state("rc-2", CallState.disconnected)
        ended = await update_state("rc-2", CallState.ended)
        assert ended.state == CallState.ended
        await end_session("rc-2")


@pytest.mark.asyncio
class TestSessionRenewal:
    """CONNECTED_SESSION_TTL_SECONDS' own doc comment flagged this gap: the
    TTL was only extended on a transition INTO `connected`, so a call that
    connected once and simply stayed up counted down from that one moment.
    The WebSocket heartbeat now renews it."""

    async def test_renew_extends_a_live_session(self):
        session = await create_session("rn-1", "u1", "u2", "l1", "audio", "A")
        await update_state("rn-1", CallState.ringing)
        # Simulate a session close to expiry.
        session = await get_session("rn-1")
        session.expires_at = time.time() + 5

        renewed = await renew_session("rn-1")
        assert renewed is not None
        assert renewed.expires_at > time.time() + (CONNECTED_SESSION_TTL_SECONDS / 2)
        await end_session("rn-1")

    async def test_renew_is_a_noop_on_a_terminal_session(self):
        await create_session("rn-2", "u1", "u2", "l2", "audio", "A")
        await update_state("rn-2", CallState.ringing)
        await update_state("rn-2", CallState.declined)
        before = (await get_session("rn-2")).expires_at

        await renew_session("rn-2")
        after = (await get_session("rn-2")).expires_at
        # A finished call must not have its session extended - that would
        # keep dead sessions alive for hours and is exactly what
        # POST_CALL_GRACE_TTL_SECONDS exists to prevent.
        assert before == after
        await end_session("rn-2")

    async def test_renew_on_a_missing_session_is_harmless(self):
        assert await renew_session("rn-does-not-exist") is None


@pytest.mark.asyncio
class TestPendingIndexAfterDrop:
    async def test_a_dropped_call_is_not_offered_as_a_new_incoming_call(self):
        # GET /calls/pending/{listing_id} must only ever surface a call
        # that is genuinely still ringing - a call that connected and then
        # dropped must not be re-offered to the callee as a fresh ring.
        await create_session("rp-1", "buyer", "seller", "listing-p", "audio", "C")
        await update_state("rp-1", CallState.ringing)
        assert await get_pending_call("listing-p", "seller") is not None

        await update_state("rp-1", CallState.accepted)
        await update_state("rp-1", CallState.connecting)
        await update_state("rp-1", CallState.connected)
        await update_state("rp-1", CallState.disconnected)
        assert await get_pending_call("listing-p", "seller") is None
        await end_session("rp-1")
