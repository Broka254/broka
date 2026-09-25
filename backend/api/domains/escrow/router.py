"""Escrow / Deal Router v4.0 - adds E-Confirm marketplace escrow endpoints
(fee-quote, fund, payment-status) alongside the original finalize/
confirm-delivery/get routes. Canonical router — mounted at /deal in
main.py. See api/domains/escrow/service.py's module docstring for how
confirm-delivery now branches between the E-Confirm flow and the original
direct-release flow.
"""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.core.client_ip import client_ip_or_none
from api.security import get_current_user
from api.core.idempotency import idempotency_guard, IdempotencyResult
from .service import EscrowService

router = APIRouter()


# Hard ceiling on a single deal's agreed price, in KES. Well above any
# plausible BROKA listing (a used car tops out around 5M) and far below the
# point where Numeric(18,2) in the ledger or M-Pesa's own transaction caps
# come into play. Its job is to stop absurd values, not to price-police.
MAX_AGREED_PRICE_KES = 20_000_000.0


class FinalizeDealIn(BaseModel):
    listing_id: str
    buyer_id: str
    # VALIDATION FIX (escrow audit, 2026-09-14): this was a bare `float`
    # with no constraints at all, on the endpoint that creates a money
    # obligation. Three things got through:
    #
    #   • Negative prices. agreed_price=-50000 produced commission=-1500
    #     and amount_to_pay=-51500, wrote a Deal row with negative money,
    #     and poisoned every aggregate computed over it.
    #   • Zero/dust prices. agreed_price=0.001 rounds commission to 0.00,
    #     so a deal could be "completed" for nothing - and completing deals
    #     is what raises a seller's completed_deals count and trust score.
    #     Free reputation.
    #   • Infinity and NaN. Python's json module parses the bare literals
    #     Infinity/-Infinity/NaN by default, so `{"agreed_price": Infinity}`
    #     reaches the handler as float('inf'). round(inf * 0.03, 2) is inf,
    #     and inf/NaN propagate silently through every downstream total
    #     until something tries to persist them.
    #
    # `gt=0` rejects zero and negatives, `le` rejects absurd values, and
    # `allow_inf_nan=False` rejects the two non-finite floats explicitly -
    # a bound alone does not, since NaN fails every comparison and would
    # otherwise slip past a naive range check.
    agreed_price: float = Field(
        ..., gt=0, le=MAX_AGREED_PRICE_KES, allow_inf_nan=False,
    )


class FundEscrowIn(BaseModel):
    payer_phone: str


@router.post("/finalize", status_code=201)
async def finalize_deal(
    body: FinalizeDealIn,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.finalize_deal(
        listing_id=body.listing_id,
        buyer_id=body.buyer_id,
        agreed_price=body.agreed_price,
        current_user_id=current_user["id"],
        request_ip=client_ip_or_none(request),
    )


@router.get("/{deal_id}/fee-quote")
async def get_fee_quote(
    deal_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Phase 5/14: real buyer-facing total (goods + BROKA commission +
    E-Confirm's own fee) before the buyer commits to funding."""
    svc = EscrowService(db)
    return await svc.get_fee_quote(deal_id, current_user["id"])


@router.post("/{deal_id}/fund")
async def fund_deal_escrow(
    deal_id: str,
    body: FundEscrowIn,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
    idempotency_result: IdempotencyResult = Depends(idempotency_guard),
):
    """Phase 7 (+ Phase 6's create-if-needed, fused - see EscrowService.
    fund_deal_escrow's docstring). Idempotency-Key-aware (Phase 9): a
    retried request with the same X-Idempotency-Key replays the cached
    result instead of re-running the STK push. This is in ADDITION to,
    not instead of, EscrowService's own DB-state idempotency (an escrow
    that already exists/is already funded is never recreated/re-funded
    even without a matching key — see fund_deal_escrow's status checks)."""
    if idempotency_result.cached:
        return idempotency_result.response

    svc = EscrowService(db)
    # A failure below releases the key (idempotency_guard does it on the
    # way out), so a corrected retry is not answered with 409. Safe even
    # after an ambiguous provider failure: the escrow's own funding claim
    # makes any retry reconcile instead of re-sending.
    result = await svc.fund_deal_escrow(
        deal_id=deal_id,
        buyer_id=current_user["id"],
        payer_phone=body.payer_phone,
        request_ip=client_ip_or_none(request),
    )
    await idempotency_result.store(result)
    return result


@router.get("/{deal_id}/payment-status")
async def get_payment_status(
    deal_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Phase 14/22. What Flutter polls instead of /mpesa/query for
    E-Confirm-funded deals — see flutter_app/lib/screens/
    econfirm_payment_screen.dart. Triggers a fresh reconciliation pass
    when the escrow isn't in a terminal state yet (Phase 8: "immediate UI
    refresh"), so this always reflects E-Confirm's latest known state,
    not just whatever was last written by the worker sweep."""
    svc = EscrowService(db)
    return await svc.get_payment_status(deal_id, current_user["id"])


@router.post("/{deal_id}/confirm-delivery")
async def confirm_delivery(
    deal_id: str,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.confirm_delivery(
        deal_id=deal_id,
        buyer_id=current_user["id"],
        request_ip=client_ip_or_none(request),
    )


@router.get("/{deal_id}")
async def get_deal(
    deal_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.get_deal(deal_id, current_user["id"])


@router.get("/")
async def get_my_deals(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = EscrowService(db)
    return await svc.get_my_deals(current_user["id"])
