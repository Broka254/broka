"""The order funnel - what My Store's insights and Marketing Studio say
about orders.

REQUESTS ARE NOT SALES
======================
Every figure here is counted from store_orders and their events, and each
is named for what it is: a request is a buyer asking, an acceptance is the
store answering, a confirmation is the buyer agreeing the final details,
and a completed order is the buyer confirming they received it. Cart
additions are interest. Nothing here is a payment: BROKA does not see the
money, so the only money figure is the agreed total of completed orders,
labelled as exactly that.

WINDOWS
=======
The period is the same Kenyan-day window as the rest of the insights
(stores/insights.py): [start, end] in Kenya time, compared with the window
of the same length before it. Event counts ("accepted in the period") use
when the event happened. Rates use a cohort - the orders *created* in the
period - with the numerator and denominator returned beside every rate, so
"3 of 8" is never presented as a bare percentage. Recent cohorts are still
in progress, and the definitions say so.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, datetime, time, timedelta
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.config import settings
from api.database import Listing, ListingStatus
from api.models.store import Store, StoreDailyCount
from api.models.store_order import StoreOrder, StoreOrderEvent, StoreOrderItem

from . import lifecycle as lc
from . import messages as msg

KENYA_OFFSET = timedelta(hours=3)


def utc_bounds(start: date, end: date) -> tuple[datetime, datetime]:
    """Kenyan days [start, end] as naive-UTC instants [lo, hi)."""
    lo = datetime.combine(start, time.min) - KENYA_OFFSET
    hi = datetime.combine(end + timedelta(days=1), time.min) - KENYA_OFFSET
    return lo, hi


def kenya_day(value: datetime) -> date:
    return (value + KENYA_OFFSET).date()


def _pct(numerator: int, denominator: int) -> Optional[float]:
    return round(numerator / denominator * 100.0, 1) if denominator > 0 else None


def _change(current: int, previous: int) -> Optional[float]:
    return round((current - previous) / previous * 100.0, 1) if previous > 0 else None


def _kpi(current: int, previous: int) -> dict:
    return {"value": int(current), "previous": int(previous), "change_percent": _change(current, previous)}


async def _count(db: AsyncSession, store_id: str, column, lo: datetime, hi: datetime, *extra) -> int:
    return int((await db.execute(
        select(func.count()).select_from(StoreOrder).where(
            StoreOrder.store_id == store_id, column.is_not(None), column >= lo, column < hi, *extra,
        )
    )).scalar_one() or 0)


async def _events(db: AsyncSession, store_id: str, kinds: tuple[str, ...], lo: datetime, hi: datetime) -> int:
    return int((await db.execute(
        select(func.count(StoreOrderEvent.id))
        .join(StoreOrder, StoreOrder.id == StoreOrderEvent.order_id)
        .where(StoreOrder.store_id == store_id, StoreOrderEvent.kind.in_(kinds),
               StoreOrderEvent.created_at >= lo, StoreOrderEvent.created_at < hi)
    )).scalar_one() or 0)


async def _cart_adds(db: AsyncSession, store_id: str, start: date, end: date) -> int:
    return int((await db.execute(
        select(func.coalesce(func.sum(StoreDailyCount.count), 0)).where(
            StoreDailyCount.store_id == store_id, StoreDailyCount.kind == "cart_add",
            StoreDailyCount.day >= start, StoreDailyCount.day <= end,
        )
    )).scalar_one() or 0)


async def window_counts(db: AsyncSession, store_id: str, start: date, end: date) -> dict:
    """What happened in the window, each counted when it happened."""
    lo, hi = utc_bounds(start, end)
    completed_value = (await db.execute(
        select(func.coalesce(func.sum(StoreOrder.total_minor), 0)).where(
            StoreOrder.store_id == store_id, StoreOrder.status == lc.COMPLETED,
            StoreOrder.completed_at >= lo, StoreOrder.completed_at < hi,
        )
    )).scalar_one()
    return {
        "requests": await _count(db, store_id, StoreOrder.created_at, lo, hi),
        "accepted": await _count(db, store_id, StoreOrder.seller_responded_at, lo, hi),
        "proposals": await _events(db, store_id, (msg.SELLER_PROPOSED_CHANGES,), lo, hi),
        "declined": await _events(db, store_id, (msg.SELLER_DECLINED,), lo, hi),
        "confirmed": await _count(db, store_id, StoreOrder.buyer_confirmed_at, lo, hi),
        "dispatched": await _events(db, store_id, (msg.DISPATCHED, msg.READY_FOR_PICKUP), lo, hi),
        "completed": await _count(db, store_id, StoreOrder.completed_at, lo, hi,
                                  StoreOrder.status == lc.COMPLETED),
        "cancelled": await _events(db, store_id, (msg.BUYER_CANCELLED, msg.SELLER_CANCELLED), lo, hi),
        "expired": await _events(db, store_id, (msg.EXPIRED,), lo, hi),
        "cart_additions": await _cart_adds(db, store_id, start, end),
        "completed_value_minor": int(completed_value or 0),
    }


async def cohort(db: AsyncSession, store_id: str, start: date, end: date) -> dict:
    """Of the orders created in the window: how many the store answered,
    the buyer confirmed, and the buyer confirmed receiving - so far."""
    lo, hi = utc_bounds(start, end)
    row = (await db.execute(
        select(
            func.count(StoreOrder.id),
            func.count(StoreOrder.seller_responded_at),
            func.count(StoreOrder.buyer_confirmed_at),
            func.count(StoreOrder.completed_at),
        ).where(StoreOrder.store_id == store_id, StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
    )).one()
    return {"created": int(row[0] or 0), "answered": int(row[1] or 0),
            "confirmed": int(row[2] or 0), "completed": int(row[3] or 0)}


async def pipeline(db: AsyncSession, store_id: str, now: Optional[datetime] = None) -> dict:
    """Open orders right now, by what they are waiting for."""
    now = now or datetime.utcnow()
    rows = dict((await db.execute(
        select(StoreOrder.status, func.count()).where(
            StoreOrder.store_id == store_id, StoreOrder.status.in_(lc.OPEN),
        ).group_by(StoreOrder.status)
    )).all())
    stale = int((await db.execute(
        select(func.count()).select_from(StoreOrder).where(
            StoreOrder.store_id == store_id, StoreOrder.status == lc.SUBMITTED,
            StoreOrder.created_at < now - timedelta(hours=24),
        )
    )).scalar_one() or 0)
    n = lambda *statuses: sum(int(rows.get(s, 0)) for s in statuses)  # noqa: E731
    return {
        "awaiting_store": n(lc.SUBMITTED),
        "awaiting_buyer": n(lc.SELLER_PROPOSED_CHANGES, lc.AWAITING_BUYER_CONFIRMATION),
        "to_fulfil": n(lc.CONFIRMED, lc.PREPARING),
        "ready_or_dispatched": n(lc.READY_FOR_PICKUP, lc.DISPATCHED),
        "delivered_awaiting_buyer": n(lc.DELIVERED),
        "open_total": n(*lc.OPEN),
        # Requests a day old with no answer: a buyer waiting.
        "stale_requests": stale,
    }


async def series(db: AsyncSession, store_id: str, start: date, end: date) -> dict:
    """Requests and completions per Kenyan day, every day present."""
    lo, hi = utc_bounds(start, end)
    days = (end - start).days + 1
    requests = {start + timedelta(days=i): 0 for i in range(days)}
    completed = dict(requests)
    for (created,) in (await db.execute(
        select(StoreOrder.created_at).where(
            StoreOrder.store_id == store_id, StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
    )).all():
        d = kenya_day(created)
        if d in requests:
            requests[d] += 1
    for (done,) in (await db.execute(
        select(StoreOrder.completed_at).where(
            StoreOrder.store_id == store_id, StoreOrder.status == lc.COMPLETED,
            StoreOrder.completed_at >= lo, StoreOrder.completed_at < hi)
    )).all():
        d = kenya_day(done)
        if d in completed:
            completed[d] += 1
    return {
        "requests": [{"date": d.isoformat(), "count": c} for d, c in requests.items()],
        "completed": [{"date": d.isoformat(), "count": c} for d, c in completed.items()],
    }


async def top_products(db: AsyncSession, store_id: str, start: date, end: date, limit: int = 5) -> list[dict]:
    """Products by genuine order activity in the window: requests that named
    them, units asked for, and units in orders the buyer confirmed receiving."""
    lo, hi = utc_bounds(start, end)
    rows = (await db.execute(
        select(
            StoreOrderItem.listing_id,
            func.max(StoreOrderItem.name),
            func.count(func.distinct(StoreOrderItem.order_id)),
            func.coalesce(func.sum(StoreOrderItem.requested_quantity), 0),
        )
        .join(StoreOrder, StoreOrder.id == StoreOrderItem.order_id)
        .where(StoreOrder.store_id == store_id, StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
        .group_by(StoreOrderItem.listing_id)
        .order_by(func.count(func.distinct(StoreOrderItem.order_id)).desc())
        .limit(limit)
    )).all()
    if not rows:
        return []
    ids = [r[0] for r in rows]
    completed_units = dict((await db.execute(
        select(StoreOrderItem.listing_id, func.coalesce(func.sum(StoreOrderItem.final_quantity), 0))
        .join(StoreOrder, StoreOrder.id == StoreOrderItem.order_id)
        .where(StoreOrder.store_id == store_id, StoreOrder.status == lc.COMPLETED,
               StoreOrderItem.listing_id.in_(ids),
               StoreOrder.completed_at >= lo, StoreOrder.completed_at < hi)
        .group_by(StoreOrderItem.listing_id)
    )).all())
    return [{
        "id": listing_id, "name": name, "requests": int(requests or 0),
        "units_requested": int(units or 0), "units_completed": int(completed_units.get(listing_id, 0) or 0),
    } for listing_id, name, requests, units in rows]


async def not_converting(db: AsyncSession, store_id: str, start: date, end: date, limit: int = 3) -> list[dict]:
    """The store's most viewed live products that no order request named in
    the window. Views are the listing's counted views (all time); the
    window applies to the requests."""
    lo, hi = utc_bounds(start, end)
    ordered = select(StoreOrderItem.listing_id).join(
        StoreOrder, StoreOrder.id == StoreOrderItem.order_id,
    ).where(StoreOrder.store_id == store_id, StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
    rows = (await db.execute(
        select(Listing.id, Listing.name, Listing.views)
        .where(Listing.store_id == store_id, Listing.status == ListingStatus.active,
               Listing.views > 0, Listing.id.not_in(ordered))
        .order_by(Listing.views.desc()).limit(limit)
    )).all()
    return [{"id": i, "name": n, "views": int(v or 0)} for i, n, v in rows]


async def by_source(db: AsyncSession, store_id: str, start: date, end: date) -> dict:
    """Requests and completed orders by where the buyer came from (?via=)."""
    lo, hi = utc_bounds(start, end)
    out: dict[str, dict] = defaultdict(lambda: {"requests": 0, "completed": 0})
    for source, status, n in (await db.execute(
        select(StoreOrder.source_channel, StoreOrder.status, func.count())
        .where(StoreOrder.store_id == store_id, StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
        .group_by(StoreOrder.source_channel, StoreOrder.status)
    )).all():
        key = source or "direct"
        out[key]["requests"] += int(n or 0)
        if status == lc.COMPLETED:
            out[key]["completed"] += int(n or 0)
    return dict(out)


async def by_campaign(db: AsyncSession, store_id: str, start: date, end: date) -> list[dict]:
    """Requests, buyer-confirmed and completed orders per Marketing Studio
    campaign, for orders that arrived through the campaign's tracked link."""
    from api.models.marketing import MarketingCampaign

    lo, hi = utc_bounds(start, end)
    rows = (await db.execute(
        select(
            StoreOrder.campaign_id, func.max(MarketingCampaign.title),
            func.count(StoreOrder.id), func.count(StoreOrder.buyer_confirmed_at),
            func.count(StoreOrder.completed_at),
        )
        .join(MarketingCampaign, MarketingCampaign.id == StoreOrder.campaign_id)
        .where(StoreOrder.store_id == store_id, StoreOrder.campaign_id.is_not(None),
               StoreOrder.created_at >= lo, StoreOrder.created_at < hi)
        .group_by(StoreOrder.campaign_id)
        .order_by(func.count(StoreOrder.id).desc())
    )).all()
    return [{"campaign_id": cid, "title": title, "requests": int(r or 0),
             "confirmed": int(c or 0), "completed": int(done or 0)}
            for cid, title, r, c, done in rows]


