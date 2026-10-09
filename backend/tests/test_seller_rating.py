"""Overall Rating (Design Journal Vol.8 §3.2/§3.3, Part XVI).

These are the scenarios the rating exists to get right. Each one is a
fairness claim someone could argue with, so each is pinned rather than left
to a reviewer's intuition about a float.
"""
import pytest

from api.domains.trust.seller_rating import (
    NEUTRAL_RATING, SellerSignals, evidence_weight, overall_rating,
    quality_factor, response_score, tenure_score, volume_score,
)


VETERAN = SellerSignals(dcr_percent=90.7, median_response_minutes=25,
                        completed_deals=88, pending_deals=9,
                        days_on_broka=730, unique_counterparties=70)
NEWCOMER = SellerSignals(dcr_percent=100.0, median_response_minutes=25,
                         completed_deals=2, pending_deals=0,
                         days_on_broka=7, unique_counterparties=2)
SYBIL = SellerSignals(dcr_percent=100.0, median_response_minutes=5,
                      completed_deals=10, pending_deals=0, days_on_broka=30,
                      unique_counterparties=1, countable_value_deals=0)


def test_veteran_outranks_a_perfect_newcomer():
    """The whole reason this module exists.

    88 of 97 over two years must beat 2 of 2 in week one. Naive
    completed/total gives the newcomer 100% and the veteran 90.7%.
    """
    assert overall_rating(VETERAN).rating > overall_rating(NEWCOMER).rating


def test_unproven_seller_sits_at_the_neutral_anchor():
    """No history means unproven, not bad."""
    blank = SellerSignals(days_on_broka=1)
    assert overall_rating(blank).rating == pytest.approx(NEUTRAL_RATING, abs=0.1)


def test_neutral_anchor_is_below_a_proven_good_seller():
    """Guards the bug that appeared while building this.

    Anchoring unproven sellers at 8.0 (§3.2's Prior_mean rescaled) put a
    two-deal newcomer ABOVE the veteran - reintroducing the exact
    unfairness the module was written to remove, one level up.
    """
    assert NEUTRAL_RATING < overall_rating(VETERAN).rating


def test_sybil_farm_is_punished_not_smoothed():
    """Ten deals with one buyer, all under the value floor.

    Must NOT be rescued by the prior. The first implementation collapsed
    evidence and quality into one confidence factor, so this scored 8.1/10 -
    shrinking a farmed record toward the neutral prior was protecting it.
    """
    assert overall_rating(SYBIL).rating < 4.0
    assert overall_rating(SYBIL).rating < overall_rating(NEWCOMER).rating - 2


def test_repeat_customers_are_not_treated_as_collusion():
    """88 deals across 70 buyers means 18 people came back.

    A raw unique/deals ratio scored that below a two-deal newcomer. In a
    marketplace, repeat business is loyalty, not a fraud signal.
    """
    assert quality_factor(VETERAN) == pytest.approx(1.0, abs=0.01)


def test_tenure_is_damped():
    """Time on BROKA must not carry a seller.

    Five years versus six months is worth well under a point, per the
    brief: minimise tenure, maximise DCR and response.
    """
    base = dict(dcr_percent=90, median_response_minutes=30, completed_deals=40,
                pending_deals=5, unique_counterparties=35)
    six_months = overall_rating(SellerSignals(days_on_broka=180, **base)).rating
    five_years = overall_rating(SellerSignals(days_on_broka=1825, **base)).rating
    assert five_years - six_months < 0.5


def test_response_time_is_the_biggest_lever_a_seller_can_move_today():
    """Same seller, replies fast versus slow, must differ substantially."""
    base = dict(dcr_percent=90, completed_deals=40, pending_deals=5,
                days_on_broka=400, unique_counterparties=35)
    fast = overall_rating(SellerSignals(median_response_minutes=5, **base)).rating
    slow = overall_rating(SellerSignals(median_response_minutes=2880, **base)).rating
    assert fast - slow > 2.0


