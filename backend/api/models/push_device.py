"""Push devices - every phone a user is signed in on.

One row per device push token. The token is the primary key, so a phone
belongs to exactly one account at a time: signing in as someone else on the
same phone moves the row to them. Before this table the token lived in one
column on `users` (`fcm_token`), which got both of these wrong:

  * Only the last phone to register received anything. Someone signed in on
    two phones got calls and messages on one of them.
  * Nothing removed a token from the account that had it before. When a
    second person signed in on a shared phone, the first person's calls,
    chat messages and payment alerts kept arriving on it.

`kind` is "fcm" (Android, and iOS alerts) or "apns_voip" (iOS PushKit, the
only push that wakes a closed iPhone for a call). Timestamps are naive UTC.

A new table, so init_db()'s create_all() creates it.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import Column, DateTime, ForeignKey, Index, String

from api.database import Base


class PushDevice(Base):
    __tablename__ = "push_devices"

    token      = Column(String, primary_key=True)
    user_id    = Column(String, ForeignKey("users.id"), nullable=False)
    kind       = Column(String, nullable=False, default="fcm")
    platform   = Column(String, nullable=True)      # "android" | "ios", as the app says
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # Moves on every registration, which the app makes at every sign-in and
    # session restore: the newest devices are the ones a user still carries.
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        Index("ix_push_devices_user_kind", "user_id", "kind"),
    )
