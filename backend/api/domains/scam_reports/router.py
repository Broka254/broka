"""HTTP contracts for scam reports, restrictions and appeals.

PEOPLE (signed in), mounted at /scam-reports:

  POST   /scam-reports                         report a suspected scam
  POST   /scam-reports/{id}/evidence           attach a private image (base64)
  GET    /scam-reports/mine                    my reports
  GET    /scam-reports/restrictions/mine       limits on MY account, and their appeals
  POST   /scam-reports/restrictions/{id}/appeal   appeal one

ADMINISTRATORS, mounted at /admin/scam-reports (permissions in each route):

  GET  /                          reports, newest first, with how many different
                                  people have reported the same account
  GET  /{id}                      one report, its evidence list, and the other
                                  reports about the same account
  GET  /{id}/evidence/{eid}       a piece of evidence (audited every time)
  POST /restrictions              apply a temporary protective restriction
  POST /restrictions/{id}/lift    lift one
  GET  /appeals                   appeals waiting for a decision
  POST /appeals/{id}/decide       uphold or overturn

A REPORT IS NOT A VERDICT. Nothing here restricts, flags or scores anyone as
a result of a report: reports create rows and, past a count of different
reporters, an alert for a person to read. See policy.py.
"""
from __future__ import annotations

import base64
import binascii
import logging
from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy import desc, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.permissions import Permission, require_permission
from api.core.rate_limit import scam_report_limiter
from api.database import User, get_db
from api.models.feedback import UserFeedback
from api.models.scam_report import (
    AccountRestriction, RestrictionAppeal, ScamReportDetail, ScamReportEvidence,
)
from api.security import get_current_user

from . import policy, service

logger = logging.getLogger(__name__)
customer_router = APIRouter()
admin_router = APIRouter()

_PAGE = 50


