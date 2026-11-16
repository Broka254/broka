"""Reading and changing provider records - the only place that does.

EVERY CHANGE passes the same gate, so there is no side door:

  validate (schema.validate_record, against the deployment's allowlist)
    -> refuse a change to a protected field (an edit cannot verify itself)
    -> refuse a fee change without its source and a reason
    -> clear the checks the change makes untrue (schema.apply_edit_consequences)
    -> write the row AND an append-only revision, in one transaction
    -> refresh this process's snapshot at once.

NOTHING HERE READS A PROVIDER'S WEBSITE. A fee changes only when a named
administrator records it with the page they read. There is no scheduled job,
scraper or webhook that updates a price: "do not silently update fees from
unverified external content" is enforced by there being no code that could.

Functions take the caller's session and do not commit; the router commits
once, after the audit row.
"""
from __future__ import annotations

import copy
import logging
from datetime import date, datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.models.escrow_provider import EscrowProviderRevision, EscrowProviderRow

from . import catalogue, schema, seed
from .links import official_url

logger = logging.getLogger(__name__)


class DirectoryError(Exception):
    """A change that was refused, with every reason, for the admin's screen."""

    def __init__(self, status_code: int, problems: list[str]):
        super().__init__("; ".join(problems))
        self.status_code = status_code
        self.problems = problems


def allowlist() -> tuple[str, ...]:
    return tuple(settings.escrow_provider_domains)


# ── Reading ──────────────────────────────────────────────────────────────

async def load_stored(db: AsyncSession) -> list[dict]:
    """The records administrators have saved, as validated dicts. A row that
    no longer validates (the allowlist changed under it) is skipped and
    logged: a provider the deployment no longer approves must not be shown."""
    rows = (await db.execute(select(EscrowProviderRow))).scalars().all()
    out = []
    for row in rows:
        record = copy.deepcopy(row.record)
        problems = schema.validate_record(record, allowlist())
        if problems:
            logger.error("[escrow_directory] stored record %s is not valid and is not served: %s",
                         row.id, "; ".join(problems[:3]))
            continue
        out.append(record)
    return out


async def all_records(db: AsyncSession) -> list[dict]:
    """Every provider, stored or seeded, listed or not (for administrators)."""
    return catalogue.merge(seed.records(), await load_stored(db))


async def get_record(db: AsyncSession, provider_id: str) -> Optional[dict]:
    return next((r for r in await all_records(db) if r["id"] == provider_id), None)


async def _row(db: AsyncSession, provider_id: str, *, lock: bool = False) -> Optional[EscrowProviderRow]:
    query = select(EscrowProviderRow).where(EscrowProviderRow.id == provider_id)
    if lock:
        query = query.with_for_update()
    # populate_existing: sessions use expire_on_commit=False, so a row read
    # earlier in this session would otherwise be served stale (AGENTS.md).
    return (await db.execute(query.execution_options(populate_existing=True))).scalar_one_or_none()


async def revisions(db: AsyncSession, provider_id: str, limit: int = 25) -> list[dict]:
    rows = (await db.execute(
        select(EscrowProviderRevision).where(EscrowProviderRevision.provider_id == provider_id)
        .order_by(EscrowProviderRevision.created_at.desc(), EscrowProviderRevision.id.desc())
        .limit(limit))).scalars().all()
    return [{
        "id": r.id, "version": r.version, "kind": r.kind, "actor_id": r.actor_id, "reason": r.reason,
        "source_url": r.source_url, "source_note": r.source_note,
        "created_at": r.created_at.isoformat() + "Z",
    } for r in rows]


# ── Writing ──────────────────────────────────────────────────────────────

def _clean_reason(reason: object) -> str:
    text = " ".join(str(reason or "").split())
    if len(text) < 5:
        raise DirectoryError(422, ["reason: say why (at least a few words); it is kept in the history"])
    return text[:500]


