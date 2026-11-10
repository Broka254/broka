"""Founder reports: the daily, weekly and monthly briefs.

A report is a snapshot of api/core/intelligence.py for one closed period,
plus the insights drawn from it and a written summary, stored in
admin_reports so the archive keeps what the platform looked like then.

Periods are local (REPORT_TZ_OFFSET_HOURS, EAT by default): "yesterday"
is the Kenyan day, a week runs Monday to Sunday, a month is the calendar
month. Their boundaries are stored as naive UTC like every column.

The 5-minute sweep calls generate_due_reports(): each kind's most recent
closed period is written once (the unique (kind, period_start) index makes
a second replica or a retry a no-op), and weekly/monthly reports are
announced in the Alert Centre. Nothing is backfilled: a fresh deployment
writes yesterday, last week and last month, not years of history.
"""
from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core import intelligence
from api.core.config import settings
from api.core.insights import build_insights, severity_counts
from api.models.admin_report import REPORT_KINDS, AdminReport

_log = logging.getLogger(__name__)

PAYLOAD_VERSION = 1

_KIND_TITLES = {"daily": "Daily brief", "weekly": "Weekly brief", "monthly": "Monthly brief"}


# ── Periods ───────────────────────────────────────────────────────────────────

def _offset() -> timedelta:
    return timedelta(hours=settings.report_tz_offset_hours)


def tz_label() -> str:
    hours = settings.report_tz_offset_hours
    if hours == 3:
        return "EAT (UTC+3)"
    return f"UTC{hours:+d}"


def _local_period_start(kind: str, local: datetime) -> datetime:
    day = local.replace(hour=0, minute=0, second=0, microsecond=0)
    if kind == "daily":
        return day
    if kind == "weekly":
        return day - timedelta(days=day.weekday())
    return day.replace(day=1)


def _local_next(kind: str, start: datetime) -> datetime:
    if kind == "daily":
        return start + timedelta(days=1)
    if kind == "weekly":
        return start + timedelta(days=7)
    if start.month == 12:
        return start.replace(year=start.year + 1, month=1)
    return start.replace(month=start.month + 1)


def _local_previous(kind: str, start: datetime) -> datetime:
    if kind == "daily":
        return start - timedelta(days=1)
    if kind == "weekly":
        return start - timedelta(days=7)
    if start.month == 1:
        return start.replace(year=start.year - 1, month=12)
    return start.replace(month=start.month - 1)


def period_label(kind: str, start_utc: datetime, end_utc: datetime) -> str:
    start = start_utc + _offset()
    last_day = end_utc + _offset() - timedelta(days=1)
    if kind == "daily":
        return start.strftime("%a %d %b %Y").replace(" 0", " ")
    if kind == "monthly":
        return start.strftime("%B %Y")
    if start.year != last_day.year:
        return f"{start:%d %b %Y} – {last_day:%d %b %Y}".replace(" 0", " ").lstrip("0")
    if start.month != last_day.month:
        return f"{start:%d %b} – {last_day:%d %b %Y}".replace(" 0", " ").lstrip("0")
    return f"{start.day}–{last_day.day} {last_day:%b %Y}"


def period_bounds(kind: str, *, now: Optional[datetime] = None, which: str = "previous",
                  anchor: Optional[datetime] = None) -> tuple[datetime, datetime]:
    """[start, end) in naive UTC.

    which="previous": the last period that has fully closed.
    which="current":  the period in progress (its end is in the future).
    anchor:           a UTC instant; the period containing it (which ignored).
    """
    if kind not in REPORT_KINDS:
        raise ValueError(f"kind must be one of {', '.join(REPORT_KINDS)}")
    now = now or datetime.utcnow()
    local = (anchor if anchor is not None else now) + _offset()
    start = _local_period_start(kind, local)
    if anchor is None and which == "previous":
        start = _local_previous(kind, start)
    elif anchor is None and which != "current":
        raise ValueError("which must be previous or current")
    end = _local_next(kind, start)
    return start - _offset(), end - _offset()


# ── Building ──────────────────────────────────────────────────────────────────

