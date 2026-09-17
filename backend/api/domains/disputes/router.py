"""
BROKA v5.0 - Dispute Engine Router
====================================
Endpoints for the new dispute case management system.

POST /disputes/v2/open               - open a dispute case
POST /disputes/v2/{case_id}/evidence - attach evidence
POST /disputes/v2/{case_id}/analyse  - run AI + rule engine
POST /disputes/v2/{case_id}/execute  - execute fund action
GET  /disputes/v2/{case_id}          - get case + evidence
GET  /disputes/v2/{case_id}/timeline - immutable event timeline
GET  /disputes/v2/deal/{deal_id}     - get active case for a deal

Legacy /disputes/... endpoints preserved for Flutter backward compat.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, Request, UploadFile, File, Form
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select

from api.database import get_db
from api.security import get_current_user
from api.models.dispute import (
    DisputeCase, CaseBranch, CaseState,
    EventType, EvidenceType, TimerKind,
    Dispute, DisputeStatus,
    DisputeType, DISPUTE_TYPE_META,
)
from .service import DisputeEngineService
from api.models.dispute import OptimisticLockError

router = APIRouter()


async def _load_case_and_authorize(
    db: AsyncSession, case_id: str, current_user: dict,
):
    """Load a dispute case and confirm the caller is allowed to touch it.

    Every /v2/{case_id}/* endpoint previously ran with ONLY
    `Depends(get_current_user)` - i.e. any logged-in user on the platform,
    not just the two parties to the underlying deal, could read another
    user's dispute (evidence, AI reasoning, timeline), attach fake evidence
    to it, re-run the AI analysis on it, or even execute its fund action.
    This is a broken-object-level-authorization (IDOR) bug - closing it here
    means every endpoint below gets the fix by construction instead of each
    needing its own copy-pasted check.

    Returns (case, deal, actor_role) where actor_role is derived from the
    deal ("buyer"/"seller"/"admin") rather than trusted from the client.
    """
    from fastapi import HTTPException
    from api.database import Deal, User as UserModel

    case_r = await db.execute(select(DisputeCase).where(DisputeCase.id == case_id))
    case = case_r.scalar_one_or_none()
    if not case:
        raise HTTPException(status_code=404, detail="Case not found")

    deal_r = await db.execute(select(Deal).where(Deal.id == case.deal_id))
    deal = deal_r.scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")

    uid = current_user["id"]
    if uid == deal.buyer_id:
        return case, deal, "buyer"
    if uid == deal.seller_id:
        return case, deal, "seller"

    user_r = await db.execute(select(UserModel).where(UserModel.id == uid))
    db_user = user_r.scalar_one_or_none()
    if db_user and db_user.is_admin:
        return case, deal, "admin"

    raise HTTPException(status_code=403, detail="Not authorized for this dispute case")

BRANCH_MAP = {
    "A1": CaseBranch.A1,
    "A2": CaseBranch.A2,
    "A3": CaseBranch.A3,
    "A4": CaseBranch.A4,
    "B":  CaseBranch.B,
    # Friendly aliases
    "goods_ok":     CaseBranch.A1,
    "wrong_item":   CaseBranch.A2,
    "damaged":      CaseBranch.A3,
    "replacement":  CaseBranch.A4,
    "not_arrived":  CaseBranch.B,
}


# ── Schemas ────────────────────────────────────────────────────────────────────

class OpenCaseIn(BaseModel):
    deal_id:      str
    branch:       Optional[str] = None   # legacy: "A1"|"A2"|"A3"|"A4"|"B" or alias
    dispute_type: Optional[str] = None   # new, preferred: DisputeType value key
    description:  str


class ExecuteIn(BaseModel):
    zac_code: Optional[str] = None  # optional — for buyer-initiated execute


# ── v2 Endpoints ──────────────────────────────────────────────────────────────

@router.post("/v2/open", status_code=201)
async def open_case(
    body: OpenCaseIn,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Open a new dispute case on a deal."""
    from fastapi import HTTPException

    # Resolve dispute_type (new) or fall back to branch (legacy)
    resolved_dtype  = None
    resolved_branch = None

    if body.dispute_type:
        try:
            resolved_dtype = DisputeType(body.dispute_type)
        except ValueError:
            raise HTTPException(
                status_code=400,
                detail=(
                    f"Invalid dispute_type '{body.dispute_type}'. "
                    f"Valid values: {[e.value for e in DisputeType]}"
                ),
            )
    elif body.branch:
        resolved_branch = BRANCH_MAP.get(body.branch)
        if not resolved_branch:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid branch. Use: {list(BRANCH_MAP.keys())}",
            )
    else:
        raise HTTPException(
            status_code=400,
            detail="Provide either dispute_type (preferred) or branch.",
        )

    svc = DisputeEngineService(db)
    case = await svc.open_case(
        deal_id=body.deal_id,
        opener_id=current_user["id"],
        branch=resolved_branch or CaseBranch.B,  # will be overridden if dispute_type set
        description=body.description,
        # NOTE: get_current_user() never carries a role claim, so this is
        # only a placeholder - open_case() derives the real buyer/seller
        # role itself from the deal record.
        actor_role=current_user.get("role", "buyer"),
        ip_address=request.client.host if request.client else None,
        dispute_type=resolved_dtype,
    )
    return await svc.get_case_dict(case)


@router.post("/v2/{case_id}/evidence", status_code=201)
async def attach_evidence(
    case_id: str,
    evidence_type: str = Form(...),
    description: str = Form(""),
    image_base64: str = Form(""),
    storage_url: str = Form(""),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Attach evidence to a case. Triggers AI analysis for images."""
    case, _deal, actor_role = await _load_case_and_authorize(db, case_id, current_user)

    ev_type = EvidenceType(evidence_type) if evidence_type in [e.value for e in EvidenceType] \
              else EvidenceType.other

    svc = DisputeEngineService(db)
    evidence = await svc.attach_evidence(
        case=case,
        uploader_id=current_user["id"],
        uploader_role=actor_role,
        evidence_type=ev_type,
        storage_url=storage_url or f"inline:{case_id[:8]}",
        description=description,
        image_base64=image_base64,
    )
    return {
        "evidence_id":    evidence.id,
        "ai_analysed":    evidence.ai_analysed,
        "ai_analysis":    evidence.ai_analysis,
        "ai_flags_damage": evidence.ai_flags_damage,
        "ai_confidence":  evidence.ai_confidence,
    }


@router.post("/v2/{case_id}/analyse")
async def analyse_and_decide(
    case_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Run AI analysis + rule engine on a case. Sets state to ready_for_* or escalated."""
    from fastapi import HTTPException
    from api.database import User
    case, deal, _actor_role = await _load_case_and_authorize(db, case_id, current_user)
    if case.state.is_terminal:
        raise HTTPException(status_code=400, detail="Case already closed")

    buyer_r  = await db.execute(select(User).where(User.id == deal.buyer_id))
    buyer    = buyer_r.scalar_one()
    seller_r = await db.execute(select(User).where(User.id == deal.seller_id))
    seller   = seller_r.scalar_one()

    svc = DisputeEngineService(db)
    decision, reason = await svc.run_ai_and_decide(
        case=case, deal=deal, buyer=buyer, seller=seller,
        issue_description=f"Branch {case.branch.value if case.branch else 'unknown'}",
    )
    return {
        "decision": decision,
        "reason":   reason,
        "state":    case.state.value,
    }


@router.post("/v2/{case_id}/execute")
async def execute_fund_action(
    case_id: str,
    body: ExecuteIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Execute the fund action (refund 97% or release 97%). Case must be in ready_for_* state."""
    case, _deal, actor_role = await _load_case_and_authorize(db, case_id, current_user)

    svc = DisputeEngineService(db)
    try:
        return await svc.execute_fund_action(
            case=case,
            actor_id=current_user["id"],
            actor_role=actor_role,
        )
    except OptimisticLockError as exc:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=409,
            detail=f"Concurrent modification detected — please refresh and try again. ({exc})",
        )


@router.get("/v2/{case_id}/timeline")
async def get_timeline(
    case_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Immutable event timeline for a dispute case."""
    await _load_case_and_authorize(db, case_id, current_user)
    svc = DisputeEngineService(db)
    return {"timeline": await svc.get_timeline(case_id)}


@router.get("/v2/deal/{deal_id}")
async def get_case_for_deal(
    deal_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get the active dispute case for a deal (if any)."""
    from fastapi import HTTPException
    from api.database import Deal, User as UserModel

    deal_r = await db.execute(select(Deal).where(Deal.id == deal_id))
    deal = deal_r.scalar_one_or_none()
    if not deal:
        raise HTTPException(status_code=404, detail="Deal not found")
    uid = current_user["id"]
    if uid not in (deal.buyer_id, deal.seller_id):
        user_r = await db.execute(select(UserModel).where(UserModel.id == uid))
        db_user = user_r.scalar_one_or_none()
        if not db_user or not db_user.is_admin:
            raise HTTPException(status_code=403, detail="Not authorized for this deal")

    result = await db.execute(
        select(DisputeCase)
        .where(DisputeCase.deal_id == deal_id)
        .order_by(DisputeCase.created_at.desc())
    )
    case = result.scalar_one_or_none()
    if not case:
        return {"case": None}
    svc = DisputeEngineService(db)
    return {"case": await svc.get_case_dict(case)}


@router.get("/v2/types")
async def list_dispute_types(
    current_user: dict = Depends(get_current_user),
):
    """
    List all available dispute types with labels and routing metadata.
    Flutter uses this to build the 'What\'s wrong?' picker dynamically —
    adding a new type only requires adding it to DisputeType, not a Flutter release.
    """
    return {
        "types": [
            {
                "value":             dt.value,
                "label":             meta["label"],
                "default_action":    meta["default_action"],
                "requires_evidence": meta["requires_evidence"],
                "ai_review":         meta["ai_review"],
            }
            for dt, meta in DISPUTE_TYPE_META.items()
        ]
    }


@router.get("/v2/stats/summary")
async def get_dispute_summary() -> dict:
    """
    Aggregate, anonymised dispute-resolution stats (Volume 2 §2.3) - shown to
    buyers at the moment they're deciding whether to pay through BROKA escrow
    (mpesa_confirmation_screen.dart) and referenced live by Zeno's off-platform-
    solicitation redirect (routers/negotiate.py §2.2). No per-case or per-user
    data, so intentionally left public (no current_user dependency) rather than
    requiring auth like the rest of this router.

    Backed by a Redis cache refreshed every ~4h by
    core.workers.task_refresh_dispute_summary_cache. On a cold cache (e.g. the
    very first request after a fresh deploy, before the sweep loop has ticked
    yet) this computes once synchronously and warms the cache for every
    request after it, rather than returning a hardcoded fallback.
    """
    from api.core.stats_cache import cache_get_json, DISPUTE_SUMMARY_KEY
    from api.core.workers import task_refresh_dispute_summary_cache

    cached = await cache_get_json(DISPUTE_SUMMARY_KEY)
    if cached is None:
        await task_refresh_dispute_summary_cache()
        cached = await cache_get_json(DISPUTE_SUMMARY_KEY)

    return cached or {
        "resolved_within_24h_pct": None,
        "median_resolution_hours": None,
        "escrow_success_rate_pct": None,
        "window":      "trailing_90_days",
        "sample_size": 0,
        "computed_at": None,
    }


@router.get("/v2/{case_id}")
async def get_case(
    case_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Get a dispute case with all evidence."""
    case, _deal, _actor_role = await _load_case_and_authorize(db, case_id, current_user)
    svc = DisputeEngineService(db)
    return await svc.get_case_dict(case)
