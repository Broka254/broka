"""Production cost tracking — the one place usage and money are combined.

WHAT COUNTS AS USAGE
====================
Only an operation the provider actually performed. `record_usage_event` is
called *after* an accepted send/generation/charge - never for an attempt
that was refused before reaching the provider. Failures are recorded when a
request may still have been billed (a 5xx or a timeout after submission),
with status failed and, where no rate is known, a NULL cost. A failed
operation therefore never looks free unless its cost basis says it is.

THE THREE COST LAYERS, KEPT APART
=================================
  actual      invoice-backed or provider-reported money
  estimated   quantity x an effective-dated unit price (or token pricing)
  manual      a figure a person entered, with an audit trail
An effective cost picks ONE of them by precedence - adjusted over manual,
manual over invoice, invoice over estimate, estimate over unpriced. It never
adds an invoice to an estimate for the same period, which is the double-count
this module exists to prevent. All three remain visible for comparison.

PRICES ARE SNAPSHOTTED
======================
An event stores the unit price in force when it happened. Changing today's
price cannot rewrite last month's report; a new price closes the old row
(`effective_until`) instead of editing it.

NOTHING IS INVENTED
===================
No row means no data. An unpriced event is NULL, reported as "unpriced" with
the real quantity beside it. It is never coerced to zero. A free service is
a known zero with basis `free_tier`, which is a different claim entirely.
"""
from __future__ import annotations

import logging
import uuid
from collections import deque
from datetime import date, datetime, timedelta
from typing import Any, Iterable, Optional

from sqlalchemy import case, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.timeutil import to_naive_utc
from api.models.service_cost import (
    CostBasis,
    CostConfidence,
    CostSource,
    PricingModel,
    ServiceCatalog,
    ServiceCostAdjustment,
    ServiceCostEntry,
    ServicePricing,
    ServiceUsageDaily,
    ServiceUsageEvent,
    UsageStatus,
)

logger = logging.getLogger(__name__)

#: Need at least this many events to make an aggregate meaningful? No -
#: even one provider charge must be priced. Kept as a named constant only so
#: callers can refer to the intent; the report does not drop small samples.
MIN_REPORTABLE_EVENTS = 1

#: In-process retry buffer for a usage write that could not reach the
#: database. Bounded so a database outage cannot grow memory without limit.
#: NOT a durable queue: a crash loses at most these events, and each loss is
#: logged with the service key and operation reference. Durable enough for
#: accounting that must never fail a user operation; a database that is down
#: cannot durably store its own recovery log either.
_PENDING: deque[dict[str, Any]] = deque(maxlen=2000)
_FLUSH_BATCH = 100

#: Throttles for the background jobs, so a 5-minute sweep does not run a
#: full aggregation pass every tick on every replica. Multi-replica safety
#: comes from the rollup's unique key, not from this clock.
_LAST_ROLLUP_AT: Optional[datetime] = None
_LAST_INFRA_AT: Optional[datetime] = None
_ROLLUP_INTERVAL = timedelta(hours=6)
_INFRA_INTERVAL = timedelta(hours=1)

class ConflictError(Exception):
    """A request would duplicate or rewrite money history."""


class ValidationError(ValueError):
    """A caller-supplied period, currency or amount is not acceptable."""


# ── Small shared helpers ─────────────────────────────────────────────────────

def utcnow() -> datetime:
    return datetime.utcnow()


def period_start_of(value: datetime) -> datetime:
    """First instant of the value's UTC month (naive UTC, like every column)."""
    value = to_naive_utc(value)
    return value.replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def month_bounds(value: datetime) -> tuple[datetime, datetime]:
    start = period_start_of(value)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1)
    else:
        end = start.replace(month=start.month + 1)
    return start, end


def iso(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    if value.tzinfo is not None:
        value = to_naive_utc(value)
    return value.isoformat() + "Z"


def validate_currency(value: str) -> str:
    currency = (value or "").strip().upper()
    if len(currency) != 3 or not currency.isalpha():
        raise ValidationError("currency must be a three-letter ISO code, e.g. KES")
    return currency


def validate_period(start: datetime, end: datetime) -> tuple[datetime, datetime]:
    """Half-open [start, end). Rejects empty, inverted and absurd periods.

    The 400-day cap is not a business rule; it keeps one malformed request
    from asking a report query to scan years of rows.
    """
    start = to_naive_utc(start)
    end = to_naive_utc(end)
    if start >= end:
        raise ValidationError("period_start must be before period_end")
    if end - start > timedelta(days=400):
        raise ValidationError("reporting period may not exceed 400 days")
    return start, end


def validate_amount(value: Optional[int], field: str) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"{field} must be an integer in minor currency units")
    if value < 0:
        raise ValidationError(f"{field} may not be negative")
    if value > 10**15:
        raise ValidationError(f"{field} is implausibly large")
    return value


def report_range(
    from_raw: Optional[str], to_raw: Optional[str], *, default_days: int = 30
) -> tuple[datetime, datetime]:
    """The [from, to) window every report and usage filter shares."""
    from api.core.timeutil import parse_iso_to_naive_utc

    now = utcnow()
    try:
        end = parse_iso_to_naive_utc(to_raw) if to_raw else now
        start = (
            parse_iso_to_naive_utc(from_raw)
            if from_raw
            else end - timedelta(days=default_days)
        )
    except ValueError as exc:
        raise ValidationError(f"invalid date: {exc}") from exc
    return validate_period(start, end)


async def _catalog_by_key(db: AsyncSession) -> dict[str, ServiceCatalog]:
    rows = (await db.execute(select(ServiceCatalog))).scalars().all()
    return {row.service_key: row for row in rows}


async def _service(db: AsyncSession, service_key: str) -> ServiceCatalog:
    # Deliberately not cached across calls: an ORM instance is bound to the
    # session that loaded it, and committing expires its attributes. Caching
    # one would hand a later request a detached, expired row (and leak one
    # session's identity map into another's). One indexed lookup per event is
    # cheap next to the provider call that preceded it.
    row = (
        await db.execute(
            select(ServiceCatalog).where(ServiceCatalog.service_key == service_key)
        )
    ).scalar_one_or_none()
    if row is None:
        from api.domains.service_costs.catalog import ensure_catalog

        # commit=False: this can run inside a payment transaction, and
        # seeding reference data must never commit someone else's money.
        await ensure_catalog(db, commit=False)
        row = (
            await db.execute(
                select(ServiceCatalog).where(
                    ServiceCatalog.service_key == service_key
                )
            )
        ).scalar_one_or_none()
    if row is None:
        raise ValidationError(f"unknown service {service_key!r}")
    return row


async def resolve_pricing(
    db: AsyncSession, service_id: int, at: datetime
) -> Optional[ServicePricing]:
    """The price in force at `at`, or None when none was ever entered."""
    at = to_naive_utc(at)
    return (
        await db.execute(
            select(ServicePricing)
            .where(
                ServicePricing.service_id == service_id,
                ServicePricing.effective_from <= at,
                or_(
                    ServicePricing.effective_until.is_(None),
                    ServicePricing.effective_until > at,
                ),
            )
            .order_by(ServicePricing.effective_from.desc())
            .limit(1)
        )
    ).scalar_one_or_none()


async def resolve_unit_price(
    db: AsyncSession, service_id: int, at: datetime
) -> Optional[tuple[int, str, str, str]]:
    """(unit_price_minor, currency, source, confidence) at `at`, or None."""
    price = await resolve_pricing(db, service_id, at)
    if price is None:
        return None
    return (
        int(price.unit_price_minor),
        price.currency,
        price.pricing_source,
        price.cost_confidence,
    )


# ── Recording ───────────────────────────────────────────────────────────────

