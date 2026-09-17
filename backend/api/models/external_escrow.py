"""ExternalEscrow model - tracks E-Confirm's side of a marketplace deal.

New table, defined the same way api/models/store.py's Store model is: a
plain SQLAlchemy model importing Base from api.database, NOT re-exported
from database.py itself. api.database.init_db()'s Base.metadata.create_all()
picks this up automatically the first time it's imported anywhere (which
happens at import time via api.domains.escrow.service — see init_db()'s own
defensive "from api.models.external_escrow import ExternalEscrow" import
too, matching the belt-and-suspenders pattern already used for Store/Dispute).
No Alembic migration needed or wanted for this — see api/core/
migrations_guide.py for why this repo doesn't use Alembic in practice.

This table is deliberately separate from Deal (api.database.Deal) and from
MpesaTransaction: Deal stays the source of truth for BROKA's business
lifecycle (see DealStatus), MpesaTransaction stays specific to Safaricom
Daraja, and this table is E-Confirm's side of the story only — the mapping
between the two lives in api/domains/escrow/service.py's status-mapping
logic (Phase 19 of the integration), not in either model.

confirmation_code is stored ENCRYPTED ONLY (see api/core/secrets_crypto.py)
and is never stored on Deal itself, never returned through any API
response, never logged. The plaintext only ever exists in memory, briefly,
inside EscrowService's release flow.

Timestamps are naive UTC (plain `DateTime`, `datetime.utcnow()`), matching
every existing timestamp column on Deal in api/database.py — NOT
timezone-aware. Mixing the two would make simple subtraction between an
ExternalEscrow timestamp and a Deal timestamp (or a bare
`datetime.utcnow()`) raise TypeError at runtime, so this deliberately
follows the codebase's existing convention rather than being "more
correct" in isolation.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


# Internal BROKA-side status vocabulary for this table's `status` column.
# Deliberately NOT a DB-level enum (plain string column) so a new provider
# state discovered later doesn't need a schema change - see
# EscrowProvider.map_status() in providers.py, which is the one place that
# turns a raw provider string into one of these. `unknown` exists precisely
# so an unrecognized provider string has somewhere safe to land without
# EscrowService having to guess (Phase 19: "Never map unknown provider
# strings automatically").
class EConfirmEscrowStatus:
    CREATING        = "creating"          # local-only: create_transaction call in flight
    PENDING         = "pending"           # created, not yet funded (incl. stk_initiated)
    FUNDED          = "funded"            # provider: "Escrow Funded"
    RELEASE_PENDING = "release_pending"   # provider: "payout_initiated"
    COMPLETED       = "completed"         # provider: "Completed" - payout done
    PAYOUT_FAILED   = "payout_failed"     # provider: "payout_failed"
    UNKNOWN         = "unknown"           # unrecognized provider status string

    TERMINAL = (COMPLETED,)  # only state past which no further reconciliation is needed


class ExternalEscrow(Base):
    __tablename__ = "external_escrows"

    id                          = sa.Column(sa.String, primary_key=True, default=_uuid)
    deal_id                     = sa.Column(sa.String, sa.ForeignKey("deals.id"), nullable=False, unique=True, index=True)
    provider                    = sa.Column(sa.String(32), nullable=False, default="econfirm")

    # Null until create_transaction() succeeds - see EscrowService's
    # two-phase create (insert 'creating' row, then fill this in) for why
    # this has to be nullable rather than required at insert time.
    provider_transaction_id     = sa.Column(sa.String, nullable=True, unique=True, index=True)

    confirmation_code_encrypted = sa.Column(sa.Text, nullable=True)

    status                      = sa.Column(sa.String(32), nullable=False, default=EConfirmEscrowStatus.CREATING)
    provider_raw_status         = sa.Column(sa.String(64), nullable=True)  # exact provider string, unmapped

    amount                      = sa.Column(sa.Float, nullable=False)      # goods price only, matches Deal.agreed_price
    currency                    = sa.Column(sa.String(8), nullable=False, default="KES")

    buyer_email                 = sa.Column(sa.String, nullable=False)
    seller_email                = sa.Column(sa.String, nullable=False)
    receiver_phone              = sa.Column(sa.String, nullable=False)  # seller payout number
    payer_phone                 = sa.Column(sa.String, nullable=True)   # set once funding is attempted

    merchant_commission_amount  = sa.Column(sa.Float, nullable=True)   # BROKA's cut, snapshotted at creation
    provider_fee_amount         = sa.Column(sa.Float, nullable=True)   # E-Confirm's own fee, from fee_quote()

    last_checked_at             = sa.Column(sa.DateTime, nullable=True)
    funding_initiated_at        = sa.Column(sa.DateTime, nullable=True)
    funded_at                   = sa.Column(sa.DateTime, nullable=True)
    release_initiated_at        = sa.Column(sa.DateTime, nullable=True)
    released_at                 = sa.Column(sa.DateTime, nullable=True)

    last_error                  = sa.Column(sa.Text, nullable=True)  # safe (non-secret) diagnostic text only

    created_at                  = sa.Column(sa.DateTime, default=datetime.utcnow, nullable=False)
    updated_at                  = sa.Column(sa.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)

    def __repr__(self) -> str:  # pragma: no cover - debugging aid only
        return f"<ExternalEscrow deal_id={self.deal_id} status={self.status} provider_tx={self.provider_transaction_id}>"
