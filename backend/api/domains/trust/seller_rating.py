"""Seller Overall Rating — one number out of 10, from the signals that matter.

SPEC SOURCE
===========
Design Journal Vol. 8 §3.1-§3.3 (DCR, Bayesian smoothing, confidence factor)
and Part XVI (eligibility and Sybil corrections). §3.2's DCR already exists
in completion_rate.py and is correct; this module is the layer above it.

THE PROBLEM THIS SOLVES
=======================
A seller of two years who completed 88 of 97 deals must not rank below a
week-old seller who completed 2 of 2. Naive completed/total gives the new
seller 100% and the veteran 90.7%.

§3.2 already fixes that for DCR itself by smoothing toward a prior. The same
trap reappears one level up: a composite built from perfect-looking thin
numbers produces a perfect-looking rating. So the composite is smoothed the
same way, against the same kind of evidence count. That is the core idea
here — **confidence is applied to the whole rating, not just to DCR.**

COMPONENTS AND WHY EACH IS WEIGHTED AS IT IS
============================================
Each is normalised to 0..1, then weighted. The weights encode the product
intent: the rating exists to push sellers toward completing deals ON BROKA
and replying quickly, so those two dominate and everything else is texture.

  DCR            0.45  The point of the whole system. A deal only counts as
                       completed if it went through the platform, so this is
                       the single number that says "does this seller keep
                       business here". Already Bayesian-smoothed upstream.

  Response time  0.25  Second-largest on purpose. It is the lever a seller
                       can move TODAY, without waiting for deals to close -
                       which is what makes the rating feel actionable rather
                       than like a verdict. Faster replies also cause higher
                       completion, so weighting it is not double-counting so
                       much as paying for the leading indicator.

  Volume         0.15  Saturating. 90 completed deals should beat 9; 900
                       should barely beat 90. Sqrt-style diminishing returns
                       stop an established trader being unreachable.

  Tenure         0.05  Deliberately the smallest weight, and it saturates
                       inside the first ~6 months. Longevity is weak evidence
                       of trustworthiness - a seller who has been here two
                       years and leaks every deal is worse than a careful
                       newcomer - but it is not NO evidence, so it earns a
                       small nudge and nothing more.

  Backlog        0.10  A penalty, not a bonus. Pending deals piling up
                       against few completions means buyers are being left
                       hanging. Measured as a ratio so a busy seller with
                       many pendings AND many completions is not punished
                       for being busy.

CONFIDENCE (§3.3 + Part XVI)
============================
Three multiplicative factors, each 0..1, per §3.3:

  * Evidence volume — Part XVI sets the eligibility bar at 10 completed
    transactions. Below that a seller's own record is not yet the best
    predictor of their behaviour, so the rating leans on the prior.
  * Counterparty uniqueness — Part XVI raised the full-weight threshold to
    10 unique counterparties. Ten deals with one friend is not ten deals.
  * Deal value — Part XVI raised the minimum countable value to KSh 500,
    noting a KSh 2,500 farming attack could buy 100% DCR against the old
    KSh 200 floor.

Low confidence pulls the rating toward NEUTRAL_RATING rather than toward
zero. A new seller is unproven, not bad, and starting everyone at 0/10 would
make the number useless as an incentive on day one.

WHAT THIS MODULE IS NOT
=======================
Pure functions only - no DB, no I/O. Everything here is testable with plain
numbers, which matters because these constants will be argued about and
re-tuned, and the arguing is much cheaper when the function can be run
against scenarios in a second.
"""
from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Optional

# ── Component weights (sum to 1.0 across the positive terms) ────────────────
W_DCR       = 0.45
W_RESPONSE  = 0.25
W_VOLUME    = 0.15
W_TENURE    = 0.05
W_BACKLOG   = 0.10   # penalty term: contributes (1 - backlog_pressure)

# ── Normalisation constants ─────────────────────────────────────────────────

# Response time at which the response component scores 0.5. Chosen because a
# reply inside an hour reads as "attentive" to a buyer deciding between two
# sellers, and beyond a day reads as absent.
RESPONSE_HALFLIFE_MINUTES = 60.0