async def campaign_orders(db: AsyncSession, campaign_id: str) -> dict:
    """All-time order counts for one campaign (Marketing Studio)."""
    row = (await db.execute(
        select(func.count(StoreOrder.id), func.count(StoreOrder.buyer_confirmed_at),
               func.count(StoreOrder.completed_at))
        .where(StoreOrder.campaign_id == campaign_id)
    )).one()
    return {"order_requests": int(row[0] or 0), "confirmed_orders": int(row[1] or 0),
            "completed_orders": int(row[2] or 0)}


RATE_DEFINITIONS = {
    "view_to_request": "Order requests made in the period, per 100 product views in the period.",
    "request_to_acceptance": "Of the order requests made in the period, the share the store accepted "
                             "or answered with changes.",
    "acceptance_to_confirmation": "Of those the store answered, the share the buyer confirmed.",
    "confirmed_to_completed": "Of those the buyer confirmed, the share the buyer has confirmed receiving.",
    "completion_rate": "Of the order requests made in the period, the share completed so far.",
}

DEFINITIONS = {
    "requests": "Order requests buyers sent in the period. A request is not a sale.",
    "accepted": "Requests the store first answered in the period - accepted, or with changes proposed.",
    "confirmed": "Orders whose final details the buyer confirmed in the period.",
    "completed": "Orders the buyer confirmed receiving in the period.",
    "cart_additions": "Times a product went into a cart (once per visitor and product per half hour). "
                      "Interest, not an order.",
    "completed_value": "Agreed totals of the orders completed in the period. Payment is arranged "
                       "between buyer and store outside BROKA and is not verified, so this is not revenue.",
    "cohort_note": "Rates follow the requests made in the period; recent ones may still be in progress.",
}


