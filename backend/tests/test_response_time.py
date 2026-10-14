"""Response-time measurement (domains/trust/response_time).

Derived entirely from existing message history, so these tests are about
the threading and censoring rules rather than about instrumentation.
"""
from datetime import datetime, timedelta

import pytest

from api.domains.trust.response_time import (
    MAX_OBSERVATION_MINUTES, MIN_OBSERVATIONS, compute_response_times,
)

NOW = datetime(2026, 9, 16, 12, 0)


def _m(seller, listing, buyer, role, recipient, minutes_ago):
    # Listing ids are seller-unique in production; keeping that true here
    # matters, because sharing one across sellers interleaves their threads
    # and silently scrambles attribution.
    return (seller, f"{seller}-{listing}", buyer, role, recipient,
            NOW - timedelta(minutes=minutes_ago))


def _run(rows):
    return compute_response_times(
        sorted(rows, key=lambda r: (r[1], r[2], r[5])), NOW)


def test_a_seller_who_never_replies_scores_worse_than_a_slow_one():
    """The trap this module is built around.

    Counting only answered messages gives a seller who ignores everyone NO
    response time, and "no data" sorts better than "slow" - so the worst
    behaviour on the platform would rank above merely sluggish behaviour.
    Unanswered threads are counted as censored observations instead.
    """
    slow = [_m("slow", f"L{i}", f"B{i}", "buyer", None, 2000 - i) for i in range(3)]
    slow += [_m("slow", f"L{i}", f"B{i}", "seller", None, 560 - i) for i in range(3)]
    ghost = [_m("ghost", f"L{i}", f"B{i}", "buyer", None, 2000 - i) for i in range(3)]
    res = _run(slow + ghost)
    assert res["ghost"] > res["slow"]


def test_unanswered_time_is_capped():
    """One thread abandoned for a month must not read as a month's latency.

    Past two days the exact figure carries no extra signal, and uncapped
    values let a single abandoned thread dominate a sparse seller's average.
    """
    rows = [_m("dead", f"L{i}", f"B{i}", "buyer", None, 14400 - i) for i in range(3)]
    assert _run(rows)["dead"] == MAX_OBSERVATION_MINUTES


def test_a_burst_of_buyer_messages_is_one_wait_not_five():
    """A buyer sending five messages in a row is one obligation.

    Counting each would punish the seller for the buyer's typing habits.
    """
    rows = [_m("burst", "L1", "B1", "buyer", None, 70 - i) for i in range(5)]
    rows.append(_m("burst", "L1", "B1", "seller", None, 60))
    rows += [_m("burst", "L2", "B2", "buyer", None, 50),
             _m("burst", "L2", "B2", "seller", None, 40),
             _m("burst", "L3", "B3", "buyer", None, 30),
             _m("burst", "L3", "B3", "seller", None, 20)]
    assert _run(rows)["burst"] == pytest.approx(10.0, abs=0.5)


def test_zeno_messages_addressed_to_the_buyer_do_not_start_the_clock():
    """Only relays the seller can see are an obligation on the seller.

    Otherwise every buyer-directed relay would start a timer against a
    seller who was never shown the message.
    """
    rows = [_m("zb", "L1", "B1", "broker", "buyer", 500),
            _m("zb", "L1", "B1", "buyer", None, 100),
            _m("zb", "L1", "B1", "seller", None, 95),
            _m("zb", "L2", "B2", "buyer", None, 90),
            _m("zb", "L2", "B2", "seller", None, 85),
            _m("zb", "L3", "B3", "buyer", None, 80),
            _m("zb", "L3", "B3", "seller", None, 75)]
    assert _run(rows)["zb"] == pytest.approx(5.0, abs=0.5)


def test_zeno_messages_addressed_to_the_seller_do_start_it():
    """In the mediated room the relay is what the seller actually sees."""
    rows = [_m("zs", f"L{i}", f"B{i}", "broker", "seller", 100 - i) for i in range(3)]
    rows += [_m("zs", f"L{i}", f"B{i}", "seller", None, 70 - i) for i in range(3)]
    assert "zs" in _run(rows)


def test_thin_history_is_unmeasured_not_fast():
    """Below MIN_OBSERVATIONS the average is noise.

    Returning None keeps "we have not measured this" distinguishable from
    "measured, and quick" - the caller falls back to a neutral score rather
    than crediting a seller for two lucky replies.
    """
    rows = [_m("thin", "L1", "B1", "buyer", None, 20),
            _m("thin", "L1", "B1", "seller", None, 18)]
    assert "thin" not in _run(rows)
    assert MIN_OBSERVATIONS >= 3


def test_the_figure_is_the_average_of_every_reply():
    """Average response time: every wait counts.

    Replies after 5, 15 and 40 minutes average 20. The median (15) it used
    to report hid the 40-minute wait entirely - a seller could leave a
    third of their buyers waiting and the number would not move.
    """
    rows = [_m("avg", "L1", "B1", "buyer", None, 100),
            _m("avg", "L1", "B1", "seller", None, 95),
            _m("avg", "L2", "B2", "buyer", None, 90),
            _m("avg", "L2", "B2", "seller", None, 75),
            _m("avg", "L3", "B3", "buyer", None, 70),
            _m("avg", "L3", "B3", "seller", None, 30)]
    assert _run(rows)["avg"] == pytest.approx(20.0)


def test_one_forgotten_thread_counts_but_is_capped():
    """An abandoned thread raises the average by at most its 48h cap."""
    rows = [_m("mix", "L1", "B1", "buyer", None, 100),
            _m("mix", "L1", "B1", "seller", None, 95),
            _m("mix", "L2", "B2", "buyer", None, 90),
            _m("mix", "L2", "B2", "seller", None, 85),
            _m("mix", "L3", "B3", "buyer", None, 99999)]
    assert _run(rows)["mix"] == pytest.approx((5 + 5 + MAX_OBSERVATION_MINUTES) / 3, abs=0.1)


def test_ranking_and_the_seller_facing_score_use_the_same_curve():
    """Two curves for one concept lets a seller improve their rating while
    their listings sink, with nothing on screen explaining why."""
    from api.domains.trust.response_time import response_time_score
    from api.domains.trust.seller_rating import response_score
    for m in (None, 0, 25, 60, 2880):
        assert response_time_score(m) == response_score(m)
