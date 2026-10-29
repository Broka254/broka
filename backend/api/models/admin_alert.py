"""AdminAlert model — persisted operational alerts for the admin dashboard.

Alerts are created by event subscribers (api/core/admin_alert_subscribers.py)
or by hand through POST /admin/alerts. They are operational state, not money:
resolving one changes no deal, payment or dispute row.
"""
from __future__ import annotations

from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class AlertStatus:
    OPEN = "open"
    ACKNOWLEDGED = "acknowledged"
    RESOLVED = "resolved"
    ALL = (OPEN, ACKNOWLEDGED, RESOLVED)


class AlertSeverity:
    CRITICAL = "critical"
    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"
    INFO = "info"
    ALL = (CRITICAL, HIGH, MEDIUM, LOW, INFO)


class AdminAlert(Base):
    __tablename__ = "admin_alerts"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    kind = sa.Column(sa.String(64), nullable=False, index=True)
    severity = sa.Column(sa.String(16), nullable=False, index=True)
    title = sa.Column(sa.String(255), nullable=False)
    body = sa.Column(sa.Text, nullable=True)
    href = sa.Column(sa.String(255), nullable=True)
    status = sa.Column(
        sa.String(16), nullable=False, default=AlertStatus.OPEN, index=True
    )
    # Stable reference for dedup, e.g. {"dispute_id": "..."}. A second
    # event for the same entity must not open a second alert while the
    # first is still open (see create_alert in api/core/admin_alerts.py).
    meta = sa.Column(sa.JSON, nullable=True)
    created_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, index=True
    )
    acknowledged_at = sa.Column(sa.DateTime, nullable=True)
    # Plain string, not a foreign key: the actor can be an admin id and the
    # column must never block a write on a missing row (AGENTS.md rule).
    acknowledged_by = sa.Column(sa.String, nullable=True)
    resolved_at = sa.Column(sa.DateTime, nullable=True)