# Completed deals at which the volume component scores 0.5. 25 is roughly a
# serious trader's first quarter; saturating here keeps the top of the scale
# reachable rather than reserving it for the largest account on the platform.
VOLUME_HALF_SATURATION = 25.0

# Tenure saturates at six months. Past that, more time earns nothing.
TENURE_SATURATION_DAYS = 180.0

# Part XVI: DCR "only counts after 10 completed transactions".
MIN_DEALS_FOR_FULL_CONFIDENCE = 10
# Part XVI: raised from 5. Ten deals with one counterparty is not ten deals.
MIN_UNIQUE_COUNTERPARTIES_FOR_FULL_CONFIDENCE = 10
# Share of deals that must be with distinct buyers for full credit. Above
# this, repeat business is treated as loyalty rather than collusion.
UNIQUENESS_FULL_CREDIT_RATIO = 0.5
# Part XVI: raised from KSh 200 - "a KSh 2,500 farming attack against the old
# thresholds could buy 100% DCR".
MIN_COUNTABLE_DEAL_VALUE_KES = 500.0

# Where an unproven seller sits.
#
# NOT §3.2's Prior_mean of 0.80 rescaled to 8.0, which was the first guess
# and was wrong: DCR's prior answers "how likely is this seller to complete
# a deal", but this composite also contains volume and tenure, which a new
# seller genuinely does not have. Anchoring at 8.0 put an unproven account
# ABOVE a proven good one - a two-deal newcomer outscoring 88-of-97 over two
# years, which is the precise failure this module was written to prevent.
#
# 6.5 is mid-scale: clearly "unproven, not bad", comfortably below any
# seller with a real record, and still high enough to be worth protecting -
# which is what makes the rating an incentive on day one rather than a
# punishment for being new.
NEUTRAL_RATING = 6.5


@dataclass(frozen=True)
class SellerSignals:
    """Everything the rating needs. All optional - absent means "no data"."""
    dcr_percent: Optional[float] = None          # 0-100, from compute_dcr
    median_response_minutes: Optional[float] = None
    completed_deals: int = 0
    pending_deals: int = 0
    days_on_broka: float = 0.0
    unique_counterparties: int = 0
    # Completed deals whose value cleared MIN_COUNTABLE_DEAL_VALUE_KES.
    countable_value_deals: Optional[int] = None


@dataclass(frozen=True)
class RatingBreakdown:
    """The rating plus every intermediate, so the UI can explain itself.

    The seller-facing screen has to say WHY the number moved, and a bare
    float cannot support that. Returning the components is what lets the
    "what's working for you / against you" panel cite a real cause rather
    than guessing at one.
    """
    rating: float              # 0-10, what the seller sees
    raw_rating: float          # 0-10 before confidence shrinkage
    confidence: float          # 0-1
    dcr_component: float
    response_component: float
    volume_component: float
    tenure_component: float
    backlog_component: float


def response_score(median_minutes: Optional[float]) -> float:
    """1.0 for instant, 0.5 at one hour, approaching 0 for very slow.

    Exponential decay rather than a linear ramp or banded tiers. Bands
    invite gaming at the boundary (§2.5's "discrete band gaming" weakness,
    solved there with a sigmoid for the same reason), and a linear ramp
    needs an arbitrary cutoff where "slow" becomes "infinitely slow".

    No data scores 0.7 - the same placeholder completion_rate.py already
    uses for an unmeasured seller, so the two agree.
    """
    if median_minutes is None:
        return 0.7
    if median_minutes <= 0:
        return 1.0
    return math.exp(-math.log(2) * median_minutes / RESPONSE_HALFLIFE_MINUTES)


def volume_score(completed: int) -> float:
    """Saturating in completed deals: 0 at zero, 0.5 at 25, →1 slowly."""
    if completed <= 0:
        return 0.0
    return completed / (completed + VOLUME_HALF_SATURATION)


