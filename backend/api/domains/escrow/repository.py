"""Escrow / Deal Repository."""
from __future__ import annotations

from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from api.database import Deal, DealStatus, MpesaTransaction, MpesaStatus
from api.models.external_escrow import ExternalEscrow


class DealRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_id(self, deal_id: str) -> Optional[Deal]:
        r = await self.db.execute(select(Deal).where(Deal.id == deal_id))
        return r.scalar_one_or_none()

    async def get_by_listing_buyer(self, listing_id: str, buyer_id: str) -> Optional[Deal]:
        r = await self.db.execute(
            select(Deal).where(
                Deal.listing_id == listing_id,
                Deal.buyer_id == buyer_id,
            )
        )
        return r.scalar_one_or_none()

    async def create(self, **kwargs) -> Deal:
        deal = Deal(**kwargs)
        self.db.add(deal)
        await self.db.flush()  # get ID without full commit
        return deal

    async def update_status(self, deal: Deal, status: DealStatus) -> Deal:
        deal.status = status
        await self.db.flush()
        return deal


class MpesaRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_checkout_id(self, checkout_id: str) -> Optional[MpesaTransaction]:
        r = await self.db.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.checkout_request_id == checkout_id
            )
        )
        return r.scalar_one_or_none()

    async def get_latest_for_deal(self, deal_id: str) -> Optional[MpesaTransaction]:
        r = await self.db.execute(
            select(MpesaTransaction)
            .where(MpesaTransaction.deal_id == deal_id)
            .order_by(MpesaTransaction.created_at.desc())
            .limit(1)
        )
        return r.scalar_one_or_none()

    async def create(self, **kwargs) -> MpesaTransaction:
        tx = MpesaTransaction(**kwargs)
        self.db.add(tx)
        await self.db.flush()
        return tx


class ExternalEscrowRepository:
    """Provider-agnostic escrow state for a Deal — see api/models/
    external_escrow.py. Deliberately its own repository class rather than
    folded into DealRepository: it's a distinct table with a distinct
    lifecycle (create → fund → reconcile → release), not a Deal field."""

    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_deal_id(self, deal_id: str) -> Optional[ExternalEscrow]:
        r = await self.db.execute(
            select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
        )
        return r.scalar_one_or_none()

    async def get_by_provider_transaction_id(self, provider_transaction_id: str) -> Optional[ExternalEscrow]:
        r = await self.db.execute(
            select(ExternalEscrow).where(
                ExternalEscrow.provider_transaction_id == provider_transaction_id
            )
        )
        return r.scalar_one_or_none()

    async def get_reconcilable(self, limit: int = 200) -> list[ExternalEscrow]:
        """Escrows not yet in a terminal state — what the periodic
        reconciliation worker sweeps (api/core/workers.py)."""
        from api.models.external_escrow import EConfirmEscrowStatus
        r = await self.db.execute(
            select(ExternalEscrow)
            .where(
                ExternalEscrow.status.notin_(EConfirmEscrowStatus.TERMINAL),
                ExternalEscrow.provider_transaction_id.isnot(None),
            )
            .order_by(ExternalEscrow.updated_at.asc())
            .limit(limit)
        )
        return list(r.scalars().all())

    async def create(self, **kwargs) -> ExternalEscrow:
        escrow = ExternalEscrow(**kwargs)
        self.db.add(escrow)
        await self.db.flush()  # get ID without full commit
        return escrow

    async def save(self, escrow: ExternalEscrow) -> ExternalEscrow:
        """Flush pending in-place attribute changes on an already-tracked
        instance (the common case: caller mutated fields directly then
        calls this to flush), matching DealRepository.update_status's
        flush-not-commit convention — the caller's endpoint commits."""
        self.db.add(escrow)
        await self.db.flush()
        return escrow
