"""User session tracking and the moderation audit trail.

A heartbeat says "this account sent a beat at this moment"; it cannot say how
long anyone used BROKA, because a closed app, a lost connection or a killed
process never sends a goodbye. `UserSession` turns the stream of heartbeats
into intervals the dashboard can add up: one open row per (user, device) that
each beat advances, closed by an explicit sign-out, by the inactivity sweep
(api/core/activity.py), or by a suspension (api/core/moderation.py).

New tables, so init_db()'s create_all() creates them. The columns `users`
gained are ALTER statements in init_db()'s migrations list - create_all never
alters an existing table.

`UserModerationAction` is append-only: nothing in the codebase updates or
deletes a row. It is the history an administrator reads to answer "who
suspended this account, when, for how long and on what evidence", which
`users` alone cannot: the user row only holds the latest state.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Index, Integer, String, Text

from api.database import Base


class UserSession(Base):
    __tablename__ = "user_sessions"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, nullable=False)
    # A client-stable device identifier. Optional: an old app build sends no
    # device id, and a session must still be recorded for it.
    device_id = Column(String, nullable=True)
    platform = Column(String, nullable=True)      # "android" | "ios" | "web"
    started_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # Advanced by every heartbeat, so presence ("active in the last five
    # minutes") reads from the session rather than from a second clock that
    # could disagree with it.
    last_activity_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    ended_at = Column(DateTime, nullable=True)
    # "logout" | "inactivity" | "suspended" | "revoked" | "replaced"
    end_reason = Column(String, nullable=True)
    # Foreground seconds only: a gap longer than the presence window is not
    # usage, and background activity never adds to this counter.
    foreground_seconds = Column(Integer, nullable=False, default=0)
    heartbeat_count = Column(Integer, nullable=False, default=0)
    is_foreground = Column(Boolean, nullable=False, default=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        # Per-user session history (the admin drill-down).
        Index("ix_user_sessions_user_activity", "user_id", "last_activity_at"),
        # The inactivity sweep and the activity series scan by these two.
        Index("ix_user_sessions_open_activity", "ended_at", "last_activity_at"),
    )


class UserModerationAction(Base):
    """One administrative decision about an account. Append-only."""

    __tablename__ = "user_moderation_actions"

    id = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String, nullable=False)
    # "suspend" | "reinstate" | "flag" | "unflag"
    action = Column(String, nullable=False)
    # "suspended" | "banned" | "active" | "restricted" - the account status
    # after this decision, so history reads without replaying every row.
    new_status = Column(String, nullable=False)
    previous_status = Column(String, nullable=False)
    actor_id = Column(String, nullable=False)
    reason = Column(Text, nullable=True)
    notes = Column(Text, nullable=True)
    # NULL for a permanent suspension (and for every non-suspension action).
    duration_hours = Column(Integer, nullable=True)
    expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        Index("ix_user_moderation_user_created", "user_id", "created_at"),
    )