def _kes(minor: int) -> str:
    return f"KES {minor / 100:,.0f}"


def _signed(value: Optional[float]) -> str:
    if value is None:
        return "–"
    return f"{value:+g}%"


_KPIS = (
    ("new_users", "New users", "count", "up"),
    ("new_sellers", "New sellers", "count", "up"),
    ("new_listings", "New listings", "count", "up"),
    ("live_listings", "Live listings", "count", "up"),
    ("active_buyers", "Active buyers", "count", "up"),
    ("active_sellers", "Active sellers", "count", "up"),
    ("conversations_started", "Buyer conversations", "count", "up"),
    ("deals_agreed", "Deals agreed", "count", "up"),
    ("sold_out_reports", "Sold-out reports", "count", "up"),
    ("complaints_filed", "Complaints filed", "count", "down"),
    ("disputes_opened", "Disputes opened", "count", "down"),
    ("income_minor", "Income", "kes_minor", "up"),
    ("profit_minor", "Profit", "kes_minor", "up"),
)


def _kpis(pulse: dict) -> list[dict]:
    out = []
    for key, label, unit, good in _KPIS:
        value = pulse["metrics"][key]
        out.append({"key": key, "label": label, "unit": unit, "good_direction": good,
                    "value": value["current"], "previous": value["previous"],
                    "change_pct": value["change_pct"]})
    liquidity = pulse["liquidity"]
    out.insert(0, {
        "key": "liquidity_pct", "label": "Liquidity (7-day buyer contact)", "unit": "pct",
        "good_direction": "up", "value": liquidity["current"]["rate_pct"],
        "previous": liquidity["previous"]["rate_pct"],
        "change_pct": None,
    })
    response = pulse["seller_response"]
    out.insert(1, {
        "key": "seller_reply_pct", "label": "Seller replies within 24h", "unit": "pct",
        "good_direction": "up", "value": response["current"]["rate_pct"],
        "previous": response["previous"]["rate_pct"], "change_pct": None,
    })
    return out


def _headline(kind: str, pulse: dict, insights: list[dict]) -> str:
    m = pulse["metrics"]
    period = {"daily": "Yesterday", "weekly": "This week", "monthly": "This month"}.get(kind, "This period")
    rate = pulse["liquidity"]["current"]["rate_pct"]
    parts = [
        f"{period}: {m['new_users']['current']} new users, {m['new_listings']['current']} new listings, "
        f"{m['conversations_started']['current']} buyer conversations"
    ]
    if rate is not None:
        parts.append(f"{rate:g}% liquidity")
    first = next((i for i in insights if i["severity"] in ("critical", "warning")), None)
    headline = ", ".join(parts) + "."
    if first:
        headline += f" Top concern: {first['title']}."
    return headline


def _summary(kind: str, pulse: dict, categories: dict, sellers: dict, insights: list[dict]) -> list[str]:
    m = pulse["metrics"]
    lines = []

    def trend(name: str, label: str) -> str:
        value = m[name]
        if value["change_pct"] is None:
            return f"{value['current']} {label}"
        return f"{value['current']} {label} ({_signed(value['change_pct'])})"

    lines.append(
        "Growth: " + ", ".join([
            trend("new_users", "new users"), trend("new_sellers", "new sellers"),
            trend("new_listings", "new listings"),
        ]) + f"; {m['live_listings']['current']} listings live now."
    )
    liquidity = pulse["liquidity"]["current"]
    if liquidity["eligible"]:
        lines.append(
            f"Liquidity: {liquidity['with_buyer_contact']} of {liquidity['eligible']} listings "
            f"({liquidity['rate_pct']:g}%) heard from a buyer within 7 days; target "
            f"{pulse['liquidity']['target_pct']:g}%."
        )
    else:
        lines.append("Liquidity: no listing finished its first week in this period.")
    response = pulse["seller_response"]["current"]
    lines.append(
        f"Demand: {trend('active_buyers', 'active buyers')} for {m['active_sellers']['current']} active "
        f"sellers; {trend('conversations_started', 'conversations started')}"
        + (f"; sellers replied to {response['rate_pct']:g}% within 24h." if response["rate_pct"] is not None else ".")
    )
    top = [c for c in categories.get("categories", []) if c["demand"]][:3]
    if top:
        lines.append("Most wanted: " + ", ".join(
            f"{c['label']} ({c['demand']} signals, {c['supply_live']} live)" for c in top) + ".")
    complaints = pulse["complaints"]
    lines.append(
        f"Trust: {complaints['filed']['current']} complaints filed, {complaints['open']} open, "
        f"{complaints['sla_breached']} past deadline; {m['disputes_opened']['current']} disputes, "
        f"{m['fraud_flags']['current']} fraud flags."
    )
    revenue = pulse["revenue"]["current"]
    lines.append(
        f"Money: {_kes(revenue['income_minor'])} income, {_kes(revenue['costs_minor'])} costs, "
        f"{_kes(revenue['profit_minor'])} profit."
    )
    if sellers.get("waiting_total"):
        lines.append(
            f"Action today: {sellers['waiting_total']} buyers are waiting over 24h on "
            f"{sellers['sellers_with_waiting_buyers']} sellers."
        )
    return lines


