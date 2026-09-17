"""
Regression tests for the cross-party leak found in the communications
audit (2026-09-14).

`_build_messages_for_party` builds the model context used to draft each
party's reply - including the reply sent to the OTHER party. It used to
filter only broker messages by recipient_role and append every human
message verbatim, which put one party's private conversation with Zeno
directly into the context of the message drafted for the other party.

These tests assert the visibility rule as a contract, not as a prompt
instruction: private words must not be in the context at all. A system
prompt asking a model not to repeat something it can see is mitigation;
not showing it is the control.
"""
import pytest

from api.routers.negotiate import _build_messages_for_party


class _Msg:
    def __init__(self, role, content, via_ai=False, recipient_role=None):
        self.role = role
        self.content = content
        self.via_ai = via_ai
        self.recipient_role = recipient_role


class _New:
    def __init__(self, sender_role, content):
        self.sender_role = sender_role
        self.content = content


BUYER_PRIVATE = "is this seller legit? i heard he scams people"
BUYER_BUDGET = "my real max is 90000 but don't tell him"
SELLER_PRIVATE = "i think this buyer is a time waster"
DIRECT_BUYER = "Hi, is it still available?"
DIRECT_SELLER = "Yes, it is."


def _history():
    return [
        _Msg("buyer", BUYER_PRIVATE, via_ai=True),
        _Msg("buyer", BUYER_BUDGET, via_ai=True),
        _Msg("broker", "Here is their track record.", recipient_role="buyer"),
        _Msg("broker", "A buyer is asking about availability.", recipient_role="seller"),
        _Msg("seller", SELLER_PRIVATE, via_ai=True),
        _Msg("buyer", DIRECT_BUYER, via_ai=False),
        _Msg("seller", DIRECT_SELLER, via_ai=False),
    ]


def _ctx(viewer_role, new):
    return "\n".join(m["content"] for m in _build_messages_for_party(_history(), new, viewer_role))


class TestPrivateWordsNeverCrossParties:
    def test_buyers_private_zeno_chat_is_absent_from_sellers_context(self):
        ctx = _ctx("seller", _New("buyer", "can you do 85000?"))
        assert BUYER_PRIVATE not in ctx
        assert BUYER_BUDGET not in ctx

    def test_sellers_private_zeno_chat_is_absent_from_buyers_context(self):
        ctx = _ctx("buyer", _New("seller", "I can do 88000."))
        assert SELLER_PRIVATE not in ctx

    def test_senders_raw_new_message_is_absent_from_the_other_partys_context(self):
        # The other party's draft is built from the relay SUMMARY (in its
        # system prompt), never the sender's own wording - which may carry
        # private content the classifier deliberately declined to relay.
        secret_laden = f"can you do 85000? also, {BUYER_PRIVATE}"
        ctx = _ctx("seller", _New("buyer", secret_laden))
        assert secret_laden not in ctx
        assert BUYER_PRIVATE not in ctx

    def test_broker_message_addressed_to_one_side_stays_there(self):
        buyer_ctx = _ctx("buyer", _New("buyer", "ok"))
        seller_ctx = _ctx("seller", _New("buyer", "ok"))
        assert "Here is their track record." in buyer_ctx
        assert "Here is their track record." not in seller_ctx
        assert "A buyer is asking about availability." in seller_ctx
        assert "A buyer is asking about availability." not in buyer_ctx


class TestLegitimateContentStillReachesTheModel:
    """The filter must not be so blunt it starves Zeno of real context -
    a broker that can't see the direct conversation can't mediate it."""

    def test_direct_chat_is_shared_with_both_sides(self):
        for role in ("buyer", "seller"):
            ctx = _ctx(role, _New(role, "ok"))
            assert DIRECT_BUYER in ctx
            assert DIRECT_SELLER in ctx

    def test_each_party_sees_their_own_private_words(self):
        buyer_ctx = _ctx("buyer", _New("buyer", "ok"))
        assert BUYER_PRIVATE in buyer_ctx
        assert BUYER_BUDGET in buyer_ctx

        seller_ctx = _ctx("seller", _New("seller", "ok"))
        assert SELLER_PRIVATE in seller_ctx

    def test_sender_sees_their_own_new_message(self):
        ctx = _ctx("buyer", _New("buyer", "can you do 85000?"))
        assert "can you do 85000?" in ctx

    def test_context_always_opens_with_a_user_turn(self):
        # Several providers reject a conversation that starts on an
        # assistant turn; the filter can empty the list, so the fallback
        # must survive it.
        history_only_other_private = [_Msg("seller", SELLER_PRIVATE, via_ai=True)]
        msgs = _build_messages_for_party(
            history_only_other_private, _New("seller", "hello"), "buyer")
        assert msgs and msgs[0]["role"] == "user"
