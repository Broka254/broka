"""Structured opening hours for a physical store.

Storage is JSON on `stores.opening_hours` (see api/models/store.py). This
module is the only thing that decides what a valid schedule is, normalises
it, and answers "is this shop open right now" - the router, the service and
the storefronts all go through it.

Shape
-----
    {"mon": {"open": "08:00", "close": "18:00"},
     "tue": {"open": "08:00", "close": "18:00"},
     "wed": null,                        # closed all day
     "thu": {"all_day": true},           # open 24 hours
     ... "sun": {"open": "20:00", "close": "02:00"}}

* A day key is one of mon..sun.
* `null` (or a missing key) means closed that day.
* `{"all_day": true}` means open 24 hours.
* Otherwise `open` and `close` are "HH:MM" 24-hour clock values. A close at
  or before the open is a window that runs past midnight (20:00-02:00).
* `open == close` is refused unless `all_day` is set: a zero-length window
  is a typo, not a business.

Times are shop-local. Kenya has one time zone, Africa/Nairobi (UTC+3) and
no daylight saving, so a fixed offset is exact and needs no tzdata package
on the server. The status is computed on read, from the stored schedule and
the current time - never stored, and never a reason for the app to poll.
"""
from __future__ import annotations

import json
from datetime import datetime, time, timedelta, timezone
from typing import Optional

DAYS = ("mon", "tue", "wed", "thu", "fri", "sat", "sun")
DAY_LABELS = {
    "mon": "Monday", "tue": "Tuesday", "wed": "Wednesday", "thu": "Thursday",
    "fri": "Friday", "sat": "Saturday", "sun": "Sunday",
}
DAY_SHORT = {
    "mon": "Mon", "tue": "Tue", "wed": "Wed", "thu": "Thu",
    "fri": "Fri", "sat": "Sat", "sun": "Sun",
}
# Kenya: UTC+3, no daylight saving. ZoneInfo("Africa/Nairobi") would give the
# same answer; a fixed offset keeps this module independent of system tzdata
# (and of whether a slim container ships it).
NAIROBI = timezone(timedelta(hours=3))

MAX_JSON_LENGTH = 4000


class OpeningHoursError(ValueError):
    """A schedule that can't be stored. The message is safe to show."""


def _parse_time(value: object, day: str) -> time:
    if not isinstance(value, str) or len(value) != 5 or value[2] != ":":
        raise OpeningHoursError(f"{DAY_LABELS[day]}: use times like 08:00 or 18:30.")
    hh, mm = value[:2], value[3:]
    if not (hh.isdigit() and mm.isdigit()):
        raise OpeningHoursError(f"{DAY_LABELS[day]}: use times like 08:00 or 18:30.")
    hour, minute = int(hh), int(mm)
    if hour > 23 or minute > 59:
        raise OpeningHoursError(f"{DAY_LABELS[day]}: that time doesn't exist.")
    return time(hour, minute)


def normalize(raw: object) -> Optional[dict]:
    """Validate a request's schedule and return the canonical dict, or None
    for "not provided". Raises OpeningHoursError for anything unusable.

    Keys that aren't a weekday are refused rather than ignored: silently
    dropping a typo would publish a shop that looks open when it isn't.
    """
    if raw is None:
        return None
    if not isinstance(raw, dict):
        raise OpeningHoursError("Opening hours must be a day-by-day schedule.")
    unknown = set(raw) - set(DAYS)
    if unknown:
        raise OpeningHoursError("Opening hours can only use mon to sun.")
    out: dict = {}
    for day in DAYS:
        value = raw.get(day)
        if value is None:
            out[day] = None
            continue
        if not isinstance(value, dict):
            raise OpeningHoursError(f"{DAY_LABELS[day]}: choose opening and closing times.")
        if value.get("all_day") is True:
            if value.get("open") or value.get("close"):
                raise OpeningHoursError(
                    f"{DAY_LABELS[day]}: choose either open 24 hours or a time range, not both.")
            out[day] = {"all_day": True}
            continue
        if "open" not in value or "close" not in value:
            raise OpeningHoursError(f"{DAY_LABELS[day]}: give both an opening and closing time.")
        opens = _parse_time(value.get("open"), day)
        closes = _parse_time(value.get("close"), day)
        if opens == closes:
            raise OpeningHoursError(
                f"{DAY_LABELS[day]}: opening and closing times can't be the same. "
                "Tick 24 hours for a shop that never closes.")
        out[day] = {"open": opens.strftime("%H:%M"), "close": closes.strftime("%H:%M")}
    return out


def dumps(schedule: Optional[dict]) -> Optional[str]:
    return json.dumps(schedule, separators=(",", ":")) if schedule else None


def loads(raw: Optional[str]) -> Optional[dict]:
    """A stored schedule, or None when the column is empty. A value that
    can't be read is treated as no schedule: the storefront then says hours
    are unavailable rather than claiming a shop is open."""
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except (TypeError, ValueError):
        return None
    if not isinstance(value, dict) or len(raw) > MAX_JSON_LENGTH:
        return None
    try:
        return normalize(value)
    except OpeningHoursError:
        return None


def _minutes(t: time) -> int:
    return t.hour * 60 + t.minute


def _fmt(t: time) -> str:
    return t.strftime("%H:%M")