def tenure_score(days: float) -> float:
    """Saturating within six months, then flat.

    Square-rooted so most of the value accrues early: the difference between
    a one-week and a two-month account is real, the difference between one
    year and two is not.
    """
    if days <= 0:
        return 0.0
    return min(1.0, math.sqrt(days / TENURE_SATURATION_DAYS))


def backlog_score(completed: int, pending: int) -> float:
    """1.0 = healthy, 0.0 = a wall of pending deals going nowhere.

    A RATIO, not a count. A seller with 40 pending and 200 completed is
    busy; a seller with 40 pending and 2 completed is leaving people
    waiting. Penalising the raw count would punish exactly the high-demand
    sellers the platform wants.

    Zero pending scores 1.0 - nothing is stuck.
    """
    if pending <= 0:
        return 1.0
    ratio = pending / max(completed + pending, 1)
    return max(0.0, 1.0 - ratio)


def evidence_weight(s: SellerSignals) -> float:
    """How much of the seller's OWN record to trust, 0..1.

    Purely a volume question - Part XVI puts the eligibility bar at 10
    completed transactions. Below that the record is too short to be the
    better predictor, so the rating leans on the prior instead.

    Kept strictly separate from quality (below), because the two failures
    look identical in a single number and must not be treated alike:
    a seller with two honest deals has ABSENT evidence and deserves the
    benefit of the prior; a seller with ten deals against one counterparty
    has PRESENT evidence that happens to be bad, and must not be handed the
    same benefit. Collapsing both into one confidence factor scored a Sybil
    farm 8.1/10 - shrinking it toward the neutral prior was protecting it.
    """
    return min(1.0, max(s.completed_deals, 0) / MIN_DEALS_FOR_FULL_CONFIDENCE)


def quality_factor(s: SellerSignals) -> float:
    """§3.3 Confidence Factor - how much the record can be believed, 0..1.

    Multiplies the score DOWN. Two independent gates, multiplied so either
    one alone can sink it:

    * Counterparty uniqueness, measured as unique/deals rather than against
      a fixed count. The ratio is what actually detects the repeat-pair
      attack §3.3 names, and it does not punish a genuine newcomer: two
      deals with two different buyers is a clean 1.0, while ten deals with
      one buyer is 0.1. A fixed threshold would score both of those the
      same way and conflate "new" with "farming".
    * Deal value, as the share of completed deals clearing Part XVI's
      KSh 500 floor - raised there from KSh 200 precisely because "a
      KSh 2,500 farming attack against the old thresholds could buy 100%
      DCR".

    Each gate floors at 0.5 rather than 0, so a single bad signal halves the
    score instead of erasing it. An accusation this strong should need both.
    """
    deals = max(s.completed_deals, 0)
    if deals == 0:
        return 1.0   # nothing to disbelieve yet; evidence_weight handles it

    # Full credit once half the deals are with distinct buyers.
    #
    # A raw unique/deals ratio punishes REPEAT CUSTOMERS, which in a
    # marketplace is the opposite of a fraud signal - 88 deals across 70
    # buyers means 18 people came back, and scoring that below a two-deal
    # newcomer recreated exactly the unfairness this module exists to fix.
    # Real collusion looks like 0.1-0.3, not 0.8, so the gate only bites
    # below UNIQUENESS_FULL_CREDIT_RATIO.
    uniq_ratio = min(1.0, (max(s.unique_counterparties, 0) / deals)
                     / UNIQUENESS_FULL_CREDIT_RATIO)

    # Unknown -> assume they counted. Punishing a seller for a metric the
    # platform has not started collecting is not a fraud signal.
    if s.countable_value_deals is None:
        value_ratio = 1.0
    else:
        value_ratio = min(1.0, max(s.countable_value_deals, 0) / deals)

    return (0.5 + 0.5 * uniq_ratio) * (0.5 + 0.5 * value_ratio)


