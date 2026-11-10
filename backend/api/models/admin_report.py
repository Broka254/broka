"""AdminReport - a stored founder report (daily, weekly or monthly brief).

The admin dashboard's report archive. A row is written by the 5-minute
sweep once a period has closed (api/core/admin_reports.py) or by an
administrator regenerating one. Reports are stored, not recomputed on
read, because part of every report is point-in-time: live listings, open
complaints and buyers waiting on a seller cannot be reconstructed later
from the tables. A brief read next month must still say what the
marketplace looked like that week.

Only aggregates, ids and the names admin screens already show are kept in
`payload` - never complaint bodies, chat text or contact details.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base

REPORT_KINDS = ("daily", "weekly", "monthly")


class AdminReport(Base):
    __tablename__ = "admin_reports"

    id = sa.Column(sa.String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    kind = sa.Column(sa.String(16), nullable=False)
    # Naive UTC, half-open [period_start, period_end). The boundaries are
    # local (EAT) midnights converted to UTC - see admin_reports.period_bounds.
    period_start = sa.Column(sa.DateTime, nullable=False)
    period_end = sa.Column(sa.DateTime, nullable=False)
    title = sa.Column(sa.String(160), nullable=False)
    headline = sa.Column(sa.Text, nullable=False, default="")
    # "system" for the scheduled run, else the administrator's user id. A
    # plain string, not a foreign key: it holds "system" (AGENTS.md).
    generated_by = sa.Column(sa.String(64), nullable=False, default="system")
    generated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow, index=True)
    payload = sa.Column(sa.JSON, nullable=False)

    __table_args__ = (
        sa.CheckConstraint(
            "kind IN ('daily','weekly','monthly')", name="ck_admin_reports_kind"),
        # One report per period: two replicas finishing the same sweep, or
        # a sweep racing an administrator's regenerate, converge on one row.
        sa.UniqueConstraint("kind", "period_start", name="uq_admin_reports_kind_period"),
    )