def test_reply_speed_moves_the_rating_before_any_deal_closes():
    """With in-app payments off no deal can complete on BROKA, so every
    seller has zero completed deals - and the rating shrank everything,
    reply speed included, to the neutral 6.5. A seller answering in five
    minutes and one ignoring buyers for two days were rated the same."""
    base = dict(completed_deals=0, days_on_broka=60)
    fast = overall_rating(SellerSignals(median_response_minutes=5, **base)).rating
    slow = overall_rating(SellerSignals(median_response_minutes=2880, **base)).rating
    assert fast > NEUTRAL_RATING > slow
    assert fast - slow > 2.0


def test_time_on_broka_counts_before_any_deal_closes_but_only_a_little():
    """Still damped, as for a seller with deals: under a point."""
    new = overall_rating(SellerSignals(days_on_broka=1)).rating
    settled = overall_rating(SellerSignals(days_on_broka=365)).rating
    assert 0.3 < settled - new < 1.0


def test_no_deals_and_fast_replies_still_below_a_proven_good_seller():
    """Reply speed counts without deals, but cannot outrank a record."""
    eager = SellerSignals(median_response_minutes=1, completed_deals=0,
                          days_on_broka=730)
    assert overall_rating(eager).rating < overall_rating(VETERAN).rating


def test_leaking_deals_off_platform_costs_the_most():
    """DCR is the heaviest weight - that is the product intent."""
    base = dict(median_response_minutes=30, completed_deals=30, pending_deals=8,
                days_on_broka=730, unique_counterparties=28)
    good = overall_rating(SellerSignals(dcr_percent=95, **base)).rating
    leak = overall_rating(SellerSignals(dcr_percent=41, **base)).rating
    assert good - leak > 2.0


def test_backlog_is_a_ratio_not_a_count():
    """A busy seller with many pendings AND many completions is not punished."""
    busy = SellerSignals(dcr_percent=90, median_response_minutes=20,
                         completed_deals=200, pending_deals=40,
                         days_on_broka=400, unique_counterparties=150)
    stuck = SellerSignals(dcr_percent=90, median_response_minutes=20,
                          completed_deals=2, pending_deals=40,
                          days_on_broka=400, unique_counterparties=2)
    idle = SellerSignals(dcr_percent=90, median_response_minutes=20,
                         completed_deals=200, pending_deals=0,
                         days_on_broka=400, unique_counterparties=150)
    # The margin was 2 while the stuck seller's prior was a flat 6.5; it now
    # carries their own 20-minute replies and 400 days, as the busy one's
    # record does, so the gap is the deal record alone.
    assert overall_rating(busy).rating > overall_rating(stuck).rating + 1.5
    assert overall_rating(idle).rating - overall_rating(busy).rating < 0.3


@pytest.mark.parametrize("fn,lo,hi", [
    (lambda: response_score(None), 0.0, 1.0),
    (lambda: response_score(0), 0.0, 1.0),
    (lambda: response_score(10_000), 0.0, 1.0),
    (lambda: volume_score(0), 0.0, 1.0),
    (lambda: volume_score(100_000), 0.0, 1.0),
    (lambda: tenure_score(-5), 0.0, 1.0),
    (lambda: tenure_score(100_000), 0.0, 1.0),
])
def test_components_stay_in_range(fn, lo, hi):
    """No component may leave 0..1, or the weights stop meaning anything."""
    assert lo <= fn() <= hi


def test_rating_never_leaves_the_scale():
    """Including on absurd input - this number is shown to users."""
    for s in [SellerSignals(dcr_percent=-50, completed_deals=-3, pending_deals=-1),
              SellerSignals(dcr_percent=500, completed_deals=10**6,
                            days_on_broka=10**6, unique_counterparties=10**6,
                            median_response_minutes=-10)]:
        assert 0.0 <= overall_rating(s).rating <= 10.0


def test_evidence_and_quality_are_independent():
    """They answer different questions and must not be collapsed again."""
    thin_honest = SellerSignals(completed_deals=2, unique_counterparties=2)
    thick_farmed = SellerSignals(completed_deals=50, unique_counterparties=1,
                                 countable_value_deals=0)
    assert evidence_weight(thin_honest) < evidence_weight(thick_farmed)
    assert quality_factor(thin_honest) > quality_factor(thick_farmed)
