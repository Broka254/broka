"""Insights: what the founder should look at first, and why.

Deterministic rules over api/core/intelligence.py's figures - no model
call, so the same numbers always give the same advice and every insight
carries the evidence it was drawn from. Each rule names the decision it
supports (BUSINESS_MODEL_REVIEW.md's liquidity bar and rollback rule, the
Day-30 targets, the complaint deadlines) rather than flagging any change.

An insight:
    id         stable across runs, so the dashboard can key on it
    severity   critical | warning | opportunity | info | positive
    area       liquidity | growth | supply | demand | sellers | trust | money | targets
    title      one line, with the number in it
    detail     why it matters and what the rule compared
    action     {label, href} into the dashboard, or None
    evidence   the inputs, for the report and for anyone who doubts it
"""
from __future__ import annotations

from typing import Optional

from api.core.intelligence import (
    COMPLAINT_SLA_HOURS,
    LIQUIDITY_TARGET_PCT,
    REPLY_TARGET_PCT,
)

SEVERITY_ORDER = {"critical": 0, "warning": 1, "opportunity": 2, "info": 3, "positive": 4}
# Below this many events a percentage change is noise, not a trend.
MIN_VOLUME = 5
# BUSINESS_MODEL_REVIEW.md 4: a category goes back to free when new
# listings per week fall more than 40% for two weeks running.
ROLLBACK_DROP_PCT = -40.0
GROWTH_SWING_PCT = 30.0
MAX_INSIGHTS = 14


def _kes(minor: int) -> str:
    return f"KES {minor / 100:,.0f}"


def _insight(id_: str, severity: str, area: str, title: str, detail: str, *,
             action: Optional[tuple[str, str]] = None, evidence: Optional[dict] = None,
             weight: float = 0.0) -> dict:
    return {
        "id": id_,
        "severity": severity,
        "area": area,
        "title": title,
        "detail": detail,
        "action": {"label": action[0], "href": action[1]} if action else None,
        "evidence": evidence or {},
        "_weight": weight,
    }


