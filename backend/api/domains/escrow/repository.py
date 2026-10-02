"""Escrow / Deal Repository."""
from __future__ import annotations

from typing import Optional
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from api.database import Deal, DealStatus, MpesaTransaction, MpesaStatus
from api.models.external_escrow import ExternalEscrow


# A deal in one of these is finished. It is history: it settled, it was
# reversed, or it was abandoned. Nothing about it can be advanced, and
# nothing about it should stop the same two people transacting again on the
# same listing months later.
#
# Everything NOT listed here - negotiating, agreed, paid, disputed, and the
# four awaiting_* post-delivery sub-states - is a live transaction with
# money or an obligation still attached to it. That is the deal a second
# finalize attempt means to join, not to duplicate.
TERMINAL_DEAL_STATUSES = frozenset({
    DealStatus.released,    # buyer confirmed delivery, seller paid out
    DealStatus.refunded,    # dispute resolved for the buyer
    DealStatus.cancelled,   # abandoned, or an auction win that lapsed unpaid
})


class DealRepository:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def get_by_id(self, deal_id: str) -> Optional[Deal]:
        r = await self.db.execute(select(Deal).where(Deal.id == deal_id))
        return r.scalar_one_or_none()

    async def get_by_listing_buyer(self, listing_id: str, buyer_id: str) -> Optional[Deal]:
        """The MOST RECENT deal for this pair, whatever state it is in.

        Used to be a bare scalar_one_or_none() over an unordered, unlimited
        query. A repeat purchase - the same buyer buying from the same
        listing twice, which this marketplace explicitly allows and
        test_completion_rate.py relies on - puts two rows here, and
        scalar_one_or_none() raises MultipleResultsFound on two rows. So
        the second deal between any pair turned this into a 500 rather than
        returning anything at all.

        Ordering newest-first and taking one makes it answer the question
        it is named for. Callers deciding whether to REUSE a deal want
        get_active_by_listing_buyer below instead.
        """
        r = await self.db.execute(
            select(Deal)
            .where(
                Deal.listing_id == listing_id,
                Deal.buyer_id == buyer_id,
            )
            .order_by(Deal.created_at.desc(), Deal.id.desc())
            .limit(1)
        )
        return r.scalars().first()

    async def get_active_by_listing_buyer(
        self, listing_id: str, buyer_id: str,
    ) -> Optional[Deal]:
        """The live deal for this pair, if there is one.

        This is what duplicate protection needs: it stops a second deal
        being created for a transaction that is still running, and says
        nothing about transactions that have finished. A released deal from
        March is not a reason to refuse a new one in September - and when
        the buyer wins the same seller's relisted item at auction, refusing
        is exactly what the old check did.
        """
        r = await self.db.execute(
            select(Deal)
            .where(
                Deal.listing_id == listing_id,
                Deal.buyer_id == buyer_id,
                Deal.status.not_in(tuple(TERMINAL_DEAL_STATUSES)),
            )
            .order_by(Deal.created_at.desc(), Deal.id.desc())
            .limit(1)
        )
        return r.scalars().first()

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

    # Both single-row reads below use populate_existing, so they always
    # return what the row holds NOW. Sessions here use
    # expire_on_commit=False, and without this a second read of an escrow
    # the session had already loaded handed back that earlier copy -
    # whatever another request had committed in between.
    #
    # That broke the double-release guard in
    # EscrowService.release_econfirm_deal. Its "authoritative
    # re-check" re-reads the escrow after taking the deal lock, but the
    # request had loaded it once already (confirm_delivery reads it to
    # choose the flow), so the re-check saw the stale `funded` rather than
    # the `release_pending` a concurrent release had just committed, and
    # went on to call release_escrow() a second time. Same bug class as
    # lock_deal_if_status's, fixed there for the Deal row only.
    #
    # Safe for callers holding unflushed edits: the session autoflushes
    # before the SELECT, so those edits are written first and read back.

    async def get_by_deal_id(self, deal_id: str) -> Optional[ExternalEscrow]:
        """The deal's LATEST payment (highest payment_no), or None.

        A deal can hold several payments (partial payments, ExternalEscrow.
        payment_no); list_for_deal returns all of them.
        """
        r = await self.db.execute(
            select(ExternalEscrow)
            .where(ExternalEscrow.deal_id == deal_id)
            .order_by(ExternalEscrow.payment_no.desc())
            .limit(1)
            .execution_options(populate_existing=True)
        )
        return r.scalars().first()

    async def list_for_deal(self, deal_id: str) -> list[ExternalEscrow]:
        """Every payment on the deal, first to last."""
        r = await self.db.execute(
            select(ExternalEscrow)
            .where(ExternalEscrow.deal_id == deal_id)
            .order_by(ExternalEscrow.payment_no.asc())
            .execution_options(populate_existing=True)
        )
        return list(r.scalars().all())

    async def list_for_deals(self, deal_ids: list[str]) -> dict[str, list[ExternalEscrow]]:
        """list_for_deal for many deals in one query (the deal list)."""
        if not deal_ids:
            return {}
        r = await self.db.execute(
            select(ExternalEscrow)
            .where(ExternalEscrow.deal_id.in_(deal_ids))
            .order_by(ExternalEscrow.deal_id, ExternalEscrow.payment_no.asc())
        )
        out: dict[str, list[ExternalEscrow]] = {}
        for e in r.scalars().all():
            out.setdefault(e.deal_id, []).append(e)
        return out

    async def get_by_provider_transaction_id(self, provider_transaction_id: str) -> Optional[ExternalEscrow]:
        r = await self.db.execute(
            select(ExternalEscrow)
            .where(ExternalEscrow.provider_transaction_id == provider_transaction_id)
            .execution_options(populate_existing=True)
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