async def record_usage_event(
    db: AsyncSession,
    *,
    service_key: str,
    operation_type: str,
    status: str = UsageStatus.SUCCESS,
    quantity: Optional[int] = None,
    input_tokens: Optional[int] = None,
    output_tokens: Optional[int] = None,
    provider_reference: Optional[str] = None,
    operation_id: Optional[str] = None,
    unit_price_minor: Optional[int] = None,
    estimated_cost_minor: Optional[int] = None,
    cost_basis: Optional[str] = None,
    cost_confidence: Optional[str] = None,
    currency: Optional[str] = None,
    metadata: Optional[dict] = None,
    occurred_at: Optional[datetime] = None,
    apply_pricing: bool = True,
) -> Optional[ServiceUsageEvent]:
    """Append one provider operation to the hot session.

    Returns None when the operation id was already recorded (idempotent) or
    when there was no provider operation to record. Raises only for a real
    database failure - callers that must never fail a user operation use
    `record_usage`, which buffers and logs instead.
    """
    if status not in UsageStatus.ALL:
        raise ValidationError(f"unknown usage status {status!r}")

    service = await _service(db, service_key)
    at = to_naive_utc(occurred_at) if occurred_at else utcnow()

    # A provider operation that never happened is not usage. Callers are
    # expected to record failures only when the request reached the provider.
    if quantity is not None and quantity < 0:
        raise ValidationError("quantity may not be negative")

    explicit_cost = estimated_cost_minor
    if explicit_cost is not None:
        validate_amount(explicit_cost, "estimated_cost_minor")
    if unit_price_minor is not None:
        validate_amount(unit_price_minor, "unit_price_minor")

    price_source: Optional[str] = None
    price_confidence: Optional[str] = None
    if explicit_cost is None and apply_pricing:
        price = await resolve_pricing(db, service.id, at)
        if price is not None:
            unit_price_minor = int(price.unit_price_minor)
            currency = price.currency
            price_source = price.pricing_source
            price_confidence = price.cost_confidence
            if quantity is not None:
                explicit_cost = int(quantity) * int(price.unit_price_minor)
                cost_basis = cost_basis or CostBasis.CONFIGURED_RATE
                cost_confidence = cost_confidence or price.cost_confidence
            elif int(price.unit_price_minor) == 0:
                # A flat free service: the request itself is the unit.
                explicit_cost = 0
                cost_basis = cost_basis or CostBasis.FREE_TIER
                cost_confidence = cost_confidence or CostConfidence.EXACT

    if explicit_cost is None:
        if service.pricing_model == PricingModel.FREE:
            explicit_cost = 0
            cost_basis = cost_basis or CostBasis.FREE_TIER
            cost_confidence = cost_confidence or CostConfidence.EXACT
            currency = currency or service.billing_currency
        else:
            # Unpriced. Keep the amount NULL: reporting can then say "we
            # don't know", which is true, instead of "KES 0", which is not.
            cost_basis = cost_basis or CostBasis.UNPRICED
            cost_confidence = cost_confidence or CostConfidence.UNKNOWN

    if explicit_cost is not None and currency is None:
        currency = service.billing_currency
    if explicit_cost == 0 and cost_basis is None:
        cost_basis = CostBasis.FREE_TIER
    if cost_basis is None:
        cost_basis = CostBasis.CONFIGURED_RATE

    meta = dict(metadata or {})
    if price_source:
        meta.setdefault("pricing_source", price_source)
    if price_confidence:
        meta.setdefault("pricing_confidence", price_confidence)

    row = ServiceUsageEvent(
        service_id=service.id,
        operation_id=(operation_id or None),
        provider_reference=(provider_reference or None),
        operation_type=operation_type,
        status=status,
        quantity=quantity,
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        usage_unit=service.usage_unit,
        unit_price_minor=unit_price_minor,
        estimated_cost_minor=explicit_cost,
        currency=currency,
        cost_basis=cost_basis,
        cost_confidence=cost_confidence or CostConfidence.UNKNOWN,
        reporting_period_start=period_start_of(at),
        meta=meta,
        occurred_at=at,
        created_at=utcnow(),
    )

    try:
        # The savepoint is what makes the unique (service, operation) guard
        # safe to hit: the violation rolls back only this insert, leaving the
        # caller's transaction (a payment, a send) intact.
        async with db.begin_nested():
            db.add(row)
            await db.flush()
    except IntegrityError:
        logger.info(
            "[service-costs] duplicate usage ignored service=%s operation=%s",
            service_key, operation_id,
        )
        return None
    return row


def _buffer(event: dict[str, Any]) -> None:
    _PENDING.append(event)


async def record_usage(**kwargs: Any) -> Optional[ServiceUsageEvent]:
    """Best-effort usage recording for call sites with no session.

    A failure here is logged and buffered for the next sweep. It never
    propagates: a provider send that succeeded must not be reported as
    failed because accounting could not reach the database.
    """
    from api.core.config import settings

    if not getattr(settings, "service_usage_enabled", True):
        return None
    try:
        from api.database import AsyncSessionLocal

        async with AsyncSessionLocal() as db:
            row = await record_usage_event(db, **kwargs)
            await db.commit()
            return row
    except Exception as exc:
        logger.warning(
            "[service-costs] usage record failed (buffered) service=%s op=%s: %s",
            kwargs.get("service_key"), kwargs.get("operation_id"), type(exc).__name__,
        )
        _buffer(dict(kwargs))
        return None


async def flush_pending_usage(limit: int = _FLUSH_BATCH) -> int:
    """Retry buffered usage writes. Returns how many landed."""
    from api.database import AsyncSessionLocal

    flushed = 0
    for _ in range(min(limit, len(_PENDING))):
        try:
            event = _PENDING.popleft()
        except IndexError:
            break
        try:
            async with AsyncSessionLocal() as db:
                await record_usage_event(db, **event)
                await db.commit()
            flushed += 1
        except Exception as exc:
            logger.warning(
                "[service-costs] buffered usage still failing service=%s: %s",
                event.get("service_key"), type(exc).__name__,
            )
            _PENDING.append(event)
            break
    return flushed


def pending_usage_count() -> int:
    """Visible to tests and diagnostics; never a billing figure."""
    return len(_PENDING)


def _token_cost(
    provider: str, input_tokens: Optional[int], output_tokens: Optional[int]
) -> tuple[Optional[int], str, str, str]:
    """(amount_minor, currency, basis, confidence) for an LLM call.

    Delegates to cost_ledger.ai_cost_minor so there is exactly one pricing
    implementation. An unpriced provider returns None, not zero: real tokens
    are still recorded on the event.
    """
    from api.core.cost_ledger import ai_cost_minor

    amount, estimated, meta = ai_cost_minor(provider, input_tokens, output_tokens)
    if meta.get("unpriced"):
        return None, "KES", CostBasis.UNPRICED, CostConfidence.UNKNOWN
    if meta.get("free_tier"):
        return 0, "KES", CostBasis.FREE_TIER, CostConfidence.EXACT
    if meta.get("tokens_unknown"):
        return None, "KES", CostBasis.UNPRICED, CostConfidence.UNKNOWN
    return (
        int(amount),
        "KES",
        CostBasis.DERIVED_RATE,
        CostConfidence.ESTIMATED if estimated else CostConfidence.EXACT,
    )


async def record_ai_attempt(
    *,
    provider: str,
    status: str,
    model: Optional[str] = None,
    call_site: str = "",
    input_tokens: Optional[int] = None,
    output_tokens: Optional[int] = None,
    response_data: Optional[dict] = None,
    provider_reference: Optional[str] = None,
    operation_id: Optional[str] = None,
) -> Optional[ServiceUsageEvent]:
    """One model request, successful or billed-after-failure.

    Success is priced from real token counts; a failure keeps whatever the
    provider reported (often nothing) and is marked failed with cost NULL
    unless a rate can be applied. It is never assumed to be free.
    """
    in_tokens = input_tokens
    out_tokens = output_tokens
    if response_data and (in_tokens is None or out_tokens is None):
        try:
            from api.core.cost_ledger import _extract_tokens

            parsed_in, parsed_out = _extract_tokens(provider, response_data)
            in_tokens = in_tokens if in_tokens is not None else parsed_in
            out_tokens = out_tokens if out_tokens is not None else parsed_out
        except Exception:
            pass

    amount: Optional[int] = None
    basis = CostBasis.UNPRICED
    confidence = CostConfidence.UNKNOWN
    if status == UsageStatus.SUCCESS:
        amount, _currency, basis, confidence = _token_cost(
            provider, in_tokens, out_tokens
        )

    metadata = {"model": model, "call_site": call_site or None}
    return await record_usage(
        service_key=f"ai.{provider}",
        operation_type="ai.chat",
        status=status,
        quantity=1,
        input_tokens=in_tokens,
        output_tokens=out_tokens,
        provider_reference=provider_reference,
        operation_id=operation_id or f"ai:{provider}:{uuid.uuid4().hex}",
        estimated_cost_minor=amount,
        cost_basis=basis,
        cost_confidence=confidence,
        currency="KES",
        metadata={k: v for k, v in metadata.items() if v is not None},
    )