async def build_report(db: AsyncSession, *, kind: str, start: datetime, end: datetime,
                       now: Optional[datetime] = None) -> dict:
    """The report payload for [start, end). `now` dates its point-in-time
    figures; for a period still running pass now <= end."""
    now = now or datetime.utcnow()
    pulse = await intelligence.pulse_between(db, start, end, now=now)
    categories = await intelligence.categories_between(db, start, end, now=now)
    sellers = await intelligence.sellers_overview(db, now=now, limit=10)
    insights = build_insights(pulse=pulse, categories=categories, sellers=sellers)
    label = period_label(kind, start, end)
    title = f"{_KIND_TITLES[kind]} · {label}"
    cats = categories["categories"]
    return {
        "version": PAYLOAD_VERSION,
        "kind": kind,
        "title": title,
        "period": {
            "from": intelligence.iso(start), "to": intelligence.iso(end), "label": label,
            "timezone": tz_label(), "in_progress": end > now,
        },
        "headline": _headline(kind, pulse, insights),
        "summary": _summary(kind, pulse, categories, sellers, insights),
        "kpis": _kpis(pulse),
        "insights": insights,
        "insight_counts": severity_counts(insights),
        "targets": pulse["targets"],
        "break_even": pulse["break_even"],
        "liquidity": pulse["liquidity"],
        "seller_response": pulse["seller_response"],
        "complaints": pulse["complaints"],
        "revenue": pulse["revenue"]["current"],
        "categories": {
            "top_demand": [_category_brief(c) for c in cats[:8]],
            "undersupplied": [_category_brief(c) for c in cats if c["signal"] in ("unserved", "undersupplied")][:5],
            "oversupplied": [_category_brief(c) for c in cats if c["signal"] == "oversupplied"][:5],
        },
        "sellers": {
            "waiting_total": sellers["waiting_total"],
            "sellers_with_waiting_buyers": sellers["sellers_with_waiting_buyers"],
            "top_waiting": [
                {k: s.get(k) for k in ("seller_id", "name", "waiting", "oldest_wait_hours")}
                for s in sellers["waiting"][:5]
            ],
            "stale_total": sellers["stale_total"],
        },
        "generated_at": intelligence.iso(now),
    }


def _category_brief(c: dict) -> dict:
    return {
        "key": c["key"], "label": c["label"], "demand": c["demand"],
        "supply_live": c["supply_live"], "new_listings": c["new_listings"],
        "liquidity_pct": c["liquidity"]["rate_pct"], "signal": c["signal"],
    }


# ── Markdown ──────────────────────────────────────────────────────────────────

def _cell(value) -> str:
    return str(value).replace("|", "\\|").replace("\n", " ")


def _fmt(value, unit: str) -> str:
    if value is None:
        return "–"
    if unit == "kes_minor":
        return _kes(int(value))
    if unit == "pct":
        return f"{value:g}%"
    return f"{value:,}" if isinstance(value, int) else f"{value:g}"


