"""Deal lifecycle attribution (domains/trust/deal_lifecycle).

The rating penalises a seller's backlog. These tests pin WHO a stalled deal
is attributed to, because the failure mode is a seller being punished for
somebody else's behaviour - and one of those somebodies is a competitor who
worked out that opening threads costs a rival rating.
"""
from datetime import datetime, timedelta

from api.domains.trust.deal_lifecycle import (
    DealStage, StallReason, assess, needs_model_review,
)

NOW = datetime(2026, 9, 17, 12, 0)


def _msgs(*spec):
    """(role, hours_ago) pairs, oldest first."""
    return [(role, NOW - timedelta(hours=h)) for role, h in spec]


def test_a_competitor_opening_threads_cannot_inflate_your_backlog():
    """One question then silence is not a deal the seller failed at.

    This is the attack the stage floor exists to stop: anyone can open
    conversations on a rival's listings, and if every open thread counted,
    that would be a cheap way to damage a competitor's ranking.
    """
    _, stall, counts, _ = assess("negotiating", False, _msgs(("buyer", 72)), NOW)
    assert stall is StallReason.seller_blocked   # honest about whose turn
    assert counts is False                       # but not held against them


def test_a_buyer_who_goes_quiet_is_not_the_sellers_fault():
    _, stall, counts, _ = assess(
        "negotiating", False, _msgs(("buyer", 130), ("seller", 120)), NOW)
    assert stall is StallReason.buyer_blocked
    assert counts is False


def test_a_seller_who_actually_ignores_a_buyer_does_count():
    """The one case that should count. Without it the metric is toothless."""
    _, stall, counts, reason = assess(
        "agreed", False, _msgs(("seller", 100), ("buyer", 72)), NOW)
    assert stall is StallReason.seller_blocked
    assert counts is True
    assert "waiting" in reason.lower()


def test_a_recent_unanswered_message_is_not_yet_a_stall():
    """Two hours is not neglect. Penalising it would make the metric noise."""
    _, stall, counts, _ = assess(
        "agreed", False, _msgs(("seller", 30), ("buyer", 2)), NOW)
    assert stall is StallReason.active
    assert counts is False


def test_a_seller_who_just_replied_is_not_waiting_on_a_quiet_buyer():
    """Buyers are entitled to think about it.

    Seller-spoke-last within the quiet window is an active conversation,
    not a buyer who vanished - labelling it otherwise told a seller their
    buyer had gone silent two hours after they answered.
    """
    _, stall, _, _ = assess(
        "agreed", False,
        _msgs(("buyer", 6), ("seller", 5), ("buyer", 3), ("seller", 2)), NOW)
    assert stall is StallReason.active


def test_a_dead_thread_is_abandoned_not_pending():
    _, stall, counts, _ = assess(
        "agreed", False, _msgs(("buyer", 600), ("seller", 590)), NOW)
    assert stall is StallReason.abandoned
    assert counts is False


def test_money_in_escrow_is_not_a_stalled_deal():
    """Funded deals wait on delivery, not on anyone to reply.

    Before the early return, message-based attribution ran on these too and
    reported "the buyer has gone quiet" about a deal that was already paid.
    """
    stage, stall, counts, _ = assess(
        "paid", True, _msgs(("buyer", 40), ("seller", 30)), NOW)
    assert stage is DealStage.funded
    assert stall is StallReason.closed
    assert counts is False


def test_terminal_deals_never_count():
    for status in ("released", "refunded", "cancelled"):
        _, stall, counts, _ = assess(status, True, _msgs(("seller", 5)), NOW)
        assert stall is StallReason.closed
        assert counts is False


def test_disputed_deals_are_handled_elsewhere():
    """A dispute has its own process; it must not also drag the backlog."""
    _, stall, counts, _ = assess("disputed", True, _msgs(("buyer", 5)), NOW)
    assert counts is False


def test_the_model_is_only_called_where_the_record_cannot_answer():
    """Cost control. Every cheap case must be settled without a model call."""
    # Abandoned, funded and terminal deals are already decided.
    assert not needs_model_review(
        DealStage.negotiating, StallReason.abandoned, 20, None, NOW)
    assert not needs_model_review(
        DealStage.funded, StallReason.active, 20, None, NOW)
    # Too little conversation to read anything from.
    assert not needs_model_review(
        DealStage.negotiating, StallReason.active, 3, None, NOW)
    # Reviewed recently - one per deal per day at most.
    assert not needs_model_review(
        DealStage.negotiating, StallReason.active, 20,
        NOW - timedelta(hours=2), NOW)
    # The genuine remainder: active, talkative, no escrow.
    assert needs_model_review(
        DealStage.negotiating, StallReason.active, 20, None, NOW)


def test_attribution_never_reads_message_content():
    """assess() takes only (role, timestamp).

    Deliberate: attribution must not depend on what people said, which keeps
    it cheap, auditable, and outside the privacy rules that govern message
    bodies. A signature change here is a design change.
    """
    import inspect
    sig = inspect.signature(assess)
    assert list(sig.parameters) == [
        "deal_status", "escrow_funded", "messages", "now"]