async def _save(db: AsyncSession, before: Optional[dict], after: dict, *, kind: str, actor_id: str,
                reason: str, expected_version: Optional[int], source_url: Optional[str] = None,
                source_note: Optional[str] = None) -> dict:
    """Validate [after], write it with its revision, and refresh the snapshot."""
    problems = schema.validate_record(after, allowlist())
    if problems:
        raise DirectoryError(422, problems)
    row = await _row(db, after["id"], lock=True)
    now = datetime.utcnow()
    if row is None:
        # First time an administrator touches a seeded provider: the stored
        # row starts at version 1, from whatever the admin edited.
        if expected_version not in (None, 0, 1):
            raise DirectoryError(409, ["this provider changed since you loaded it; reload and try again"])
        row = EscrowProviderRow(id=after["id"], status=after["status"],
                                canonical_domain=after["identity"]["canonical_domain"],
                                record=copy.deepcopy(after), version=1, updated_at=now, updated_by=actor_id)
        db.add(row)
    else:
        if expected_version is not None and expected_version != row.version:
            raise DirectoryError(409, ["this provider changed since you loaded it; reload and try again"])
        row.status = after["status"]
        row.canonical_domain = after["identity"]["canonical_domain"]
        row.record = copy.deepcopy(after)
        row.version = row.version + 1
        row.updated_at = now
        row.updated_by = actor_id
    db.add(EscrowProviderRevision(
        provider_id=after["id"], version=row.version, kind=kind, actor_id=actor_id, reason=reason,
        source_url=source_url, source_note=source_note, before=copy.deepcopy(before),
        after=copy.deepcopy(after), created_at=now))
    await db.flush()
    # This process sees the change immediately; others within SNAPSHOT_SECONDS.
    catalogue.reset()
    return {"record": after, "version": row.version}


async def create_provider(db: AsyncSession, record: dict, *, actor_id: str, reason: str) -> dict:
    """Add a provider as a DRAFT. A new provider needs its domain already on
    the deployment's allowlist: adding one is a configuration change."""
    reason = _clean_reason(reason)
    if not isinstance(record, dict):
        raise DirectoryError(422, ["record must be an object"])
    record = copy.deepcopy(record)
    record["status"] = "draft"
    trust = record.get("trust")
    if isinstance(trust, dict):
        trust.update(identity_verification="not_started", terms_review="not_started",
                     pricing_review="not_started", operational_test="not_started",
                     last_verified=None, next_review=None, reviewed_by=None)
    if isinstance(record.get("pricing"), dict):
        record["pricing"]["last_verified"] = None
    if await get_record(db, str(record.get("id"))) is not None:
        raise DirectoryError(409, [f"a provider with id {record.get('id')!r} already exists"])
    return await _save(db, None, record, kind="created", actor_id=actor_id, reason=reason,
                       expected_version=None)


async def edit_provider(db: AsyncSession, provider_id: str, patch: dict, *, actor_id: str, reason: str,
                        source_url: Optional[str] = None, source_note: Optional[str] = None,
                        expected_version: Optional[int] = None) -> dict:
    """Apply [patch] to a provider's details.

    Refused if the patch tries to set a field that records a review; a
    change to pricing needs [source_url] (on the provider's own domain) and
    [source_note]. Whatever the change makes untrue is cleared: see
    schema.apply_edit_consequences."""
    reason = _clean_reason(reason)
    if not isinstance(patch, dict) or not patch:
        raise DirectoryError(422, ["nothing to change"])
    protected = schema.protected_paths_in(patch)
    if protected:
        hint = "cannot be set by an edit; use the review or status endpoint"
        raise DirectoryError(422, [f"{path}: {hint}" for path in protected])
    before = await get_record(db, provider_id)
    if before is None:
        raise DirectoryError(404, ["no such provider"])
    if "id" in patch and patch["id"] != provider_id:
        raise DirectoryError(422, ["id: cannot be changed"])
    merged = schema.merge_patch(before, patch)
    after, cleared = schema.apply_edit_consequences(before, merged)

    pricing_changed = "pricing" in schema.changed_areas(before, after)
    clean_source: Optional[str] = None
    if pricing_changed:
        domain = after["identity"]["canonical_domain"]
        clean_source = official_url(source_url, domain)
        if clean_source is None:
            raise DirectoryError(422, ["source_url: a fee change needs the provider's own page it was "
                                       f"read from (https, on {domain})"])
        if len(" ".join(str(source_note or "").split())) < 10:
            raise DirectoryError(422, ["source_note: say what that page says (the figures you read)"])
    kind = "pricing_changed" if pricing_changed else "edited"
    result = await _save(db, before, after, kind=kind, actor_id=actor_id, reason=reason,
                         expected_version=expected_version, source_url=clean_source,
                         source_note=" ".join(str(source_note or "").split())[:1000] or None)
    result["cleared"] = cleared
    return result