def render_markdown(payload: dict) -> str:
    """The report as Markdown: what the dashboard downloads and what a
    founder pastes into an email or an investor update."""
    period = payload.get("period", {})
    lines = [
        f"# {payload.get('title', 'BROKA report')}",
        "",
        f"_Period: {period.get('label', '')} ({period.get('timezone', '')})"
        + (" · in progress" if period.get("in_progress") else "")
        + f" · generated {payload.get('generated_at', '')}_",
        "",
        f"**{payload.get('headline', '')}**",
        "",
        "## Summary",
        "",
        *[f"- {_cell(line)}" for line in payload.get("summary", [])],
        "",
        "## Key numbers",
        "",
        "| Metric | This period | Previous | Change |",
        "|---|---:|---:|---:|",
    ]
    for kpi in payload.get("kpis", []):
        lines.append(
            f"| {_cell(kpi['label'])} | {_fmt(kpi['value'], kpi['unit'])} | "
            f"{_fmt(kpi['previous'], kpi['unit'])} | {_signed(kpi.get('change_pct'))} |"
        )
    insights = payload.get("insights", [])
    if insights:
        lines += ["", "## What needs attention", ""]
        for insight in insights:
            action = insight.get("action") or {}
            lines.append(
                f"- **{insight['severity'].upper()}** {_cell(insight['title'])}. "
                f"{_cell(insight['detail'])}"
                + (f" _Next: {_cell(action['label'])}._" if action.get("label") else "")
            )
    targets = payload.get("targets", [])
    if targets:
        lines += ["", "## Day-30 targets", "", "| Target | Actual | Goal | Progress |", "|---|---:|---:|---:|"]
        for t in targets:
            lines.append(
                f"| {_cell(t['label'])} | {_fmt(t['actual'], t['unit'])} | {_fmt(t['target'], t['unit'])} | "
                f"{_fmt(t['progress_pct'], 'pct')}{' ✓' if t['met'] else ''} |"
            )
    cats = (payload.get("categories") or {}).get("top_demand", [])
    if cats:
        lines += ["", "## Demand and supply by category", "",
                  "| Category | Demand | Live listings | New listings | Liquidity | Signal |",
                  "|---|---:|---:|---:|---:|---|"]
        for c in cats:
            lines.append(
                f"| {_cell(c['label'])} | {c['demand']} | {c['supply_live']} | {c['new_listings']} | "
                f"{_fmt(c['liquidity_pct'], 'pct')} | {c['signal']} |"
            )
    complaints = payload.get("complaints") or {}
    if complaints:
        filed = complaints.get("filed", {})
        lines += [
            "", "## Complaints", "",
            f"- Filed: {filed.get('current', 0)} (previous {filed.get('previous', 0)})",
            f"- Open: {complaints.get('open', 0)}, unanswered {complaints.get('unanswered', 0)}, "
            f"past deadline {complaints.get('sla_breached', 0)}",
            f"- Median time to reply (90 days): {_fmt(complaints.get('median_response_hours_90d'), 'num')} h",
        ]
    revenue = payload.get("revenue") or {}
    if revenue:
        lines += ["", "## Money", "",
                  f"- Income {_kes(revenue.get('income_minor', 0))}, costs {_kes(revenue.get('costs_minor', 0))}, "
                  f"profit {_kes(revenue.get('profit_minor', 0))}"]
        for stream in revenue.get("streams", []):
            lines.append(f"  - {_cell(stream['label'])}: {_kes(stream['amount_minor'])} ({stream['count']} payments)")
        be = payload.get("break_even") or {}
        if be:
            lines.append(
                f"- Break-even: {_fmt(be.get('coverage_pct'), 'pct')} of "
                f"{_kes(be.get('fixed_monthly_cost_minor', 0))} monthly fixed costs covered over 30 days"
            )
    lines += ["", "---", "_Generated by BROKA Admin from durable platform data. Staff accounts are excluded._", ""]
    return "\n".join(lines)


