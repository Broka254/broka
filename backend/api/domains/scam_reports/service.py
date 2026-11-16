"""Filing, reviewing and restricting - the database work behind scam reports.

Every function takes the caller's session and does NOT commit; the router
commits once, after the audit row, so a report and the audit of it succeed or
fail together.

WHAT THIS NEVER DOES, by design and by test:
  * change a user's trust score, flag, listings, money or access because of a
    report - reports only create rows for people to read, and (past a count of
    independent reporters) an alert asking a person to look;
  * apply a restriction except through restrict(), which an administrator
    calls with a reason and an end date, and which has no automatic caller.
"""
from __future__ import annotations

import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.models.feedback import UserFeedback
from api.models.scam_report import (
    AccountRestriction, RestrictionAppeal, ScamReportDetail, ScamReportEvidence,
)

from . import policy

logger = logging.getLogger(__name__)

ALERT_KIND = "scam_reports_repeated"
DUPLICATE_WINDOW_HOURS = 24


class ReportError(Exception):
    def __init__(self, status_code: int, problems: list[str]):
        super().__init__("; ".join(problems))
        self.status_code = status_code
        self.problems = problems


def _scopes_to_text(scopes: list[str]) -> str:
    return ",".join(sorted(set(scopes)))


def scopes_of(restriction: AccountRestriction) -> list[str]:
    return [s for s in (restriction.scopes or "").split(",") if s]


# ── Filing ───────────────────────────────────────────────────────────────

async def file_report(db: AsyncSession, reporter_id: str, *, reason_code: str, description: str,
                      reported_user_id: Optional[str], reported_account_ref: Optional[str],
                      provider_id: Optional[str], transaction_reference: Optional[str],
                      amount_kes: Optional[int], payment_sent: bool, now: datetime) -> dict:
    """File a scam report as a complaint plus its details.

    The same reporter filing about the same account again within a day gets
    their existing report back instead of a second one: a double tap or a
    retry must not look like two reports."""
    problems = policy.validate_report(
        reason_code, description, reported_user_id=reported_user_id,
        reported_account_ref=reported_account_ref, reporter_id=reporter_id)
    if problems:
        raise ReportError(422, problems)
    ref = policy.clean_text(reported_account_ref, policy.MAX_REF) or None
    key = policy.normalise_account_ref(ref) if ref else None

    since = now - timedelta(hours=DUPLICATE_WINDOW_HOURS)
    same = select(ScamReportDetail).where(
        ScamReportDetail.reporter_id == reporter_id, ScamReportDetail.created_at >= since)
    same = same.where(ScamReportDetail.reported_user_id == reported_user_id) if reported_user_id \
        else same.where(ScamReportDetail.reported_account_key == key)
    existing = (await db.execute(same.order_by(ScamReportDetail.created_at.desc()).limit(1))).scalar_one_or_none()
    if existing is not None:
        return {"feedback_id": existing.feedback_id, "duplicate": True}

    label = policy.REASONS[reason_code]
    feedback = UserFeedback(
        user_id=reporter_id, kind="complaint", category="safety",
        severity="high" if payment_sent else "normal",
        subject=f"Suspected scam: {label}"[:160],
        body=policy.clean_text(description, policy.MAX_TEXT, newlines=True),
        related_user_id=reported_user_id or None, status="open", created_at=now, updated_at=now)
    db.add(feedback)
    await db.flush()
    db.add(ScamReportDetail(
        feedback_id=feedback.id, reporter_id=reporter_id, reported_user_id=reported_user_id or None,
        reported_account_ref=ref, reported_account_key=key,
        provider_id=policy.clean_text(provider_id, 40) or None,
        transaction_reference=policy.clean_text(transaction_reference, 80) or None,
        reason_code=reason_code, amount_kes=amount_kes, payment_sent=bool(payment_sent), created_at=now))
    await db.flush()
    return {"feedback_id": feedback.id, "duplicate": False, "severity": feedback.severity}