# ── Aggregation ─────────────────────────────────────────────────────────────

def _empty_bucket() -> dict[str, int]:
    return {
        "requests": 0,
        "quantity": 0,
        "input_tokens": 0,
        "output_tokens": 0,
        "cost_minor": 0,
        "priced_events": 0,
        "unpriced_events": 0,
    }


def _merge(
    target: dict[tuple[int, str], dict[str, int]],
    service_id: int,
    status: str,
    *,
    requests: int,
    quantity: int,
    input_tokens: int,
    output_tokens: int,
    cost_minor: int,
    priced_events: int,
    unpriced_events: int,
) -> None:
    bucket = target.setdefault((service_id, status), _empty_bucket())
    bucket["requests"] += int(requests or 0)
    bucket["quantity"] += int(quantity or 0)
    bucket["input_tokens"] += int(input_tokens or 0)
    bucket["output_tokens"] += int(output_tokens or 0)
    bucket["cost_minor"] += int(cost_minor or 0)
    bucket["priced_events"] += int(priced_events or 0)
    bucket["unpriced_events"] += int(unpriced_events or 0)


async def _raw_totals(
    db: AsyncSession, start: datetime, end: datetime
) -> dict[tuple[int, str], dict[str, int]]:
    unpriced = func.coalesce(
        func.sum(
            case((ServiceUsageEvent.estimated_cost_minor.is_(None), 1), else_=0)
        ),
        0,
    )
    priced = func.coalesce(
        func.sum(
            case((ServiceUsageEvent.estimated_cost_minor.is_not(None), 1), else_=0)
        ),
        0,
    )
    rows = (
        await db.execute(
            select(
                ServiceUsageEvent.service_id,
                ServiceUsageEvent.status,
                func.count(ServiceUsageEvent.id),
                func.coalesce(func.sum(ServiceUsageEvent.quantity), 0),
                func.coalesce(func.sum(ServiceUsageEvent.input_tokens), 0),
                func.coalesce(func.sum(ServiceUsageEvent.output_tokens), 0),
                func.coalesce(func.sum(ServiceUsageEvent.estimated_cost_minor), 0),
                priced,
                unpriced,
            )
            .where(
                ServiceUsageEvent.occurred_at >= start,
                ServiceUsageEvent.occurred_at < end,
            )
            .group_by(ServiceUsageEvent.service_id, ServiceUsageEvent.status)
        )
    ).all()
    totals: dict[tuple[int, str], dict[str, int]] = {}
    for sid, status, count, qty, tin, tout, cost, priced_n, unpriced_n in rows:
        _merge(
            totals, sid, status,
            requests=count, quantity=qty, input_tokens=tin, output_tokens=tout,
            cost_minor=cost, priced_events=priced_n, unpriced_events=unpriced_n,
        )
    return totals


async def _rolled_totals(
    db: AsyncSession, start: datetime, end: datetime
) -> dict[tuple[int, str], dict[str, int]]:
    rows = (
        await db.execute(
            select(
                ServiceUsageDaily.service_id,
                ServiceUsageDaily.status,
                func.coalesce(func.sum(ServiceUsageDaily.event_count), 0),
                func.coalesce(func.sum(ServiceUsageDaily.quantity), 0),
                func.coalesce(func.sum(ServiceUsageDaily.input_tokens), 0),
                func.coalesce(func.sum(ServiceUsageDaily.output_tokens), 0),
                func.coalesce(func.sum(ServiceUsageDaily.estimated_cost_minor), 0),
                func.coalesce(func.sum(ServiceUsageDaily.unpriced_count), 0),
            )
            .where(
                ServiceUsageDaily.day >= start.date(),
                ServiceUsageDaily.day < end.date(),
            )
            .group_by(ServiceUsageDaily.service_id, ServiceUsageDaily.status)
        )
    ).all()
    totals: dict[tuple[int, str], dict[str, int]] = {}
    for sid, status, count, qty, tin, tout, cost, unpriced_n in rows:
        priced_n = max(0, int(count) - int(unpriced_n))
        _merge(
            totals, sid, status,
            requests=count, quantity=qty, input_tokens=tin, output_tokens=tout,
            cost_minor=cost, priced_events=priced_n, unpriced_events=unpriced_n,
        )
    return totals


async def usage_totals(
    db: AsyncSession, start: datetime, end: datetime
) -> dict[tuple[int, str], dict[str, int]]:
    """Usage in [start, end), from live events plus archived daily rollups.

    Raw events and rollups never overlap: a day is rolled up and its events
    deleted in one transaction, so a sum of both cannot double-count a day.
    """
    totals = await _raw_totals(db, start, end)
    for (sid, status), bucket in (await _rolled_totals(db, start, end)).items():
        target = totals.setdefault((sid, status), _empty_bucket())
        for key, value in bucket.items():
            target[key] += value
    return totals


