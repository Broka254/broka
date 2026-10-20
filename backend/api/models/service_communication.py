"""Admin-controlled service communications and their delivery ledger.

These rows are the durable source of truth for operational messaging:
drafts, scheduled maintenance/incident notices and their audience snapshot.
Provider delivery is deliberately a separate state machine from in-app
availability - a published announcement remains readable even when every
push attempt fails.

The recipient table has one row per (communication, user), enforced by the
database. A user can have several phones, so device-level attempts live in a
second table. Those rows store only a fingerprint of the FCM token: the token
itself is already managed by `push_devices`, and copying it into an audit or
delivery ledger would turn a retry history into a list of bearer credentials.
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean, CheckConstraint, Column, DateTime, ForeignKey, Index, Integer,
    String, Text, UniqueConstraint,
)

from api.database import Base


COMMUNICATION_TYPES = ("announcement", "maintenance", "incident", "product_update")
COMMUNICATION_SEVERITIES = ("low", "normal", "high", "critical")
COMMUNICATION_STATUSES = (
    "draft", "scheduled", "publishing", "published", "completed", "cancelled",
    "failed",
)
DELIVERY_STATUSES = (
    "queued", "sending", "provider_accepted", "delivered", "failed",
    "retry_scheduled",
)


class ServiceCommunication(Base):
    __tablename__ = "service_communications"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    title = Column(String(160), nullable=False)
    body = Column(Text, nullable=False)
    communication_type = Column(String(32), nullable=False)
    severity = Column(String(16), nullable=False, default="normal")
    status = Column(String(24), nullable=False, default="draft")

    audience_json = Column(Text, nullable=False)
    channels_json = Column(Text, nullable=False)
    audience_count = Column(Integer, nullable=True)
    deep_link = Column(String(512), nullable=True)

    created_by_id = Column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    updated_by_id = Column(String(36), ForeignKey("users.id"), nullable=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow, index=True)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    scheduled_at = Column(DateTime, nullable=True, index=True)
    published_at = Column(DateTime, nullable=True, index=True)
    completed_at = Column(DateTime, nullable=True)
    cancelled_at = Column(DateTime, nullable=True)
    expires_at = Column(DateTime, nullable=True, index=True)

    # Scoped, hashed client idempotency key. The unique index makes two
    # concurrent publish requests converge even when Redis is unavailable.
    publish_idempotency_key = Column(String(64), nullable=True, unique=True)
    # A publishing row whose lease expired is resumable. The token names the
    # worker that owns audience expansion; it is never sent to a client.
    publish_claim_token = Column(String(64), nullable=True)
    publish_claim_expires_at = Column(DateTime, nullable=True)
    version = Column(Integer, nullable=False, default=1)

    __table_args__ = (
        CheckConstraint(
            "communication_type IN ('announcement','maintenance','incident','product_update')",
            name="ck_service_communications_type",
        ),
        CheckConstraint(
            "severity IN ('low','normal','high','critical')",
            name="ck_service_communications_severity",
        ),
        CheckConstraint(
            "status IN ('draft','scheduled','publishing','published','completed','cancelled','failed')",
            name="ck_service_communications_status",
        ),
        Index("ix_service_communications_status_schedule", "status", "scheduled_at"),
        Index("ix_service_communications_visibility", "status", "published_at", "expires_at"),
        Index("ix_service_communications_publish_claim", "publish_claim_token"),
    )


class ServiceCommunicationVersion(Base):
    """Append-only draft/edit snapshots.

    The live row is what workers read; this table is for accountability and
    lets an administrator see exactly what was queued before publication.
    """

    __tablename__ = "service_communication_versions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    communication_id = Column(
        String(36), ForeignKey("service_communications.id"), nullable=False, index=True,
    )
    version = Column(Integer, nullable=False)
    title = Column(String(160), nullable=False)
    body = Column(Text, nullable=False)
    communication_type = Column(String(32), nullable=False)
    severity = Column(String(16), nullable=False)
    audience_json = Column(Text, nullable=False)
    channels_json = Column(Text, nullable=False)
    deep_link = Column(String(512), nullable=True)
    edited_by_id = Column(String(36), ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("communication_id", "version", name="uq_service_communication_version"),
        Index("ix_service_communication_versions_created", "communication_id", "created_at"),
    )


class ServiceCommunicationRecipient(Base):
    """One user's aggregate delivery state for one communication.

    `delivered_at` is reserved for provider evidence that actually proves
    display. FCM's message id only proves acceptance, so this column stays
    NULL for FCM deliveries. `read_at` is the in-app read acknowledgement and
    is independent of push delivery.
    """

    __tablename__ = "service_communication_recipients"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    communication_id = Column(
        String(36), ForeignKey("service_communications.id"), nullable=False, index=True,
    )
    user_id = Column(String(36), ForeignKey("users.id"), nullable=False, index=True)
    status = Column(String(24), nullable=False, default="queued")
    attempt_count = Column(Integer, nullable=False, default=0)
    last_attempt_at = Column(DateTime, nullable=True)
    provider_message_id = Column(String(255), nullable=True)
    delivered_at = Column(DateTime, nullable=True)
    read_at = Column(DateTime, nullable=True)
    failure_category = Column(String(64), nullable=True)
    retry_eligible = Column(Boolean, nullable=False, default=False)
    next_attempt_at = Column(DateTime, nullable=True)
    claim_token = Column(String(64), nullable=True)
    claim_expires_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint("communication_id", "user_id", name="uq_service_communication_recipient"),
        CheckConstraint(
            "status IN ('queued','sending','provider_accepted','delivered','failed','retry_scheduled')",
            name="ck_service_communication_recipient_status",
        ),
        Index(
            "ix_service_communication_recipient_due",
            "status", "next_attempt_at",
        ),
        Index(
            "ix_service_communication_recipient_user_read",
            "user_id", "read_at",
        ),
        Index("ix_service_communication_recipient_claim", "claim_token"),
    )


class ServiceCommunicationDeviceDelivery(Base):
    """Per-device attempt state for a recipient.

    `device_fingerprint` is SHA-256 of the token, never the token. A rotated
    token therefore creates a new row while old outcomes remain auditable.
    """

    __tablename__ = "service_communication_device_deliveries"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    recipient_id = Column(
        String(36), ForeignKey("service_communication_recipients.id"),
        nullable=False, index=True,
    )
    communication_id = Column(
        String(36), ForeignKey("service_communications.id"), nullable=False, index=True,
    )
    device_fingerprint = Column(String(64), nullable=False)
    status = Column(String(24), nullable=False, default="queued")
    attempt_count = Column(Integer, nullable=False, default=0)
    last_attempt_at = Column(DateTime, nullable=True)
    provider_message_id = Column(String(255), nullable=True)
    delivered_at = Column(DateTime, nullable=True)
    failure_category = Column(String(64), nullable=True)
    retry_eligible = Column(Boolean, nullable=False, default=False)
    next_attempt_at = Column(DateTime, nullable=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        UniqueConstraint(
            "recipient_id", "device_fingerprint",
            name="uq_service_communication_device",
        ),
        CheckConstraint(
            "status IN ('queued','sending','provider_accepted','delivered','failed','retry_scheduled')",
            name="ck_service_communication_device_status",
        ),
        Index("ix_service_communication_device_status", "recipient_id", "status"),
    )
