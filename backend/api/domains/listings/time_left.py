"""How long before a listing or store goes offline - computed once, here.

Clients must not each do this arithmetic on their own clocks: a phone set
an hour fast would show "expired" on a live listing. The server returns
`seconds_left` and a ready-to-show `label`; a client only renders them
(and may tick the label down locally between fetches).

paid_until semantics (listings/paid.py, stores/billing.py):
  None        no fee applies - it never goes offline for non-payment;
  <= now      already offline (or, == created_at, never went live);
  >  now      live until then.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

# Within this of the deadline a payload says "ending" and the app should
# offer renewal. Matches listings/paid.ENDING_SOON.
ENDING_SOON_DAYS = 7


def format_time_left(seconds: int) -> str:
    """'2d 3h left', '5h 12m left', '45m left'. Never negative."""
    seconds = max(0, int(seconds))
    days, rem = divmod(seconds, 86400)
    hours, rem = divmod(rem, 3600)
    minutes = rem // 60
    if days:
        return f"{days}d {hours}h left"
    if hours:
        return f"{hours}h {minutes}m left"
    if minutes:
        return f"{minutes}m left"
    return "Less than a minute left" if seconds else "Offline"


def time_left(paid_until: Optional[datetime], now: Optional[datetime] = None,
              created_at: Optional[datetime] = None) -> dict:
    """The offline countdown for one paid_until.

    `status` mirrors fee_state's vocabulary so screens can switch on one
    word: unlimited | live | ending | unpaid | expired.
    """
    now = now or datetime.utcnow()
    if paid_until is None:
        return {
            "status": "unlimited",
            "paid_until": None,
            "goes_offline_at": None,
            "seconds_left": None,
            "days_left": None,
            "label": "No expiry",
            "is_expiring_soon": False,
        }
    seconds = int((paid_until - now).total_seconds())
    if seconds <= 0:
        status = (
            "unpaid"
            if created_at is not None and paid_until <= created_at
            else "expired"
        )
        return {
            "status": status,
            "paid_until": paid_until.isoformat(),
            "goes_offline_at": paid_until.isoformat(),
            "seconds_left": 0,
            "days_left": 0.0,
            "label": "Offline",
            "is_expiring_soon": False,
        }
    return {
        "status": "ending" if seconds <= ENDING_SOON_DAYS * 86400 else "live",
        "paid_until": paid_until.isoformat(),
        "goes_offline_at": paid_until.isoformat(),
        "seconds_left": seconds,
        "days_left": round(seconds / 86400.0, 2),
        "label": format_time_left(seconds),
        "is_expiring_soon": seconds <= ENDING_SOON_DAYS * 86400,
    }
