"""Scam reports: their structured details, private evidence, protective
restrictions and appeals (api/domains/scam_reports).

A scam report is a complaint first: filing one creates a `user_feedback` row
(kind "complaint", category "safety"), so the existing triage queue, alerts,
SLA clock and `repeat_reported_users` all see it. `scam_report_details` hangs
the structured facts off that row.

EVIDENCE IS PRIVATE. A screenshot of a chat or an M-Pesa message carries
phone numbers and names. It is stored here, as bytes, and served only to the
person who filed the report and to administrators who hold the evidence
permission - every such view by an administrator is written to the audit
log. It is never in the public media bucket, whose URLs are readable by
anyone who learns one (see models/chat_file.py for the same reasoning).

NO PIN, OTP OR PASSWORD IS STORED. The report form has no field for one, and
the description is user text that Zeno's guidance tells people never to put
a code into; nothing here asks for or checks for one, so an administrator
who sees one in a description should tell the reporter to change it.

New tables, so init_db()'s create_all() creates them (schema revision 18).
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, Index, Integer, LargeBinary, String, Text

from api.database import Base


class ScamReportDetail(Base):
    __tablename__ = "scam_report_details"

    # One-to-one with the complaint it extends. The feedback row holds who
    # filed it, the status and the admin's replies; this holds the facts.
    feedback_id = Column(String(36), primary_key=True)
    # Denormalised so "my report" checks need no join, and a report survives
    # the complaint's own edits.
    reporter_id = Column(String(36), nullable=False, index=True)
    # The Broka account reported, when it is one. Not a foreign key: the user
    # may be deleted before the report is reviewed and the report must survive.
    reported_user_id = Column(String(36), nullable=True, index=True)
    # What the reporter typed for an account outside Broka (a phone number, a
    # website, a name), and its normalised form, used to count independent
    # reports of the same one (policy.normalise_account_ref).
    reported_account_ref = Column(String(120), nullable=True)
    reported_account_key = Column(String(120), nullable=True, index=True)
    # The provider and transaction the reporter says were involved. Free text:
    # a provider's own reference means nothing to BROKA and is never looked up.
    provider_id = Column(String(40), nullable=True)
    transaction_reference = Column(String(80), nullable=True)
    reason_code = Column(String(40), nullable=False)
    amount_kes = Column(Integer, nullable=True)
    payment_sent = Column(Boolean, nullable=False, default=False)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow, index=True)


class ScamReportEvidence(Base):
    __tablename__ = "scam_report_evidence"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    feedback_id = Column(String(36), nullable=False, index=True)
    uploader_id = Column(String(36), nullable=False)
    # Decided by the server from the file's first bytes, never the client's word.
    file_name = Column(String(100), nullable=False)
    mime_type = Column(String(40), nullable=False)
    size_bytes = Column(Integer, nullable=False)
    sha256 = Column(String(64), nullable=False)
    data = Column(LargeBinary, nullable=False)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)


class AccountRestriction(Base):
    __tablename__ = "account_restrictions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(String(36), nullable=False, index=True)
    # The report that prompted it, when one did.
    feedback_id = Column(String(36), nullable=True)
    # JSON list of scopes ("create_listing", "make_offer"): stored as text so
    # the column is portable; policy.SCOPES is the vocabulary.
    scopes = Column(String(120), nullable=False)
    # What the team wrote down, and what the person is told. Never the same field.
    internal_reason = Column(Text, nullable=False)
    public_reason = Column(String(300), nullable=False)
    status = Column(String(12), nullable=False, default="active", index=True)
    applied_by = Column(String(36), nullable=False)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # Required: every restriction ends. The clock ends it; nothing has to run.
    expires_at = Column(DateTime, nullable=False)
    lifted_at = Column(DateTime, nullable=True)
    lifted_by = Column(String(36), nullable=True)
    lift_note = Column(Text, nullable=True)

    __table_args__ = (Index("ix_account_restrictions_user_status", "user_id", "status"),)


class RestrictionAppeal(Base):
    __tablename__ = "restriction_appeals"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    restriction_id = Column(String(36), nullable=False, index=True)
    user_id = Column(String(36), nullable=False, index=True)
    statement = Column(Text, nullable=False)
    status = Column(String(12), nullable=False, default="open", index=True)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    decided_by = Column(String(36), nullable=True)
    decided_at = Column(DateTime, nullable=True)
    # What the person is told about the decision.
    decision_note = Column(Text, nullable=True)
