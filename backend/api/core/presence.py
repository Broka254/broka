"""Shared "online / last seen" presence formatting.

Both GET /auth/user/{id} (the 1:1 chat header) and GET /negotiate/inbox/{id}
(the inbox list) need to answer the exact same question - "is this person
online right now, and if not, when were they last active?" - from the same
underlying `User.last_seen` timestamp. This used to be implemented twice
(once inline in each endpoint) and had drifted: the inbox version computed
a friendly `(is_online, label)` pair, while the profile version returned
neither `is_online` nor a friendly label, just the raw timestamp. Centralizing
it here means both endpoints - and any future one - agree by construction.

A user counts as "online" if their last heartbeat was within the last 5
minutes; the Flutter app pings PATCH /auth/heartbeat every ~60s while it's
in the foreground, so 5 minutes gives comfortable slack for a couple of
missed beats without marking someone offline the instant they background
the app.
"""
from datetime import datetime, timezone

ONLINE_THRESHOLD_SECS = 300  # 5 minutes


def online_status(last_seen: datetime | None) -> tuple[bool, str]:
    """Return (is_online, friendly_label) for a User.last_seen timestamp."""
    if last_seen is None:
        return False, "Recently active"

    now = datetime.utcnow() if last_seen.tzinfo is None else datetime.now(timezone.utc)
    secs = max(0, int((now - last_seen).total_seconds()))
    is_online = secs < ONLINE_THRESHOLD_SECS

    if secs < 60:
        label = "Active now"
    elif secs < 3600:
        label = f"Active {secs // 60}m ago"
    elif secs < 86400:
        label = f"Active {secs // 3600}h ago"
    else:
        label = f"Active {secs // 86400}d ago"
    return is_online, label