def _cost_for_service(
    bucket_rows: dict[str, dict[str, int]],
    entries: list[ServiceCostEntry],
    adjustments: list[ServiceCostAdjustment],
) -> dict[str, Any]:
    success = bucket_rows.get(UsageStatus.SUCCESS, _empty_bucket())
    failed = bucket_rows.get(UsageStatus.FAILED, _empty_bucket())
    rejected = bucket_rows.get(UsageStatus.REJECTED, _empty_bucket())
    accepted = bucket_rows.get(UsageStatus.ACCEPTED, _empty_bucket())

    all_buckets = [success, failed, rejected, accepted]
    requests = sum(b["requests"] for b in all_buckets)
    quantity = sum(b["quantity"] for b in all_buckets)
    input_tokens = sum(b["input_tokens"] for b in all_buckets)
    output_tokens = sum(b["output_tokens"] for b in all_buckets)
    priced = sum(b["priced_events"] for b in all_buckets)
    unpriced = sum(b["unpriced_events"] for b in all_buckets)
    known_cost = sum(b["cost_minor"] for b in all_buckets)

    usage_estimate: Optional[int] = known_cost if priced > 0 else None

    def _sum_same_currency(
        pairs: list[tuple[int, str]],
    ) -> tuple[Optional[int], Optional[str]]:
        """Sum only amounts that share a currency.

        Mixing currencies would require an FX conversion and a recorded
        rate; adding 1,000 KES to 20 USD and calling it 1,020 is worse than
        saying "mixed". A mixed set is therefore unpriced at the service
        level and the per-currency entries remain visible.
        """
        currencies = {pair[1] for pair in pairs}
        if not currencies:
            return None, None
        if len(currencies) > 1:
            return None, "MULTI"
        return sum(int(pair[0]) for pair in pairs), currencies.pop()

    actual_pairs = [
        (int(e.actual_cost_minor), e.currency)
        for e in entries if e.actual_cost_minor is not None
    ]
    manual_pairs = [
        (int(e.manually_entered_cost_minor), e.currency)
        for e in entries if e.manually_entered_cost_minor is not None
    ]
    entry_estimate_pairs = [
        (int(e.estimated_cost_minor), e.currency)
        for e in entries if e.estimated_cost_minor is not None
    ]
    actual_cost, actual_currency = _sum_same_currency(actual_pairs)
    manual_cost, manual_currency = _sum_same_currency(manual_pairs)
    entry_estimate, entry_estimate_currency = _sum_same_currency(entry_estimate_pairs)

    # Latest adjustment per exact period window. Two edits in one month are
    # two audit rows, but only the latest is the current figure.
    latest: dict[tuple[Optional[datetime], Optional[datetime]], ServiceCostAdjustment] = {}
    for adj in sorted(adjustments, key=lambda a: (a.created_at, a.id)):
        latest[(adj.period_start, adj.period_end)] = adj
    adjusted_cost, adjusted_currency = _sum_same_currency(
        [(int(a.adjusted_amount_minor), a.currency) for a in latest.values()]
    )

    estimate = entry_estimate if entry_estimate is not None else usage_estimate
    effective_currency: Optional[str] = None

    if adjusted_cost is not None:
        effective, source, confidence = adjusted_cost, CostSource.ADJUSTED, CostConfidence.MANUAL
        effective_currency = adjusted_currency
    elif manual_cost is not None:
        effective, source, confidence = manual_cost, CostSource.MANUAL, CostConfidence.MANUAL
        effective_currency = manual_currency
    elif actual_cost is not None:
        effective, source, confidence = actual_cost, CostSource.INVOICE, CostConfidence.EXACT
        effective_currency = actual_currency
    elif entry_estimate is not None:
        effective, source, confidence = entry_estimate, CostSource.ESTIMATE_ENTRY, CostConfidence.ESTIMATED
        effective_currency = entry_estimate_currency
    elif usage_estimate is not None:
        effective, source, confidence = usage_estimate, CostSource.USAGE_ESTIMATE, CostConfidence.ESTIMATED
        effective_currency = None  # filled from the catalogue at serialisation
    else:
        effective, source, confidence = None, CostSource.NONE, CostConfidence.UNKNOWN

    mixed_currency = "MULTI" in {
        adjusted_currency, manual_currency, actual_currency, entry_estimate_currency
    }
    if mixed_currency:
        # Several currencies fed this service's figures; no conversion exists.
        effective, source, confidence = None, CostSource.NONE, CostConfidence.UNKNOWN

    if requests == 0 and not entries:
        status = "no_usage"
    elif mixed_currency:
        status = "mixed_currency"
    elif effective is None:
        status = "unpriced"
    elif effective == 0 and unpriced == 0 and source == CostSource.USAGE_ESTIMATE:
        # Every priced event cost zero: a genuinely free service, which is a
        # known zero rather than an unknown one. A manual zero is not relabelled.
        status = "free"
        confidence = CostConfidence.EXACT
    elif unpriced:
        status = "partially_unpriced"
    else:
        status = "priced"

    return {
        "requests_total": requests,
        "requests_success": success["requests"],
        "requests_failed": failed["requests"] + rejected["requests"],
        "requests_accepted": accepted["requests"],
        "usage_quantity": quantity,
        "successful_quantity": success["quantity"],
        "failed_quantity": failed["quantity"] + rejected["quantity"],
        "accepted_quantity": accepted["quantity"],
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "total_tokens": input_tokens + output_tokens,
        "actual_cost_minor": actual_cost,
        "estimated_cost_minor": estimate,
        "entry_estimated_cost_minor": entry_estimate,
        "usage_estimated_cost_minor": usage_estimate,
        "manually_entered_cost_minor": manual_cost,
        "adjusted_cost_minor": adjusted_cost,
        "effective_cost_minor": effective,
        "effective_currency": effective_currency,
        "cost_source": source,
        "confidence": confidence,
        "cost_status": status,
        "unpriced_events": unpriced,
        "priced_events": priced,
        "has_usage": requests > 0,
        "has_cost_information": effective is not None,
    }


async def _entries_in_range(
    db: AsyncSession, start: datetime, end: datetime, service_ids: Iterable[int]
) -> dict[int, list[ServiceCostEntry]]:
    ids = list(service_ids)
    if not ids:
        return {}
    rows = (
        await db.execute(
            select(ServiceCostEntry).where(
                ServiceCostEntry.service_id.in_(ids),
                ServiceCostEntry.period_start < end,
                ServiceCostEntry.period_end > start,
            )
        )
    ).scalars().all()
    grouped: dict[int, list[ServiceCostEntry]] = {}
    for row in rows:
        grouped.setdefault(row.service_id, []).append(row)
    return grouped


async def _adjustments_in_range(
    db: AsyncSession, start: datetime, end: datetime, service_ids: Iterable[int]
) -> dict[int, list[ServiceCostAdjustment]]:
    ids = list(service_ids)
    if not ids:
        return {}
    rows = (
        await db.execute(
            select(ServiceCostAdjustment).where(
                ServiceCostAdjustment.service_id.in_(ids),
                ServiceCostAdjustment.period_start < end,
                ServiceCostAdjustment.period_end > start,
            )
        )
    ).scalars().all()
    grouped: dict[int, list[ServiceCostAdjustment]] = {}
    for row in rows:
        grouped.setdefault(row.service_id, []).append(row)
    return grouped


def _service_payload(
    service: ServiceCatalog,
    totals: dict[tuple[int, str], dict[str, int]],
    entries: list[ServiceCostEntry],
    adjustments: list[ServiceCostAdjustment],
    start: datetime,
    end: datetime,
) -> dict[str, Any]:
    by_status: dict[str, dict[str, int]] = {}
    for (sid, status), bucket in totals.items():
        if sid == service.id:
            by_status[status] = bucket
    money = _cost_for_service(by_status, entries, adjustments)
    estimate = money["estimated_cost_minor"]
    maximum = (
        (int(estimate) * int(service.max_cost_multiplier_bps or 10000) + 9999) // 10000
        if estimate is not None
        else None
    )
    payload = {
        "service_key": service.service_key,
        "service_name": service.service_name,
        "provider": service.provider,
        "category": service.category,
        "usage_unit": service.usage_unit,
        "pricing_model": service.pricing_model,
        "billable": bool(service.is_billable),
        "active": bool(service.active),
        "currency": (
            money["effective_currency"]
            or ("MULTI" if money["cost_status"] == "mixed_currency" else service.billing_currency)
        ),
        "default_confidence": service.cost_confidence,
        "maximum_estimated_cost_minor": maximum,
        "notes": service.reporting_notes,
        "reporting_period": {"start": iso(start), "end": iso(end)},
    }
    payload.update(money)
    return payload


async def services_report(
    db: AsyncSession,
    *,
    start: datetime,
    end: datetime,
    service_key: Optional[str] = None,
    category: Optional[str] = None,
    active_only: bool = False,
) -> dict[str, Any]:
    """Per-service usage and effective cost for one reporting period."""
    from api.domains.service_costs.catalog import ensure_catalog

    await ensure_catalog(db)
    catalog = await _catalog_by_key(db)
    services = list(catalog.values())
    if service_key:
        services = [s for s in services if s.service_key == service_key]
    if category:
        services = [s for s in services if s.category == category]
    if active_only:
        services = [s for s in services if s.active]
    services.sort(key=lambda s: (s.category, s.service_name))

    totals = await usage_totals(db, start, end)
    ids = [s.id for s in services]
    entries_by = await _entries_in_range(db, start, end, ids)
    adjustments_by = await _adjustments_in_range(db, start, end, ids)

    rows = [
        _service_payload(
            s,
            totals,
            entries_by.get(s.id, []),
            adjustments_by.get(s.id, []),
            start,
            end,
        )
        for s in services
    ]

    currencies = sorted({
        r["currency"] for r in rows
        if r["effective_cost_minor"] is not None and r["currency"] != "MULTI"
    })
    totals_by_currency = []
    for currency in currencies:
        scoped = [r for r in rows if r["currency"] == currency]
        totals_by_currency.append(
            {
                "currency": currency,
                "effective_cost_minor": sum(
                    int(r["effective_cost_minor"]) for r in scoped
                    if r["effective_cost_minor"] is not None
                ),
                "actual_cost_minor": sum(
                    int(r["actual_cost_minor"]) for r in scoped
                    if r["actual_cost_minor"] is not None
                ),
                "estimated_cost_minor": sum(
                    int(r["estimated_cost_minor"]) for r in scoped
                    if r["estimated_cost_minor"] is not None
                ),
                "manually_entered_cost_minor": sum(
                    int(r["manually_entered_cost_minor"]) for r in scoped
                    if r["manually_entered_cost_minor"] is not None
                ),
                "adjusted_cost_minor": sum(
                    int(r["adjusted_cost_minor"]) for r in scoped
                    if r["adjusted_cost_minor"] is not None
                ),
                "maximum_estimated_cost_minor": sum(
                    int(r["maximum_estimated_cost_minor"]) for r in scoped
                    if r["maximum_estimated_cost_minor"] is not None
                ),
                "services_with_cost": sum(
                    1 for r in scoped if r["effective_cost_minor"] is not None
                ),
                "unpriced_services": sum(
                    1 for r in scoped if r["effective_cost_minor"] is None
                ),
            }
        )

    return {
        "currency": "MULTI" if len(currencies) > 1 else (currencies[0] if currencies else "KES"),
        "currencies": currencies,
        "reporting_period": {"start": iso(start), "end": iso(end)},
        "generated_at": iso(utcnow()),
        "totals_by_currency": totals_by_currency,
        "services": rows,
    }


