"""LedgerEntry model — moved here for domain consistency. Logic stays in api/core/ledger.py."""
import uuid
from datetime import datetime
from decimal import Decimal
from enum import Enum
from sqlalchemy import Column, String, Numeric, DateTime, Enum as PgEnum
from api.database import Base

class LedgerAccount(str, Enum):
    buyer_wallet   = "BUYER_WALLET"
    escrow_holding = "ESCROW_HOLDING"
    seller_wallet  = "SELLER_WALLET"
    broka_revenue  = "BROKA_REVENUE"
    refund_payable = "REFUND_PAYABLE"

class LedgerDirection(str, Enum):
    debit  = "DEBIT"
    credit = "CREDIT"

class LedgerEntry(Base):
    """Immutable append-only ledger. NEVER UPDATE or DELETE — add compensating entries only."""
    __tablename__ = "ledger_entries"
    id          = Column(String, primary_key=True, default=lambda: str(uuid.uuid4()))
    deal_id     = Column(String, nullable=False, index=True)
    account     = Column(PgEnum(LedgerAccount, name="ledger_account"), nullable=False)
    direction   = Column(PgEnum(LedgerDirection, name="ledger_direction"), nullable=False)
    amount_kes  = Column(Numeric(precision=18, scale=2), nullable=False)
    description = Column(String, nullable=False)
    ref_id      = Column(String, nullable=True)
    created_at  = Column(DateTime, default=datetime.utcnow, nullable=False)
