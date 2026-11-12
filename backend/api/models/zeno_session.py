"""ZenoSession - one use of Zeno's listing insights or of the Buying Agent.

A free account gets a few of these a day (premium/zeno_sessions.py), and a
session is the whole conversation, not a message: every question asked
about one listing that day is one listing session, and one hunt by the
Buying Agent - its questions, its searches and the refinements after - is
one agent session. "Find me something similar" from a listing hands its
hunt to the Buying Agent as part of the listing's session (parent_id), so
it is not counted again.

`slot` is what makes the daily limit hold under two taps at once: a counted
session takes the lowest free number from 1 to the day's limit, and the
unique (user, kind, day, slot) index lets only one request have each. A
session that is not counted - a plan holder's, or a hunt handed over from a
listing - has no slot.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class ZenoSession(Base):
    __tablename__ = "zeno_sessions"

    id           = sa.Column(sa.String, primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id      = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    # "listing" (questions about one listing) or "agent" (a Buying Agent hunt).
    kind         = sa.Column(sa.String(16), nullable=False)
    # The listing's id for a listing session; the hunt's own id for a hunt.
    # Not a foreign key: a hunt's key is not a row anywhere.
    session_key  = sa.Column(sa.String(80), nullable=False)
    # The day in Kenya it was opened, "YYYY-MM-DD" - the day it counts for.
    day          = sa.Column(sa.String(10), nullable=False)
    # 1..the day's limit for a counted session; NULL when it is not counted.
    slot         = sa.Column(sa.Integer, nullable=True)
    # The listing session a hunt was handed over from.
    parent_id    = sa.Column(sa.String, nullable=True)
    turns        = sa.Column(sa.Integer, nullable=False, default=0)
    created_at   = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    last_turn_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        sa.UniqueConstraint("user_id", "kind", "session_key", "day", name="uq_zeno_sessions_key_day"),
        sa.UniqueConstraint("user_id", "kind", "day", "slot", name="uq_zeno_sessions_slot"),
        sa.Index("ix_zeno_sessions_user_day", "user_id", "day"),
    )
