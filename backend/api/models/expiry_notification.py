"""Expiry SMS dedup: one "goes offline in 2 days" text per paid period.

The sweep (pricing/expiry_alerts.py) runs every few minutes on every
replica, so "have we already texted about this?" cannot live in process
memory. One row per (entity, paid_until) is the answer:

  * UNIQUE(entity_type, entity_id, paid_until) - renewing moves paid_until,
    so a renewed listing/store legitimately earns a NEW text for its new
    period, while every sweep pass for the same period finds the row and
    stays silent;
  * a row is only kept once the SMS provider accepted the message. A failed
    send deletes its claim row, so the next pass retries instead of the
    dedup table permanently swallowing the one warning the seller gets.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class ExpiryEntity:
    LISTING = "listing"
    STORE = "store"


class ExpiryNotification(Base):
    __tablename__ = "expiry_notifications"
    __table_args__ = (
        sa.UniqueConstraint(
            "entity_type", "entity_id", "paid_until",
            name="uq_expiry_notification_period",
        ),
        sa.Index("ix_expiry_notification_entity", "entity_type", "entity_id"),
    )

    id          = sa.Column(sa.String, primary_key=True, default=_uuid)
    entity_type = sa.Column(sa.String(16), nullable=False)   # ExpiryEntity.*
    entity_id   = sa.Column(sa.String, nullable=False)
    user_id     = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    # Snapshot of the deadline this text warned about. Never updated:
    # it is the dedup key, and a renewal writes a different value.
    paid_until  = sa.Column(sa.DateTime, nullable=False)
    channel     = sa.Column(sa.String(8), nullable=False, default="sms")
    sent_at     = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
