"""The escrow provider directory's storage (api/domains/escrow_directory).

Two tables, and neither holds money or any customer's data:

  escrow_providers           one row per provider an administrator has
                             edited: the whole record as JSON. A provider
                             with no row is served from the seed in code
                             (catalogue.merge), so a fresh database lists
                             the starting providers - as under review.
  escrow_provider_revisions  every change, kept: who, when, what kind of
                             change, why, the source for a fee change, and
                             the record before and after. Append-only by
                             convention (nothing in the app updates or
                             deletes a row), like audit_logs - and the
                             answer to "who changed Kenya Escrow's fee, and
                             what did they say they read?".

The record is JSON, not a column per field, because it is a document that is
validated as a whole (escrow_directory/schema.py) and read as a whole; a
column per fee band would only make a fee change a migration.

New tables, so init_db()'s create_all() creates them (schema revision 18).
"""
from __future__ import annotations

import uuid
from datetime import datetime

from sqlalchemy import Column, DateTime, Index, Integer, JSON, String, Text

from api.database import Base

# What a revision records.
REVISION_KINDS = (
    "created", "edited", "pricing_changed", "reviewed", "approved", "suspended",
    "reinstated", "rejected", "status_changed",
)


class EscrowProviderRow(Base):
    __tablename__ = "escrow_providers"

    # The record's own id ("kenyaescrow"): stable and human-readable, and the
    # one the apps and Zeno use. Not a UUID.
    id = Column(String(40), primary_key=True)
    # Duplicated out of the JSON so a list can be filtered and an index used
    # without parsing every document. The JSON is the truth; the repository
    # writes both together and re-derives these from it.
    status = Column(String(16), nullable=False, index=True)
    canonical_domain = Column(String(120), nullable=False)
    record = Column(JSON, nullable=False)
    # Optimistic concurrency: an edit names the version it read, and loses to
    # an edit that landed in between instead of overwriting it silently.
    version = Column(Integer, nullable=False, default=1)
    updated_at = Column(DateTime, nullable=False, default=datetime.utcnow)
    # Plain string, not a foreign key (AGENTS.md): an admin id must never
    # block a write on a missing row.
    updated_by = Column(String(36), nullable=True)


class EscrowProviderRevision(Base):
    __tablename__ = "escrow_provider_revisions"

    id = Column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    provider_id = Column(String(40), nullable=False, index=True)
    version = Column(Integer, nullable=False)
    kind = Column(String(24), nullable=False)
    actor_id = Column(String(36), nullable=False)
    # Why: required for every administrative change.
    reason = Column(Text, nullable=False)
    # For a fee change: the page the new figures were read from and what it
    # said. A fee with no source is refused before it gets here.
    source_url = Column(String(300), nullable=True)
    source_note = Column(Text, nullable=True)
    before = Column(JSON, nullable=True)
    after = Column(JSON, nullable=False)
    created_at = Column(DateTime, nullable=False, default=datetime.utcnow, index=True)

    __table_args__ = (
        Index("ix_escrow_provider_revisions_provider_created", "provider_id", "created_at"),
    )