def overall_rating(s: SellerSignals) -> RatingBreakdown:
    """The seller's headline number, 0-10.

    Shrunk toward NEUTRAL_RATING by the confidence factor, for the same
    reason §3.2 shrinks DCR toward Prior_mean: without it, two perfect deals
    produce a perfect rating and the veteran with 88 of 97 ranks below a
    week-old account. That failure is the whole reason this module exists,
    so the correction belongs at the top level, not only inside DCR.
    """
    dcr = (s.dcr_percent if s.dcr_percent is not None else 80.0) / 100.0
    dcr = min(max(dcr, 0.0), 1.0)

    resp    = response_score(s.median_response_minutes)
    vol     = volume_score(s.completed_deals)
    ten     = tenure_score(s.days_on_broka)
    backlog = backlog_score(s.completed_deals, s.pending_deals)

    raw = (W_DCR * dcr + W_RESPONSE * resp + W_VOLUME * vol
           + W_TENURE * ten + W_BACKLOG * backlog) * 10.0

    # Quality multiplies DOWN; evidence decides how much of the result to
    # believe versus the prior. Order matters: quality is applied BEFORE
    # shrinkage, so a farmed record is dragged down and then only partly
    # rescued by the prior, instead of being averaged back up toward it.
    quality  = quality_factor(s)
    evidence = evidence_weight(s)
    rating = evidence * (raw * quality) + (1 - evidence) * NEUTRAL_RATING

    return RatingBreakdown(
        rating=round(min(max(rating, 0.0), 10.0), 1),
        raw_rating=round(raw, 2),
        confidence=round(evidence * quality, 3),
        dcr_component=round(dcr, 3),
        response_component=round(resp, 3),
        volume_component=round(vol, 3),
        tenure_component=round(ten, 3),
        backlog_component=round(backlog, 3),
    )


# ── Credibility ─────────────────────────────────────────────────────────────
#
# "How much would you trust this seller?", 0-10, driven mainly by how long
# they have been here and whether their deals actually close on BROKA.
#
# Distinct from the Overall Rating on purpose, and the difference is the
# whole reason it exists. The rating is about PERFORMANCE - it moves with
# reply speed and backlog, it can be lifted this week, and it is meant to.
# Credibility is about TRACK RECORD: it accumulates, it cannot be
# fixed in an afternoon, and it is the number a buyer wants when deciding
# whether to send money to a stranger.
#
# That makes the tenure weighting the opposite of the rating's. There,
# tenure is damped to 0.05 so longevity cannot carry a bad seller. Here it
# is deliberately heavy, because "has been trading here for two years" is
# exactly the kind of evidence credibility is asking about - a Sybil account
# can fake a week, not a year.
#
# DCR still leads, though, and by more than tenure. Time alone is not
# credibility: a seller who has been here two years and routes every deal
# off-platform has demonstrated the opposite of trustworthiness, and must
# not out-score a careful six-month-old account.
W_CRED_DCR    = 0.55
W_CRED_TENURE = 0.30
W_CRED_VOLUME = 0.15

# Credibility saturates later than the rating's tenure term - two years
# rather than six months - because this is the axis where the long haul is
# supposed to count for something.
CREDIBILITY_TENURE_SATURATION_DAYS = 730.0


def credibility_score(s: SellerSignals) -> float:
    """0-10. Track record, not current form.

    Shrunk toward NEUTRAL_RATING by the same evidence/quality split the
    Overall Rating uses, so a farmed account cannot buy credibility with
    volume and a new account is shown as unproven rather than untrustworthy.
    """
    dcr = min(max((s.dcr_percent if s.dcr_percent is not None else 80.0) / 100.0,
                  0.0), 1.0)

    days = max(s.days_on_broka, 0.0)
    tenure = min(1.0, math.sqrt(days / CREDIBILITY_TENURE_SATURATION_DAYS))

    vol = volume_score(s.completed_deals)

    raw = (W_CRED_DCR * dcr + W_CRED_TENURE * tenure + W_CRED_VOLUME * vol) * 10.0

    quality = quality_factor(s)
    evidence = evidence_weight(s)
    value = evidence * (raw * quality) + (1 - evidence) * NEUTRAL_RATING
    return round(min(max(value, 0.0), 10.0), 1)