def _iso(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() + "Z" if value else None


def problem_detail(problems: list[str], code: str) -> dict:
    """An error body the app can show. The app (ApiClient) reads `message`
    and `code` from a structured detail; a bare list of strings comes out as
    "Request failed", which tells a person nothing about what to fix. The
    individual problems stay in `problems` for a screen that wants them."""
    return {"code": code, "message": " ".join(p.rstrip(".") + "." for p in problems), "problems": problems}


def _fail(error: service.ReportError):
    raise HTTPException(status_code=error.status_code, detail=problem_detail(error.problems, "SCAM_REPORT_REFUSED"))


# ── People ───────────────────────────────────────────────────────────────

class ReportIn(BaseModel):
    reason_code: str = Field(max_length=40)
    description: str = Field(max_length=policy.MAX_TEXT)
    reported_user_id: Optional[str] = Field(None, max_length=36)
    reported_account_ref: Optional[str] = Field(None, max_length=policy.MAX_REF)
    provider_id: Optional[str] = Field(None, max_length=40)
    transaction_reference: Optional[str] = Field(None, max_length=80)
    amount_kes: Optional[int] = Field(None, ge=0, le=100_000_000)
    payment_sent: bool = False


class EvidenceIn(BaseModel):
    file_name: str = Field("evidence", max_length=120)
    # base64 of the image. Capped before decoding: 1.5 MB of image is ~2 MB of text.
    content_base64: str = Field(max_length=2_200_000)


class AppealIn(BaseModel):
    statement: str = Field(max_length=2000)


@customer_router.post("", status_code=201)
async def report_scam(
    body: ReportIn, request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    me = current_user["id"]
    await scam_report_limiter.check_and_record(me)
    now = datetime.utcnow()
    try:
        filed = await service.file_report(
            db, me, reason_code=body.reason_code, description=body.description,
            reported_user_id=body.reported_user_id, reported_account_ref=body.reported_account_ref,
            provider_id=body.provider_id, transaction_reference=body.transaction_reference,
            amount_kes=body.amount_kes, payment_sent=body.payment_sent, now=now)
    except service.ReportError as error:
        _fail(error)
    if not filed["duplicate"]:
        detail = await db.get(ScamReportDetail, filed["feedback_id"])
        count = await service.independent_reporters(
            db, reported_user_id=detail.reported_user_id,
            reported_account_key=detail.reported_account_key, now=now)
        await service.raise_repeat_alert(
            db, reported_user_id=detail.reported_user_id,
            reported_account_key=detail.reported_account_key, count=count)
        await record_audit(db, me, "scam_report_filed", "user_feedback", filed["feedback_id"],
                           detail=f"reason={body.reason_code}", ip_address=client_ip_or_none(request))
    await db.commit()
    # What the reporter is told: that it will be reviewed - not that anyone
    # is guilty, and not that money will come back.
    return {"id": filed["feedback_id"], "duplicate": filed["duplicate"],
            "message": ("Thank you. The Broka team will review this. A report is not a finding "
                        "against anyone, and Broka cannot promise to recover money sent to "
                        "another person or to an escrow provider."),
            "next_steps": [
                "Keep the messages, numbers, receipts and transaction IDs.",
                "Contact the escrow provider through its official contact details.",
                "If money went through a payment route you now think was fraudulent, contact "
                "that payment provider (for example Safaricom) promptly.",
                "If you believe a crime was committed, report it to the police."]}


@customer_router.post("/{feedback_id}/evidence", status_code=201)
async def add_evidence(
    feedback_id: str, body: EvidenceIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await scam_report_limiter.check_and_record(current_user["id"])
    try:
        data = base64.b64decode(body.content_base64, validate=True)
    except (binascii.Error, ValueError):
        raise HTTPException(status_code=422, detail=problem_detail(["content_base64: not valid base64"], "SCAM_REPORT_REFUSED"))
    try:
        out = await service.add_evidence(db, feedback_id, current_user["id"], name=body.file_name, data=data)
    except service.ReportError as error:
        _fail(error)
    await db.commit()
    return out


@customer_router.get("/mine")
async def my_reports(
    limit: int = Query(_PAGE, ge=1, le=100), offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    rows = (await db.execute(
        select(ScamReportDetail, UserFeedback)
        .join(UserFeedback, UserFeedback.id == ScamReportDetail.feedback_id)
        .where(ScamReportDetail.reporter_id == current_user["id"])
        .order_by(desc(ScamReportDetail.created_at)).limit(limit).offset(offset))).all()
    return {"items": [{
        "id": d.feedback_id, "reason": policy.REASONS.get(d.reason_code, d.reason_code),
        "status": f.status, "created_at": _iso(d.created_at),
        "reported": d.reported_account_ref or "a Broka account",
        # The team's reply to the reporter is the feedback row's own admin_response.
        "reply": f.admin_response} for d, f in rows]}


@customer_router.get("/evidence/{feedback_id}/{evidence_id}")
async def my_evidence(
    feedback_id: str, evidence_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    detail = await db.get(ScamReportDetail, feedback_id)
    # Not yours is "not found", never "forbidden": that would confirm it exists.
    if detail is None or detail.reporter_id != current_user["id"]:
        raise HTTPException(status_code=404, detail="Not found")
    row = await service.evidence_row(db, feedback_id, evidence_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Not found")
    return _file(row)


def _file(row: ScamReportEvidence) -> Response:
    """The bytes, as a download that no browser will run or cache: evidence is
    private, and a screenshot is shown to be looked at, not to be trusted."""
    return Response(content=row.data, media_type=row.mime_type, headers={
        "Content-Disposition": f'attachment; filename="{row.file_name}"',
        "X-Content-Type-Options": "nosniff",
        "Content-Security-Policy": "sandbox",
        "Cache-Control": "private, no-store",
    })


def _restriction_out(r: AccountRestriction, now: datetime, appeals: list[RestrictionAppeal]) -> dict:
    return {
        "id": r.id, "scopes": [policy.SCOPES.get(s, s) for s in service.scopes_of(r)],
        "reason": r.public_reason, "status": policy.effective_status(r.status, r.expires_at, now),
        "starts": _iso(r.created_at), "ends": _iso(r.expires_at),
        "notice": policy.RESTRICTION_NOTICE,
        "can_appeal": policy.can_appeal(r.status, r.expires_at, now, len(appeals),
                                        any(a.status == "open" for a in appeals)) is None,
        "appeals": [{"id": a.id, "status": a.status, "created_at": _iso(a.created_at),
                     "decision": a.decision_note, "decided_at": _iso(a.decided_at)} for a in appeals],
    }


@customer_router.get("/restrictions/mine")
async def my_restrictions(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Limits on MY account only. The person is always told what and until
    when, in words meant for them - never the team's internal reason."""
    now = datetime.utcnow()
    rows = (await db.execute(select(AccountRestriction).where(
        AccountRestriction.user_id == current_user["id"])
        .order_by(desc(AccountRestriction.created_at)).limit(20))).scalars().all()
    out = []
    for r in rows:
        appeals = (await db.execute(select(RestrictionAppeal).where(
            RestrictionAppeal.restriction_id == r.id).order_by(RestrictionAppeal.created_at))).scalars().all()
        out.append(_restriction_out(r, now, list(appeals)))
    return {"items": out}


@customer_router.post("/restrictions/{restriction_id}/appeal", status_code=201)
async def appeal_restriction(
    restriction_id: str, body: AppealIn, request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await scam_report_limiter.check_and_record(current_user["id"])
    try:
        appeal = await service.file_appeal(db, current_user["id"], restriction_id,
                                           statement=body.statement, now=datetime.utcnow())
    except service.ReportError as error:
        _fail(error)
    await record_audit(db, current_user["id"], "restriction_appeal_filed", "account_restriction",
                       restriction_id, detail=f"appeal={appeal.id}", ip_address=client_ip_or_none(request))
    await _alert_appeal(db, appeal.id, restriction_id)
    await db.commit()
    return {"id": appeal.id, "status": appeal.status,
            "message": "Your appeal has been received. A member of the team will review it."}


async def _alert_appeal(db: AsyncSession, appeal_id: str, restriction_id: str) -> None:
    from api.core.admin_alerts import create_alert
    await create_alert(db, kind="restriction_appeal", severity="high", title="Restriction appeal to review",
                       body="Someone appealed a temporary restriction. Appeals are reviewed by a person.",
                       href="/scam-reports/appeals",
                       meta={"appeal_id": appeal_id, "restriction_id": restriction_id})


# ── Administrators ───────────────────────────────────────────────────────

class RestrictIn(BaseModel):
    user_id: str = Field(max_length=36)
    scopes: list[str] = Field(max_length=5)
    days: int = Field(ge=1, le=policy.MAX_DAYS)
    internal_reason: str = Field(max_length=1000)
    public_reason: str = Field(max_length=300)
    feedback_id: Optional[str] = Field(None, max_length=36)


class LiftIn(BaseModel):
    note: str = Field(max_length=1000)


class DecideIn(BaseModel):
    outcome: str = Field(max_length=12)
    note: str = Field(max_length=1000)


_VIEW = Permission.VIEW_FEEDBACK
_MANAGE = Permission.MANAGE_USERS


@admin_router.get("")
async def admin_reports(
    limit: int = Query(_PAGE, ge=1, le=100), offset: int = Query(0, ge=0),
    reason: Optional[str] = Query(None, max_length=40),
    admin: User = Depends(require_permission(_VIEW)),
    db: AsyncSession = Depends(get_db),
):
    now = datetime.utcnow()
    query = select(ScamReportDetail, UserFeedback).join(
        UserFeedback, UserFeedback.id == ScamReportDetail.feedback_id)
    if reason:
        query = query.where(ScamReportDetail.reason_code == reason)
    rows = (await db.execute(query.order_by(desc(ScamReportDetail.created_at)).limit(limit).offset(offset))).all()
    items = []
    for d, f in rows:
        reporters = await service.independent_reporters(
            db, reported_user_id=d.reported_user_id, reported_account_key=d.reported_account_key, now=now)
        items.append({
            "id": d.feedback_id, "reason_code": d.reason_code, "status": f.status, "severity": f.severity,
            "reported_user_id": d.reported_user_id, "reported_account": d.reported_account_ref,
            "provider_id": d.provider_id, "amount_kes": d.amount_kes, "payment_sent": d.payment_sent,
            "created_at": _iso(d.created_at), "different_reporters_30d": reporters,
            "needs_attention": policy.should_alert([str(i) for i in range(reporters)])})
    return {"items": items, "limit": limit, "offset": offset}


@admin_router.get("/appeals")
async def admin_appeals(
    admin: User = Depends(require_permission(_VIEW)),
    db: AsyncSession = Depends(get_db),
):
    rows = (await db.execute(select(RestrictionAppeal, AccountRestriction)
            .join(AccountRestriction, AccountRestriction.id == RestrictionAppeal.restriction_id)
            .where(RestrictionAppeal.status == "open").order_by(RestrictionAppeal.created_at))).all()
    return {"items": [{"id": a.id, "user_id": a.user_id, "statement": a.statement,
                       "created_at": _iso(a.created_at), "restriction_id": r.id,
                       "restriction_reason": r.internal_reason, "ends": _iso(r.expires_at)} for a, r in rows]}


@admin_router.get("/{feedback_id}")
async def admin_report(
    feedback_id: str,
    admin: User = Depends(require_permission(_VIEW)),
    db: AsyncSession = Depends(get_db),
):
    d = await db.get(ScamReportDetail, feedback_id)
    f = await db.get(UserFeedback, feedback_id)
    if d is None or f is None:
        raise HTTPException(status_code=404, detail="No such report")
    now = datetime.utcnow()
    others = []
    if d.reported_user_id or d.reported_account_key:
        q = select(ScamReportDetail).where(ScamReportDetail.feedback_id != feedback_id)
        q = q.where(ScamReportDetail.reported_user_id == d.reported_user_id) if d.reported_user_id \
            else q.where(ScamReportDetail.reported_account_key == d.reported_account_key)
        others = (await db.execute(q.order_by(desc(ScamReportDetail.created_at)).limit(20))).scalars().all()
    restrictions = []
    if d.reported_user_id:
        restrictions = (await db.execute(select(AccountRestriction).where(
            AccountRestriction.user_id == d.reported_user_id).order_by(desc(AccountRestriction.created_at))
            .limit(10))).scalars().all()
    return {
        "id": feedback_id, "reason_code": d.reason_code, "reason": policy.REASONS.get(d.reason_code),
        "description": f.body, "status": f.status, "severity": f.severity, "reporter_id": d.reporter_id,
        "reported_user_id": d.reported_user_id, "reported_account": d.reported_account_ref,
        "provider_id": d.provider_id, "transaction_reference": d.transaction_reference,
        "amount_kes": d.amount_kes, "payment_sent": d.payment_sent, "created_at": _iso(d.created_at),
        "different_reporters_30d": await service.independent_reporters(
            db, reported_user_id=d.reported_user_id, reported_account_key=d.reported_account_key, now=now),
        "evidence": await service.evidence_list(db, feedback_id),
        "other_reports": [{"id": o.feedback_id, "reason_code": o.reason_code, "created_at": _iso(o.created_at)}
                          for o in others],
        "restrictions": [{"id": r.id, "scopes": service.scopes_of(r), "status": policy.effective_status(
            r.status, r.expires_at, now), "ends": _iso(r.expires_at), "internal_reason": r.internal_reason}
            for r in restrictions],
    }


@admin_router.get("/{feedback_id}/evidence/{evidence_id}")
async def admin_evidence(
    feedback_id: str, evidence_id: str, request: Request,
    admin: User = Depends(require_permission(_VIEW)),
    db: AsyncSession = Depends(get_db),
):
    row = await service.evidence_row(db, feedback_id, evidence_id)
    if row is None:
        raise HTTPException(status_code=404, detail="Not found")
    # Written and committed BEFORE the bytes are returned: if the audit row
    # cannot be saved the evidence is not shown. Looking is an action.
    await record_audit(db, admin.id, "scam_evidence_viewed", "scam_report_evidence", evidence_id,
                       detail=f"report={feedback_id}", ip_address=client_ip_or_none(request))
    await db.commit()
    return _file(row)


@admin_router.post("/restrictions", status_code=201)
async def admin_restrict(
    body: RestrictIn, request: Request,
    admin: User = Depends(require_permission(_MANAGE)),
    db: AsyncSession = Depends(get_db),
):
    if await db.get(User, body.user_id) is None:
        raise HTTPException(status_code=404, detail="No such user")
    try:
        row = await service.restrict(
            db, admin.id, body.user_id, scopes=body.scopes, days=body.days,
            internal_reason=body.internal_reason, public_reason=body.public_reason,
            feedback_id=body.feedback_id, now=datetime.utcnow())
    except service.ReportError as error:
        _fail(error)
    await record_audit(db, admin.id, "restriction_applied", "user", body.user_id,
                       detail=f"restriction={row.id} scopes={row.scopes} days={body.days} | {row.internal_reason}"[:900],
                       ip_address=client_ip_or_none(request))
    await db.commit()
    return {"id": row.id, "ends": _iso(row.expires_at)}


@admin_router.post("/restrictions/{restriction_id}/lift")
async def admin_lift(
    restriction_id: str, body: LiftIn, request: Request,
    admin: User = Depends(require_permission(_MANAGE)),
    db: AsyncSession = Depends(get_db),
):
    try:
        row = await service.lift(db, admin.id, restriction_id, note=body.note, now=datetime.utcnow())
    except service.ReportError as error:
        _fail(error)
    await record_audit(db, admin.id, "restriction_lifted", "user", row.user_id,
                       detail=f"restriction={row.id} | {body.note}"[:900], ip_address=client_ip_or_none(request))
    await db.commit()
    return {"id": row.id, "status": row.status}


@admin_router.post("/appeals/{appeal_id}/decide")
async def admin_decide(
    appeal_id: str, body: DecideIn, request: Request,
    admin: User = Depends(require_permission(_MANAGE)),
    db: AsyncSession = Depends(get_db),
):
    try:
        appeal = await service.decide_appeal(db, admin.id, appeal_id, outcome=body.outcome,
                                             note=body.note, now=datetime.utcnow())
    except service.ReportError as error:
        _fail(error)
    await record_audit(db, admin.id, "restriction_appeal_decided", "account_restriction",
                       appeal.restriction_id, detail=f"appeal={appeal.id} outcome={appeal.status}",
                       ip_address=client_ip_or_none(request))
    await db.commit()
    return {"id": appeal.id, "status": appeal.status}
