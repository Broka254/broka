"""Message deliveries - what happened to each chat message, per recipient.

One row per (message, recipient): written in the same transaction as the
NegotiationMessage itself (api/core/message_delivery.py, from the session
hook in message_push.py), so a message that is saved is a message that is
tracked, whichever of the twenty-odd code paths wrote it.

Before this table the only record of delivery was the per-thread watermark
(ThreadReadState): "this side has everything up to T". That answers the
sender's tick, but not "was message X pushed, did the phone get it, is it
still waiting?" - and nothing about a push survived a restart, so a push
that failed was never tried again. The rows here are also the queue the
push retry sweep works from, and what the app's offline sync asks for.

`status` only moves up the ladder in STATUS_RANK, with one exception: a
failed push may be tried again (PUSH_FAILED -> PUSH_PENDING). DELIVERED is
written only when the recipient's app says it has the message - never
because FCM accepted a push - and READ only by the read receipts.

The message, listing and store ids are plain columns, not foreign keys: a
tracking row must never be what stops a message being written or removed.
Timestamps are naive UTC, like every other DateTime column here.

A new table, so init_db()'s create_all() creates it (schema revision 17).
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Index, Integer, String, UniqueConstraint

from api.database import Base

SAVED = "SAVED"
PUSH_PENDING = "PUSH_PENDING"
PUSH_ACCEPTED = "PUSH_ACCEPTED"
PUSH_FAILED = "PUSH_FAILED"
DELIVERED = "DELIVERED"
READ = "READ"

# How far along a row is. A late or repeated event never moves a row down:
# a push result arriving after the phone already acknowledged the message,
# or a delivery receipt after it was read, changes nothing.
STATUS_RANK = {
    SAVED: 0,
    PUSH_PENDING: 1,
    PUSH_FAILED: 2,
    PUSH_ACCEPTED: 3,
    DELIVERED: 4,
    READ: 5,
}

# Not yet on the recipient's phone as far as the server can prove: what the
# app's sync hands out, and what a push may still be tried for.
UNDELIVERED = (SAVED, PUSH_PENDING, PUSH_FAILED, PUSH_ACCEPTED)


class MessageDelivery(Base):
    __tablename__ = "message_deliveries"

    id                 = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    message_id         = Column(String(64), nullable=False)
    # The conversation: (listing_id, buyer_id) or (store_id, buyer_id).
    listing_id         = Column(String, nullable=True)
    store_id           = Column(String, nullable=True)
    buyer_id           = Column(String, nullable=False)
    sender_id          = Column(String, nullable=False)    # "broker" for Zeno
    recipient_id       = Column(String, nullable=False)
    recipient_role     = Column(String(16), nullable=False)  # "buyer" | "seller"
    # Zeno's message to this side: read in Zeno's room, not the direct chat,
    # so the direct chat's read receipt does not read it.
    from_zeno          = Column(Boolean, nullable=False, default=False)
    message_created_at = Column(DateTime, nullable=False)

    status             = Column(String(16), nullable=False, default=SAVED)
    push_attempts      = Column(Integer, nullable=False, default=0)
    # When the retry sweep should look at this row's push again. NULL once
    # nothing more will be tried: accepted, given up, or delivered already.
    next_push_at       = Column(DateTime, nullable=True)
    push_error         = Column(String(64), nullable=True)
    push_accepted_at   = Column(DateTime, nullable=True)
    delivered_at       = Column(DateTime, nullable=True)
    # What proved it: "sync", "chat", "push_receipt", "read".
    delivered_via      = Column(String(24), nullable=True)
    read_at            = Column(DateTime, nullable=True)
    # The last time the app's sync handed this message out.
    synced_at          = Column(DateTime, nullable=True)
    created_at         = Column(DateTime, nullable=False, default=datetime.utcnow)
    updated_at         = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("message_id", "recipient_id", name="uq_message_deliveries_message_recipient"),
        # The app's sync: this recipient's undelivered messages, oldest first.
        Index("ix_message_deliveries_recipient_status", "recipient_id", "status", "message_created_at"),
        # The retry sweep.
        Index("ix_message_deliveries_next_push", "next_push_at"),
        # Push claims and read receipts, per conversation and side.
        Index("ix_message_deliveries_listing_thread", "listing_id", "buyer_id", "recipient_role"),
        Index("ix_message_deliveries_store_thread", "store_id", "buyer_id", "recipient_role"),
        Index("ix_message_deliveries_created", "created_at"),
    )
