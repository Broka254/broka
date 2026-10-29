"""PlatformCost model — every shilling BROKA spends to serve users.

One row per unit of cost actually incurred (an SMS handed to a provider, a
provider fee on a settled payment), never per hypothetical. Rows written
from an assumed rate carry estimated=True so revenue math can separate
measured spend from modelled spend. Amounts are integer minor units of
`currency` (KES cents: KES 0.35 is 35).
"""
from __future__ import annotations

from datetime import datetime

import sqlalchemy as sa

from api.database import Base


class CostKind:
    SMS = "sms"
    AI = "ai"
    API = "api"
    PAYMENT_FEE = "payment_fee"
    INFRA = "infra"
    OTHER = "other"
    ALL = (SMS, AI, API, PAYMENT_FEE, INFRA, OTHER)


class PlatformCost(Base):
    __tablename__ = "platform_costs"

    id = sa.Column(sa.Integer, primary_key=True, autoincrement=True)
    kind = sa.Column(sa.String(16), nullable=False, index=True)
    amount_minor = sa.Column(sa.Integer, nullable=False)
    currency = sa.Column(sa.String(8), nullable=False, default="KES")
    provider = sa.Column(sa.String(64), nullable=True)
    ref_type = sa.Column(sa.String(64), nullable=True)
    ref_id = sa.Column(sa.String, nullable=True, index=True)
    estimated = sa.Column(sa.Boolean, nullable=False, default=False)
    meta = sa.Column(sa.JSON, nullable=True)
    created_at = sa.Column(
        sa.DateTime, nullable=False, default=datetime.utcnow, index=True
    )