async def costs_summary(
    db: AsyncSession, *, start: datetime, end: datetime
) -> dict[str, Any]:
    report = await services_report(db, start=start, end=end)
    rows = report["services"]
    currencies = report["currencies"]

    # Only services that actually did something can be "unpriced". Listing
    # all 28 catalogue rows on a quiet month would call unused services
    # unpriced and overstate the gap.
    unpriced = [
        r["service_key"]
        for r in rows
        if r["effective_cost_minor"] is None and r["has_usage"]
    ]
    by_category: dict[tuple[str, str], dict[str, Any]] = {}
    by_source: dict[tuple[str, str], dict[str, Any]] = {}
    for row in rows:
        if row["effective_cost_minor"] is None:
            continue
        cat = by_category.setdefault(
            (row["category"], row["currency"]),
            {"category": row["category"], "currency": row["currency"],
             "effective_cost_minor": 0, "services": 0},
        )
        cat["effective_cost_minor"] += int(row["effective_cost_minor"])
        cat["services"] += 1
        src = by_source.setdefault(
            (row["cost_source"], row["currency"]),
            {"cost_source": row["cost_source"], "currency": row["currency"],
             "effective_cost_minor": 0, "services": 0},
        )
        src["effective_cost_minor"] += int(row["effective_cost_minor"])
        src["services"] += 1

    notes: list[str] = []
    if unpriced:
        notes.append(
            f"{len(unpriced)} service(s) have usage with no known price; their "
            "cost is reported as null, not zero. Record a price or an invoice "
            "to price them."
        )
    if len(currencies) > 1:
        notes.append(
            "Totals are separated by currency. BROKA does not convert between "
            "currencies in reports."
        )
    if any(
        r["actual_cost_minor"] is not None and r["estimated_cost_minor"] is not None
        for r in rows
    ):
        notes.append(
            "For services with both an invoice and an estimate, the effective "
            "cost is the invoice-backed figure; the estimate is retained for "
            "comparison and is not added to it."
        )
    notes.append(
        "Estimates are quantity x the rate effective at the time of each "
        "operation; they are not audited provider totals. Actual, estimated "
        "and manually adjusted costs are reported separately."
    )

    return {
        "reporting_period": report["reporting_period"],
        "generated_at": report["generated_at"],
        "currency": report["currency"],
        "currencies": currencies,
        "totals_by_currency": report["totals_by_currency"],
        "by_category": sorted(
            by_category.values(),
            key=lambda r: (r["currency"], -r["effective_cost_minor"]),
        ),
        "by_cost_source": sorted(
            by_source.values(),
            key=lambda r: (r["currency"], -r["effective_cost_minor"]),
        ),
        "usage": {
            "requests_total": sum(r["requests_total"] for r in rows),
            "requests_success": sum(r["requests_success"] for r in rows),
            "requests_failed": sum(r["requests_failed"] for r in rows),
            "input_tokens": sum(r["input_tokens"] for r in rows),
            "output_tokens": sum(r["output_tokens"] for r in rows),
            "images": sum(
                r["usage_quantity"] for r in rows
                if r["service_key"] == "image.huggingface_fal"
            ),
            "sms_segments": sum(
                r["usage_quantity"] for r in rows
                if r["category"] == "messaging" and r["usage_unit"] == "sms_segment"
            ),
            "emails": sum(
                r["usage_quantity"] for r in rows if r["usage_unit"] == "email"
            ),
        },
        "services_total": len(rows),
        "services_with_cost": sum(
            1 for r in rows if r["effective_cost_minor"] is not None
        ),
        "unpriced_services": unpriced,
        "notes": notes,
    }


# ── Serialisation ───────────────────────────────────────────────────────────

def event_payload(event: ServiceUsageEvent, service: Optional[ServiceCatalog]) -> dict:
    return {
        "id": event.id,
        "service_key": service.service_key if service else None,
        "service_name": service.service_name if service else None,
        "provider": service.provider if service else None,
        "operation_type": event.operation_type,
        "status": event.status,
        "provider_reference": event.provider_reference,
        "operation_id": event.operation_id,
        "quantity": event.quantity,
        "usage_unit": event.usage_unit,
        "input_tokens": event.input_tokens,
        "output_tokens": event.output_tokens,
        "unit_price_minor": event.unit_price_minor,
        "estimated_cost_minor": event.estimated_cost_minor,
        "currency": event.currency,
        "cost_basis": event.cost_basis,
        "confidence": event.cost_confidence,
        "occurred_at": iso(event.occurred_at),
        "reporting_period_start": iso(event.reporting_period_start),
        "metadata": event.meta or {},
    }


def entry_payload(entry: ServiceCostEntry, service: Optional[ServiceCatalog]) -> dict:
    return {
        "id": entry.id,
        "service_key": service.service_key if service else None,
        "service_name": service.service_name if service else None,
        "period_start": iso(entry.period_start),
        "period_end": iso(entry.period_end),
        "actual_cost_minor": entry.actual_cost_minor,
        "estimated_cost_minor": entry.estimated_cost_minor,
        "manually_entered_cost_minor": entry.manually_entered_cost_minor,
        "currency": entry.currency,
        "cost_source": entry.cost_source,
        "confidence": entry.confidence,
        "notes": entry.notes,
        "invoice_reference": entry.invoice_reference,
        "entered_by": entry.entered_by,
        "created_at": iso(entry.created_at),
        "updated_at": iso(entry.updated_at),
    }


def pricing_payload(row, service: Optional[ServiceCatalog]) -> dict:
    return {
        "id": row.id,
        "service_key": service.service_key if service else None,
        "service_name": service.service_name if service else None,
        "pricing_unit": row.pricing_unit,
        "unit_price_minor": row.unit_price_minor,
        "currency": row.currency,
        "effective_from": iso(row.effective_from),
        "effective_until": iso(row.effective_until),
        "pricing_source": row.pricing_source,
        "confidence": row.cost_confidence,
        "created_by": row.created_by,
        "created_at": iso(row.created_at),
    }


def adjustment_payload(row: ServiceCostAdjustment, service: Optional[ServiceCatalog]) -> dict:
    return {
        "id": row.id,
        "service_key": service.service_key if service else None,
        "service_name": service.service_name if service else None,
        "entry_id": row.entry_id,
        "period_start": iso(row.period_start),
        "period_end": iso(row.period_end),
        "original_estimate_minor": row.original_estimate_minor,
        "adjusted_amount_minor": row.adjusted_amount_minor,
        "currency": row.currency,
        "reason": row.reason,
        "adjusted_by": row.adjusted_by,
        "created_at": iso(row.created_at),
    }


