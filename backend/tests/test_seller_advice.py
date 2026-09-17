"""Seller advice cards (domains/trust/seller_advice).

Rules over snapshot deltas, not a model call. These tests exist because the
failure mode of advice is subtle: it stays fluent and plausible while being
wrong, so the claims have to be pinned to the numbers they came from.
"""
from api.domains.trust.seller_advice import build_advice


def _hist(n=8, **series):
    return [{"date": f"2026-09-{i+1:02d}",
             **{k: v for k, v in ((k, s[i]) for k, s in series.items())}}
            for i in range(n)]


def _codes(block):
    return {c["code"] for c in block}


def test_a_slipping_seller_is_told_plainly():
    cur = {"dcr": 68.0, "median_response_minutes": 240.0, "completed_deals": 20,
           "pending_deals": 4, "overall_rating": 6.1, "rank_position": 40}
    out = build_advice(cur, _hist(dcr=[78] * 8, response_minutes=[90] * 8,
                                  overall_rating=[7.0] * 8, rank_position=[25] * 8))
    codes = _codes(out["negatives"])
    assert "dcr_down" in codes
    assert "response_down" in codes
    assert not out["positives"]


def test_the_same_point_is_not_made_twice():
    """A falling DCR triggers both the trend rule and the absolute rule.

    Firing both says one thing in two ways, reads as padding, and costs a
    slot that should hold a different problem.
    """
    cur = {"dcr": 60.0, "median_response_minutes": 240.0, "completed_deals": 20,
           "pending_deals": 2, "overall_rating": 5.5, "rank_position": 60}
    out = build_advice(cur, _hist(dcr=[80] * 8, response_minutes=[90] * 8,
                                  overall_rating=[7.0] * 8, rank_position=[30] * 8))
    codes = [c["code"] for c in out["negatives"]]
    assert not ("dcr_down" in codes and "dcr_weak" in codes)
    assert not ("response_down" in codes and "response_slow" in codes)


def test_improvements_are_credited():
    cur = {"dcr": 91.0, "median_response_minutes": 18.0, "completed_deals": 45,
           "pending_deals": 3, "overall_rating": 8.4, "rank_position": 12}
    out = build_advice(cur, _hist(dcr=[84] * 8, response_minutes=[55] * 8,
                                  overall_rating=[7.8] * 8, rank_position=[19] * 8))
    codes = _codes(out["positives"])
    assert {"rating_up", "dcr_up", "response_up"} <= codes


def test_rank_improvement_is_a_decrease_not_an_increase():
    """#12 is better than #19.

    Every other metric here improves by going up, so the sign on rank is
    easy to invert by accident - and inverting it would congratulate a
    seller for sinking.
    """
    cur = {"dcr": 85.0, "completed_deals": 10, "pending_deals": 1,
           "overall_rating": 7.5, "rank_position": 12,
           "median_response_minutes": 40.0}
    improved = build_advice(cur, _hist(rank_position=[19] * 8, dcr=[85] * 8,
                                       overall_rating=[7.5] * 8,
                                       response_minutes=[40] * 8))
    assert "rank_up" in _codes(improved["positives"])

    worsened = build_advice({**cur, "rank_position": 30},
                            _hist(rank_position=[19] * 8, dcr=[85] * 8,
                                  overall_rating=[7.5] * 8,
                                  response_minutes=[40] * 8))
    assert "rank_up" not in _codes(worsened["positives"])


def test_a_brand_new_seller_gets_something_true_to_read():
    """No history must not mean an empty panel or an invented trend."""
    out = build_advice({"dcr": None, "median_response_minutes": None,
                        "completed_deals": 0, "pending_deals": 0,
                        "overall_rating": 6.5, "rank_position": None}, [])
    assert _codes(out["positives"]) == {"welcome"}
    assert not out["negatives"]


def test_absolute_rules_work_without_any_history():
    """A seller with a real problem hears about it on day one."""
    out = build_advice({"dcr": 55.0, "median_response_minutes": 400.0,
                        "completed_deals": 12, "pending_deals": 2,
                        "overall_rating": 5.0, "rank_position": None}, [])
    codes = _codes(out["negatives"])
    assert "response_slow" in codes and "dcr_weak" in codes


def test_backlog_needs_both_a_ratio_and_a_count():
    """1 pending against 1 completed is 50% and is not a backlog."""
    tiny = build_advice({"dcr": 90.0, "completed_deals": 1, "pending_deals": 1,
                         "overall_rating": 7.0,
                         "median_response_minutes": 20.0}, [])
    assert "backlog" not in _codes(tiny["negatives"])

    real = build_advice({"dcr": 90.0, "completed_deals": 4, "pending_deals": 11,
                         "overall_rating": 7.0,
                         "median_response_minutes": 20.0}, [])
    assert "backlog" in _codes(real["negatives"])


def test_cards_are_capped_and_worst_first():
    """A wall of cards is read as decoration."""
    out = build_advice({"dcr": 40.0, "median_response_minutes": 900.0,
                        "completed_deals": 5, "pending_deals": 20,
                        "overall_rating": 4.0, "rank_position": 90},
                       _hist(dcr=[85] * 8, response_minutes=[60] * 8,
                             overall_rating=[7.5] * 8, rank_position=[20] * 8))
    assert len(out["negatives"]) <= 4
    severities = [c["severity"] for c in out["negatives"]]
    assert severities == sorted(severities, reverse=True)


def test_small_moves_are_not_announced():
    """A 0.1-point drift every day trains sellers to ignore the panel."""
    cur = {"dcr": 85.4, "median_response_minutes": 42.0, "completed_deals": 20,
           "pending_deals": 2, "overall_rating": 7.6, "rank_position": 20}
    out = build_advice(cur, _hist(dcr=[85.0] * 8, response_minutes=[40] * 8,
                                  overall_rating=[7.5] * 8, rank_position=[20] * 8))
    codes = _codes(out["positives"]) | _codes(out["negatives"])
    assert "dcr_up" not in codes and "rating_up" not in codes
