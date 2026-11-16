"""How current a provider's information is - and what must be said when it
is not.

Providers change their fees and terms without telling anyone. A fee table
that was right in September and is shown in December as today's price is
worse than no table: it is a confident wrong number on the screen where
someone is deciding to send money. So every record carries the date BROKA
last checked it against the provider's own page, and that date expires.

THREE STATES for pricing, and only one of them is good news:

  current     a person at BROKA checked the pricing against the provider's
              own source, recently enough (PRICING_MAX_AGE_DAYS), and the
              record's next review is not overdue;
  expired     it was checked once, but too long ago, or the review is
              overdue: shown with an "outdated" warning, never ranked;
  unverified  nobody has checked it (a fresh record, or one whose fees were
              just edited and are waiting for review): shown as "not yet
              verified", never ranked, never called current.

A date in the future is treated as unverified: it cannot be a real check,
and accepting it would keep stale data "current" until that date.

Plain functions of (record, today): no clock reads, so they test exactly.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Optional

CURRENT, EXPIRED, UNVERIFIED = "current", "expired", "unverified"

# Fees change more often than a company's identity, so pricing goes stale
# faster than the rest of the record. Both are settings
# (ESCROW_PRICING_MAX_AGE_DAYS, ESCROW_RECORD_MAX_AGE_DAYS); these are the
# defaults the code falls back on.
PRICING_MAX_AGE_DAYS = 30
RECORD_MAX_AGE_DAYS = 90

OUTDATED_PRICING_WARNING = (
    "This provider's pricing was last checked on {date}, which is more than {days} days ago. "
    "Fees may have changed. Confirm the current fee on the provider's own site before paying."
)
UNVERIFIED_PRICING_WARNING = (
    "BROKA has not yet verified this provider's pricing. The figures come from the provider's own "
    "public pages. Confirm them on the provider's site before paying."
)
OVERDUE_REVIEW_WARNING = (
    "BROKA's review of this provider was due on {date} and has not been repeated. Treat the "
    "details below as possibly out of date."
)


def parse_date(value: object) -> Optional[date]:
    """A "YYYY-MM-DD" string (or a date) as a date, else None. Times and
    time zones are refused: a verification is a day, not an instant."""
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, date):
        return value
    if not isinstance(value, str) or len(value) != 10:
        return None
    try:
        return date.fromisoformat(value)
    except ValueError:
        return None


def as_date(now: object) -> date:
    parsed = parse_date(now)
    if parsed is None:
        raise ValueError("now must be a date")
    return parsed


def _label(day: date) -> str:
    return f"{day.day} {day.strftime('%b %Y')}"


def pricing_freshness(record: dict, now: object, *, max_age_days: int = PRICING_MAX_AGE_DAYS) -> dict:
    """The state of [record]'s pricing as of [now] (a date)."""
    today = as_date(now)
    pricing = record.get("pricing") or {}
    trust = record.get("trust") or {}
    verified_on = parse_date(pricing.get("last_verified"))
    reviewed = trust.get("pricing_review") == "verified"
    next_review = parse_date(trust.get("next_review"))

    base = {"state": UNVERIFIED, "verified_on": None, "expires_on": None,
            "days_since_verified": None, "days_until_expiry": None,
            "label": "Not yet verified by BROKA", "warning": UNVERIFIED_PRICING_WARNING}
    if verified_on is None or not reviewed or verified_on > today:
        return base

    expires_on = verified_on + timedelta(days=max_age_days)
    if next_review is not None and next_review < expires_on:
        expires_on = next_review
    out = {**base, "verified_on": verified_on.isoformat(), "expires_on": expires_on.isoformat(),
           "days_since_verified": (today - verified_on).days,
           "days_until_expiry": (expires_on - today).days}
    if today > expires_on:
        overdue_review = next_review is not None and today > next_review and next_review == expires_on
        out.update(
            state=EXPIRED,
            label=f"Outdated: last verified {_label(verified_on)}",
            warning=(OVERDUE_REVIEW_WARNING.format(date=_label(next_review)) if overdue_review
                     else OUTDATED_PRICING_WARNING.format(date=_label(verified_on), days=max_age_days)))
        return out
    out.update(state=CURRENT, label=f"Pricing verified {_label(verified_on)}", warning=None)
    return out


def record_freshness(record: dict, now: object, *, max_age_days: int = RECORD_MAX_AGE_DAYS) -> dict:
    """The state of the rest of the record (identity, terms, protection)."""
    today = as_date(now)
    trust = record.get("trust") or {}
    verified_on = parse_date(trust.get("last_verified"))
    next_review = parse_date(trust.get("next_review"))
    base = {"state": UNVERIFIED, "verified_on": None, "next_review": None, "label": "Not yet verified by BROKA",
            "warning": "BROKA has not yet verified this provider's details. They come from the "
                       "provider's own public pages."}
    if verified_on is None or verified_on > today:
        return base
    due = verified_on + timedelta(days=max_age_days)
    if next_review is not None and next_review < due:
        due = next_review
    out = {**base, "verified_on": verified_on.isoformat(), "next_review": due.isoformat()}
    if today > due:
        out.update(state=EXPIRED, label=f"Outdated: last verified {_label(verified_on)}",
                   warning=OVERDUE_REVIEW_WARNING.format(date=_label(due)))
        return out
    out.update(state=CURRENT, label=f"Verified {_label(verified_on)}", warning=None)
    return out


_ORDER = {CURRENT: 0, EXPIRED: 1, UNVERIFIED: 2}


def evaluate(record: dict, now: object, *, pricing_max_age_days: int = PRICING_MAX_AGE_DAYS,
             record_max_age_days: int = RECORD_MAX_AGE_DAYS) -> dict:
    """Both states and the worse of the two. A record is only as current as
    its least current part."""
    pricing = pricing_freshness(record, now, max_age_days=pricing_max_age_days)
    rest = record_freshness(record, now, max_age_days=record_max_age_days)
    worst = max((pricing, rest), key=lambda f: _ORDER[f["state"]])
    return {
        "state": worst["state"],
        "pricing": pricing,
        "record": rest,
        "warnings": [w for w in (pricing["warning"], rest["warning"]) if w],
        "needs_review": worst["state"] != CURRENT,
    }
