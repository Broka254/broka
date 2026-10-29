"""Revenue aggregation — BROKA income vs platform costs.

INCOME SOURCE (read this before touching the queries): ZetuPayPayment is the
parent ledger for every shilling BROKA collects — listing fees, plans,
boosts, badges, store payments (models/zetupay.py, domains/payments/). Each
ZetuPayPayment points at its domain row (listing_payments,
subscription_payments, featured_payments, verification_payments,
store_payments) via target_id. Counting both the parent and the domain rows
would count every ZetuPay payment twice.

So income is aggregated from exactly one row per payment:
  - domain rows whose provider is NOT 'zetupay' (Daraja charges, settled on
    their own tables — their ZetuPayPayment row does not exist), plus
  - zetupay_payments rows (ZetuPay charges — the domain rows are the same
    payment, excluded via the provider filter above).

Test-charge references (purpose='test', the KES 10 going-live check) buy
nothing and are excluded. Only SUCCEEDED rows count: 'success' on the
string-status domain tables, ZetuPayStatus.SUCCESS on zetupay_payments.
Deal/escrow money is E-Confirm's and never appears in any of these tables
(ZETUPAY.md) — only BROKA income is summed here by construction.

COLLECTION FEES are derived, not stored. The fee on a settled payment is a
pure function of its provider and amount (ZetuPay 1.5% assumption,
Daraja's tariff bands — see cost_ledger.mpesa_fee_minor/zetupay_fee_minor),
so deriving at report time is complete by construction: every settled
payment contributes exactly once, history backfills itself, and a
redelivered webhook cannot double-count. Stored platform_costs rows of
kind payment_fee are EXCLUDED below — by definition they would duplicate
the derived figure (cost_ledger.py's header says the same; do not record
payment_fee rows).

All bucketing is in Python (portable across SQLite/Postgres): rows are read
with their timestamps and dropped into day/week/month buckets keyed by
naive-UTC dates. Amounts: domain tables store whole KES (listing,
subscription, store) or float KES (featured, verification), ZetuPay stores
whole KES — all converted to integer minor units (KES cents).
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.cost_ledger import mpesa_fee_minor, zetupay_fee_minor
from api.models.platform_cost import CostKind
from api.core.timeutil import parse_iso_to_naive_utc, to_naive_utc

_STREAM_LABELS = {
    "listing_fee": "Listing fees",
    "subscription": "Premium plans",
    "store": "Store plans",
    "boost": "Featured boosts",
    "verification": "Verification badges",
    "daraja_deal": "Deal commission (Daraja)",
}

_KIND_LABELS = {
    "sms": "SMS",
    "ai": "AI inference",
    "api": "API usage",
    "payment_fee": "Collection fees",
    "infra": "Infrastructure",
    "other": "Other",
}


def _to_minor(amount) -> int:
    try:
        return int(round(float(amount or 0) * 100))
    except (TypeError, ValueError):
        return 0


def _bucket_start(value: datetime, bucket: str) -> datetime:
    value = value.replace(hour=0, minute=0, second=0, microsecond=0)
    if bucket == "day":
        return value
    if bucket == "week":
        return value - timedelta(days=value.weekday())
    return value.replace(day=1)


def _iter_buckets(start: datetime, end: datetime, bucket: str):
    cursor = _bucket_start(start, bucket)
    out = []
    guard = 0
    while cursor < end and guard < 500:
        if bucket == "day":
            nxt = cursor + timedelta(days=1)
        elif bucket == "week":
            nxt = cursor + timedelta(weeks=1)
        elif cursor.month < 12:
            nxt = cursor.replace(month=cursor.month + 1, day=1)
        else:
            nxt = cursor.replace(year=cursor.year + 1, month=1, day=1)
        out.append((cursor, nxt))
        cursor = nxt
        guard += 1
    return out


def _parse_range(
    from_raw: Optional[str], to_raw: Optional[str]
) -> tuple[datetime, datetime]:
    now = datetime.utcnow()
    end = parse_iso_to_naive_utc(to_raw) if to_raw else now
    start = (
        parse_iso_to_naive_utc(from_raw)
        if from_raw
        else (end - timedelta(days=30))
    )
    if start > end:
        start, end = end, start
    return start, end


async def revenue_report(
    db: AsyncSession,
    *,
    from_raw: Optional[str] = None,
    to_raw: Optional[str] = None,
    bucket: str = "day",
) -> dict:
    """Aggregate BROKA income, platform costs and profit over [from, to)."""
    from api.database import FeaturedPayment, MpesaTransaction, VerificationPayment
    from api.models.listing_payment import ListingPayment
    from api.models.platform_cost import PlatformCost
    from api.models.store_billing import StorePayment
    from api.models.subscription import SubscriptionPayment
    from api.models.zetupay import Purpose, ZetuPayPayment, ZetuPayStatus

    if bucket not in ("day", "week", "month"):
        raise ValueError("bucket must be one of day, week, month")
    start, end = _parse_range(from_raw, to_raw)

    # Each stream keeps per-row (timestamp, amount_minor) pairs so the
    # bucket series below is a second pass over the same rows — one query
    # per table, bucketing in Python.
    streams: dict[str, dict] = {}
    # (timestamp, fee_minor, fee_estimated) per settled payment, in the same
    # loops that count income — the derived collection-fee series.
    derived_fees: list[tuple[datetime, int, bool]] = []

    def _add_stream(
        key: str,
        amount_minor: int,
        at: datetime,
        *,
        amount_kes: float = 0.0,
        fee_fn=None,
    ) -> None:
        entry = streams.setdefault(
            key,
            {
                "key": key,
                "label": _STREAM_LABELS.get(key, key),
                "amount_minor": 0,
                "count": 0,
                "rows": [],
            },
        )
        entry["amount_minor"] += amount_minor
        entry["count"] += 1
        entry["rows"].append((at, amount_minor))
        if fee_fn is not None:
            fee_minor, fee_estimated = fee_fn(amount_kes)
            if fee_minor > 0:
                derived_fees.append((at, fee_minor, fee_estimated))

    async def _string_status_rows(model, purpose_key: str) -> None:
        rows = (
            await db.execute(
                select(model).where(
                    model.status == "success",
                    model.created_at >= start,
                    model.created_at < end,
                    # Same payment as a zetupay_payments row — counted there.
                    model.provider != "zetupay",
                )
            )
        ).scalars().all()
        for row in rows:
            if row.created_at is None:
                continue
            _add_stream(
                purpose_key,
                _to_minor(row.amount),
                to_naive_utc(row.created_at),
                amount_kes=float(row.amount or 0),
                fee_fn=mpesa_fee_minor,
            )

    await _string_status_rows(ListingPayment, "listing_fee")
    await _string_status_rows(SubscriptionPayment, "subscription")
    await _string_status_rows(StorePayment, "store")

    # Featured/verification carry the MpesaStatus enum column: filter the
    # status in Python (portable) rather than comparing enums in SQL.
    for model, key in (
        (FeaturedPayment, "boost"),
        (VerificationPayment, "verification"),
    ):
        rows = (
            await db.execute(
                select(model).where(
                    model.created_at >= start,
                    model.created_at < end,
                    model.provider != "zetupay",
                )
            )
        ).scalars().all()
        for row in rows:
            if getattr(row.status, "value", row.status) != "success":
                continue
            if row.created_at is None:
                continue
            _add_stream(
                key,
                _to_minor(row.amount),
                to_naive_utc(row.created_at),
                amount_kes=float(row.amount or 0),
                fee_fn=mpesa_fee_minor,
            )

    # ZetuPay parent ledger: one row per ZetuPay payment (purpose → stream).
    z_rows = (
        await db.execute(
            select(
                ZetuPayPayment.purpose,
                ZetuPayPayment.amount,
                ZetuPayPayment.created_at,
            ).where(
                ZetuPayPayment.status == ZetuPayStatus.SUCCESS,
                ZetuPayPayment.created_at >= start,
                ZetuPayPayment.created_at < end,
                ZetuPayPayment.purpose != Purpose.TEST,
            )
        )
    ).all()
    _purpose_to_stream = {
        Purpose.LISTING_FEE: "listing_fee",
        Purpose.SUBSCRIPTION: "subscription",
        Purpose.STORE: "store",
        Purpose.BOOST: "boost",
        Purpose.VERIFICATION: "verification",
    }
    for purpose, amount, created_at in z_rows:
        if created_at is None:
            continue
        _add_stream(
            _purpose_to_stream.get(purpose, purpose),
            _to_minor(amount),
            to_naive_utc(created_at),
            amount_kes=float(amount or 0),
            fee_fn=zetupay_fee_minor,
        )

    # Legacy Daraja deal-commission intents (MpesaTransaction with a deal).
    # E-Confirm escrow holdings are NOT income and never appear here: these
    # rows are the commission charges buyers paid to BROKA, not deal funds.
    # Note: mpesa_transactions has no provider column (Daraja-only table),
    # so no provider exclusion is needed here unlike the domain tables.
    deal_rows = (
        await db.execute(
            select(MpesaTransaction).where(
                MpesaTransaction.created_at >= start,
                MpesaTransaction.created_at < end,
                MpesaTransaction.deal_id.is_not(None),
            )
        )
    ).scalars().all()
    for row in deal_rows:
        if getattr(row.status, "value", row.status) != "success":
            continue
        if row.created_at is None:
            continue
        _add_stream(
            "daraja_deal",
            _to_minor(row.amount),
            to_naive_utc(row.created_at),
            amount_kes=float(row.amount or 0),
            fee_fn=mpesa_fee_minor,
        )

    income_total = sum(entry["amount_minor"] for entry in streams.values())

    cost_rows = (
        await db.execute(
            select(PlatformCost).where(
                PlatformCost.created_at >= start,
                PlatformCost.created_at < end,
                # payment_fee is derived below, never stored (see module
                # header): a stored row can only duplicate the derived
                # figure, so it is excluded rather than double-counted.
                PlatformCost.kind != CostKind.PAYMENT_FEE,
            )
        )
    ).scalars().all()
    kinds: dict[str, dict] = {}
    costs_total = 0
    estimated_total = 0
    for row in cost_rows:
        entry = kinds.setdefault(
            row.kind,
            {
                "key": row.kind,
                "label": _KIND_LABELS.get(row.kind, row.kind),
                "amount_minor": 0,
                "count": 0,
                "estimated": False,
                "rows": [],
            },
        )
        amount = int(row.amount_minor or 0)
        entry["amount_minor"] += amount
        entry["count"] += 1
        entry["rows"].append((to_naive_utc(row.created_at), amount))
        if row.estimated:
            entry["estimated"] = True
            estimated_total += amount
        costs_total += amount
    # Derived collection fees join the same kinds structure (with rows, so
    # the bucket series below picks them up); count = settled payments.
    if derived_fees:
        fee_total = sum(fee for _, fee, _ in derived_fees)
        fee_estimated_total = sum(
            fee for _, fee, est in derived_fees if est
        )
        kinds[CostKind.PAYMENT_FEE] = {
            "key": CostKind.PAYMENT_FEE,
            "label": _KIND_LABELS[CostKind.PAYMENT_FEE],
            "amount_minor": fee_total,
            "count": len(derived_fees),
            "estimated": fee_estimated_total > 0,
            "rows": [(at, fee) for at, fee, _ in derived_fees],
        }
        costs_total += fee_total
        estimated_total += fee_estimated_total

    series = []
    for b_start, b_end in _iter_buckets(start, end, bucket):
        income_minor = sum(
            amount
            for entry in streams.values()
            for stamp, amount in entry["rows"]
            if b_start <= stamp < b_end
        )
        costs_minor = sum(
            amount
            for entry in kinds.values()
            for stamp, amount in entry["rows"]
            if b_start <= stamp < b_end
        )
        series.append(
            {
                "bucket_start": b_start.isoformat() + "Z",
                "income_minor": income_minor,
                "costs_minor": costs_minor,
                "profit_minor": income_minor - costs_minor,
            }
        )

    profit = income_total - costs_total
    margin = round(profit / income_total * 100, 2) if income_total else 0.0

    notes: list[str] = []
    if estimated_total:
        notes.append(
            f"KES {estimated_total / 100:.2f} of costs are estimated "
            "(assumed rates, not billed amounts) — see costs.estimated_minor."
        )
    if any(e["key"] == "ai" and e["estimated"] for e in kinds.values()):
        notes.append(
            "AI costs are priced from real per-call token counts at "
            "off-peak rates; peak multipliers, cache-hit ratios and FX "
            "moves are untracked, and providers without verified rates "
            "record zero-amount rows (see costs.estimated_minor)."
        )
    if CostKind.PAYMENT_FEE in kinds:
        notes.append(
            "Collection fees are derived from settled payments at assumed "
            "rates (ZetuPay 1.5%, Daraja tariff bands), not read from "
            "provider statements."
        )
    if not streams and not kinds:
        notes.append("No income or cost rows in this range.")

    def _iso(value: datetime) -> str:
        return value.isoformat() + "Z"

    return {
        "currency": "KES",
        "from": _iso(start),
        "to": _iso(end),
        "bucket": bucket,
        "income": {
            "total_minor": income_total,
            "streams": [
                {
                    "key": e["key"],
                    "label": e["label"],
                    "amount_minor": e["amount_minor"],
                    "count": e["count"],
                }
                for e in sorted(streams.values(), key=lambda e: -e["amount_minor"])
            ],
        },
        "costs": {
            "total_minor": costs_total,
            "estimated_minor": estimated_total,
            "kinds": [
                {
                    "key": e["key"],
                    "label": e["label"],
                    "amount_minor": e["amount_minor"],
                    "count": e["count"],
                    "estimated": e["estimated"],
                }
                for e in sorted(kinds.values(), key=lambda e: -e["amount_minor"])
            ],
        },
        "profit_minor": profit,
        "margin_pct": margin,
        "series": series,
        "notes": notes,
    }