# ── Manual cost entries ─────────────────────────────────────────────────────

async def list_entries(
    db: AsyncSession, *, start: datetime, end: datetime,
    service_key: Optional[str] = None, limit: int = 200, offset: int = 0,
) -> dict[str, Any]:
    stmt = (
        select(ServiceCostEntry, ServiceCatalog)
        .join(ServiceCatalog, ServiceCatalog.id == ServiceCostEntry.service_id)
        .where(
            ServiceCostEntry.period_start < end,
            ServiceCostEntry.period_end > start,
        )
        .order_by(ServiceCostEntry.period_start.desc(), ServiceCostEntry.id.desc())
    )
    if service_key:
        stmt = stmt.where(ServiceCatalog.service_key == service_key)
    rows = (await db.execute(stmt.limit(limit).offset(offset))).all()
    return {
        "reporting_period": {"start": iso(start), "end": iso(end)},
        "entries": [entry_payload(entry, service) for entry, service in rows],
        "limit": limit,
        "offset": offset,
    }


async def create_cost_entry(
    db: AsyncSession,
    *,
    admin_id: str,
    service_key: str,
    period_start: datetime,
    period_end: datetime,
    currency: str,
    actual_cost_minor: Optional[int] = None,
    estimated_cost_minor: Optional[int] = None,
    manually_entered_cost_minor: Optional[int] = None,
    notes: Optional[str] = None,
    invoice_reference: Optional[str] = None,
) -> dict[str, Any]:
    start, end = validate_period(period_start, period_end)
    currency = validate_currency(currency)
    actual = validate_amount(actual_cost_minor, "actual_cost_minor")
    estimate = validate_amount(estimated_cost_minor, "estimated_cost_minor")
    manual = validate_amount(manually_entered_cost_minor, "manually_entered_cost_minor")
    if actual is None and estimate is None and manual is None:
        raise ValidationError(
            "provide actual_cost_minor, estimated_cost_minor or "
            "manually_entered_cost_minor"
        )
    service = await _service(db, service_key)

    source = (
        CostSource.MANUAL if manual is not None
        else CostSource.INVOICE if actual is not None
        else CostSource.ESTIMATE_ENTRY
    )
    confidence = (
        CostConfidence.MANUAL if manual is not None
        else CostConfidence.EXACT if actual is not None
        else CostConfidence.ESTIMATED
    )

    existing = (
        await db.execute(
            select(ServiceCostEntry.id).where(
                ServiceCostEntry.service_id == service.id,
                ServiceCostEntry.period_start == start,
                ServiceCostEntry.period_end == end,
                ServiceCostEntry.cost_source == source,
            )
        )
    ).scalar_one_or_none()
    if existing is not None:
        raise ConflictError(
            f"a {source} entry for this service and period already exists "
            f"(id {existing}); update it instead of adding a second one"
        )

    row = ServiceCostEntry(
        service_id=service.id,
        period_start=start,
        period_end=end,
        actual_cost_minor=actual,
        estimated_cost_minor=estimate,
        manually_entered_cost_minor=manual,
        currency=currency,
        cost_source=source,
        confidence=confidence,
        notes=notes,
        invoice_reference=invoice_reference,
        entered_by=admin_id,
        created_at=utcnow(),
        updated_at=utcnow(),
    )
    db.add(row)
    try:
        await db.flush()
    except IntegrityError as exc:
        await db.rollback()
        raise ConflictError(
            "a cost entry for this service, period and source already exists"
        ) from exc

    from api.core.audit import record_audit

    await record_audit(
        db, admin_id, "service_cost_entry_created", "service_cost_entry", str(row.id),
        detail=(
            f"service={service.service_key} period={start.date()}..{end.date()} "
            f"source={source} currency={currency} actual={actual} "
            f"estimated={estimate} manual={manual}"
        ),
    )
    await db.commit()
    return {"entry": entry_payload(row, service)}


async def update_cost_entry(
    db: AsyncSession,
    *,
    admin_id: str,
    entry_id: int,
    actual_cost_minor: Optional[int] = None,
    estimated_cost_minor: Optional[int] = None,
    manually_entered_cost_minor: Optional[int] = None,
    currency: Optional[str] = None,
    notes: Optional[str] = None,
    invoice_reference: Optional[str] = None,
    reason: Optional[str] = None,
    clear_manual: bool = False,
) -> dict[str, Any]:
    row = (
        await db.execute(
            select(ServiceCostEntry, ServiceCatalog)
            .join(ServiceCatalog, ServiceCatalog.id == ServiceCostEntry.service_id)
            .where(ServiceCostEntry.id == entry_id)
        )
    ).one_or_none()
    if row is None:
        raise LookupError("cost entry not found")
    entry, service = row

    new_actual = validate_amount(actual_cost_minor, "actual_cost_minor")
    new_estimate = validate_amount(estimated_cost_minor, "estimated_cost_minor")
    new_manual = validate_amount(manually_entered_cost_minor, "manually_entered_cost_minor")
    changed_fields: list[str] = []

    if currency is not None:
        currency = validate_currency(currency)
        if currency != entry.currency:
            changed_fields.append(f"currency {entry.currency}->{currency}")
            entry.currency = currency
    if new_actual is not None and new_actual != entry.actual_cost_minor:
        changed_fields.append(f"actual {entry.actual_cost_minor}->{new_actual}")
        entry.actual_cost_minor = new_actual
        entry.cost_source = CostSource.INVOICE
        entry.confidence = CostConfidence.EXACT
    if new_estimate is not None and new_estimate != entry.estimated_cost_minor:
        changed_fields.append(f"estimated {entry.estimated_cost_minor}->{new_estimate}")
        entry.estimated_cost_minor = new_estimate
    if clear_manual and entry.manually_entered_cost_minor is not None:
        changed_fields.append(f"manual {entry.manually_entered_cost_minor}->cleared")
        if entry.actual_cost_minor is not None:
            entry.cost_source = CostSource.INVOICE
            entry.confidence = CostConfidence.EXACT
        else:
            entry.cost_source = CostSource.ESTIMATE_ENTRY
            entry.confidence = CostConfidence.ESTIMATED
        entry.manually_entered_cost_minor = None
    elif new_manual is not None and new_manual != entry.manually_entered_cost_minor:
        previous = entry.manually_entered_cost_minor
        changed_fields.append(f"manual {previous}->{new_manual}")
        # The adjustment retains what the system believed before the change:
        # the usage-derived estimate for this window when one exists.
        original = await _estimate_for_window(db, service.id, entry.period_start, entry.period_end)
        db.add(
            ServiceCostAdjustment(
                service_id=service.id,
                entry_id=entry.id,
                period_start=entry.period_start,
                period_end=entry.period_end,
                original_estimate_minor=original,
                adjusted_amount_minor=new_manual,
                currency=entry.currency,
                reason=reason or notes or "manual cost adjustment",
                adjusted_by=admin_id,
                created_at=utcnow(),
            )
        )
        entry.manually_entered_cost_minor = new_manual
        entry.cost_source = CostSource.MANUAL
        entry.confidence = CostConfidence.MANUAL
    if notes is not None:
        changed_fields.append("notes")
        entry.notes = notes
    if invoice_reference is not None:
        changed_fields.append("invoice_reference")
        entry.invoice_reference = invoice_reference

    if not changed_fields:
        return {"entry": entry_payload(entry, service)}

    entry.updated_at = utcnow()
    from api.core.audit import record_audit

    await record_audit(
        db, admin_id, "service_cost_entry_updated", "service_cost_entry", str(entry.id),
        detail=(
            f"service={service.service_key} period={entry.period_start.date()}.."
            f"{entry.period_end.date()} changes={'; '.join(changed_fields)} "
            f"reason={reason or notes or '-'}"
        ),
    )
    await db.commit()
    return {"entry": entry_payload(entry, service)}