async def orders_block(db: AsyncSession, store: Store, *, start: date, end: date,
                       prev_start: date, prev_end: date, product_views: int,
                       views_available: bool) -> dict:
    """The orders section of GET /stores/{id}/insights."""
    cur = await window_counts(db, store.id, start, end)
    prev = await window_counts(db, store.id, prev_start, prev_end)
    group = await cohort(db, store.id, start, end)

    def rate(key: str, numerator: int, denominator: int) -> dict:
        return {"key": key, "numerator": int(numerator), "denominator": int(denominator),
                "percent": _pct(numerator, denominator), "definition": RATE_DEFINITIONS[key]}

    rates = []
    if views_available:
        rates.append(rate("view_to_request", group["created"], product_views))
    rates.extend([
        rate("request_to_acceptance", group["answered"], group["created"]),
        rate("acceptance_to_confirmation", group["confirmed"], group["answered"]),
        rate("confirmed_to_completed", group["completed"], group["confirmed"]),
        rate("completion_rate", group["completed"], group["created"]),
    ])
    keys = ("requests", "accepted", "proposals", "declined", "confirmed", "dispatched",
            "completed", "cancelled", "expired", "cart_additions")
    return {
        "enabled": bool(settings.store_orders_enabled),
        "accepting": bool(getattr(store, "accepting_orders", True)),
        "currency": "KES",
        "kpis": {k: _kpi(cur[k], prev[k]) for k in keys},
        "completed_value_minor": cur["completed_value_minor"],
        "previous_completed_value_minor": prev["completed_value_minor"],
        "cohort": group,
        "rates": rates,
        "pipeline": await pipeline(db, store.id),
        "series": await series(db, store.id, start, end),
        "top_products": await top_products(db, store.id, start, end),
        "not_converting": await not_converting(db, store.id, start, end),
        "by_source": await by_source(db, store.id, start, end),
        "by_campaign": await by_campaign(db, store.id, start, end),
        "definitions": DEFINITIONS,
    }