def build_insights(*, pulse: dict, categories: Optional[dict] = None,
                   sellers: Optional[dict] = None) -> list[dict]:
    m = pulse["metrics"]
    out: list[dict] = []
    days = pulse["window"]["days"]
    period = "this week" if abs(days - 7) < 0.01 else f"these {days:g} days"

    # ── Trust: complaints past their deadline come first ──────────────────
    complaints = pulse.get("complaints") or {}
    breached = int(complaints.get("sla_breached") or 0)
    if breached:
        urgent = int(complaints.get("sla_breached_urgent") or 0)
        out.append(_insight(
            "complaints_sla", "critical", "trust",
            f"{breached} complaint{'s' if breached != 1 else ''} past the first-reply deadline",
            "A complaint without a reply is the one users repeat to other people. "
            f"Deadlines: urgent {COMPLAINT_SLA_HOURS['urgent']}h, high {COMPLAINT_SLA_HOURS['high']}h, "
            f"normal {COMPLAINT_SLA_HOURS['normal']}h."
            + (f" {urgent} of them are urgent." if urgent else ""),
            action=("Answer complaints", "/complaints?queue=overdue"),
            evidence={"sla_breached": breached, "urgent": urgent,
                      "oldest_unanswered_hours": complaints.get("oldest_unanswered_hours")},
            weight=breached * 10 + urgent * 20,
        ))
    for reported in complaints.get("repeat_reported_users") or []:
        count = int(reported.get("complaints_90d") or 0)
        name = reported.get("name") or "One user"
        out.append(_insight(
            f"repeat_reported:{reported.get('user_id')}",
            "critical" if count >= 3 else "warning", "trust",
            f"{name} has {count} complaints against them in 90 days",
            "Several people reporting the same trader is the clearest fraud and conduct "
            "signal BROKA has. Review their deals and chats, and flag them if it holds.",
            action=("Open the user", f"/users/{reported.get('user_id')}"),
            evidence=reported, weight=count,
        ))

    # ── Liquidity: the north-star ─────────────────────────────────────────
    liquidity = pulse["liquidity"]["current"]
    previous_liquidity = pulse["liquidity"]["previous"]
    rate = liquidity.get("rate_pct")
    if rate is not None and liquidity["eligible"] >= MIN_VOLUME:
        evidence = {"rate_pct": rate, "eligible": liquidity["eligible"],
                    "with_buyer_contact": liquidity["with_buyer_contact"],
                    "previous_rate_pct": previous_liquidity.get("rate_pct"),
                    "target_pct": LIQUIDITY_TARGET_PCT}
        if rate < LIQUIDITY_TARGET_PCT:
            out.append(_insight(
                "liquidity", "critical" if rate < LIQUIDITY_TARGET_PCT / 2 else "warning", "liquidity",
                f"Only {rate:g}% of new listings got a buyer within 7 days",
                f"{liquidity['with_buyer_contact']} of {liquidity['eligible']} listings heard from a "
                f"buyer in their first week; the bar is {LIQUIDITY_TARGET_PCT:g}%. Sellers who hear "
                "nothing do not list again - bring buyers to the categories that have the stock.",
                action=("See demand by category", "/intelligence"),
                evidence=evidence, weight=LIQUIDITY_TARGET_PCT - rate,
            ))
        else:
            out.append(_insight(
                "liquidity", "positive", "liquidity",
                f"{rate:g}% of new listings got a buyer within 7 days",
                f"Above the {LIQUIDITY_TARGET_PCT:g}% bar: listings are finding buyers. This is "
                "the condition BROKA set for charging in a category.",
                action=("See demand by category", "/intelligence"), evidence=evidence,
            ))

    # ── Growth ────────────────────────────────────────────────────────────
    listings = m["new_listings"]
    if (listings["previous"] or 0) >= MIN_VOLUME and listings["change_pct"] is not None \
            and listings["change_pct"] <= ROLLBACK_DROP_PCT:
        out.append(_insight(
            "listings_drop", "warning", "growth",
            f"New listings fell {abs(listings['change_pct']):g}% on the previous period",
            f"{listings['current']} against {listings['previous']}. BROKA's rollback rule returns a "
            "category to free when weekly listings fall more than 40% two weeks running; check "
            "whether a price change or an app release caused it.",
            action=("Supply by category", "/intelligence"),
            evidence=listings, weight=abs(listings["change_pct"]),
        ))
    users = m["new_users"]
    if (users["previous"] or 0) >= MIN_VOLUME and users["change_pct"] is not None:
        if users["change_pct"] >= GROWTH_SWING_PCT:
            out.append(_insight(
                "signups_up", "positive", "growth",
                f"Sign-ups up {users['change_pct']:g}% ({users['current']} {period})",
                "Whatever brought them, find out and do more of it; then check the funnel to "
                "see whether they go on to list or buy.",
                action=("Growth funnel", "/growth"), evidence=users,
            ))
        elif users["change_pct"] <= -GROWTH_SWING_PCT:
            out.append(_insight(
                "signups_down", "warning", "growth",
                f"Sign-ups down {abs(users['change_pct']):g}% ({users['current']} {period})",
                f"Down from {users['previous']}. Look for a paused campaign, a broken sign-up "
                "step or an OTP/SMS outage.",
                action=("Growth funnel", "/growth"), evidence=users,
                weight=abs(users["change_pct"]),
            ))

    balance = pulse.get("balance") or {}
    buyers, sellers_active = int(balance.get("active_buyers") or 0), int(balance.get("active_sellers") or 0)
    if sellers_active >= 3 and buyers < sellers_active:
        out.append(_insight(
            "buyer_shortage", "warning", "demand",
            f"{buyers} active buyers for {sellers_active} active sellers",
            "Buyers are the side BROKA lacks: a seller who gets no buyer leaves. Put acquisition "
            "into buyers before recruiting more sellers.",
            action=("Growth funnel", "/growth"), evidence=balance,
            weight=sellers_active - buyers,
        ))

    # ── Sellers ───────────────────────────────────────────────────────────
    response = pulse["seller_response"]["current"]
    if response.get("rate_pct") is not None and response["eligible"] >= MIN_VOLUME \
            and response["rate_pct"] < REPLY_TARGET_PCT:
        out.append(_insight(
            "reply_rate", "warning", "sellers",
            f"Sellers answered {response['rate_pct']:g}% of new chats within 24 hours",
            f"{response['replied_24h']} of {response['eligible']} buyers got a reply from the seller "
            f"within a day (bar {REPLY_TARGET_PCT:g}%). Slow sellers lose buyers BROKA paid to bring.",
            action=("Seller responsiveness", "/intelligence#sellers"), evidence=response,
            weight=REPLY_TARGET_PCT - response["rate_pct"],
        ))
    if sellers:
        waiting = int(sellers.get("waiting_total") or 0)
        if waiting:
            first = (sellers.get("waiting") or [{}])[0]
            out.append(_insight(
                "buyers_waiting", "warning", "sellers",
                f"{waiting} buyer{'s' if waiting != 1 else ''} waiting over 24h for a seller",
                f"Across {sellers.get('sellers_with_waiting_buyers', 0)} sellers. "
                + (f"{first.get('name') or 'One seller'} has {first.get('waiting')} waiting, the "
                   f"longest for {first.get('oldest_wait_hours')}h. " if first.get("waiting") else "")
                + "A call or SMS to these sellers today saves the sale.",
                action=("Sellers to call", "/intelligence#sellers"),
                evidence={"waiting_total": waiting,
                          "sellers": sellers.get("sellers_with_waiting_buyers")},
                weight=waiting,
            ))
        stale = int(sellers.get("stale_total") or 0)
        if stale:
            out.append(_insight(
                "stale_listings", "info", "supply",
                f"{stale} live listing{'s' if stale != 1 else ''} with no buyer contact in 14+ days",
                "Prompt these sellers to refresh the price and photos, or let the listing go; "
                "dead stock makes the feed look empty of good deals.",
                action=("Stale listings", "/intelligence#stale"), evidence={"stale_total": stale},
            ))

    # ── Supply and demand by category ─────────────────────────────────────
    if categories:
        rows = categories.get("categories") or []
        gaps = [c for c in rows if c["signal"] in ("unserved", "undersupplied")]
        gaps.sort(key=lambda c: (-(c["demand"] - c["supply_live"]), c["label"]))
        for c in gaps[:2]:
            out.append(_insight(
                f"undersupplied:{c['key']}", "opportunity", "supply",
                f"Recruit sellers for {c['label']}: {c['demand']} buyer signals, "
                f"{c['supply_live']} live listing{'s' if c['supply_live'] != 1 else ''}",
                c["recommendation"]
                + (f" {c['buy_agent_unmatched']} Buying Agent requests here found nothing."
                   if c.get("buy_agent_unmatched") else ""),
                action=("Category detail", f"/intelligence?category={c['key']}"),
                evidence={k: c[k] for k in ("demand", "supply_live", "buyer_threads", "interests",
                                            "buy_agent_requests", "buy_agent_unmatched")},
                weight=c["demand"] - c["supply_live"],
            ))
        gluts = [c for c in rows if c["signal"] == "oversupplied"]
        gluts.sort(key=lambda c: (-c["supply_live"], c["label"]))
        for c in gluts[:2]:
            out.append(_insight(
                f"oversupplied:{c['key']}", "opportunity", "demand",
                f"{c['label']} has {c['supply_live']} live listings but {c['demand']} buyer signals",
                c["recommendation"],
                action=("Category detail", f"/intelligence?category={c['key']}"),
                evidence={k: c[k] for k in ("demand", "supply_live", "median_price_kes")},
                weight=c["supply_live"],
            ))

    unmet = int(m["buy_agent_unmet_open"]["current"] or 0)
    if unmet:
        out.append(_insight(
            "buy_agent_unmet", "opportunity", "demand",
            f"{unmet} Buying Agent request{'s' if unmet != 1 else ''} with no match yet",
            "Buyers told BROKA exactly what they want and nothing listed fits. Each one is a "
            "listing a seller could post today.",
            action=("Demand by category", "/intelligence"), evidence={"unmet_open": unmet},
            weight=unmet,
        ))

    # ── Trust signals ─────────────────────────────────────────────────────
    fraud = m["fraud_flags"]
    if fraud["current"]:
        out.append(_insight(
            "fraud_flags", "warning", "trust",
            f"{fraud['current']} new fraud flag{'s' if fraud['current'] != 1 else ''} {period}",
            "Review them before the users involved complete another deal.",
            action=("Fraud queue", "/fraud?state=open"), evidence=fraud,
            weight=fraud["current"] * 2,
        ))
    disputes = m["disputes_opened"]
    if disputes["current"]:
        out.append(_insight(
            "disputes", "info", "trust",
            f"{disputes['current']} dispute{'s' if disputes['current'] != 1 else ''} opened {period}",
            "Each is a deal where trust broke down; the dispute engine is handling them.",
            action=("Disputes", "/disputes"), evidence=disputes,
        ))

    # ── Money ─────────────────────────────────────────────────────────────
    break_even = pulse["break_even"]
    monetisation = pulse.get("monetisation") or {}
    income = m["income_minor"]
    if not income["current"] and not income["previous"] and not any(
        monetisation.get(k) for k in ("listing_fees_enabled", "premium_enabled", "store_billing_enabled")
    ):
        out.append(_insight(
            "monetisation_off", "info", "money",
            "No income: listing fees, Premium and store billing are all switched off",
            f"Fixed running costs are {_kes(break_even['fixed_monthly_cost_minor'])} a month. "
            "Switch fees on per category once it clears the liquidity bar.",
            action=("Revenue", "/revenue"), evidence=monetisation,
        ))
    elif break_even["fixed_monthly_cost_minor"]:
        coverage = break_even.get("coverage_pct")
        if coverage is not None and coverage >= 100:
            out.append(_insight(
                "break_even", "positive", "money",
                f"Income covers {coverage:g}% of fixed running costs",
                f"{_kes(break_even['net_30d_minor'])} net over 30 days against "
                f"{_kes(break_even['fixed_monthly_cost_minor'])} a month.",
                action=("Revenue", "/revenue"), evidence=break_even,
            ))
        else:
            out.append(_insight(
                "break_even", "info", "money",
                f"{_kes(break_even['gap_minor'])} a month short of break-even",
                f"Net income over the last 30 days is {_kes(break_even['net_30d_minor'])} against "
                f"{_kes(break_even['fixed_monthly_cost_minor'])} of fixed costs.",
                action=("Revenue", "/revenue"), evidence=break_even,
            ))

    # ── Day-30 targets ────────────────────────────────────────────────────
    targets = pulse.get("targets") or []
    met = [t for t in targets if t["met"]]
    behind = [t for t in targets if not t["met"]]
    if met:
        out.append(_insight(
            "targets_met", "positive", "targets",
            f"{len(met)} of {len(targets)} Day-30 targets met",
            "Met: " + ", ".join(t["label"] for t in met) + ".",
            action=("Command Center", "/"), evidence={"met": [t["key"] for t in met]},
        ))
    if behind:
        furthest = min(behind, key=lambda t: t["progress_pct"] or 0)
        out.append(_insight(
            "targets_behind", "info", "targets",
            f"Furthest behind: {furthest['label']} at {furthest['progress_pct'] or 0:g}% of target",
            "Still open: " + ", ".join(f"{t['label']} ({t['progress_pct'] or 0:g}%)" for t in behind) + ".",
            action=("Command Center", "/"), evidence={"behind": [t["key"] for t in behind]},
        ))

    out.sort(key=lambda i: (SEVERITY_ORDER[i["severity"]], -i["_weight"], i["id"]))
    for insight in out:
        insight.pop("_weight", None)
    return out[:MAX_INSIGHTS]


def severity_counts(insights: list[dict]) -> dict[str, int]:
    counts = {severity: 0 for severity in SEVERITY_ORDER}
    for insight in insights:
        counts[insight["severity"]] = counts.get(insight["severity"], 0) + 1
    return counts