async def _estimate_for_window(
    db: AsyncSession, service_id: int, start: datetime, end: datetime
) -> Optional[int]:
    totals = await usage_totals(db, start, end)
    buckets = [
        bucket for (sid, _status), bucket in totals.items() if sid == service_id
    ]
    if not buckets:
        return None
    priced = sum(b["priced_events"] for b in buckets)
    if priced == 0:
        return None
    return sum(b["cost_minor"] for b in buckets)


async def list_adjustments(
    db: AsyncSession, *, start: datetime, end: datetime,
    service_key: Optional[str] = None, limit: int = 200, offset: int = 0,
) -> dict[str, Any]:
    stmt = (
        select(ServiceCostAdjustment, ServiceCatalog)
        .join(ServiceCatalog, ServiceCatalog.id == ServiceCostAdjustment.service_id)
        .where(
            ServiceCostAdjustment.period_start < end,
            ServiceCostAdjustment.period_end > start,
        )
        .order_by(ServiceCostAdjustment.created_at.desc(), ServiceCostAdjustment.id.desc())
    )
    if service_key:
        stmt = stmt.where(ServiceCatalog.service_key == service_key)
    rows = (await db.execute(stmt.limit(limit).offset(offset))).all()
    return {
        "reporting_period": {"start": iso(start), "end": iso(end)},
        "adjustments": [adjustment_payload(a, s) for a, s in rows],
        "limit": limit,
        "offset": offset,
    }


# ── Pricing ─────────────────────────────────────────────────────────────────

async def list_pricing(
    db: AsyncSession, *, service_key: Optional[str] = None,
    active_at: Optional[datetime] = None, limit: int = 500, offset: int = 0,
) -> dict[str, Any]:
    stmt = (
        select(ServicePricing, ServiceCatalog)
        .join(ServiceCatalog, ServiceCatalog.id == ServicePricing.service_id)
        .order_by(
            ServiceCatalog.service_key,
            ServicePricing.effective_from.desc(),
        )
    )
    if service_key:
        stmt = stmt.where(ServiceCatalog.service_key == service_key)
    if active_at is not None:
        at = to_naive_utc(active_at)
        stmt = stmt.where(
            ServicePricing.effective_from <= at,
            or_(
                ServicePricing.effective_until.is_(None),
                ServicePricing.effective_until > at,
            ),
        )
    rows = (await db.execute(stmt.limit(limit).offset(offset))).all()
    return {
        "pricing": [pricing_payload(price, service) for price, service in rows],
        "limit": limit,
        "offset": offset,
    }


async def create_pricing(
    db: AsyncSession,
    *,
    admin_id: str,
    service_key: str,
    pricing_unit: str,
    unit_price_minor: int,
    currency: str,
    effective_from: datetime,
    pricing_source: str,
    confidence: str = CostConfidence.ESTIMATED,
    effective_until: Optional[datetime] = None,
) -> dict[str, Any]:
    service = await _service(db, service_key)
    unit_price = validate_amount(unit_price_minor, "unit_price_minor")
    if unit_price is None:
        raise ValidationError("unit_price_minor is required")
    currency = validate_currency(currency)
    if confidence not in CostConfidence.ALL:
        raise ValidationError(f"unknown confidence {confidence!r}")
    start = to_naive_utc(effective_from)
    end = to_naive_utc(effective_until) if effective_until else None
    if end is not None and end <= start:
        raise ValidationError("effective_until must be after effective_from")
    if not (pricing_source or "").strip():
        raise ValidationError("pricing_source is required")
    unit = (pricing_unit or "").strip()
    if not unit:
        raise ValidationError("pricing_unit is required")

    duplicate = (
        await db.execute(
            select(ServicePricing.id).where(
                ServicePricing.service_id == service.id,
                ServicePricing.effective_from == start,
            )
        )
    ).scalar_one_or_none()
    if duplicate is not None:
        raise ConflictError(
            "a price with this effective_from already exists for the service"
        )

    # Close the open row. Setting effective_until to the new start keeps the
    # old price valid for every event before it, which is what preserves a
    # past report.
    open_rows = (
        await db.execute(
            select(ServicePricing).where(
                ServicePricing.service_id == service.id,
                ServicePricing.effective_until.is_(None),
                ServicePricing.effective_from < start,
            )
        )
    ).scalars().all()
    for old in open_rows:
        old.effective_until = start

    row = ServicePricing(
        service_id=service.id,
        pricing_unit=unit,
        unit_price_minor=int(unit_price),
        currency=currency,
        effective_from=start,
        effective_until=end,
        pricing_source=pricing_source.strip()[:160],
        cost_confidence=confidence,
        created_by=admin_id,
        created_at=utcnow(),
    )
    db.add(row)
    await db.flush()

    from api.core.audit import record_audit

    await record_audit(
        db, admin_id, "service_pricing_created", "service_pricing", str(row.id),
        detail=(
            f"service={service.service_key} unit={unit} price={unit_price} "
            f"{currency} from={start.isoformat()} source={pricing_source}"
        ),
    )
    await db.commit()
    return {"pricing": pricing_payload(row, service)}


async def update_pricing(
    db: AsyncSession,
    *,
    admin_id: str,
    pricing_id: int,
    unit_price_minor: Optional[int] = None,
    effective_until: Optional[datetime] = None,
    pricing_source: Optional[str] = None,
    confidence: Optional[str] = None,
    reason: Optional[str] = None,
) -> dict[str, Any]:
    row = (
        await db.execute(
            select(ServicePricing, ServiceCatalog)
            .join(ServiceCatalog, ServiceCatalog.id == ServicePricing.service_id)
            .where(ServicePricing.id == pricing_id)
        )
    ).one_or_none()
    if row is None:
        raise LookupError("pricing row not found")
    price, service = row
    changes: list[str] = []

    if unit_price_minor is not None:
        price_value = validate_amount(unit_price_minor, "unit_price_minor")
        if price.effective_from <= utcnow():
            raise ConflictError(
                "this price is already in force; create a new price with a "
                "later effective_from instead of rewriting history"
            )
        if price_value != price.unit_price_minor:
            changes.append(f"price {price.unit_price_minor}->{price_value}")
            price.unit_price_minor = int(price_value)
    if effective_until is not None:
        end = to_naive_utc(effective_until)
        if end <= price.effective_from:
            raise ValidationError("effective_until must be after effective_from")
        changes.append(f"effective_until {iso(price.effective_until)}->{iso(end)}")
        price.effective_until = end
    if pricing_source is not None:
        if not pricing_source.strip():
            raise ValidationError("pricing_source may not be empty")
        changes.append("pricing_source")
        price.pricing_source = pricing_source.strip()[:160]
    if confidence is not None:
        if confidence not in CostConfidence.ALL:
            raise ValidationError(f"unknown confidence {confidence!r}")
        changes.append(f"confidence->{confidence}")
        price.cost_confidence = confidence

    if not changes:
        return {"pricing": pricing_payload(price, service)}
    from api.core.audit import record_audit

    await record_audit(
        db, admin_id, "service_pricing_updated", "service_pricing", str(price.id),
        detail=(
            f"service={service.service_key} changes={'; '.join(changes)} "
            f"reason={reason or '-'}"
        ),
    )
    await db.commit()
    return {"pricing": pricing_payload(price, service)}


# ── Usage listing ───────────────────────────────────────────────────────────

async def list_usage_events(
    db: AsyncSession, *, start: datetime, end: datetime,
    service_key: Optional[str] = None, status: Optional[str] = None,
    limit: int = 200, offset: int = 0,
) -> dict[str, Any]:
    stmt = (
        select(ServiceUsageEvent, ServiceCatalog)
        .join(ServiceCatalog, ServiceCatalog.id == ServiceUsageEvent.service_id)
        .where(
            ServiceUsageEvent.occurred_at >= start,
            ServiceUsageEvent.occurred_at < end,
        )
        .order_by(ServiceUsageEvent.occurred_at.desc(), ServiceUsageEvent.id.desc())
    )
    if service_key:
        stmt = stmt.where(ServiceCatalog.service_key == service_key)
    if status:
        if status not in UsageStatus.ALL:
            raise ValidationError(f"unknown status {status!r}")
        stmt = stmt.where(ServiceUsageEvent.status == status)
    rows = (await db.execute(stmt.limit(limit).offset(offset))).all()
    return {
        "reporting_period": {"start": iso(start), "end": iso(end)},
        "events": [event_payload(event, service) for event, service in rows],
        "limit": limit,
        "offset": offset,
        "note": (
            "Raw events are retained for SERVICE_USAGE_RETENTION_DAYS and then "
            "rolled into daily totals; summaries include rolled-up history, "
            "this detail endpoint does not."
        ),
    }