async def record_review(db: AsyncSession, provider_id: str, *, actor_id: str, reason: str, area: str,
                        outcome: str, verified_on: Optional[str] = None, next_review: Optional[str] = None,
                        source_url: Optional[str] = None, source_note: Optional[str] = None,
                        expected_version: Optional[int] = None) -> dict:
    """An administrator records the result of checking one area.

    area: "identity" | "terms" | "pricing" | "operational".
    outcome: "verified"/"passed" (the check was done and it held), "failed",
    or "pending". "Verified" needs a real date no later than today and, for
    pricing, the page it was read from: the date is what freshness.py ages."""
    reason = _clean_reason(reason)
    before = await get_record(db, provider_id)
    if before is None:
        raise DirectoryError(404, ["no such provider"])
    after = copy.deepcopy(before)
    trust, domain = after["trust"], after["identity"]["canonical_domain"]
    good = outcome in ("verified", "passed")
    if area not in ("identity", "terms", "pricing", "operational"):
        raise DirectoryError(422, ["area: must be identity, terms, pricing or operational"])
    if outcome not in ("verified", "passed", "failed", "pending"):
        raise DirectoryError(422, ["outcome: must be verified, passed, failed or pending"])
    if (area == "operational") != (outcome == "passed") and good:
        raise DirectoryError(422, ["outcome: operational tests are 'passed'; the others are 'verified'"])

    from .freshness import parse_date
    clean_source: Optional[str] = None
    when: Optional[date] = None
    if good:
        when = parse_date(verified_on)
        if when is None:
            raise DirectoryError(422, ["verified_on: a date such as 2026-11-16 is required"])
        if when > datetime.utcnow().date():
            raise DirectoryError(422, ["verified_on: cannot be in the future"])
        if area == "pricing":
            clean_source = official_url(source_url, domain)
            if clean_source is None:
                raise DirectoryError(422, ["source_url: verifying pricing needs the provider's own page "
                                           f"you checked it against (https, on {domain})"])
            if len(" ".join(str(source_note or "").split())) < 10:
                raise DirectoryError(422, ["source_note: say what the page showed"])
            if after["pricing"].get("source_url") != clean_source:
                after["pricing"]["source_url"] = clean_source
    field = {"identity": "identity_verification", "terms": "terms_review", "pricing": "pricing_review",
             "operational": "operational_test"}[area]
    trust[field] = outcome
    if good:
        if area == "pricing":
            after["pricing"]["last_verified"] = when.isoformat()
        # The record's own date is the oldest of the areas' checks that count
        # (a record is as current as its least current part), set by the
        # administrator with next_review; here it records the latest check.
        trust["last_verified"] = when.isoformat()
        if next_review is not None:
            nxt = parse_date(next_review)
            if nxt is None or nxt <= when:
                raise DirectoryError(422, ["next_review: a date after the verification date"])
            trust["next_review"] = nxt.isoformat()
    elif area == "pricing":
        after["pricing"]["last_verified"] = None
    trust["reviewed_by"] = actor_id
    result = await _save(db, before, after, kind="reviewed", actor_id=actor_id, reason=reason,
                         expected_version=expected_version, source_url=clean_source,
                         source_note=" ".join(str(source_note or "").split())[:1000] or None)
    return result


async def change_status(db: AsyncSession, provider_id: str, target: str, *, actor_id: str, reason: str,
                        public_notice: Optional[str] = None,
                        expected_version: Optional[int] = None) -> dict:
    """Move a provider to [target]. Suspending needs only a reason and takes
    effect at once; approving needs every check done (approval_blockers)."""
    reason = _clean_reason(reason)
    before = await get_record(db, provider_id)
    if before is None:
        raise DirectoryError(404, ["no such provider"])
    bad = schema.transition_error(before["status"], target)
    if bad:
        raise DirectoryError(409, [bad])
    after = copy.deepcopy(before)
    if target == "approved":
        blockers = schema.approval_blockers(before)
        if blockers:
            raise DirectoryError(422, ["cannot be approved yet: " + "; ".join(blockers)])
    after["status"] = target
    if public_notice is not None:
        after["public_notice"] = " ".join(str(public_notice).split()) or None
    kind = {"approved": "approved", "suspended": "suspended", "rejected": "rejected",
            "under_review": "reinstated" if before["status"] in ("suspended", "rejected") else "status_changed",
            }.get(target, "status_changed")
    if target == "approved":
        after["trust"]["reviewed_by"] = actor_id
    return await _save(db, before, after, kind=kind, actor_id=actor_id, reason=reason,
                       expected_version=expected_version)


async def stored_version(db: AsyncSession, provider_id: str) -> int:
    """The version an edit should name: 0 for a provider with no row yet."""
    row = await _row(db, provider_id)
    return row.version if row is not None else 0
