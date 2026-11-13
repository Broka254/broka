"""ThreadClear - one person deleting a chat from their own inbox.

A chat is never deleted from the database: its messages are the evidence a
dispute is decided on (domains/disputes/), the record a leak check reads
(domains/trust/), and still the other person's copy. What one side deletes
is its own view. This row is a watermark for that side: every message up to
`cleared_at` is gone from their inbox, their history and their chat socket's
replay. A message after it brings the chat back, starting from that
message - what WhatsApp's "Delete chat" does.

One row per person and thread, rewritten each time they delete it again.
Exactly one of listing_id / store_id names the thread, as in
ThreadReadState.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class ThreadClear(Base):
    __tablename__ = "thread_clears"

    id         = sa.Column(sa.String, primary_key=True, default=lambda: str(uuid.uuid4()))
    # Whose view this is. The role is derived from it (a seller can't be the
    # buyer of their own listing), but is kept for reading the table.
    user_id    = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    listing_id = sa.Column(sa.String, sa.ForeignKey("listings.id"), nullable=True)
    store_id   = sa.Column(sa.String, sa.ForeignKey("stores.id"), nullable=True)
    buyer_id   = sa.Column(sa.String, nullable=False)
    role       = sa.Column(sa.String, nullable=False)  # "buyer" | "seller"
    # Naive UTC, like every DateTime here (core/timeutil.to_naive_utc).
    cleared_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    # NULLs never collide, so each constraint covers its own thread kind.
    __table_args__ = (
        sa.UniqueConstraint("user_id", "listing_id", "buyer_id", name="uq_thread_clear_listing"),
        sa.UniqueConstraint("user_id", "store_id", "buyer_id", name="uq_thread_clear_store"),
    )