async def independent_reporters(db: AsyncSession, *, reported_user_id: Optional[str],
                                reported_account_key: Optional[str], now: datetime) -> int:
    """How many DIFFERENT people reported this account or website recently."""
    since = policy.window_start(now)
    query = select(func.count(func.distinct(ScamReportDetail.reporter_id))).where(
        ScamReportDetail.created_at >= since)
    if reported_user_id:
        query = query.where(ScamReportDetail.reported_user_id == reported_user_id)
    elif reported_account_key:
        query = query.where(ScamReportDetail.reported_account_key == reported_account_key)
    else:
        return 0
    return int((await db.execute(query)).scalar() or 0)


async def raise_repeat_alert(db: AsyncSession, *, reported_user_id: Optional[str],
                             reported_account_key: Optional[str], count: int) -> bool:
    """Ask an administrator to look, once, when enough different people have
    reported the same account or website. An alert, nothing more: it changes
    no one's access, score or listings. Deduplicated while still open."""
    if not policy.should_alert([str(i) for i in range(count)]):
        return False
    from api.core.admin_alerts import create_alert
    subject = f"user {reported_user_id}" if reported_user_id else f"“{reported_account_key}”"
    # No text a reporter wrote goes into the alert: only the count and a pointer.
    await create_alert(
        db, kind=ALERT_KIND, severity="high",
        title="Repeated scam reports to review",
        body=(f"{count} different people reported {subject} in the last {policy.ALERT_WINDOW_DAYS} "
              "days. This is a reason to look, not a finding."),
        href="/scam-reports",
        meta={"user_id": reported_user_id} if reported_user_id else {"account_key": reported_account_key})
    return True


# ── Evidence ─────────────────────────────────────────────────────────────

async def add_evidence(db: AsyncSession, feedback_id: str, uploader_id: str, *, name: str, data: bytes) -> dict:
    """Attach a private image to the caller's own report."""
    detail = await db.get(ScamReportDetail, feedback_id)
    if detail is None or detail.reporter_id != uploader_id:
        # 404, not 403: it does not confirm that someone else's report exists.
        raise ReportError(404, ["no such report"])
    if not data or len(data) > policy.MAX_EVIDENCE_BYTES:
        raise ReportError(413, [f"each file may be up to {policy.MAX_EVIDENCE_BYTES // 1000} KB"])
    kind = policy.sniff_image(data)
    if kind is None:
        raise ReportError(415, ["evidence must be a PNG, JPEG or WebP image"])
    count = int((await db.execute(select(func.count(ScamReportEvidence.id)).where(
        ScamReportEvidence.feedback_id == feedback_id))).scalar() or 0)
    if count >= policy.MAX_EVIDENCE_FILES:
        raise ReportError(409, [f"a report can have up to {policy.MAX_EVIDENCE_FILES} files"])
    mime, ext = kind
    row = ScamReportEvidence(
        feedback_id=feedback_id, uploader_id=uploader_id, file_name=policy.safe_file_name(name, ext),
        mime_type=mime, size_bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), data=data,
        created_at=datetime.utcnow())
    db.add(row)
    await db.flush()
    return {"id": row.id, "file_name": row.file_name, "mime_type": mime, "size_bytes": row.size_bytes}


async def evidence_list(db: AsyncSession, feedback_id: str) -> list[dict]:
    rows = (await db.execute(select(ScamReportEvidence).where(
        ScamReportEvidence.feedback_id == feedback_id).order_by(ScamReportEvidence.created_at))).scalars().all()
    return [{"id": r.id, "file_name": r.file_name, "mime_type": r.mime_type, "size_bytes": r.size_bytes,
             "sha256": r.sha256, "created_at": r.created_at.isoformat() + "Z"} for r in rows]


async def evidence_row(db: AsyncSession, feedback_id: str, evidence_id: str) -> Optional[ScamReportEvidence]:
    return (await db.execute(select(ScamReportEvidence).where(
        ScamReportEvidence.id == evidence_id, ScamReportEvidence.feedback_id == feedback_id))).scalar_one_or_none()


# ── Restrictions and appeals ─────────────────────────────────────────────