# ── Retention / aggregation ─────────────────────────────────────────────────

async def rollup_old_usage(db: AsyncSession, *, now: Optional[datetime] = None) -> int:
    """Roll days older than the retention window into daily totals, then
    delete their raw events in the same transaction.

    Returns the number of days archived. Bounded per run so a first run on a
    large history is a series of small transactions, not one long lock.
    """
    from api.core.config import settings

    retention_days = max(30, int(getattr(settings, "service_usage_retention_days", 400)))
    cutoff = (now or utcnow()) - timedelta(days=retention_days)
    cutoff_day = cutoff.date()

    days = (
        await db.execute(
            select(func.date(ServiceUsageEvent.occurred_at))
            .where(ServiceUsageEvent.occurred_at < cutoff)
            .group_by(func.date(ServiceUsageEvent.occurred_at))
            .order_by(func.date(ServiceUsageEvent.occurred_at))
            .limit(10)
        )
    ).scalars().all()
    archived = 0
    for raw_day in days:
        day_value = raw_day if isinstance(raw_day, date) else date.fromisoformat(str(raw_day))
        if day_value >= cutoff_day:
            continue
        day_start = datetime(day_value.year, day_value.month, day_value.day)
        day_end = day_start + timedelta(days=1)

        rows = (
            await db.execute(
                select(
                    ServiceUsageEvent.service_id,
                    ServiceUsageEvent.status,
                    ServiceUsageEvent.currency,
                    func.count(ServiceUsageEvent.id),
                    func.coalesce(func.sum(ServiceUsageEvent.quantity), 0),
                    func.coalesce(func.sum(ServiceUsageEvent.input_tokens), 0),
                    func.coalesce(func.sum(ServiceUsageEvent.output_tokens), 0),
                    func.coalesce(func.sum(ServiceUsageEvent.estimated_cost_minor), 0),
                    func.coalesce(
                        func.sum(
                            case(
                                (ServiceUsageEvent.estimated_cost_minor.is_(None), 1),
                                else_=0,
                            )
                        ),
                        0,
                    ),
                )
                .where(
                    ServiceUsageEvent.occurred_at >= day_start,
                    ServiceUsageEvent.occurred_at < day_end,
                )
                .group_by(
                    ServiceUsageEvent.service_id,
                    ServiceUsageEvent.status,
                    ServiceUsageEvent.currency,
                )
            )
        ).all()

        for sid, status, currency, count, qty, tin, tout, cost, unpriced in rows:
            key = currency or ""
            existing = (
                await db.execute(
                    select(ServiceUsageDaily.id).where(
                        ServiceUsageDaily.service_id == sid,
                        ServiceUsageDaily.day == day_value,
                        ServiceUsageDaily.status == status,
                        ServiceUsageDaily.currency == key,
                    )
                )
            ).scalar_one_or_none()
            if existing is None:
                db.add(
                    ServiceUsageDaily(
                        service_id=sid,
                        day=day_value,
                        status=status,
                        event_count=int(count),
                        quantity=int(qty),
                        input_tokens=int(tin),
                        output_tokens=int(tout),
                        estimated_cost_minor=int(cost),
                        unpriced_count=int(unpriced),
                        currency=key,
                        created_at=utcnow(),
                    )
                )
                await db.flush()
        # Deleting in the same transaction as the insert is what guarantees a
        # day is never counted twice and never lost.
        from sqlalchemy import delete as sql_delete

        await db.execute(
            sql_delete(ServiceUsageEvent).where(
                ServiceUsageEvent.occurred_at >= day_start,
                ServiceUsageEvent.occurred_at < day_end,
            )
        )
        await db.commit()
        archived += 1
    return archived


async def sample_infrastructure_usage(*, force: bool = False) -> dict[str, Any]:
    """Record provider-exposed infrastructure metrics, when they are real.

    PostgreSQL exposes its database size; Redis exposes memory and command
    counters when INFO is permitted. Neither is billed at a rate this code
    knows, so the events are unpriced with the measured quantity attached -
    an admin prices them from the provider invoice. SQLite records nothing.
    """
    global _LAST_INFRA_AT
    now = utcnow()
    if not force and _LAST_INFRA_AT is not None and now - _LAST_INFRA_AT < _INFRA_INTERVAL:
        return {"sampled": False, "reason": "throttled"}
    _LAST_INFRA_AT = now
    hour_key = now.strftime("%Y-%m-%dT%H")
    recorded: list[str] = []

    try:
        from api.database import AsyncSessionLocal, DATABASE_URL

        if DATABASE_URL.startswith("postgres"):
            from sqlalchemy import text as sql_text

            async with AsyncSessionLocal() as db:
                size = (
                    await db.execute(sql_text("SELECT pg_database_size(current_database())"))
                ).scalar_one()
            await record_usage(
                service_key="infra.postgres",
                operation_type="infra.database_size",
                status=UsageStatus.SUCCESS,
                quantity=int(size),
                operation_id=f"infra.postgres:size:{hour_key}",
                cost_basis=CostBasis.UNPRICED,
                cost_confidence=CostConfidence.UNKNOWN,
                metadata={"metric": "database_size_bytes"},
                occurred_at=now,
            )
            recorded.append("infra.postgres")
    except Exception as exc:
        logger.info("[service-costs] postgres size sample skipped: %s", type(exc).__name__)

    try:
        from api.core.config import settings

        if settings.redis_url:
            import redis.asyncio as aioredis

            client = aioredis.from_url(
                settings.redis_url, socket_connect_timeout=2, socket_timeout=2
            )
            try:
                info = await client.info()
            finally:
                await client.aclose()
            used_memory = info.get("used_memory")
            if used_memory is not None:
                await record_usage(
                    service_key="infra.redis",
                    operation_type="infra.redis_memory",
                    status=UsageStatus.SUCCESS,
                    quantity=int(used_memory),
                    operation_id=f"infra.redis:memory:{hour_key}",
                    cost_basis=CostBasis.UNPRICED,
                    cost_confidence=CostConfidence.UNKNOWN,
                    metadata={
                        "metric": "used_memory_bytes",
                        "total_commands_processed": info.get(
                            "total_commands_processed"
                        ),
                    },
                    occurred_at=now,
                )
                recorded.append("infra.redis")
    except Exception as exc:
        logger.info("[service-costs] redis INFO sample skipped: %s", type(exc).__name__)

    return {"sampled": True, "recorded": recorded}


async def run_cost_maintenance() -> dict[str, Any]:
    """One pass of the background accounting jobs, called by the sweep.

    Flushing the retry buffer runs every pass; rollups and infrastructure
    samples are throttled inside their own functions. Everything here is
    best-effort: the sweep must keep working when accounting cannot.
    """
    global _LAST_ROLLUP_AT
    now = utcnow()
    flushed = await flush_pending_usage()
    archived = 0
    if _LAST_ROLLUP_AT is None or now - _LAST_ROLLUP_AT >= _ROLLUP_INTERVAL:
        _LAST_ROLLUP_AT = now
        try:
            from api.database import AsyncSessionLocal

            async with AsyncSessionLocal() as db:
                archived = await rollup_old_usage(db, now=now)
        except Exception as exc:
            logger.warning("[service-costs] rollup failed: %s", type(exc).__name__)
    sample = await sample_infrastructure_usage()
    return {
        "flushed": flushed,
        "days_archived": archived,
        "infrastructure": sample,
    }
