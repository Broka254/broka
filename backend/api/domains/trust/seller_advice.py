"""Seller advice — "working for you" / "working against you".

Deterministic rules over real snapshot deltas. No model call.

WHY NOT AN LLM
==============
Zeno cannot see a trend. Asked "how is this seller doing", it would receive
today's numbers and infer a direction it has no evidence for — and phrase
the guess fluently, which is worse than phrasing it badly. The whole value
of this panel is that "your response time has slipped" is a fact the system
can prove from two snapshots, not an impression.

It is also billed per call, on a $2 balance, for output that is a handful of
comparisons.

So: rules, over `SellerMetricSnapshot` history, with the numbers quoted back
so a seller can check the claim.

DESIGN RULES
============
Every card must satisfy three things, or it does not ship:

  * **Provable.** It cites a real delta between two real snapshots, or a
    current value against a stated threshold. No adjectives without a number
    behind them.
  * **Actionable.** A seller reading it must know what to DO. "Your DCR is
    low" is a verdict; "three deals closed off-platform this month — those
    don't count toward your rating" is an instruction.
  * **Honest about direction.** A negative card is not softened into a
    positive one. The panel exists to change behaviour, and a seller who
    only ever sees green learns nothing from it.

Positives are capped and negatives are ordered worst-first, because a wall
of twelve cards is read as decoration. The point is the two or three things
worth doing this week.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional

# How far back to compare. A week is long enough that daily noise cancels
# and short enough that the advice is about what the seller did recently.
COMPARISON_WINDOW_DAYS = 7

# Deltas smaller than these are noise, not news. Without a floor the panel
# would announce a 0.1-point rating move every day and train sellers to
# ignore it.
MIN_RATING_DELTA        = 0.3
MIN_DCR_DELTA           = 2.0     # percentage points
MIN_RESPONSE_DELTA_PCT  = 15.0    # relative change in median minutes

# Absolute thresholds for "this is a problem regardless of trend".
SLOW_RESPONSE_MINUTES   = 180.0   # 3h median — a buyer has moved on
WEAK_DCR_PERCENT        = 70.0
HEAVY_BACKLOG_RATIO     = 0.5     # pending >= half of all deals

MAX_POSITIVES = 4
MAX_NEGATIVES = 4
MAX_RECOMMENDATIONS = 3


@dataclass(frozen=True)
class AdviceCard:
    kind: str        # "positive" | "negative"
    code: str        # stable id, so the client can theme or dismiss one
    title: str
    detail: str
    severity: int = 0   # negatives only; higher sorts first


def _fmt_duration(minutes: Optional[float]) -> str:
    if minutes is None:
        return "unknown"
    if minutes < 60:
        return f"{round(minutes)} min"
    if minutes < 1440:
        return f"{minutes / 60:.1f} hr"
    return f"{minutes / 1440:.1f} days"


def _pick(history: List[dict], days_ago: int) -> Optional[dict]:
    """Snapshot closest to `days_ago` days back, or None.

    Closest rather than exact: the nightly job can miss a day, and a
    comparison that silently returns nothing whenever one snapshot is
    absent would make the panel disappear for a week after a single
    failed run.
    """
    if len(history) < 2:
        return None
    idx = max(0, len(history) - 1 - days_ago)
    return history[idx] if idx < len(history) - 1 else history[0]


def build_advice(current: Dict, history: List[dict]) -> Dict[str, List[Dict]]:
    """Return {"positives": [...], "negatives": [...]}.

    `current` is the metrics endpoint's `current` block; `history` its daily
    series, oldest first.
    """
    pos: List[AdviceCard] = []
    neg: List[AdviceCard] = []

    past = _pick(history, COMPARISON_WINDOW_DAYS)

    dcr       = current.get("dcr")
    response  = current.get("median_response_minutes")
    completed = current.get("completed_deals") or 0
    pending   = current.get("pending_deals") or 0
    rating    = current.get("overall_rating")

    # ── Trends (need history) ────────────────────────────────────────────
    if past:
        if rating is not None and past.get("overall_rating") is not None:
            d = rating - past["overall_rating"]
            if d >= MIN_RATING_DELTA:
                pos.append(AdviceCard(
                    "positive", "rating_up", "Your rating is climbing",
                    f"Up {d:.1f} points in the last week, now {rating:.1f}/10. "
                    f"Buyers see this on every listing you post."))
            elif d <= -MIN_RATING_DELTA:
                neg.append(AdviceCard(
                    "negative", "rating_down", "Your rating has slipped",
                    f"Down {abs(d):.1f} points this week, now {rating:.1f}/10. "
                    f"The fastest thing to fix is usually reply speed.",
                    severity=2))

        if dcr is not None and past.get("dcr") is not None:
            d = dcr - past["dcr"]
            if d >= MIN_DCR_DELTA:
                pos.append(AdviceCard(
                    "positive", "dcr_up", "More deals are closing on BROKA",
                    f"Your completion rate is up {d:.1f} points, now {dcr:.0f}%. "
                    f"This is the heaviest factor in your rating."))
            elif d <= -MIN_DCR_DELTA:
                neg.append(AdviceCard(
                    "negative", "dcr_down", "Deals are leaving the platform",
                    f"Your completion rate fell {abs(d):.1f} points to {dcr:.0f}%. "
                    f"A deal only counts once payment goes through BROKA escrow.",
                    severity=4))

        if response is not None and past.get("response_minutes"):
            old = past["response_minutes"]
            change_pct = (response - old) / old * 100
            if change_pct <= -MIN_RESPONSE_DELTA_PCT:
                pos.append(AdviceCard(
                    "positive", "response_up", "You're replying faster",
                    f"Median reply time is down from {_fmt_duration(old)} to "
                    f"{_fmt_duration(response)}. Faster replies close more deals."))
            elif change_pct >= MIN_RESPONSE_DELTA_PCT:
                neg.append(AdviceCard(
                    "negative", "response_down", "You're taking longer to reply",
                    f"Median reply time has gone from {_fmt_duration(old)} to "
                    f"{_fmt_duration(response)}. Buyers usually message several "
                    f"sellers at once.",
                    severity=3))

        if past.get("rank_position") and current.get("rank_position"):
            # Lower is better, so an improvement is a DECREASE. Stating that
            # explicitly because every other metric here goes the other way
            # and the sign is easy to invert by accident.
            moved = past["rank_position"] - current["rank_position"]
            if moved > 0:
                pos.append(AdviceCard(
                    "positive", "rank_up", "You've moved up the rankings",
                    f"Up {moved} places this week, now #{current['rank_position']}. "
                    f"Higher-ranked listings show first in search."))

    # ── Absolutes (work with no history at all) ──────────────────────────
    already_said_response = any(c.code == "response_down" for c in neg)
    if (response is not None and response >= SLOW_RESPONSE_MINUTES
            and not already_said_response):
        neg.append(AdviceCard(
            "negative", "response_slow", "Buyers are waiting too long",
            f"You take {_fmt_duration(response)} to reply on average. Replying "
            f"within the hour is the single fastest way to lift your rating.",
            severity=5))
    elif response is not None and response <= 30:
        pos.append(AdviceCard(
            "positive", "response_fast", "You reply quickly",
            f"Median reply under {_fmt_duration(response)}. That is a real "
            f"advantage over sellers who take hours."))

    # Only if the trend card didn't already make this point. Firing both
    # says the same thing twice in different words, which reads as padding
    # and costs one of the four slots that should hold a different problem.
    already_said_dcr = any(c.code == "dcr_down" for c in neg)
    if dcr is not None and dcr < WEAK_DCR_PERCENT and completed > 0 and not already_said_dcr:
        neg.append(AdviceCard(
            "negative", "dcr_weak", "Too many deals finish off-platform",
            f"Your completion rate is {dcr:.0f}%. Deals settled in cash outside "
            f"BROKA don't count, and they leave you without escrow protection "
            f"if the buyer disputes.",
            severity=4))

    total = completed + pending
    if total > 0 and pending / total >= HEAVY_BACKLOG_RATIO and pending >= 3:
        neg.append(AdviceCard(
            "negative", "backlog", f"{pending} deals are still open",
            f"{pending} of your {total} deals haven't been completed. Open deals "
            f"hold your rating down until they close either way.",
            severity=3))

    if completed == 0 and pending == 0:
        pos.append(AdviceCard(
            "positive", "welcome", "You're starting with a clean slate",
            "New sellers begin at a neutral rating, not zero. Your first few "
            "completed deals will move it most."))

    neg.sort(key=lambda c: -c.severity)
    return {
        "positives": [vars(c) for c in pos[:MAX_POSITIVES]],
        "negatives": [vars(c) for c in neg[:MAX_NEGATIVES]],
        "recommendations": _recommendations(current),
    }


def _recommendations(current: Dict) -> List[Dict]:
    """What to do next - actions, and the features that make them easier.

    Distinct from the two panels above, and the distinction is the point.
    "Working for you" and "needs attention" are both DIAGNOSIS: here is what
    the numbers say. This is PRESCRIPTION: here is what to do about it, and
    which part of the app does it.

    Each action is paired with the mechanism that makes it achievable,
    because "reply faster" without one is a nag rather than advice.

    Kept short. Three suggestions a seller might act on beat ten they scroll
    past, and a list that reads as a feature tour stops being read at all.
    """
    recs: List[Dict] = []

    response = current.get("median_response_minutes")
    dcr = current.get("dcr")
    pending = current.get("pending_deals") or 0
    completed = current.get("completed_deals") or 0

    if response is not None and response > 60:
        recs.append({
            "code": "rec_response",
            "title": "Cut your reply time",
            "detail": (
                f"You are averaging {_fmt_duration(response)}. Turn on chat "
                f"notifications and let Zeno answer availability questions "
                f"while you are busy - the clock stops when the buyer gets an "
                f"answer, not when you get to your phone."
            ),
            "action": "notifications",
        })

    if dcr is not None and dcr < 85 and completed > 0:
        recs.append({
            "code": "rec_escrow",
            "title": "Take your next deal through escrow",
            "detail": (
                "The buyer pays in, you get released on delivery. It removes "
                "the part of the conversation where a stranger has to decide "
                "whether to trust you with their money - and it is the only "
                "kind of deal that counts toward your completion rate and "
                "your ranking."
            ),
            "action": "escrow",
        })

    if pending >= 3:
        recs.append({
            "code": "rec_close_pending",
            "title": f"Close out your {pending} open deals",
            "detail": (
                "Each one sits against your record until it resolves. "
                "Completing or cancelling clears the drag either way - an "
                "honest cancellation costs you far less than a deal left "
                "hanging."
            ),
            "action": "deals",
        })

    if completed == 0:
        recs.append({
            "code": "rec_first_deal",
            "title": "Get your first deal on the board",
            "detail": (
                "Buyers have no way to judge a seller with no record. One "
                "completed deal through BROKA does more for how you rank "
                "than anything else available to you right now."
            ),
            "action": "deals",
        })

    recs = recs[:MAX_RECOMMENDATIONS]
    # The store always comes last, and always appears - see below.
    recs.append(dict(_STORE_RECOMMENDATION))
    return recs


# Always present, always last.
#
# Not an upsell: it is free. It is the feature most sellers do not know
# exists, and the one that changes what BROKA is for them - from a place
# they post items to a shop they own.
#
# The wording leads with what the seller gets rather than what the platform
# wants, because here those are the same thing. A seller sharing their store
# link on WhatsApp status is advertising their own business; that it also
# brings their audience to BROKA is a consequence, not the pitch. Leading
# with the platform's interest would be both less persuasive and less
# honest.
#
# "One link shows everything you sell" is the concrete benefit for someone
# running 40 listings, which is what most real businesses on a marketplace
# look like - and what BROKA had no way to represent before this existed.
_STORE_RECOMMENDATION = {
    "code": "rec_store",
    "title": "Stop posting one item at a time",
    # Short on purpose.
    #
    # The previous version was two full paragraphs inside a card the seller
    # had not asked to read - the whole pitch, delivered before they had
    # shown any interest in it. A recommendation card has one job: earn the
    # tap. The argument belongs on the screen behind it, where someone who
    # opted in will actually read it.
    #
    # Leads with the problem rather than the feature. "Create an online
    # store" describes what the button does; "stop posting one item at a
    # time" describes what the seller is already tired of.
    "detail": (
        "Your own storefront, one link, everything you sell behind it — "
        "free, and yours to share anywhere."
    ),
    "cta": "See how it works",
    "action": "store",
    "featured": True,
}
