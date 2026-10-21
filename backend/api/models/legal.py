"""Durable evidence of what a user accepted, and when.

Append-only by intent: a row is written once, inside the same transaction
as the account it belongs to, and never updated. A later revision of a
document adds a new row (the unique key includes the version), so the
history of what was accepted - and what it said - survives a rename or a
rewrite of the document itself.

Deliberately absent: IP address, device identifiers, user agent and any
timestamp the client supplied. The only timestamp is the server's clock.
The age row records a declared eligibility, not a verified age.
"""
from __future__ import annotations

import uuid

from sqlalchemy import (
    CheckConstraint, Column, DateTime, ForeignKey, String, UniqueConstraint,
)

from api.database import Base


class LegalAcceptance(Base):
    __tablename__ = "legal_acceptances"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id = Column(
        String(36), ForeignKey("users.id"), nullable=False, index=True,
    )
    # What was declared: an age eligibility, an agreement to the Terms, or
    # an acknowledgement of the Privacy Policy. These are not interchangeable
    # and one is never inferred from another.
    acceptance_type = Column(String(40), nullable=False)
    # Which document (stable id) and which revision of it. For the age row,
    # the version of the declaration wording.
    document_id = Column(String(80), nullable=False)
    document_version = Column(String(64), nullable=False)
    # SHA-256 of the exact text shown, when there is a published document.
    # This is the revision identifier that survives two edits on one day;
    # NULL on the eligibility declaration, which has no document beside it.
    document_digest = Column(String(64), nullable=True)
    # Server-generated, naive UTC (the codebase-wide convention). Never
    # read from the request.
    accepted_at = Column(DateTime, nullable=False)

    __table_args__ = (
        # One acceptance of one revision per user. A re-acceptance after a
        # document change is a different document_version, so it gets its
        # own row rather than overwriting history.
        UniqueConstraint(
            "user_id", "acceptance_type", "document_version",
            name="uq_legal_acceptances_user_type_version",
        ),
        CheckConstraint(
            "acceptance_type IN ('age_confirmed', 'terms_accepted', "
            "'privacy_acknowledged')",
            name="ck_legal_acceptances_type",
        ),
    )