def _window(day: str, value: dict) -> tuple[int, int, bool]:
    """(open minutes, close minutes, crosses midnight) for a day's window."""
    if value.get("all_day"):
        return 0, 24 * 60, False
    opens = _parse_time(value["open"], day)
    closes = _parse_time(value["close"], day)
    return _minutes(opens), _minutes(closes), _minutes(closes) <= _minutes(opens)


def day_label(day: str, value: Optional[dict]) -> str:
    if not value:
        return "Closed"
    if value.get("all_day"):
        return "Open 24 hours"
    return f"{value['open']} – {value['close']}"


def weekly_schedule(schedule: Optional[dict]) -> list[dict]:
    """Monday-first rows for the storefront: {day, label, hours, closed}.

    Every day is present, so the screen can show "Closed" rather than
    leaving gaps a reader has to interpret.
    """
    return [
        {
            "day": day,
            "label": DAY_LABELS[day],
            "short": DAY_SHORT[day],
            "hours": day_label(day, (schedule or {}).get(day)),
            "closed": not bool((schedule or {}).get(day)),
            "all_day": bool((schedule or {}).get(day, {}).get("all_day"))
            if (schedule or {}).get(day) else False,
        }
        for day in DAYS
    ]


def open_status(schedule: Optional[dict], now: Optional[datetime] = None) -> dict:
    """Whether the shop is open, worded the way a buyer needs it.

    Returns:
      state   "open" | "closed" | "unknown"
      label   "Open now · closes 18:00" / "Closed now · opens Monday 08:00"
              / "Opening hours unavailable"
      opens_at / closes_at  "HH:MM" when known, else None
      next_day  weekday label when the next opening is not today, else None

    `unknown` is used when no schedule was provided - never "closed", which
    would say something BROKA cannot know. `now` is for tests; production
    callers pass nothing and get the real Africa/Nairobi time.
    """
    if not schedule:
        return {"state": "unknown", "label": "Opening hours unavailable",
                "opens_at": None, "closes_at": None, "next_day": None}

    current = (now or datetime.now(timezone.utc)).astimezone(NAIROBI)
    day_index = current.weekday()          # Monday=0, matching DAYS
    minutes = current.hour * 60 + current.minute
    today = DAYS[day_index]
    yesterday = DAYS[(day_index - 1) % 7]

    # A window that started yesterday and crosses midnight is still open in
    # the small hours - the case a plain "today's hours" check gets wrong.
    prev = schedule.get(yesterday)
    if prev and not prev.get("all_day"):
        p_open, p_close, crosses = _window(yesterday, prev)
        if crosses and minutes < p_close:
            close_t = _parse_time(prev["close"], yesterday)
            return {"state": "open", "label": f"Open now · closes {_fmt(close_t)}",
                    "opens_at": None, "closes_at": _fmt(close_t), "next_day": None}

    value = schedule.get(today)
    if value:
        open_m, close_m, crosses = _window(today, value)
        if value.get("all_day"):
            return {"state": "open", "label": "Open now · 24 hours",
                    "opens_at": None, "closes_at": None, "next_day": None}
        if crosses:
            # Today's window opened before midnight and ends tomorrow.
            if minutes >= open_m:
                close_t = _parse_time(value["close"], today)
                return {"state": "open", "label": f"Open now · closes {_fmt(close_t)}",
                        "opens_at": None, "closes_at": _fmt(close_t), "next_day": None}
        elif open_m <= minutes < close_m:
            close_t = _parse_time(value["close"], today)
            return {"state": "open", "label": f"Open now · closes {_fmt(close_t)}",
                    "opens_at": None, "closes_at": _fmt(close_t), "next_day": None}

    # Closed: find the next opening, today later or the first open day ahead.
    # A crossing-midnight window still opens later today (15:00 before a
    # 20:00-02:00 shift); skipping it because it crosses midnight would
    # claim the shop is shut until next week.
    if value and not value.get("all_day"):
        open_m, _, _ = _window(today, value)
        if minutes < open_m:
            open_t = _parse_time(value["open"], today)
            return {"state": "closed", "label": f"Closed now · opens {_fmt(open_t)}",
                    "opens_at": _fmt(open_t), "closes_at": None, "next_day": None}

    for step in range(1, 8):
        day = DAYS[(day_index + step) % 7]
        value = schedule.get(day)
        if not value:
            continue
        opens_at = "24 hours" if value.get("all_day") else value["open"]
        label = f"Closed now · opens {DAY_SHORT[day]} {'24 hours' if value.get('all_day') else _fmt(_parse_time(value['open'], day))}"
        return {"state": "closed", "label": label, "opens_at": opens_at,
                "closes_at": None, "next_day": DAY_SHORT[day]}

    return {"state": "closed", "label": "Closed now", "opens_at": None,
            "closes_at": None, "next_day": None}


def public_payload(raw: Optional[str], now: Optional[datetime] = None) -> dict:
    """What every store payload carries: the schedule, its week rows, and
    the current status. One function so the app and the web read the same
    thing and neither recalculates the status itself."""
    schedule = loads(raw)
    return {
        "opening_hours": schedule,
        "opening_hours_week": weekly_schedule(schedule),
        "opening_hours_available": schedule is not None,
        "open_status": open_status(schedule, now),
    }
