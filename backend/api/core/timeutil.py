"""One rule for timestamps that come from outside: store them as naive UTC.

Every DateTime column in this codebase is timezone-naive and every "now" is
datetime.utcnow(), so a stored timestamp means UTC by convention. A value
arriving from a client can carry an offset ("...Z", "...+03:00"), and there
were two ways to get that wrong:

  * keep it aware - then the first comparison with utcnow() raises
    "can't compare offset-naive and offset-aware datetimes" (a 500), and
    Postgres/asyncpg rejects it for a `timestamp without time zone` column;
  * strip the offset with .replace(tzinfo=None) WITHOUT converting first -
    then 18:00+03:00 is stored as 18:00 UTC, three hours late, silently.

to_naive_utc converts to UTC first and only then drops the zone.
"""
from __future__ import annotations

from datetime import datetime, timezone


def to_naive_utc(value: datetime) -> datetime:
    """The same instant as naive UTC. A naive input is taken to be UTC
    already - the codebase-wide convention - and returned unchanged."""
    if value.tzinfo is None:
        return value
    return value.astimezone(timezone.utc).replace(tzinfo=None)


def parse_iso_to_naive_utc(text: str) -> datetime:
    """Parse ISO 8601 (with or without an offset, "Z" included) to naive UTC.

    Raises ValueError on anything unparseable - callers decide whether that
    is a 422 or an "absent".
    """
    return to_naive_utc(datetime.fromisoformat(text.strip().replace("Z", "+00:00")))