# ── Storage ───────────────────────────────────────────────────────────────────

def report_meta(row: AdminReport) -> dict:
    payload = row.payload or {}
    return {
        "id": row.id,
        "kind": row.kind,
        "title": row.title,
        "headline": row.headline,
        "period_start": intelligence.iso(row.period_start),
        "period_end": intelligence.iso(row.period_end),
        "period_label": (payload.get("period") or {}).get("label"),
        "generated_at": intelligence.iso(row.generated_at),
        "generated_by": row.generated_by,
        "insight_counts": payload.get("insight_counts") or {},
    }


def report_detail(row: AdminReport) -> dict:
    return {**report_meta(row), "stored": True, "payload": row.payload,
            "markdown": render_markdown(row.payload or {})}


async def save_report(db: AsyncSession, *, kind: str, start: datetime, end: datetime,
                      generated_by: str, now: Optional[datetime] = None,
                      replace: bool = False) -> tuple[AdminReport, bool]:
    """Write the report for [start, end). Returns (row, created).

    With replace=False an existing report for the period is returned as it
    is (the sweep's once-per-period rule); with replace=True its contents
    are rebuilt in place (an administrator's regenerate). A concurrent
    writer that wins the unique index is not an error: its row is used."""
    existing = (await db.execute(
        select(AdminReport).where(AdminReport.kind == kind, AdminReport.period_start == start)
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if existing is not None and not replace:
        return existing, False
    payload = await build_report(db, kind=kind, start=start, end=end, now=now)
    if existing is not None:
        existing.payload = payload
        existing.title = payload["title"]
        existing.headline = payload["headline"]
        existing.period_end = end
        existing.generated_by = generated_by
        existing.generated_at = datetime.utcnow()
        await db.commit()
        return existing, False
    row = AdminReport(
        kind=kind, period_start=start, period_end=end, title=payload["title"],
        headline=payload["headline"], generated_by=generated_by,
        generated_at=datetime.utcnow(), payload=payload,
    )
    db.add(row)
    try:
        await db.commit()
    except IntegrityError:
        # Another writer stored this period first: theirs stands, or is
        # replaced by ours when this is an explicit regenerate.
        await db.rollback()
        winner = (await db.execute(
            select(AdminReport).where(AdminReport.kind == kind, AdminReport.period_start == start)
            .execution_options(populate_existing=True)
        )).scalar_one()
        if replace:
            winner.payload = payload
            winner.title = payload["title"]
            winner.headline = payload["headline"]
            winner.generated_by = generated_by
            winner.generated_at = datetime.utcnow()
            await db.commit()
        return winner, False
    return row, True


async def _announce(row: AdminReport) -> None:
    """Weekly and monthly briefs land in the Alert Centre, so the founder
    hears about them without opening the archive. Best effort."""
    from api.core.admin_alert_subscribers import _create

    await _create(
        "report_ready", "info", f"{row.title} is ready",
        body=row.headline[:500] if row.headline else None,
        href=f"/reports?id={row.id}",
        meta={"report_id": row.id},
    )


async def generate_due_reports(*, now: Optional[datetime] = None) -> list[str]:
    """Write each kind's last closed period if it is missing. Returns the ids
    of the reports created by this call."""
    if not settings.admin_reports_enabled:
        return []
    from api.database import AsyncSessionLocal

    now = now or datetime.utcnow()
    created: list[str] = []
    for kind in REPORT_KINDS:
        start, end = period_bounds(kind, now=now, which="previous")
        try:
            async with AsyncSessionLocal() as db:
                row, was_created = await save_report(
                    db, kind=kind, start=start, end=end, generated_by="system", now=now)
                report_id, title = row.id, row.title
        except Exception as exc:
            # One kind failing must not stop the others, or the sweep.
            _log.error("[reports] %s report failed: %s", kind, type(exc).__name__)
            continue
        if was_created:
            created.append(report_id)
            _log.info("[reports] generated %s report %s (%s)", kind, report_id, title)
            if kind in ("weekly", "monthly"):
                await _announce(row)
    return created
