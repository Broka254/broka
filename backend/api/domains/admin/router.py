"""Admin Router v3.0 — now includes fraud management and audit log access.

Every route here is a read-only operational view unless its name says
otherwise. Financial routes read the canonical ledger and payment rows; they
never write, re-send a provider request, release money or change a status.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from datetime import datetime, timedelta
from decimal import Decimal
from typing import Optional, Sequence

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import (
    Float, String, and_, case, cast, desc, exists, func, literal, or_, select,
    text, union_all,
)

from api.database import (
    get_db, User, Listing, ListingStatus, Deal, Dispute, DisputeStatus,
    MpesaTransaction, MpesaStatus, AuditLog, FraudEvent, DealStatus, AccountType,
    FeaturedPayment, VerificationPayment, NegotiationMessage,
)
from api.models.dispute import CaseBranch, CaseState, DisputeCase
from api.models.escrow_ledger import LedgerAccount, LedgerDirection, LedgerEntry
from api.models.external_escrow import EConfirmEscrowStatus, ExternalEscrow
from api.models.listing_payment import ListingPayment
from api.models.media import AttachState, MediaAsset
from api.models.store import Store
from api.models.store_billing import StorePayment
from api.models.subscription import SubscriptionPayment
from api.models.zetupay import ZetuPayPayment, ZetuPayStatus
from api.core.audit import record_audit
from api.core.client_ip import client_ip_or_none
from api.core.money import money_decimal
from api.core.observability import request_id_var
from api.core.permissions import Permission, require_permission
from api.core.fraud import compute_trust_score, trust_band

_log = logging.getLogger(__name__)

router = APIRouter()

_MPESA_STATUSES = ("pending", "success", "failed")
_ZETUPAY_STATUSES = (
    ZetuPayStatus.INITIATED, ZetuPayStatus.PROCESSING,
    ZetuPayStatus.SUCCESS, ZetuPayStatus.FAILED,
)
_MANUAL_REFUND_OUTCOMES = ("seller_accepted", "seller_silent")
_PAYMENT_STATUSES = tuple(dict.fromkeys(_MPESA_STATUSES + _ZETUPAY_STATUSES))
_HEALTH_CHECK_TIMEOUT_SECONDS = 3.0


class AdminActionIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=500)


# ── Shared serialization / query helpers ─────────────────────────────────────

def _iso(value: Optional[datetime]) -> Optional[str]:
    """Naive UTC in, ISO-8601 UTC out. Never a timezone-dependent string."""
    if value is None:
        return None
    if value.tzinfo is not None:
        from api.core.timeutil import to_naive_utc
        value = to_naive_utc(value)
    return value.isoformat() + "Z"


def _now_iso() -> str:
    return _iso(datetime.utcnow())


def _money(value) -> Optional[float]:
    if value is None:
        return None
    return float(money_decimal(value))


def _status(value) -> Optional[str]:
    if value is None:
        return None
    return getattr(value, "value", str(value))


def _count_map(rows, statuses: Sequence[str]) -> dict[str, int]:
    counts = {status: 0 for status in statuses}
    for key, count in rows:
        name = _status(key)
        if name is None:
            continue
        counts[name] = counts.get(name, 0) + int(count or 0)
    return counts


def _audit_item(row: AuditLog, *, include_ip: bool = False) -> dict:
    """One audit row in the dashboard's contract.

    `detail` is nullable in the database but the admin client expects a
    string; an older row written without a note reads as "". Only the
    fields named here leave the API - no ORM state or provider payloads.
    """
    item = {
        "id": row.id,
        "actor_id": row.actor_id,
        "action": row.action,
        "resource_type": row.resource_type,
        "resource_id": row.resource_id,
        "detail": row.detail or "",
        "created_at": _iso(row.created_at),
    }
    if include_ip:
        item["ip_address"] = row.ip_address
    return item


def _deal_item(deal: Deal) -> dict:
    return {
        "id": deal.id,
        "listing_id": deal.listing_id,
        "seller_id": deal.seller_id,
        "buyer_id": deal.buyer_id,
        "agreed_price": _money(deal.agreed_price),
        "commission": _money(deal.commission),
        "status": _status(deal.status),
        "created_at": _iso(deal.created_at),
        "delivery_confirmed_at": _iso(deal.delivery_confirmed_at),
        "released_at": _iso(deal.released_at),
        "refunded_at": _iso(deal.refunded_at),
        "refund_outcome": deal.refund_outcome,
        "refund_requested_at": _iso(deal.refund_requested_at),
        "dispute_branch": deal.dispute_branch,
        "leak_flag": bool(deal.leak_flag),
    }


async def _deal_status_counts(db: AsyncSession) -> dict[str, int]:
    """Global lifecycle counts, unfiltered. `total` on the list is filtered."""
    rows = (await db.execute(
        select(Deal.status, func.count(Deal.id)).group_by(Deal.status)
    )).all()
    return _count_map(rows, [status.value for status in DealStatus])


async def _listing_status_counts(db: AsyncSession) -> dict[str, int]:
    rows = (await db.execute(
        select(Listing.status, func.count(Listing.id)).group_by(Listing.status)
    )).all()
    return _count_map(rows, [status.value for status in ListingStatus])


async def _dispute_state_counts(db: AsyncSession) -> dict[str, int]:
    rows = (await db.execute(
        select(DisputeCase.state, func.count(DisputeCase.id)).group_by(DisputeCase.state)
    )).all()
    return _count_map(rows, [state.value for state in CaseState])


def _mpesa_payment_selects():
    """Every distinct Daraja payment intent, normalized to one shape.

    These are intent rows, one per charge the payer was asked to approve.
    PaymentCallback is deliberately absent: a callback is the provider's
    delivery of the result for one of these rows, not a second payment.
    Domain rows whose provider is `zetupay` are excluded because their
    ZetuPayPayment row is the same underlying payment.
    """
    not_zetupay = lambda model: or_(  # noqa: E731 - local shorthand
        model.provider.is_(None), model.provider != "zetupay",
    )

    def select_row(model, *, reference, user_id, deal_id, purpose, status, amount):
        return select(
            model.id.label("id"),
            literal("mpesa").label("source"),
            reference.label("reference"),
            user_id.label("user_id"),
            deal_id.label("deal_id"),
            literal(purpose).label("purpose"),
            cast(amount, Float).label("amount"),
            status.label("status"),
            model.created_at.label("created_at"),
        )

    none = literal(None, String)
    return [
        select_row(
            MpesaTransaction,
            reference=func.coalesce(
                MpesaTransaction.mpesa_receipt, MpesaTransaction.checkout_request_id,
                MpesaTransaction.id,
            ),
            user_id=MpesaTransaction.buyer_id,
            deal_id=MpesaTransaction.deal_id,
            purpose="deal_commission",
            status=cast(MpesaTransaction.status, String),
            amount=MpesaTransaction.amount,
        ),
        select_row(
            ListingPayment,
            reference=func.coalesce(
                ListingPayment.mpesa_receipt, ListingPayment.checkout_request_id,
                ListingPayment.id,
            ),
            user_id=ListingPayment.user_id,
            deal_id=none,
            purpose="listing_fee",
            status=ListingPayment.status,
            amount=ListingPayment.amount,
        ).where(not_zetupay(ListingPayment)),
        select_row(
            SubscriptionPayment,
            reference=func.coalesce(
                SubscriptionPayment.mpesa_receipt, SubscriptionPayment.checkout_request_id,
                SubscriptionPayment.id,
            ),
            user_id=SubscriptionPayment.user_id,
            deal_id=none,
            purpose="subscription",
            status=SubscriptionPayment.status,
            amount=SubscriptionPayment.amount,
        ).where(not_zetupay(SubscriptionPayment)),
        select_row(
            StorePayment,
            reference=func.coalesce(
                StorePayment.mpesa_receipt, StorePayment.checkout_request_id,
                StorePayment.id,
            ),
            user_id=StorePayment.user_id,
            deal_id=none,
            purpose="store",
            status=StorePayment.status,
            amount=StorePayment.amount,
        ).where(not_zetupay(StorePayment)),
        select_row(
            FeaturedPayment,
            reference=func.coalesce(
                FeaturedPayment.mpesa_receipt, FeaturedPayment.checkout_request_id,
                FeaturedPayment.id,
            ),
            user_id=FeaturedPayment.user_id,
            deal_id=none,
            purpose="boost",
            status=cast(FeaturedPayment.status, String),
            amount=FeaturedPayment.amount,
        ).where(not_zetupay(FeaturedPayment)),
        select_row(
            VerificationPayment,
            reference=func.coalesce(
                VerificationPayment.mpesa_receipt, VerificationPayment.checkout_request_id,
                VerificationPayment.id,
            ),
            user_id=VerificationPayment.user_id,
            deal_id=none,
            purpose="verification",
            status=cast(VerificationPayment.status, String),
            amount=VerificationPayment.amount,
        ).where(not_zetupay(VerificationPayment)),
    ]


def _payment_union():
    """One paginated, filterable collection across both providers.

    ZetuPay's own transaction rows are not included: each is a terminal
    state of a ZetuPayPayment, so including both would count one payment
    twice. Deal escrow held by E-Confirm is not a payment to BROKA and is
    reported separately by /finance-integrity.
    """
    zetupay = select(
        ZetuPayPayment.id.label("id"),
        literal("zetupay").label("source"),
        ZetuPayPayment.reference.label("reference"),
        ZetuPayPayment.user_id.label("user_id"),
        literal(None, String).label("deal_id"),
        ZetuPayPayment.purpose.label("purpose"),
        cast(ZetuPayPayment.amount, Float).label("amount"),
        ZetuPayPayment.status.label("status"),
        ZetuPayPayment.created_at.label("created_at"),
    )
    return union_all(*_mpesa_payment_selects(), zetupay).subquery("admin_payments")


async def _payment_status_counts(db: AsyncSession) -> tuple[dict, dict]:
    normalized = _payment_union()
    rows = (await db.execute(
        select(normalized.c.source, normalized.c.status, func.count())
        .group_by(normalized.c.source, normalized.c.status)
    )).all()
    mpesa = {status: 0 for status in _MPESA_STATUSES}
    zetupay = {status: 0 for status in _ZETUPAY_STATUSES}
    for source, status, count in rows:
        name = _status(status)
        # Provider rows written before the status column had a default can
        # hold NULL. A None key is not a valid JSON object key and would make
        # the dashboard's fixed status list silently miss the row; it is
        # unknown, not pending.
        if name is None:
            continue
        if source == "mpesa":
            mpesa[name] = mpesa.get(name, 0) + int(count or 0)
        elif source == "zetupay":
            zetupay[name] = zetupay.get(name, 0) + int(count or 0)
    return mpesa, zetupay


def _awaiting_manual_refund_condition():
    """E-Confirm refunds BROKA approved but cannot execute through its API.

    The deal is frozen as disputed, the approved outcome is recorded, no
    refund timestamp exists yet, and at least one provider payment actually
    took the buyer's money.
    """
    return and_(
        Deal.status == DealStatus.disputed,
        Deal.refund_outcome.in_(_MANUAL_REFUND_OUTCOMES),
        Deal.refunded_at.is_(None),
        exists().where(
            ExternalEscrow.deal_id == Deal.id,
            ExternalEscrow.status.in_(EConfirmEscrowStatus.MONEY_IN),
        ),
    )


@router.get("/summary")
async def admin_summary(
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    from api.domains.listings.paid import live_clause

    users_r = await db.execute(select(func.count(User.id)))
    listings_r = await db.execute(select(func.count(Listing.id)))
    # Same definition as ops_snapshot.listings.active: an "active" count
    # that included expired/unpaid, sold-out or (while auctions are off)
    # auction rows would tell the dashboard buyers can see listings they
    # cannot. The full lifecycle count stays in `listings`.
    listings_active_r = await db.execute(
        select(func.count(Listing.id)).where(
            Listing.status == ListingStatus.active, live_clause())
    )
    deals_r = await db.execute(select(func.count(Deal.id)))
    deals_released_r = await db.execute(
        select(func.count(Deal.id)).where(Deal.status == DealStatus.released)
    )
    revenue_r = await db.execute(
        select(func.sum(Deal.commission)).where(Deal.status == DealStatus.released)
    )
    disputes_r = await db.execute(select(func.count(Dispute.id)))
    active_case_states = [state for state in CaseState if state.is_active]
    dispute_cases_active_r = await db.execute(
        select(func.count(DisputeCase.id)).where(DisputeCase.state.in_(active_case_states))
    )
    flagged_r = await db.execute(select(func.count(User.id)).where(User.is_flagged == True))  # noqa: E712

    return {
        "users": users_r.scalar() or 0,
        "listings": listings_r.scalar() or 0,
        "listings_active": int(listings_active_r.scalar() or 0),
        "deals": deals_r.scalar() or 0,
        "deals_released": int(deals_released_r.scalar() or 0),
        "commission_earned_kes": _money(revenue_r.scalar() or 0),
        "disputes": disputes_r.scalar() or 0,
        "dispute_cases_active": int(dispute_cases_active_r.scalar() or 0),
        "flagged_users": flagged_r.scalar() or 0,
    }


@router.get("/ops-snapshot")
async def ops_snapshot(
    window_hours: int = Query(24, ge=1, le=720),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """One bounded read for the dashboard's operations page.

    Windows are half-open UTC intervals [now - window_hours, now); the
    previous interval is the equally long one immediately before it. Counts
    are durable table totals, never process-local metrics.
    """
    from api.domains.listings.paid import live_clause

    now = datetime.utcnow()
    width = timedelta(hours=window_hours)
    current_start = now - width
    previous_start = current_start - width

    async def count(model, *where):
        query = select(func.count()).select_from(model)
        if where:
            query = query.where(*where)
        return int((await db.execute(query)).scalar() or 0)

    deal_rows = (await db.execute(
        select(Deal.status, func.count(Deal.id)).group_by(Deal.status)
    )).all()
    deals_by_status = _count_map(deal_rows, [status.value for status in DealStatus])
    listing_rows = (await db.execute(
        select(Listing.status, func.count(Listing.id)).group_by(Listing.status)
    )).all()
    listings_by_status = _count_map(listing_rows, [status.value for status in ListingStatus])
    case_rows = (await db.execute(
        select(DisputeCase.state, func.count(DisputeCase.id)).group_by(DisputeCase.state)
    )).all()
    cases_by_state = _count_map(case_rows, [state.value for state in CaseState])

    commission_total = _money((await db.execute(
        select(func.coalesce(func.sum(Deal.commission), 0))
        .where(Deal.status == DealStatus.released)
    )).scalar() or 0)
    commission_current = _money((await db.execute(
        select(func.coalesce(func.sum(Deal.commission), 0)).where(
            Deal.status == DealStatus.released,
            Deal.released_at >= current_start, Deal.released_at < now,
        )
    )).scalar() or 0)
    commission_previous = _money((await db.execute(
        select(func.coalesce(func.sum(Deal.commission), 0)).where(
            Deal.status == DealStatus.released,
            Deal.released_at >= previous_start, Deal.released_at < current_start,
        )
    )).scalar() or 0)

    mpesa_counts, zetupay_counts = await _payment_status_counts(db)
    escrow_rows = (await db.execute(
        select(ExternalEscrow.status, func.count(ExternalEscrow.id))
        .group_by(ExternalEscrow.status)
    )).all()
    escrow_by_status = _count_map(
        escrow_rows,
        (
            EConfirmEscrowStatus.CREATING, EConfirmEscrowStatus.PENDING,
            EConfirmEscrowStatus.FUNDED, EConfirmEscrowStatus.RELEASE_PENDING,
            EConfirmEscrowStatus.COMPLETED, EConfirmEscrowStatus.PAYOUT_FAILED,
            EConfirmEscrowStatus.UNKNOWN,
        ),
    )
    media_rows = (await db.execute(
        select(MediaAsset.purpose, func.count(MediaAsset.id))
        .where(MediaAsset.attach_state == AttachState.PENDING)
        .group_by(MediaAsset.purpose)
    )).all()
    media_by_kind = {
        (_status(kind) or "unknown"): int(count or 0) for kind, count in media_rows
    }

    from api.core.ledger import ledger as _ledger
    trial = await _ledger.trial_balance(db)
    credits = await _ledger_account_total(db, LedgerAccount.escrow_holding, LedgerDirection.credit)
    debits = await _ledger_account_total(db, LedgerAccount.escrow_holding, LedgerDirection.debit)

    return {
        "generated_at": _iso(now),
        "timezone": "UTC",
        "window_hours": window_hours,
        "definitions": {
            "window": (
                "current is [generated_at-window_hours, generated_at); previous is "
                "the same-length interval immediately before it. UTC throughout."
            ),
            "users.high_risk": "trust_score below 20 (the fraud engine's high_risk band).",
            "listings.active": (
                "status=active AND visible to buyers under the canonical paid/"
                "store/auction/sold-out clause."
            ),
            "deals.released_current": "released_at inside the current interval.",
            "commission": (
                "Recognized commission (Deal.commission) on released deals, not "
                "reconciled bank cash. Current/previous use released_at."
            ),
            "disputes.legacy": "rows in the legacy disputes table.",
            "disputes.cases_active": (
                "dispute_cases in an active state; escalated and closed states are excluded."
            ),
            "payments.mpesa": (
                "Daraja payment intents (deal, listing, subscription, store, boost, "
                "verification); callbacks and ZetuPay-railed domain rows excluded."
            ),
            "payments.zetupay": "ZetuPayPayment intent rows (not their transaction receipts).",
            "payments.zetupay_unfinished": "initiated or processing ZetuPay payments.",
            "escrow.open": "E-Confirm payments still creating, pending or unknown.",
            "escrow.awaiting_manual_refund": (
                "disputed deals whose refund was approved on an E-Confirm-held payment "
                "but not yet marked refunded."
            ),
            "media.pending_by_kind": "media_assets with attach_state=pending, by purpose.",
            "ledger": (
                "Whole-table double-entry ledger and the per-deal negative escrow "
                "assertion from the canonical EscrowLedger.trial_balance()."
            ),
        },
        "users": {
            "total": await count(User),
            "new_current": await count(
                User, User.created_at >= current_start, User.created_at < now),
            "new_previous": await count(
                User, User.created_at >= previous_start, User.created_at < current_start),
            "flagged": await count(User, User.is_flagged == True),  # noqa: E712
            "high_risk": await count(
                User, User.trust_score.is_not(None), User.trust_score < 20),
            "admins": await count(User, User.is_admin == True),     # noqa: E712
        },
        "listings": {
            "total": await count(Listing),
            "by_status": listings_by_status,
            "active": await count(
                Listing, Listing.status == ListingStatus.active, live_clause(now)),
            "created_current": await count(
                Listing, Listing.created_at >= current_start, Listing.created_at < now),
            "created_previous": await count(
                Listing, Listing.created_at >= previous_start,
                Listing.created_at < current_start),
        },
        "deals": {
            "total": await count(Deal),
            "by_status": deals_by_status,
            "created_current": await count(
                Deal, Deal.created_at >= current_start, Deal.created_at < now),
            "created_previous": await count(
                Deal, Deal.created_at >= previous_start, Deal.created_at < current_start),
            "released_current": await count(
                Deal, Deal.status == DealStatus.released,
                Deal.released_at >= current_start, Deal.released_at < now),
            "released_previous": await count(
                Deal, Deal.status == DealStatus.released,
                Deal.released_at >= previous_start, Deal.released_at < current_start),
        },
        "commission": {
            "released_total_kes": commission_total,
            "released_current_kes": commission_current,
            "released_previous_kes": commission_previous,
        },
        "disputes": {
            "legacy_total": await count(Dispute),
            "legacy_open": await count(Dispute, Dispute.status == DisputeStatus.open),
            "cases_total": await count(DisputeCase),
            "cases_active": sum(
                cases_by_state.get(state.value, 0)
                for state in CaseState if state.is_active
            ),
            "cases_by_state": cases_by_state,
        },
        "fraud": {
            "events_total": await count(FraudEvent),
            "events_open": await count(
                FraudEvent, or_(FraudEvent.resolved.is_(None), FraudEvent.resolved == False)),  # noqa: E712
        },
        "payments": {
            "mpesa": mpesa_counts,
            "zetupay": zetupay_counts,
            "zetupay_unfinished": sum(
                zetupay_counts.get(status, 0)
                for status in (ZetuPayStatus.INITIATED, ZetuPayStatus.PROCESSING)
            ),
            "mpesa_pending": mpesa_counts.get(MpesaStatus.pending.value, 0),
        },
        "escrow": {
            "total": sum(escrow_by_status.values()),
            "by_status": escrow_by_status,
            "open": sum(escrow_by_status.get(status, 0) for status in EConfirmEscrowStatus.OPEN),
            "payout_failed": escrow_by_status.get(EConfirmEscrowStatus.PAYOUT_FAILED, 0),
            "release_pending": escrow_by_status.get(EConfirmEscrowStatus.RELEASE_PENDING, 0),
            "completed": escrow_by_status.get(EConfirmEscrowStatus.COMPLETED, 0),
            "awaiting_manual_refund": await count(Deal, _awaiting_manual_refund_condition()),
        },
        "media": {
            "pending_total": sum(media_by_kind.values()),
            "pending_by_kind": media_by_kind,
        },
        "ledger": {
            "balanced": bool(trial["balanced"]),
            "discrepancy_kes": _money(trial["discrepancy_kes"]),
            "negative_escrow_deals": len(trial["negative_escrow_deals"]),
            "escrow_held_kes": _money(credits - debits),
        },
    }


async def _ledger_account_total(db: AsyncSession, account, direction) -> Decimal:
    value = (await db.execute(
        select(func.coalesce(func.sum(LedgerEntry.amount_kes), 0)).where(
            LedgerEntry.account == account,
            LedgerEntry.direction == direction,
        )
    )).scalar() or 0
    return money_decimal(value)


@router.get("/health/services")
async def service_health(
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """Dependency checks and provider configuration, bounded by timeouts.

    A database connection check is separate from schema readiness: an
    unreachable database and a reachable one missing critical columns are
    different incidents. Provider entries only report whether configuration
    exists - `probe: not_run` says plainly that no provider was contacted.
    No credential, DSN, token or provider body is returned.
    """
    from api.core.config import settings
    from api.database import engine, schema_status

    checks: list[dict] = []

    async def add_check(name: str, kind: str, work):
        started = time.perf_counter()
        checked_at = _now_iso()
        try:
            status, detail = await asyncio.wait_for(
                work(), timeout=_HEALTH_CHECK_TIMEOUT_SECONDS,
            )
        except asyncio.TimeoutError:
            status, detail = (
                "unavailable",
                f"check timed out after {_HEALTH_CHECK_TIMEOUT_SECONDS:g} seconds",
            )
        except Exception as exc:                    # type name only, never str(exc)
            status, detail = "unavailable", f"check failed ({type(exc).__name__})"
        checks.append({
            "name": name,
            "kind": kind,
            "status": status,
            "detail": detail,
            "latency_ms": round((time.perf_counter() - started) * 1000, 1),
            "checked_at": checked_at,
        })

    async def database_connectivity():
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
        return "ok", "SELECT 1 succeeded"

    async def database_schema():
        status = await schema_status()
        if status["current"]:
            return "ok", (
                f"schema {status['current_version']} meets required "
                f"{status['required_version']}"
            )
        detail = (
            f"schema {status['current_version']} below required "
            f"{status['required_version']}"
        )
        if status.get("missing"):
            detail += f"; missing tables/columns reported: {len(status['missing'])}"
        if status.get("missing_indexes"):
            detail += f"; missing indexes reported: {len(status['missing_indexes'])}"
        return "degraded", detail

    async def redis_check():
        if not settings.redis_enabled:
            return "unconfigured", "Redis is not configured; in-process fallbacks are active"
        import redis.asyncio as aioredis
        client = aioredis.from_url(
            settings.redis_url, socket_connect_timeout=2, socket_timeout=2,
        )
        try:
            await client.ping()
            return "ok", "PING succeeded"
        finally:
            await client.aclose()

    await add_check("database_connectivity", "database", database_connectivity)
    await add_check("database_schema", "database", database_schema)
    await add_check("redis", "cache", redis_check)

    def configured(*values) -> bool:
        return all(bool(value) for value in values)

    provider_specs = [
        (
            "mpesa",
            configured(settings.mpesa_consumer_key, settings.mpesa_consumer_secret),
            "Daraja credentials and callback secret"
            + (" are configured" if settings.mpesa_callback_secret else
               " are configured; callback secret is not"),
        ),
        (
            "econfirm",
            bool(settings.econfirm_api_key),
            "E-Confirm API key is configured" if settings.econfirm_api_key
            else "E-Confirm API key is not configured",
        ),
        (
            "zetupay",
            bool(settings.zetupay_enabled and settings.zetupay_secret_key),
            "ZetuPay is enabled and its secret key is configured"
            if settings.zetupay_enabled and settings.zetupay_secret_key
            else "ZetuPay is disabled or its secret key is not configured",
        ),
        (
            # Mobitech is deprecated and deliberately not counted: stale
            # MOBITECH_* values must never read as "SMS configured".
            "sms_texin",
            bool(settings.texin_api_key),
            "Texin BulkSMS is configured (primary SMS provider)"
            if settings.texin_api_key
            else "Texin BulkSMS is not configured",
        ),
        (
            "sms_africas_talking",
            bool(settings.at_api_key and settings.at_username),
            "Africa's Talking is configured (fallback SMS provider)"
            if (settings.at_api_key and settings.at_username)
            else "Africa's Talking is not configured",
        ),
        (
            "sms",
            bool(settings.texin_api_key
                 or (settings.at_api_key and settings.at_username)),
            "an SMS provider is configured" if (
                settings.texin_api_key
                or (settings.at_api_key and settings.at_username)
            ) else "no SMS provider is configured",
        ),
        (
            "email",
            bool(settings.email_enabled),
            "email delivery is enabled" if settings.email_enabled
            else "email delivery is disabled or not configured",
        ),
        (
            "object_storage",
            bool(settings.r2_configured),
            "R2 object storage is configured" if settings.r2_configured
            else "R2 object storage is not configured",
        ),
        (
            "error_tracking",
            bool(settings.sentry_dsn),
            "Sentry is configured" if settings.sentry_dsn
            else "Sentry is not configured",
        ),
    ]
    providers = [
        {
            "name": name,
            "kind": "external_provider",
            "status": "configured" if ok else "not_configured",
            "probe": "not_run",
            "detail": detail,
        }
        for name, ok, detail in provider_specs
    ]

    return {
        "generated_at": _now_iso(),
        "checks": checks,
        "providers": providers,
        "note": (
            "Provider entries report configuration only; no external provider was "
            "contacted (probe=not_run). Each dependency check is bounded to "
            f"{_HEALTH_CHECK_TIMEOUT_SECONDS:g} seconds."
        ),
    }


@router.get("/stores")
async def admin_stores(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    search: Optional[str] = Query(None, max_length=100),
    category: Optional[str] = Query(None, max_length=100),
    county: Optional[str] = Query(None, max_length=100),
    status: Optional[str] = Query(None),
    active: Optional[bool] = None,
    deleted: bool = False,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Paginated store directory. Deleted stores are excluded by default.

    `status` is one of active|inactive|deleted. Legacy `active` and
    `deleted` query parameters still work and are combined with it.
    """
    conditions = []
    if status is not None:
        if status not in ("active", "inactive", "deleted"):
            raise HTTPException(
                status_code=422,
                detail="status must be one of active, inactive, deleted",
            )
        if status == "deleted":
            conditions.append(Store.deleted_at.is_not(None))
        else:
            conditions.append(Store.deleted_at.is_(None))
            conditions.append(Store.is_active == (status == "active"))
    elif deleted:
        conditions.append(Store.deleted_at.is_not(None))
    else:
        conditions.append(Store.deleted_at.is_(None))
    if active is not None:
        conditions.append(Store.is_active == active)
    if search:
        term = f"%{search.strip()}%"
        conditions.append(or_(Store.name.ilike(term), Store.slug.ilike(term)))
    if category:
        conditions.append(Store.category == category)
    if county:
        conditions.append(Store.county == county)

    total = int((await db.execute(
        select(func.count(Store.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(Store).where(*conditions)
        .order_by(desc(Store.created_at), desc(Store.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    return {
        "items": [
            {
                "id": store.id,
                "name": store.name,
                "slug": store.slug,
                "owner_id": store.owner_id,
                "category": store.category,
                "county": store.county,
                "is_active": bool(store.is_active),
                "rating": store.rating,
                "rating_reviews": int(store.rating_reviews or 0),
                "deleted_at": _iso(store.deleted_at),
                "created_at": _iso(store.created_at),
            }
            for store in rows
        ],
        "total": total,
        "limit": limit,
        "offset": offset,
        "generated_at": _now_iso(),
    }


def _user_item(user: User) -> dict:
    score = user.trust_score if user.trust_score is not None else 100
    return {
        "id": user.id,
        "name": user.name,
        "email": user.email,
        "phone": user.phone,
        "is_admin": bool(user.is_admin),
        "is_verified": bool(user.is_verified),
        "trust_score": score,
        "trust_band": trust_band(score),
        "is_flagged": bool(user.is_flagged),
        "completed_deals": int(user.completed_deals or 0),
        "rating": user.rating,
        "created_at": _iso(user.created_at),
    }


@router.get("/users")
async def list_users(
    response: Response,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    search: Optional[str] = Query(None, max_length=100),
    is_admin: Optional[bool] = None,
    account_type: Optional[AccountType] = None,
    flagged_only: bool = False,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    """User directory. X-Total-Count is the filtered total, not the page size."""
    conditions = []
    if search and search.strip():
        term = f"%{search.strip()}%"
        conditions.append(or_(
            User.name.ilike(term),
            User.nickname.ilike(term),
            User.email.ilike(term),
            User.phone.ilike(term),
            User.business_name.ilike(term),
            User.business_display_name.ilike(term),
        ))
    if is_admin is not None:
        conditions.append(User.is_admin == is_admin)
    if account_type is not None:
        conditions.append(User.account_type == account_type)
    if flagged_only:
        conditions.append(User.is_flagged == True)  # noqa: E712

    total = int((await db.execute(
        select(func.count(User.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(User).where(*conditions)
        .order_by(desc(User.created_at), desc(User.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    response.headers["X-Total-Count"] = str(total)
    return [_user_item(user) for user in rows]


def _validated_choices(values, allowed: Sequence[str], label: str) -> Optional[list[str]]:
    if not values:
        return None
    cleaned: list[str] = []
    for raw in values:
        for value in str(raw).split(","):
            value = value.strip()
            if not value:
                continue
            if value not in allowed:
                raise HTTPException(
                    status_code=422,
                    detail=f"invalid {label}: {value!r}; expected one of {sorted(allowed)}",
                )
            if value not in cleaned:
                cleaned.append(value)
    return cleaned or None


# ── Deals ─────────────────────────────────────────────────────────────────────

@router.get("/deals")
async def admin_deals(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    status: Optional[list[str]] = Query(None),
    seller_id: Optional[str] = Query(None, max_length=64),
    buyer_id: Optional[str] = Query(None, max_length=64),
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
    db: AsyncSession = Depends(get_db),
):
    """Paginated deals. `status_counts` is global; `total` is filtered."""
    statuses = _validated_choices(status, [value.value for value in DealStatus], "deal status")
    conditions = []
    if statuses:
        conditions.append(Deal.status.in_(statuses))
    if seller_id:
        conditions.append(Deal.seller_id == seller_id)
    if buyer_id:
        conditions.append(Deal.buyer_id == buyer_id)

    total = int((await db.execute(
        select(func.count(Deal.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(Deal).where(*conditions)
        .order_by(desc(Deal.created_at), desc(Deal.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    return {
        "items": [_deal_item(deal) for deal in rows],
        "total": total,
        "limit": limit,
        "offset": offset,
        "status_counts": await _deal_status_counts(db),
        "generated_at": _now_iso(),
    }


@router.get("/deals/{deal_id}")
async def admin_deal_detail(
    deal_id: str,
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
    db: AsyncSession = Depends(get_db),
):
    """One deal and its real child records. Missing children are empty arrays."""
    deal = (await db.execute(
        select(Deal).where(Deal.id == deal_id)
    )).scalar_one_or_none()
    if deal is None:
        raise HTTPException(status_code=404, detail="Deal not found")

    ledger_rows = (await db.execute(
        select(LedgerEntry).where(LedgerEntry.deal_id == deal_id)
        .order_by(desc(LedgerEntry.created_at), desc(LedgerEntry.id))
    )).scalars().all()
    escrow_rows = (await db.execute(
        select(ExternalEscrow).where(ExternalEscrow.deal_id == deal_id)
        .order_by(ExternalEscrow.payment_no, ExternalEscrow.created_at)
    )).scalars().all()
    mpesa_rows = (await db.execute(
        select(MpesaTransaction).where(MpesaTransaction.deal_id == deal_id)
        .order_by(desc(MpesaTransaction.created_at), desc(MpesaTransaction.id))
    )).scalars().all()
    dispute_rows = (await db.execute(
        select(DisputeCase).where(DisputeCase.deal_id == deal_id)
        .order_by(desc(DisputeCase.created_at), desc(DisputeCase.id))
    )).scalars().all()

    return {
        "deal": _deal_item(deal),
        "ledger_entries": [
            {
                "id": row.id,
                "account": _status(row.account),
                "direction": _status(row.direction),
                "amount_kes": _money(row.amount_kes),
                "description": row.description,
                "ref_id": row.ref_id,
                "created_at": _iso(row.created_at),
            }
            for row in ledger_rows
        ],
        "external_escrows": [
            {
                "id": row.id,
                "payment_no": row.payment_no,
                "provider": row.provider,
                "provider_transaction_id": row.provider_transaction_id,
                "status": row.status,
                "provider_raw_status": row.provider_raw_status,
                "amount": _money(row.amount),
                "currency": row.currency,
                "merchant_commission_amount": _money(row.merchant_commission_amount),
                "provider_fee_amount": _money(row.provider_fee_amount),
                "last_checked_at": _iso(row.last_checked_at),
                "funding_initiated_at": _iso(row.funding_initiated_at),
                "funded_at": _iso(row.funded_at),
                "release_initiated_at": _iso(row.release_initiated_at),
                "released_at": _iso(row.released_at),
                "last_error": row.last_error,
                "created_at": _iso(row.created_at),
            }
            for row in escrow_rows
        ],
        "mpesa_transactions": [
            {
                "id": row.id,
                "amount": _money(row.amount),
                "mpesa_receipt": row.mpesa_receipt,
                "status": _status(row.status),
                "created_at": _iso(row.created_at),
            }
            for row in mpesa_rows
        ],
        "dispute_cases": [
            {
                "id": row.id,
                "state": _status(row.state),
                "dispute_type": row.dispute_type,
                "branch": _status(row.branch),
                "rule_decision": row.rule_decision,
                "rule_decision_reason": row.rule_decision_reason,
                "fund_action": row.fund_action,
                "fund_amount": _money(row.fund_amount),
                "resolved_by": row.resolved_by,
                "created_at": _iso(row.created_at),
                "closed_at": _iso(row.closed_at),
            }
            for row in dispute_rows
        ],
        "generated_at": _now_iso(),
    }


# ── Listings ──────────────────────────────────────────────────────────────────

@router.get("/listings")
async def admin_listings(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    status: Optional[list[str]] = Query(None),
    category: Optional[str] = Query(None, max_length=100),
    seller_id: Optional[str] = Query(None, max_length=64),
    store_id: Optional[str] = Query(None, max_length=64),
    search: Optional[str] = Query(None, max_length=100),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Paginated listings. `status_counts` is global; `total` is filtered.

    Listing has no soft-delete column: status is the canonical lifecycle
    field. Counts include every status, so cancelled/completed are visible
    here rather than silently treated as active.
    """
    statuses = _validated_choices(
        status, [value.value for value in ListingStatus], "listing status")
    conditions = []
    if statuses:
        conditions.append(Listing.status.in_(statuses))
    if category:
        conditions.append(Listing.category == category)
    if seller_id:
        conditions.append(Listing.seller_id == seller_id)
    if store_id:
        conditions.append(Listing.store_id == store_id)
    if search and search.strip():
        term = f"%{search.strip()}%"
        conditions.append(or_(Listing.name.ilike(term), Listing.description.ilike(term)))

    total = int((await db.execute(
        select(func.count(Listing.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(Listing).where(*conditions)
        .order_by(desc(Listing.created_at), desc(Listing.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    return {
        "items": [
            {
                "id": listing.id,
                "name": listing.name,
                "seller_id": listing.seller_id,
                "store_id": listing.store_id,
                "category": listing.category,
                "price": _money(listing.price),
                "status": _status(listing.status),
                "listing_type": _status(listing.listing_type),
                "location_name": listing.location_name,
                "views": int(listing.views or 0),
                "is_featured": bool(listing.is_featured),
                "created_at": _iso(listing.created_at),
            }
            for listing in rows
        ],
        "total": total,
        "limit": limit,
        "offset": offset,
        "status_counts": await _listing_status_counts(db),
        "generated_at": _now_iso(),
    }


# ── Disputes ──────────────────────────────────────────────────────────────────

@router.get("/disputes")
async def admin_disputes(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    state: Optional[list[str]] = Query(None),
    branch: Optional[str] = Query(None),
    dispute_type: Optional[str] = Query(None, max_length=64),
    deal_id: Optional[str] = Query(None, max_length=64),
    admin: User = Depends(require_permission(Permission.VIEW_ALL_DISPUTES)),
    db: AsyncSession = Depends(get_db),
):
    """Modern dispute cases plus a separate legacy-dispute summary.

    `items`/`total`/`state_counts` describe dispute_cases only. `legacy`
    describes the older `disputes` table only. They are never added
    together: one deal can appear in both, so summing would double-count it.
    No AI decision is run by this read.
    """
    states = _validated_choices(state, [value.value for value in CaseState], "dispute state")
    conditions = []
    if states:
        conditions.append(DisputeCase.state.in_(states))
    if branch:
        allowed_branches = [value.value for value in CaseBranch]
        if branch not in allowed_branches:
            raise HTTPException(
                status_code=422,
                detail=f"invalid dispute branch: {branch!r}",
            )
        conditions.append(DisputeCase.branch == CaseBranch(branch))
    if dispute_type:
        conditions.append(DisputeCase.dispute_type == dispute_type)
    if deal_id:
        conditions.append(DisputeCase.deal_id == deal_id)

    total = int((await db.execute(
        select(func.count(DisputeCase.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(DisputeCase, Deal).outerjoin(Deal, Deal.id == DisputeCase.deal_id)
        .where(*conditions)
        .order_by(desc(DisputeCase.created_at), desc(DisputeCase.id))
        .limit(limit).offset(offset)
    )).all()
    now = datetime.utcnow()
    items = []
    for dispute, deal in rows:
        age = None
        if dispute.created_at is not None:
            age = round(max(0.0, (now - dispute.created_at).total_seconds() / 3600), 2)
        items.append({
            "id": dispute.id,
            "deal_id": dispute.deal_id,
            "opener_id": dispute.opener_id,
            "dispute_type": dispute.dispute_type,
            "branch": _status(dispute.branch),
            "state": _status(dispute.state),
            "ai_recommendation": dispute.ai_recommendation,
            "rule_decision": dispute.rule_decision,
            "rule_decision_reason": dispute.rule_decision_reason,
            "fund_action": dispute.fund_action,
            "fund_amount": _money(dispute.fund_amount),
            "resolved_by": dispute.resolved_by,
            "created_at": _iso(dispute.created_at),
            "updated_at": _iso(dispute.updated_at),
            "closed_at": _iso(dispute.closed_at),
            "age_hours": age,
            "deal_amount_kes": _money(deal.agreed_price) if deal is not None else None,
            "deal_seller_id": deal.seller_id if deal is not None else None,
            "deal_buyer_id": deal.buyer_id if deal is not None else None,
        })

    legacy_total = int((await db.execute(
        select(func.count(Dispute.id))
    )).scalar() or 0)
    legacy_open = int((await db.execute(
        select(func.count(Dispute.id)).where(Dispute.status == DisputeStatus.open)
    )).scalar() or 0)
    return {
        "items": items,
        "total": total,
        "limit": limit,
        "offset": offset,
        "state_counts": await _dispute_state_counts(db),
        "legacy": {"total": legacy_total, "open": legacy_open},
        "generated_at": _now_iso(),
    }


# ── Payments ──────────────────────────────────────────────────────────────────

@router.get("/payments")
async def admin_payments(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    source: Optional[str] = Query(None),
    status: Optional[list[str]] = Query(None),
    purpose: Optional[str] = Query(None, max_length=32),
    user_id: Optional[str] = Query(None, max_length=64),
    deal_id: Optional[str] = Query(None, max_length=64),
    search: Optional[str] = Query(None, max_length=100),
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
    db: AsyncSession = Depends(get_db),
):
    """Read-only payment intents across Daraja and ZetuPay.

    One row per underlying payment: provider callbacks, ZetuPay transaction
    receipts and E-Confirm escrow records are not counted as additional
    payments. `counts` is global/unfiltered; `items` honours the filters.
    This endpoint never initiates, retries or mutates a payment.
    """
    if source is not None and source not in ("mpesa", "zetupay"):
        raise HTTPException(
            status_code=422, detail="source must be one of mpesa, zetupay")
    statuses = _validated_choices(status, _PAYMENT_STATUSES, "payment status")

    normalized = _payment_union()
    conditions = []
    if source:
        conditions.append(normalized.c.source == source)
    if statuses:
        conditions.append(normalized.c.status.in_(statuses))
    if purpose:
        conditions.append(normalized.c.purpose == purpose)
    if user_id:
        conditions.append(normalized.c.user_id == user_id)
    if deal_id:
        conditions.append(normalized.c.deal_id == deal_id)
    if search and search.strip():
        conditions.append(normalized.c.reference.ilike(f"%{search.strip()}%"))

    total = int((await db.execute(
        select(func.count()).select_from(normalized).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(
            normalized.c.id, normalized.c.source, normalized.c.reference,
            normalized.c.user_id, normalized.c.deal_id, normalized.c.purpose,
            normalized.c.amount, normalized.c.status, normalized.c.created_at,
        )
        .where(*conditions)
        .order_by(desc(normalized.c.created_at), desc(normalized.c.id))
        .limit(limit).offset(offset)
    )).all()
    mpesa_counts, zetupay_counts = await _payment_status_counts(db)

    return {
        "items": [
            {
                "id": row.id,
                "source": row.source,
                "reference": row.reference,
                "user_id": row.user_id,
                "deal_id": row.deal_id,
                "purpose": row.purpose,
                "amount": _money(row.amount),
                "status": _status(row.status),
                "created_at": _iso(row.created_at),
            }
            for row in rows
        ],
        "total": total,
        "limit": limit,
        "offset": offset,
        "counts": {"mpesa": mpesa_counts, "zetupay": zetupay_counts},
        "generated_at": _now_iso(),
    }


# ── Financial integrity ───────────────────────────────────────────────────────

@router.get("/finance-integrity")
async def finance_integrity(
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
    db: AsyncSession = Depends(get_db),
):
    """Read-only financial diagnostics from canonical ledger/deal records.

    The two release checks are complete-table counts with a bounded sample
    of at most 20 rows. `sample_scope` says so explicitly; the sample is
    never presented as exhaustive.
    """
    from api.core.ledger import ledger as _ledger

    trial = await _ledger.trial_balance(db)
    released_commission = money_decimal((await db.execute(
        select(func.coalesce(func.sum(Deal.commission), 0))
        .where(Deal.status == DealStatus.released)
    )).scalar() or 0)
    revenue_credits = await _ledger_account_total(
        db, LedgerAccount.broka_revenue, LedgerDirection.credit)
    escrow_credits = await _ledger_account_total(
        db, LedgerAccount.escrow_holding, LedgerDirection.credit)
    escrow_debits = await _ledger_account_total(
        db, LedgerAccount.escrow_holding, LedgerDirection.debit)
    refund_credits = await _ledger_account_total(
        db, LedgerAccount.refund_payable, LedgerDirection.credit)
    refund_debits = await _ledger_account_total(
        db, LedgerAccount.refund_payable, LedgerDirection.debit)

    missing_release = ~exists().where(
        LedgerEntry.deal_id == Deal.id,
        LedgerEntry.account == LedgerAccount.escrow_holding,
        LedgerEntry.direction == LedgerDirection.debit,
    )
    missing_release_where = and_(Deal.status == DealStatus.released, missing_release)
    missing_release_count = int((await db.execute(
        select(func.count(Deal.id)).where(missing_release_where)
    )).scalar() or 0)
    missing_release_sample = (await db.execute(
        select(Deal.id, Deal.commission, Deal.released_at)
        .where(missing_release_where)
        .order_by(desc(func.coalesce(Deal.released_at, Deal.created_at)), desc(Deal.id))
        .limit(20)
    )).all()

    missing_revenue = ~exists().where(
        LedgerEntry.deal_id == Deal.id,
        LedgerEntry.account == LedgerAccount.broka_revenue,
        LedgerEntry.direction == LedgerDirection.credit,
    )
    missing_revenue_where = and_(
        Deal.status == DealStatus.released,
        Deal.commission > 0,
        missing_revenue,
    )
    missing_revenue_count = int((await db.execute(
        select(func.count(Deal.id)).where(missing_revenue_where)
    )).scalar() or 0)
    missing_revenue_sample = (await db.execute(
        select(Deal.id, Deal.commission, Deal.released_at)
        .where(missing_revenue_where)
        .order_by(desc(func.coalesce(Deal.released_at, Deal.created_at)), desc(Deal.id))
        .limit(20)
    )).all()

    manual_refund_condition = _awaiting_manual_refund_condition()
    manual_refund_count = int((await db.execute(
        select(func.count(Deal.id)).where(manual_refund_condition)
    )).scalar() or 0)
    manual_refund_sample = (await db.execute(
        select(Deal.id, Deal.agreed_price, Deal.refund_outcome, Deal.refund_requested_at)
        .where(manual_refund_condition)
        .order_by(desc(Deal.refund_requested_at), desc(Deal.id))
        .limit(20)
    )).all()

    mpesa_counts, zetupay_counts = await _payment_status_counts(db)
    econfirm_rows = (await db.execute(
        select(ExternalEscrow.status, func.count(ExternalEscrow.id))
        .group_by(ExternalEscrow.status)
    )).all()
    econfirm_counts = _count_map(
        econfirm_rows,
        (
            EConfirmEscrowStatus.CREATING, EConfirmEscrowStatus.PENDING,
            EConfirmEscrowStatus.FUNDED, EConfirmEscrowStatus.RELEASE_PENDING,
            EConfirmEscrowStatus.COMPLETED, EConfirmEscrowStatus.PAYOUT_FAILED,
            EConfirmEscrowStatus.UNKNOWN,
        ),
    )

    return {
        "generated_at": _now_iso(),
        "definitions": {
            "ledger": (
                "Whole-table ledger totals and per-deal escrow balances from the "
                "canonical EscrowLedger.trial_balance(). A globally balanced ledger "
                "does not prove every deal's escrow balance is correct."
            ),
            "commission.released_deals_kes": (
                "Sum of Deal.commission for deals with status=released; recognized "
                "revenue, not reconciled bank cash."
            ),
            "commission.ledger_revenue_credits_kes": (
                "All BROKA_REVENUE credits in the ledger, all time."
            ),
            "commission.gap_kes": (
                "released_deals_kes - ledger_revenue_credits_kes; a positive gap "
                "means recognized commission is missing from ledger revenue."
            ),
            "release_checks": (
                "Complete counts with a bounded sample of at most 20. A released "
                "deal needs an ESCROW_HOLDING debit; commission above zero also "
                "needs a BROKA_REVENUE credit."
            ),
            "escrow_held_kes": "ESCROW_HOLDING credits minus debits, all time.",
            "refund_payable_kes": "REFUND_PAYABLE credits minus debits, all time.",
            "awaiting_manual_refund": (
                "Disputed E-Confirm deals whose refund was approved "
                "(seller_accepted/seller_silent) and not yet marked refunded."
            ),
            "payments": (
                "Normalized Daraja and ZetuPay payment intents; callbacks and "
                "ZetuPay transaction receipts are excluded to avoid double counting."
            ),
            "econfirm": "ExternalEscrow rows by internal provider status.",
        },
        "ledger": {
            "total_credits_kes": _money(trial["total_credits_kes"]),
            "total_debits_kes": _money(trial["total_debits_kes"]),
            "balanced": bool(trial["balanced"]),
            "discrepancy_kes": _money(trial["discrepancy_kes"]),
            "negative_escrow_deals": [
                {
                    "deal_id": row["deal_id"],
                    "escrow_balance_kes": _money(row["escrow_balance_kes"]),
                }
                for row in trial["negative_escrow_deals"]
            ],
            "escrow_integrity_ok": bool(trial["escrow_integrity_ok"]),
        },
        "commission": {
            "released_deals_kes": _money(released_commission),
            "ledger_revenue_credits_kes": _money(revenue_credits),
            "gap_kes": _money(released_commission - revenue_credits),
        },
        "released_deals_without_release_entries": {
            "count": missing_release_count,
            "sample": [
                {
                    "deal_id": row.id,
                    "commission": _money(row.commission),
                    "released_at": _iso(row.released_at),
                }
                for row in missing_release_sample
            ],
            "sample_scope": "bounded first 20 by released_at",
        },
        "released_deals_without_revenue_credit": {
            "count": missing_revenue_count,
            "sample": [
                {
                    "deal_id": row.id,
                    "commission": _money(row.commission),
                    "released_at": _iso(row.released_at),
                }
                for row in missing_revenue_sample
            ],
            "sample_scope": "bounded first 20 by released_at",
        },
        "escrow_held_kes": _money(escrow_credits - escrow_debits),
        "refund_payable_kes": _money(refund_credits - refund_debits),
        "awaiting_manual_refund": {
            "count": manual_refund_count,
            "sample": [
                {
                    "deal_id": row.id,
                    "agreed_price_kes": _money(row.agreed_price),
                    "refund_outcome": row.refund_outcome,
                    "refund_requested_at": _iso(row.refund_requested_at),
                }
                for row in manual_refund_sample
            ],
            "sample_scope": "bounded first 20 by refund_requested_at",
        },
        "payments": {"mpesa": mpesa_counts, "zetupay": zetupay_counts},
        "econfirm": econfirm_counts,
    }


# ── User detail ───────────────────────────────────────────────────────────────

@router.get("/users/{user_id}")
async def admin_user_detail(
    user_id: str,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    """One user's account state, bounded recent activity and real deal stats."""
    user = (await db.execute(
        select(User).where(User.id == user_id)
    )).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    deal_stats = (await db.execute(
        select(
            func.count(case((Deal.seller_id == user_id, 1))),
            func.count(case((Deal.buyer_id == user_id, 1))),
            func.count(case((
                and_(Deal.status == DealStatus.released,
                     or_(Deal.seller_id == user_id, Deal.buyer_id == user_id)), 1))),
            func.count(case((
                and_(Deal.status == DealStatus.refunded,
                     or_(Deal.seller_id == user_id, Deal.buyer_id == user_id)), 1))),
        )
    )).one()
    disputed_deals = int((await db.execute(
        select(func.count(func.distinct(Deal.id))).where(
            or_(Deal.seller_id == user_id, Deal.buyer_id == user_id),
            or_(
                Deal.status == DealStatus.disputed,
                exists().where(DisputeCase.deal_id == Deal.id),
            ),
        )
    )).scalar() or 0)
    open_fraud = int((await db.execute(
        select(func.count(FraudEvent.id)).where(
            FraudEvent.user_id == user_id,
            or_(FraudEvent.resolved.is_(None), FraudEvent.resolved == False),  # noqa: E712
        )
    )).scalar() or 0)

    recent_deals = (await db.execute(
        select(Deal).where(
            or_(Deal.seller_id == user_id, Deal.buyer_id == user_id)
        ).order_by(desc(Deal.created_at), desc(Deal.id)).limit(10)
    )).scalars().all()
    fraud_events = (await db.execute(
        select(FraudEvent).where(FraudEvent.user_id == user_id)
        .order_by(desc(FraudEvent.created_at), desc(FraudEvent.id)).limit(50)
    )).scalars().all()
    recent_audit = (await db.execute(
        select(AuditLog).where(or_(
            and_(AuditLog.resource_type == "user", AuditLog.resource_id == user_id),
            AuditLog.actor_id == user_id,
        )).order_by(desc(AuditLog.created_at), desc(AuditLog.id)).limit(20)
    )).scalars().all()

    return {
        "user": {
            "id": user.id,
            "name": user.name,
            "nickname": user.nickname,
            "phone": user.phone,
            "phone_verified": bool(user.phone_verified),
            "email": user.email,
            "email_verified": bool(user.email_verified),
            "is_verified": bool(user.is_verified),
            "verify_tier": user.verify_tier,
            "verify_expires_at": _iso(user.verify_expires_at),
            "account_type": _status(user.account_type),
            "seller_tier": _status(user.seller_tier),
            "is_admin": bool(user.is_admin),
            "is_premium": bool(user.is_premium),
            "trust_score": user.trust_score if user.trust_score is not None else 100,
            "trust_band": trust_band(
                user.trust_score if user.trust_score is not None else 100),
            "is_flagged": bool(user.is_flagged),
            "rating": user.rating,
            "completed_deals": int(user.completed_deals or 0),
            "last_seen": _iso(user.last_seen),
            "created_at": _iso(user.created_at),
            "business_name": user.business_name,
            "business_category": user.business_category,
            "business_display_name": user.business_display_name,
        },
        "stats": {
            "deals_as_seller": int(deal_stats[0] or 0),
            "deals_as_buyer": int(deal_stats[1] or 0),
            "released_deals": int(deal_stats[2] or 0),
            "refunded_deals": int(deal_stats[3] or 0),
            "disputed_deals": disputed_deals,
            "open_fraud_events": open_fraud,
        },
        "recent_deals": [_deal_item(deal) for deal in recent_deals],
        "fraud_events": [
            {
                "id": event.id,
                "reason": event.reason,
                "triggered_by": event.triggered_by,
                "trust_score_at_flag": event.trust_score_at_flag,
                "reviewed_by_admin": bool(event.reviewed_by_admin),
                "resolved": bool(event.resolved),
                "created_at": _iso(event.created_at),
            }
            for event in fraud_events
        ],
        "recent_audit": [_audit_item(row) for row in recent_audit],
        "generated_at": _now_iso(),
    }


# ── Fraud-event resolution ────────────────────────────────────────────────────

@router.post("/fraud-events/{event_id}/resolve")
async def resolve_fraud_event(
    event_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    """Resolve one fraud event once; repeat calls report changed=false."""
    event = (await db.execute(
        select(FraudEvent).where(FraudEvent.id == event_id).with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if event is None:
        raise HTTPException(status_code=404, detail="Fraud event not found")

    before = {
        "resolved": bool(event.resolved),
        "reviewed_by_admin": bool(event.reviewed_by_admin),
    }
    if before["resolved"] and before["reviewed_by_admin"]:
        return {
            "id": event.id,
            "resolved": True,
            "changed": False,
            "reviewed_by_admin": True,
        }

    event.resolved = True
    event.reviewed_by_admin = True
    after = {"resolved": True, "reviewed_by_admin": True}
    await record_audit(
        db, admin.id, "fraud_event_resolved", "fraud_event", event.id,
        detail=json.dumps({
            "before": before,
            "after": after,
            "request_id": request_id_var.get("-"),
            "reason": (body.reason if body else None),
        }),
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {
        "id": event.id,
        "resolved": True,
        "changed": True,
        "reviewed_by_admin": True,
    }


# ── Zeno activity ─────────────────────────────────────────────────────────────

@router.get("/zeno/activity")
async def zeno_activity(
    window_hours: int = Query(24, ge=1, le=720),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Durable Zeno/negotiation activity, plus honestly-labelled local counters.

    `via_ai` marks a human message sent through the AI broker; it does not
    prove a model composed the reply. `is_agent_initiated` marks a thread
    opened on the buyer's behalf by the Buying Agent. No provider usage,
    token, latency, cost or speech outcome is estimated because those facts
    are not stored.
    """
    from api.core.ai_cost import AISavings
    from api.core.observability import get_event_metrics

    now = datetime.utcnow()
    width = timedelta(hours=window_hours)
    current_start = now - width
    previous_start = current_start - width

    async def count(model, *where):
        query = select(func.count()).select_from(model)
        if where:
            query = query.where(*where)
        return int((await db.execute(query)).scalar() or 0)

    zeno_actions = (await db.execute(
        select(AuditLog.action, func.count(AuditLog.id))
        .where(AuditLog.actor_id == "zeno")
        .group_by(AuditLog.action)
    )).all()
    last_zeno_audit = (await db.execute(
        select(func.max(AuditLog.created_at)).where(AuditLog.actor_id == "zeno")
    )).scalar()
    event_counts = get_event_metrics()

    return {
        "generated_at": _iso(now),
        "window_hours": window_hours,
        "durable": {
            "source": (
                "negotiation_messages (role, via_ai, is_agent_initiated, created_at) "
                "and audit_logs (actor_id='zeno'); windows are half-open UTC "
                "[generated_at-window_hours, generated_at)"
            ),
            "messages_total": await count(NegotiationMessage),
            "ai_relayed_total": await count(
                NegotiationMessage, NegotiationMessage.via_ai == True),  # noqa: E712
            "agent_initiated_total": await count(
                NegotiationMessage, NegotiationMessage.is_agent_initiated == True),  # noqa: E712
            "messages_current": await count(
                NegotiationMessage,
                NegotiationMessage.created_at >= current_start,
                NegotiationMessage.created_at < now),
            "messages_previous": await count(
                NegotiationMessage,
                NegotiationMessage.created_at >= previous_start,
                NegotiationMessage.created_at < current_start),
            "ai_relayed_current": await count(
                NegotiationMessage, NegotiationMessage.via_ai == True,  # noqa: E712
                NegotiationMessage.created_at >= current_start,
                NegotiationMessage.created_at < now),
            "ai_relayed_previous": await count(
                NegotiationMessage, NegotiationMessage.via_ai == True,  # noqa: E712
                NegotiationMessage.created_at >= previous_start,
                NegotiationMessage.created_at < current_start),
            "zeno_audit_events_total": await count(
                AuditLog, AuditLog.actor_id == "zeno"),
            "zeno_audit_events_current": await count(
                AuditLog, AuditLog.actor_id == "zeno",
                AuditLog.created_at >= current_start, AuditLog.created_at < now),
            "zeno_last_audit_at": _iso(last_zeno_audit),
            "zeno_audit_actions": {
                action: int(count or 0) for action, count in zeno_actions
            },
        },
        "process_local": {
            "ai_savings": AISavings.snapshot(),
            "event_metrics_total": sum(event_counts.values()),
            "event_metrics_by_type": event_counts,
            "scope": "process_local",
            "durability": "none",
            "note": (
                "These counters live in this worker process and reset on restart. "
                "They are not historical totals."
            ),
        },
        "not_instrumented": [
            {
                "metric": "ai_provider_usage",
                "reason": "No per-call provider/model selection is persisted.",
            },
            {
                "metric": "ai_tokens",
                "reason": "Prompt and completion token counts are not stored.",
            },
            {
                "metric": "ai_model_latency",
                "reason": "Model latency is not persisted, only request latency logs.",
            },
            {
                "metric": "ai_cost",
                "reason": "No durable token or price record exists to compute cost.",
            },
            {
                "metric": "ai_reply_provenance",
                "reason": (
                    "NegotiationMessage records via_ai relay and Buying-Agent "
                    "initiation, not whether a broker message was model-generated."
                ),
            },
            {
                "metric": "speech_to_text_outcomes",
                "reason": "STT request outcomes are not stored durably.",
            },
            {
                "metric": "text_to_speech_outcomes",
                "reason": "TTS request outcomes are not stored durably.",
            },
        ],
    }


@router.post("/users/{user_id}/promote-admin")
async def promote_to_admin(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_permission(Permission.PROMOTE_ADMIN)),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_admin = True
    await record_audit(
        db, admin.id, "admin_promoted", "user", user_id,
        detail=(body.reason if body else None) or "promoted by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id}


@router.post("/users/{user_id}/flag")
async def flag_user(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    # Idempotent: clicking flag twice used to subtract another 30 points.
    if not user.is_flagged:
        user.is_flagged = True
        user.trust_score = max(0, (user.trust_score or 100) - 30)
    await record_audit(
        db, admin.id, "user_flagged", "user", user_id,
        detail=(body.reason if body else None) or "flagged by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": user.trust_score}


@router.post("/users/{user_id}/unflag")
async def unflag_user(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(select(User).where(User.id == user_id))
    user = r.scalar_one_or_none()
    if not user:
        raise HTTPException(status_code=404, detail="User not found")
    user.is_flagged = False
    # Recompute trust score
    score = await compute_trust_score(user_id, db)
    await record_audit(
        db, admin.id, "user_unflagged", "user", user_id,
        detail=(body.reason if body else None) or "unflagged by administrator",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"ok": True, "user_id": user_id, "trust_score": score}


@router.post("/users/{user_id}/recompute-trust")
async def recompute_trust(
    user_id: str,
    request: Request,
    body: Optional[AdminActionIn] = None,
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    score = await compute_trust_score(user_id, db)
    await record_audit(
        db, admin.id, "user_trust_recomputed", "user", user_id,
        detail=(body.reason if body else None) or f"trust recomputed to {score}",
        ip_address=client_ip_or_none(request),
    )
    await db.commit()
    return {"user_id": user_id, "trust_score": score, "trust_band": trust_band(score)}


@router.get("/ai-savings")
async def ai_savings(admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY))):
    """How many relay-classification calls are being avoided.

    Process-local counters, so they reset on deploy and are per-worker -
    an observability aid for tuning the pre-filter word list, not billing.
    Compare `avoided_fraction` against your provider dashboard.
    """
    from api.core.ai_cost import AISavings
    return AISavings.snapshot()


@router.get("/ledger-integrity")
async def ledger_integrity(
    db: AsyncSession = Depends(get_db),
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
):
    """Escrow ledger health.

    Added in the escrow audit (2026-09-14): EscrowLedger.trial_balance()
    already existed but NOTHING ever called it - the double-entry ledger's
    only integrity check was unreachable dead code, which is how a bug that
    left escrow_holding short by 97% of the goods price on every legacy
    deal went unnoticed.

    Read `escrow_integrity_ok`, not `balanced`. `balanced` compares total
    debits to total credits across the whole table, and every ledger helper
    writes matched pairs, so it is true by construction however wrong the
    amounts are. `negative_escrow_deals` is the real assertion: a deal
    whose escrow account has had more money leave it than ever entered it.
    """
    from api.core.ledger import ledger as _ledger
    report = await _ledger.trial_balance(db)
    if not report["escrow_integrity_ok"]:
        _log.error(
            "[ledger] INTEGRITY_FAILURE %d deal(s) with negative escrow balance",
            len(report["negative_escrow_deals"]),
        )
    return report


@router.get("/diagnostics/econfirm")
async def econfirm_diagnostics(
    amount: float = Query(1000, gt=0, le=1_000_000),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """Is E-Confirm reachable with this deployment's key? Asks for the fee
    on `amount` - a read that moves no money - and returns what came back,
    including E-Confirm's own error, so a failed payment can be told apart
    from a wrong key, a wrong base URL or E-Confirm being down."""
    from api.core.config import settings
    from api.core.econfirm_client import EConfirmAPIError, EConfirmClient, EConfirmError
    out = {
        "configured": bool(settings.econfirm_api_key),
        "base_url": settings.econfirm_base_url,
        "call": f"GET /fee-quote?amount={int(round(amount))}",
    }
    try:
        out["response"] = await EConfirmClient().fee_quote(amount)
        out["ok"] = True
    except EConfirmAPIError as exc:
        out.update(ok=False, error="rejected", status_code=exc.status_code,
                   message=exc.message, provider_detail=exc.provider_detail)
    except EConfirmError as exc:
        out.update(ok=False, error=type(exc).__name__, message=str(exc))
    return out


@router.post("/deals/{deal_id}/econfirm-refunded")
async def econfirm_refunded(
    deal_id: str,
    request: Request,
    admin: User = Depends(require_permission(Permission.OVERRIDE_ESCROW)),
    db: AsyncSession = Depends(get_db),
):
    """Close an approved refund that was returned by hand through E-Confirm.

    BROKA has no refund call on E-Confirm's API, so an approved refund on an
    E-Confirm deal freezes it and raises an `econfirm_refund_required`
    reconciliation alert (api/domains/escrow/protection.py). Once the money
    is back with the buyer, this marks the deal refunded and records it in
    the ledger.
    """
    from api.core.client_ip import client_ip_or_none
    from api.domains.escrow.protection import mark_econfirm_refunded
    return await mark_econfirm_refunded(db, deal_id, admin.id, request_ip=client_ip_or_none(request))


@router.get("/audit-logs")
async def get_audit_logs(
    response: Response,
    resource_type: Optional[str] = None,
    resource_id: Optional[str] = None,
    actor_id: Optional[str] = None,
    limit: int = Query(100, ge=1, le=500),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
    db: AsyncSession = Depends(get_db),
):
    """Filtered audit trail. X-Total-Count is the filtered total."""
    conditions = []
    if resource_type:
        conditions.append(AuditLog.resource_type == resource_type)
    if resource_id:
        conditions.append(AuditLog.resource_id == resource_id)
    if actor_id:
        conditions.append(AuditLog.actor_id == actor_id)

    total = int((await db.execute(
        select(func.count(AuditLog.id)).where(*conditions)
    )).scalar() or 0)
    rows = (await db.execute(
        select(AuditLog).where(*conditions)
        .order_by(desc(AuditLog.created_at), desc(AuditLog.id))
        .limit(limit).offset(offset)
    )).scalars().all()
    response.headers["X-Total-Count"] = str(total)
    return [_audit_item(row, include_ip=True) for row in rows]


@router.get("/fraud-events")
async def get_fraud_events(
    resolved: Optional[bool] = None,
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.MANAGE_USERS)),
    db: AsyncSession = Depends(get_db),
):
    q = (select(FraudEvent)
         .order_by(desc(FraudEvent.created_at), desc(FraudEvent.id))
         .limit(limit).offset(offset))
    if resolved is not None:
        q = q.where(FraudEvent.resolved == resolved)
    r = await db.execute(q)
    events = r.scalars().all()
    return [
        {
            "id": e.id, "user_id": e.user_id, "reason": e.reason,
            "triggered_by": e.triggered_by, "trust_score_at_flag": e.trust_score_at_flag,
            "reviewed_by_admin": bool(e.reviewed_by_admin),
            "resolved": bool(e.resolved),
            "created_at": _iso(e.created_at),
        }
        for e in events
    ]


@router.get("/transactions")
async def get_transactions(
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
    admin: User = Depends(require_permission(Permission.VIEW_TRANSACTIONS)),
    db: AsyncSession = Depends(get_db),
):
    r = await db.execute(
        select(MpesaTransaction).order_by(
            desc(MpesaTransaction.created_at), desc(MpesaTransaction.id)
        ).limit(limit).offset(offset)
    )
    txns = r.scalars().all()
    return [
        {
            "id": t.id, "deal_id": t.deal_id, "buyer_id": t.buyer_id,
            "phone": t.phone, "amount": _money(t.amount),
            "mpesa_receipt": t.mpesa_receipt,
            "status": _status(t.status),
            "created_at": _iso(t.created_at),
        }
        for t in txns
    ]


# ── Platform Architecture Endpoints (v6.0) ────────────────────────────────────

@router.get("/workflow-versions")
async def get_workflow_versions(
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """
    Return all registered workflow versions and their rule sets.
    Useful for understanding which rules apply to in-flight deals.
    """
    from api.core.workflow import spec_summary, CURRENT_VERSION
    return {
        "current_version": CURRENT_VERSION,
        "versions": spec_summary(),
    }


@router.get("/event-metrics")
async def get_event_metrics(
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """
    Return in-process event counts since last restart.
    For persistent metrics, configure Prometheus + Grafana.
    """
    from api.core.observability import get_event_metrics
    from api.core.event_catalog import handler_count
    counts = get_event_metrics()
    total  = sum(counts.values())
    return {
        "total_events":      total,
        "by_type":           counts,
        "registered_handlers": handler_count(),
    }


@router.get("/event-catalog")
async def get_event_catalog(
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """
    Return the full Broka Event Catalog — every event type and its domain.
    Useful for documentation, consumer discovery, and schema governance.
    """
    from api.core.event_catalog import EventType
    catalog = {}
    for et in EventType:
        domain = et.value.split(".")[0]
        catalog.setdefault(domain, []).append(et.value)
    return {
        "total_event_types": len(EventType),
        "by_domain": catalog,
    }


@router.post("/media/backfill")
async def run_media_backfill(
    rows_per_kind: int = Query(50, ge=1, le=500),
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """Run one media backfill pass now (the 5-minute sweep runs smaller
    ones on its own) and report what is left."""
    from api.domains.media.backfill import pending_counts, run_backfill_pass
    done = await run_backfill_pass(rows_per_kind=rows_per_kind, time_budget=60.0)
    return {"converted": done, "remaining": await pending_counts()}


@router.get("/diagnostics/client-ip")
async def client_ip_diagnostics(
    request: Request,
    admin: User = Depends(require_permission(Permission.ADMIN_SUMMARY)),
):
    """What this deployment believes the caller's address is, and why.

    Every per-IP rate limit depends on it (api/core/client_ip.py). Call it
    from a phone on mobile data: `resolved` should be that phone's public
    address, and `source` should not be "peer" behind a proxy - a peer
    address there is the proxy, shared by every user."""
    from api.core.client_ip import resolve
    from api.core.config import settings

    ip, source = resolve(request)
    return {
        "resolved": ip,
        "source": source,
        "peer": request.client.host if request.client else None,
        "headers": {
            name: request.headers.get(name)
            for name in ("cf-connecting-ip", "true-client-ip", "x-forwarded-for", "x-real-ip")
        },
        "config": {
            "client_ip_header": settings.client_ip_header or None,
            "trusted_proxy_hops": settings.trusted_proxy_hops,
            "storefront_key_set": bool(settings.storefront_api_key),
        },
    }
