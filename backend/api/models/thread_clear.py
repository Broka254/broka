"""ThreadClear - one person deleting a conversation from their own inbox.

A conversation has no row of its own: it is the messages on (listing,
buyer) or (store, buyer). Deleting one for good would take the other
person's copy with it, and the record a dispute is settled on. So deleting
a chat is a watermark, the way reading one is (ThreadReadState): one row
per person and conversation saying "everything up to here is gone for me".

Everything sent up to `cleared_at` is left out of that person's inbox, the
chat's history, its socket replay, the unread counts and the offline sync
(api/core/thread_clears.py). The conversation leaves their inbox and comes
back, with only the new messages, when either side writes again - as a
deleted WhatsApp chat does. The other person's copy is untouched.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class ThreadClear(Base):
    __tablename__ = "thread_clears"

    id         = sa.Column(sa.String, primary_key=True, default=lambda: str(uuid.uuid4()))
    # Whose view this is. Not a foreign key, like the other per-user
    # watermarks: nothing here is worth failing a delete over.
    user_id    = sa.Column(sa.String, nullable=False, index=True)
    # Exactly one of listing_id / store_id names the conversation, with
    # buyer_id (ThreadReadState's identity). Plain columns as well: a
    # listing deleted later must not take its sellers' deletions with it.
    listing_id = sa.Column(sa.String, nullable=True)
    store_id   = sa.Column(sa.String, nullable=True)
    buyer_id   = sa.Column(sa.String, nullable=False)
    # "buyer" | "seller": the side `user_id` is on.
    role       = sa.Column(sa.String, nullable=False)
    cleared_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    # NULLs never collide, so each kind of conversation gets its own unique.
    __table_args__ = (
        sa.UniqueConstraint("user_id", "listing_id", "buyer_id", name="uq_thread_clear_listing"),
        sa.UniqueConstraint("user_id", "store_id", "buyer_id", name="uq_thread_clear_store"),
    )
