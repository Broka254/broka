"""Validated, database-bounded audience resolution.

An audience is one of BROKA's real account classifications, never a free-form
client SQL fragment. The service only ever adds a fixed predicate to a User
query; explicit user ids are bounded and checked against the same eligibility
policy as the broad audiences.
"""
from __future__ import annotations

import json
from sqlalchemy import and_, exists, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AccountType, User
from api.models.service_communication import (
    ServiceCommunicationRecipient,
    ServiceCommunicationVersion,
)
from api.models.store import Store


AUDIENCE_KINDS = ("all", "buyers", "sellers", "store_owners", "user_ids")
MAX_EXPLICIT_USER_IDS = 5_000
# 5,000 uuid-sized ids plus JSON quoting and separators. The old 80 KB cap
# silently rejected the configured default before the configured audience
# limit could be applied, so an apparently supported selection failed as
# "too large" for a different reason.
MAX_AUDIENCE_JSON_CHARS = 400_000


class AudienceValidationError(ValueError):
    """A client-supplied audience that cannot be honoured as written."""

    def __init__(self, message: str, *, missing_user_ids: int = 0):
        super().__init__(message)
        self.missing_user_ids = missing_user_ids


def normalize_audience(raw: dict | None) -> dict:
    """Canonical audience JSON, or AudienceValidationError.

    No arbitrary keys are retained. Besides making the stored value stable,
    this is what keeps a future query builder from accidentally interpreting
    client-provided SQL-ish data as a filter.
    """
    if not isinstance(raw, dict):
        raise AudienceValidationError("audience must be an object")
    kind = raw.get("kind")
    if kind not in AUDIENCE_KINDS:
        raise AudienceValidationError(
            "audience.kind must be one of " + ", ".join(AUDIENCE_KINDS)
        )

    raw_ids = raw.get("user_ids") or []
    if not isinstance(raw_ids, list):
        raise AudienceValidationError("audience.user_ids must be an array")
    if len(raw_ids) > MAX_EXPLICIT_USER_IDS:
        raise AudienceValidationError(
            f"audience.user_ids may contain at most {MAX_EXPLICIT_USER_IDS} ids"
        )

    ids: list[str] = []
    seen: set[str] = set()
    for value in raw_ids:
        if not isinstance(value, str):
            raise AudienceValidationError("audience.user_ids must contain strings")
        cleaned = value.strip()
        if not cleaned or len(cleaned) > 64:
            raise AudienceValidationError("each audience user id must be 1-64 characters")
        if cleaned in seen:
            continue
        seen.add(cleaned)
        ids.append(cleaned)

    if kind == "user_ids" and not ids:
        raise AudienceValidationError("user_ids audience requires at least one user id")
    if kind != "user_ids" and ids:
        raise AudienceValidationError("user_ids is only valid with audience.kind=user_ids")

    result = {"kind": kind}
    if kind == "user_ids":
        result["user_ids"] = ids
    encoded = json.dumps(result, separators=(",", ":"), sort_keys=True)
    if len(encoded) > MAX_AUDIENCE_JSON_CHARS:
        raise AudienceValidationError("audience definition is too large")
    return result


def audience_json(audience: dict) -> str:
    return json.dumps(normalize_audience(audience), separators=(",", ":"), sort_keys=True)


def parse_audience(value: str | None) -> dict:
    if not value:
        return {"kind": "all"}
    try:
        parsed = json.loads(value)
        return normalize_audience(parsed)
    except (TypeError, ValueError, json.JSONDecodeError):
        # A malformed historical row is not executed as an audience. Refusing
        # to resolve it is safer than accidentally addressing everybody.
        return {"kind": "user_ids", "user_ids": []}


def parse_stored_audience(value: str | None) -> dict:
    """Strict read for publication: a corrupt row is an error, not "nobody".

    The lenient `parse_audience` is only for rendering a damaged historical row
    without executing it as a broad audience. Publication must not turn the
    same damage into a successfully published zero-recipient campaign.
    """
    if not value:
        raise AudienceValidationError("stored audience is missing")
    try:
        parsed = json.loads(value)
    except (TypeError, ValueError, json.JSONDecodeError) as exc:
        raise AudienceValidationError("stored audience is not valid JSON") from exc
    return normalize_audience(parsed)


def eligible_conditions() -> list:
    """The existing account policy, expressed as database predicates.

    Suspension is the fraud engine's high-risk band (trust_score < 20), and
    flagged accounts are excluded from operational broadcasts. These are the
    same signals `api.core.permissions` and listing eligibility already use;
    this module invents no new user status.
    """
    return [
        or_(User.trust_score.is_(None), User.trust_score >= 20),
        User.is_flagged.is_(False),
    ]


def audience_conditions(audience: dict) -> list:
    audience = normalize_audience(audience)
    kind = audience["kind"]
    conditions = eligible_conditions()
    if kind == "buyers":
        conditions.append(User.account_type == AccountType.buyer)
    elif kind == "sellers":
        conditions.append(User.account_type == AccountType.buyer_seller)
    elif kind == "store_owners":
        conditions.append(User.id.in_(
            select(Store.owner_id).where(
                Store.deleted_at.is_(None), Store.is_active.is_(True),
            )
        ))
    elif kind == "user_ids":
        conditions.append(User.id.in_(audience["user_ids"]))
    return conditions


async def validate_explicit_audience(db: AsyncSession, audience: dict) -> None:
    """Refuse a selected-id audience that silently drops unauthorized ids."""
    audience = normalize_audience(audience)
    if audience["kind"] != "user_ids":
        return
    ids = audience["user_ids"]
    found = int((await db.execute(
        select(func.count(User.id)).where(*audience_conditions(audience))
    )).scalar() or 0)
    if found != len(ids):
        raise AudienceValidationError(
            "one or more selected users do not exist or are not eligible",
            missing_user_ids=len(ids) - found,
        )


async def count_audience(db: AsyncSession, audience: dict) -> int:
    return int((await db.execute(
        select(func.count(User.id)).where(*audience_conditions(audience))
    )).scalar() or 0)


async def missing_user_ids(
    db: AsyncSession, communication_id: str, audience: dict, limit: int,
) -> list[str]:
    """The next bounded batch of users not yet in this communication's ledger."""
    already = exists().where(
        and_(
            ServiceCommunicationRecipient.communication_id == communication_id,
            ServiceCommunicationRecipient.user_id == User.id,
        )
    )
    rows = (await db.execute(
        select(User.id)
        .where(*audience_conditions(audience), ~already)
        .order_by(User.id)
        .limit(limit)
    )).scalars().all()
    return list(rows)

__all__ = [
    "AUDIENCE_KINDS", "MAX_EXPLICIT_USER_IDS", "AudienceValidationError",
    "normalize_audience", "audience_json", "parse_audience",
    "parse_stored_audience", "eligible_conditions", "audience_conditions",
    "validate_explicit_audience", "count_audience", "missing_user_ids",
]