async def restrict(db: AsyncSession, admin_id: str, user_id: str, *, scopes: list[str], days: int,
                   internal_reason: str, public_reason: str, feedback_id: Optional[str], now: datetime) -> AccountRestriction:
    """Apply a temporary protective restriction. Called only by an
    administrator's request; nothing calls it automatically."""
    problems = policy.validate_restriction(scopes, days, internal_reason, public_reason)
    if problems:
        raise ReportError(422, problems)
    if user_id == admin_id:
        raise ReportError(422, ["you cannot restrict your own account"])
    row = AccountRestriction(
        user_id=user_id, feedback_id=feedback_id, scopes=_scopes_to_text(scopes),
        internal_reason=policy.clean_text(internal_reason, 1000, newlines=True),
        public_reason=policy.clean_text(public_reason, 300), status="active", applied_by=admin_id,
        created_at=now, expires_at=now + timedelta(days=days))
    db.add(row)
    await db.flush()
    return row


async def active_restrictions(db: AsyncSession, user_id: str, now: datetime) -> list[AccountRestriction]:
    rows = (await db.execute(select(AccountRestriction).where(
        AccountRestriction.user_id == user_id, AccountRestriction.status == "active",
        AccountRestriction.expires_at > now))).scalars().all()
    return list(rows)


async def is_restricted(db: AsyncSession, user_id: str, scope: str, now: Optional[datetime] = None) -> Optional[AccountRestriction]:
    """The active restriction that stops [scope] for this user, if any."""
    for row in await active_restrictions(db, user_id, now or datetime.utcnow()):
        if scope in scopes_of(row):
            return row
    return None


async def lift(db: AsyncSession, admin_id: str, restriction_id: str, *, note: str, now: datetime) -> AccountRestriction:
    row = await db.get(AccountRestriction, restriction_id)
    if row is None:
        raise ReportError(404, ["no such restriction"])
    if len(policy.clean_text(note, 1000, newlines=True)) < 10:
        raise ReportError(422, ["note: say why it is being lifted"])
    if row.status == "active":
        row.status = "lifted"
        row.lifted_at, row.lifted_by = now, admin_id
        row.lift_note = policy.clean_text(note, 1000, newlines=True)
    return row


async def file_appeal(db: AsyncSession, user_id: str, restriction_id: str, *, statement: str, now: datetime) -> RestrictionAppeal:
    row = await db.get(AccountRestriction, restriction_id)
    if row is None or row.user_id != user_id:
        raise ReportError(404, ["no such restriction"])
    problems = policy.validate_appeal(statement)
    if problems:
        raise ReportError(422, problems)
    appeals = (await db.execute(select(RestrictionAppeal).where(
        RestrictionAppeal.restriction_id == restriction_id))).scalars().all()
    reason = policy.can_appeal(row.status, row.expires_at, now, len(appeals),
                               any(a.status == "open" for a in appeals))
    if reason:
        raise ReportError(409, [reason])
    appeal = RestrictionAppeal(restriction_id=restriction_id, user_id=user_id,
                               statement=policy.clean_text(statement, 2000, newlines=True),
                               status="open", created_at=now)
    db.add(appeal)
    await db.flush()
    return appeal


async def decide_appeal(db: AsyncSession, admin_id: str, appeal_id: str, *, outcome: str, note: str,
                        now: datetime) -> RestrictionAppeal:
    """Decide an appeal. 'overturned' lifts the restriction; 'upheld' leaves
    it to run out on its date. The person is told the note either way."""
    appeal = await db.get(RestrictionAppeal, appeal_id)
    if appeal is None:
        raise ReportError(404, ["no such appeal"])
    problems = policy.validate_decision(outcome, note)
    if problems:
        raise ReportError(422, problems)
    if appeal.status != "open":
        raise ReportError(409, ["this appeal has already been decided"])
    appeal.status, appeal.decided_by, appeal.decided_at = outcome, admin_id, now
    appeal.decision_note = policy.clean_text(note, 1000, newlines=True)
    if outcome == "overturned":
        restriction = await db.get(AccountRestriction, appeal.restriction_id)
        if restriction is not None and restriction.status == "active":
            restriction.status, restriction.lifted_at, restriction.lifted_by = "lifted", now, admin_id
            restriction.lift_note = "Appeal overturned: " + appeal.decision_note
    return appeal
