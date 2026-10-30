"""User feedback and complaints.

One table for both: `kind` separates an opinion/suggestion (`feedback`)
from a problem that needs remedy (`complaint`). This is deliberately not
the dispute engine: a complaint here is about the platform experience
(a rude trader, a confusing screen, a failed payment flow), not a ruling
on escrowed money. Complaints that turn out to be deal disputes are
triaged by an admin pointing the user at /disputes.

Bodies are user text: never logged verbatim, never echoed to another
user. Admin replies are stored on the row so the user can see the
outcome in their own submission history.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    CheckConstraint, Column, DateTime, ForeignKey, Index, Integer, String, Text,
)

from api.database import Base

FEEDBACK_KINDS = ("feedback", "complaint")
FEEDBACK_CATEGORIES = (
    "general", "bug", "suggestion", "compliment", "account", "payments",
    "listing", "seller_conduct", "buyer_conduct", "delivery", "safety",
    "other",
)
FEEDBACK_SEVERITIES = ("low", "normal", "high", "urgent")
FEEDBACK_STATUSES = ("open", "acknowledged", "in_progress", "resolved", "closed")


class UserFeedback(Base):
    __tablename__ = "user_feedback"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    kind = Column(String(16), nullable=False, default="feedback")
    category = Column(String(32), nullable=False, default="general")
    severity = Column(String(16), nullable=False, default="normal")
    subject = Column(String(160), nullable=False)
    body = Column(Text, nullable=False)
    # Optional pointers at what the report is about. Free ids, not foreign
    # keys: the listing/deal/user may be deleted before triage, and the
    # report must survive that.
    related_listing_id = Column(String(36), nullable=True)
    related_deal_id = Column(String(36), nullable=True)
    related_user_id = Column(String(36), nullable=True)
    status = Column(String(24), nullable=False, default="open")
    admin_response = Column(Text, nullable=True)
    responded_by_id = Column(String(36), ForeignKey("users.id"), nullable=True)
    responded_at = Column(DateTime, nullable=True)
    resolved_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow, index=True)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        CheckConstraint(
            "kind IN ('feedback','complaint')", name="ck_user_feedback_kind"),
        CheckConstraint(
            "status IN ('open','acknowledged','in_progress','resolved','closed')",
            name="ck_user_feedback_status"),
        CheckConstraint(
            "severity IN ('low','normal','high','urgent')",
            name="ck_user_feedback_severity"),
        Index("ix_user_feedback_status_created", "status", "created_at"),
        Index("ix_user_feedback_user_created", "user_id", "created_at"),
    )
