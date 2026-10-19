"""What a store owner actually needs to know — the store dashboard's data.

WHY THIS IS A SEPARATE MODULE FROM stats.py
===========================================
`stats.py` counts visits and shares. That is real, but it answers "did
anyone open the door", not "is the shop working". A seller deciding what to
do this week needs product views, saves, interested buyers, conversations,
reply speed and a rating they can move — the same things the seller
dashboard shows, scoped to one shop.

EVERY NUMBER HERE IS MEASURED, AND A MISSING ONE IS MISSING
===========================================================
No extrapolation, no "estimated reach". Where a source cannot answer for
the whole period (product views need a snapshot covering the period's
start), the block says so with `exact: false` and the client labels it,
rather than presenting a partial count as a total. Same rule the seller
metrics endpoint follows.

PERIODS AND DELTAS
==================
Every KPI carries the current period and the period immediately before it,
so "312 views, up 18%" is computed here and not guessed in the app. The
previous period is the same number of days ending the day before the
current one starts.

STORE-SCOPED BY CONSTRUCTION
============================
Every query joins through `listings.store_id`. A seller with two shops sees
each shop's own traffic, conversations and reply time; nothing leaks from
one to the other.

LIVE VISITORS
=============
`stats.live_visitors` is a Redis sorted set (in-process fallback) of
visitors seen in the last five minutes. It is a real count of people who
opened the shop recently — not a model estimate — and it is labelled as
"in the last 5 minutes" on the screen for exactly that reason.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Dict, Iterable, List, Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import (
    Interest, Listing, ListingLike, ListingMetricSnapshot, ListingStatus,
    NegotiationMessage, Wishlist,
)
from api.models.store import Store, StoreDailyCount
from api.domains.listings.paid import live_clause
from . import stats as store_stats


def _day(value) -> date:
    return value.date() if isinstance(value, datetime) else value


def _period_bounds(day: date, days: int) -> tuple[date, date, date, date]:
    """(start, end, prev_start, prev_end) for a `days`-day window ending
    `day`, and the window immediately before it."""
    end = day
    start = end - timedelta(days=days - 1)
    prev_end = start - timedelta(days=1)
    prev_start = prev_end - timedelta(days=days - 1)
    return start, end, prev_start, prev_end


def _pct_change(current: float, previous: float) -> Optional[float]:
    """Percent change, or None when there is no previous value to compare
    against. A jump from zero is not "+100%" - it is "new", and the app says
    so when this is null and `current > 0`."""
    if previous <= 0:
        return None
    return round((current - previous) / previous * 100.0, 1)


# ── Counters ────────────────────────────────────────────────────────────────

async def _visit_and_share_totals(
    db: AsyncSession, store_id: str,
    windows: Iterable[tuple[date, date]],
) -> tuple[List[int], List[int]]:
    """(visits, shares) per window. They share a table and a shape, so one
    pass over the same rows answers both."""
    visits: List[int] = []
    shares: List[int] = []
    for start, end in windows:
        rows = (await db.execute(
            select(StoreDailyCount.kind, func.coalesce(func.sum(StoreDailyCount.count), 0))
            .where(
                StoreDailyCount.store_id == store_id,
                StoreDailyCount.day >= start,
                StoreDailyCount.day <= end,
            )
            .group_by(StoreDailyCount.kind)
        )).all()
        by_kind = {kind: int(total or 0) for kind, total in rows}
        visits.append(by_kind.get("visit", 0))
        shares.append(by_kind.get("share", 0))
    return visits, shares


async def _engagement_totals(
    db: AsyncSession, store_id: str,
    windows: Iterable[tuple[date, date]],
) -> Dict[str, List[int]]:
    """Saves, likes and interested buyers per window.

    All three tables carry `created_at`, so the period counts are exact.
    Scoped to the store's listings, so a seller's personal listings do not
    inflate the shop's numbers.
    """
    store_listings = select(Listing.id).where(Listing.store_id == store_id)
    out = {"saves": [], "likes": [], "interested": []}
    for start, end in windows:
        lo = datetime.combine(start, datetime.min.time())
        hi = datetime.combine(end + timedelta(days=1), datetime.min.time())
        saves = (await db.execute(
            select(func.count(Wishlist.id)).where(
                Wishlist.listing_id.in_(store_listings),
                Wishlist.created_at >= lo, Wishlist.created_at < hi,
            )
        )).scalar_one()
        likes = (await db.execute(
            select(func.count(ListingLike.id)).where(
                ListingLike.listing_id.in_(store_listings),
                ListingLike.created_at >= lo, ListingLike.created_at < hi,
            )
        )).scalar_one()
        interested = (await db.execute(
            select(func.count(func.distinct(Interest.buyer_id))).where(
                Interest.listing_id.in_(store_listings),
                Interest.created_at >= lo, Interest.created_at < hi,
            )
        )).scalar_one()
        out["saves"].append(int(saves or 0))
        out["likes"].append(int(likes or 0))
        out["interested"].append(int(interested or 0))
    return out


async def _conversation_totals(
    db: AsyncSession, store_id: str,
    windows: Iterable[tuple[date, date]],
) -> Dict[str, List[int]]:
    """Messages sent to/about the shop, and new conversations, per window.

    A conversation is one (listing, buyer) thread. Counting distinct pairs
    answers "how many new buyers wrote", which a raw message count cannot:
    twenty messages from one buyer is not twenty customers.
    """
    out = {"messages": [], "threads": []}
    for start, end in windows:
        lo = datetime.combine(start, datetime.min.time())
        hi = datetime.combine(end + timedelta(days=1), datetime.min.time())
        messages = (await db.execute(
            # visibility-ok: counts rows for the owner's own stats; selects no
            # content anywhere in this statement, so no audience can be leaked
            select(func.count(NegotiationMessage.id))
            .join(Listing, Listing.id == NegotiationMessage.listing_id)
            .where(
                Listing.store_id == store_id,
                NegotiationMessage.created_at >= lo,
                NegotiationMessage.created_at < hi,
                NegotiationMessage.buyer_id.is_not(None),
            )
        )).scalar_one()
        # DISTINCT over the pair, not a string concat: portable across
        # SQLite and PostgreSQL and it cannot collide on ids containing '|'.
        pairs = (await db.execute(
            # visibility-ok: reads listing and buyer ids to count distinct
            # threads; no message content and no per-message row is returned
            select(NegotiationMessage.listing_id, NegotiationMessage.buyer_id)
            .join(Listing, Listing.id == NegotiationMessage.listing_id)
            .where(
                Listing.store_id == store_id,
                NegotiationMessage.created_at >= lo,
                NegotiationMessage.created_at < hi,
                NegotiationMessage.buyer_id.is_not(None),
            )
            .distinct()
        )).all()
        out["messages"].append(int(messages or 0))
        out["threads"].append(len(pairs))
    return out


async def _view_deltas(
    db: AsyncSession, store_id: str, start: date, end: date,
) -> Optional[dict]:
    """Daily NEW product views inside [start, end], from daily snapshots.

    `Listing.views` is cumulative and never reset, so a period's views are
    only knowable if a snapshot exists at or before the period's first day.

    Returns None when the history does not cover the window at all, and
    `exact: False` when it covers only some of the store's listings - a
    partial count must never be presented as a total. The caller reports
    "since tracking began" in that case instead of pretending the lifetime
    counter is a weekly number.
    """
    rows = (await db.execute(
        select(
            ListingMetricSnapshot.listing_id,
            ListingMetricSnapshot.snapshot_date,
            ListingMetricSnapshot.views,
        )
        .join(Listing, Listing.id == ListingMetricSnapshot.listing_id)
        .where(
            Listing.store_id == store_id,
            ListingMetricSnapshot.snapshot_date >= start - timedelta(days=1),
            ListingMetricSnapshot.snapshot_date <= end,
        )
        .order_by(ListingMetricSnapshot.listing_id, ListingMetricSnapshot.snapshot_date)
    )).all()
    if not rows:
        return None

    # Every listing with a row in the window needs a baseline strictly
    # before `start`, or its first day's delta would be its whole lifetime.
    covered: Dict[str, int] = {}
    seen_in_window: set[str] = set()
    by_day: Dict[date, int] = {start + timedelta(days=i): 0 for i in range((end - start).days + 1)}
    for listing_id, day, views in rows:
        day = _day(day)
        views = int(views or 0)
        if day < start:
            covered[listing_id] = views
            continue
        seen_in_window.add(listing_id)
        if listing_id not in covered:
            continue
        delta = max(0, views - covered[listing_id])
        covered[listing_id] = views
        if day in by_day:
            by_day[day] += delta
    if not covered:
        return None
    return {
        "by_day": [{"date": d.isoformat(), "count": n} for d, n in by_day.items()],
        # True only when every listing seen in the window had a baseline.
        "exact": seen_in_window <= set(covered),
    }


# ── Series ──────────────────────────────────────────────────────────────────

async def _visit_series(
    db: AsyncSession, store_id: str, start: date, end: date,
) -> List[dict]:
    rows = dict((_day(day), int(n or 0)) for day, n in (await db.execute(
        select(StoreDailyCount.day, func.sum(StoreDailyCount.count))
        .where(
            StoreDailyCount.store_id == store_id,
            StoreDailyCount.kind == "visit",
            StoreDailyCount.day >= start, StoreDailyCount.day <= end,
        )
        .group_by(StoreDailyCount.day)
    )).all())
    return [
        {"date": (start + timedelta(days=i)).isoformat(),
         "count": rows.get(start + timedelta(days=i), 0)}
        for i in range((end - start).days + 1)
    ]


async def _chat_series(
    db: AsyncSession, store_id: str, start: date, end: date,
) -> List[dict]:
    lo = datetime.combine(start, datetime.min.time())
    hi = datetime.combine(end + timedelta(days=1), datetime.min.time())
    rows = (await db.execute(
        # visibility-ok: counts messages per day for the owner's chart;
        # selects only the date and a count, never content
        select(func.date(NegotiationMessage.created_at), func.count(NegotiationMessage.id))
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(
            Listing.store_id == store_id,
            NegotiationMessage.created_at >= lo,
            NegotiationMessage.created_at < hi,
            NegotiationMessage.buyer_id.is_not(None),
        )
        .group_by(func.date(NegotiationMessage.created_at))
    )).all()
    by_day: Dict[str, int] = {}
    for day, n in rows:
        key = _day(day)
        by_day[str(key)] = int(n or 0)
    return [
        {"date": (start + timedelta(days=i)).isoformat(),
         "count": by_day.get(str(start + timedelta(days=i)), 0)}
        for i in range((end - start).days + 1)
    ]


# ── Products ────────────────────────────────────────────────────────────────

async def _top_products(db: AsyncSession, store_id: str, limit: int = 5) -> List[dict]:
    listings = (await db.execute(
        select(Listing)
        .where(
            Listing.store_id == store_id,
            Listing.status.in_([ListingStatus.active, ListingStatus.pending,
                                ListingStatus.completed]),
        )
        .order_by(Listing.views.desc())
        .limit(limit)
    )).scalars().all()
    if not listings:
        return []
    ids = [l.id for l in listings]
    saves = dict((await db.execute(
        select(Wishlist.listing_id, func.count(Wishlist.id))
        .where(Wishlist.listing_id.in_(ids)).group_by(Wishlist.listing_id)
    )).all())
    likes = dict((await db.execute(
        select(ListingLike.listing_id, func.count(ListingLike.id))
        .where(ListingLike.listing_id.in_(ids)).group_by(ListingLike.listing_id)
    )).all())
    interested = dict((await db.execute(
        select(Interest.listing_id, func.count(func.distinct(Interest.buyer_id)))
        .where(Interest.listing_id.in_(ids)).group_by(Interest.listing_id)
    )).all())
    return [
        {
            "id": l.id,
            "name": l.name,
            "price": float(l.price) if l.price is not None else None,
            "views": int(l.views or 0),
            "saves": int(saves.get(l.id, 0)),
            "likes": int(likes.get(l.id, 0)),
            "interested_buyers": int(interested.get(l.id, 0)),
            "state": getattr(l.status, "value", l.status),
        }
        for l in listings
    ]


# ── Rank ────────────────────────────────────────────────────────────────────

async def _rank(db: AsyncSession, store: Store) -> tuple[Optional[int], int]:
    """(position, total) among live stores by rating, 1 = best.

    One subquery, counted twice. Selecting Store.id and Store.rating into it
    (rather than filtering a bare `select(Store.id)`) keeps the outer count
    off the stores table: mixing a select_from(subquery) with a Store
    column in WHERE adds stores to the FROM list and silently turns the
    count into a cartesian product.
    """
    live = (
        select(Store.id, Store.rating)
        .where(Store.is_active.is_(True), Store.deleted_at.is_(None))
        .subquery()
    )
    total = (await db.execute(
        select(func.count()).select_from(live)
    )).scalar_one()
    if store.rating is None:
        return None, int(total or 0)
    better = (await db.execute(
        select(func.count()).select_from(live).where(live.c.rating > store.rating)
    )).scalar_one()
    return int(better or 0) + 1, int(total or 0)


# ── Advice ──────────────────────────────────────────────────────────────────

def build_advice(
    *,
    rating: Optional[float],
    review_count: int,
    response_minutes: Optional[float],
    visits_now: int,
    visits_before: int,
    saves: int,
    chats: int,
    views_available: bool,
    product_views: int,
    products: int,
) -> Dict[str, List[dict]]:
    """Concrete, number-backed cards. No model call, no adjectives without
    a figure behind them — the rule `trust/seller_advice.py` follows, for
    the same reason: advice that cannot cite a number is decoration.

    At most three positives and four negatives; a wall of cards is skipped.
    Negatives sort worst-first.
    """
    pos: List[dict] = []
    neg: List[dict] = []

    if rating is not None:
        if rating >= 8.0:
            pos.append({
                "code": "rating_high", "severity": 0,
                "title": "Buyers rate this shop highly",
                "detail": f"{rating:.1f}/10 from {review_count} review"
                          f"{'s' if review_count != 1 else ''}. Keep the "
                          "photos and descriptions as they are.",
            })
        elif rating < 6.0:
            neg.append({
                "code": "rating_low", "severity": 3,
                "title": "The shop's rating is holding it back",
                "detail": f"{rating:.1f}/10. Reviews and reply speed are the "
                          "two levers you can move this week.",
            })

    if review_count == 0:
        neg.append({
            "code": "no_reviews", "severity": 2,
            "title": "No reviews yet",
            "detail": "Ask buyers who collected an item to leave one. A shop "
                      "with no reviews sits on the neutral score, below any "
                      "shop with a real record.",
        })

    if response_minutes is not None:
        if response_minutes <= 30:
            pos.append({
                "code": "fast_replies", "severity": 0,
                "title": "You answer fast",
                "detail": f"About {round(response_minutes)} min on average. "
                          "Reply speed is 30% of the store rating.",
            })
        elif response_minutes >= 180:
            neg.append({
                "code": "slow_replies", "severity": 4,
                "title": "Buyers wait too long for an answer",
                "detail": f"About {round(response_minutes)} min on average. "
                          "Past three hours most buyers have moved on.",
            })
    else:
        neg.append({
            "code": "unmeasured_replies", "severity": 1,
            "title": "Your reply time is not measured yet",
            "detail": "Answer three buyer conversations and the rating starts "
                      "counting your real speed instead of the neutral default.",
        })

    change = _pct_change(visits_now, visits_before)
    if change is not None and change <= -20:
        neg.append({
            "code": "visits_down", "severity": 3,
            "title": "Fewer people opened the shop",
            "detail": f"{visits_now} visits, {abs(change):.0f}% fewer than the "
                      f"previous period. Share the link again on WhatsApp.",
        })
    elif change is not None and change >= 20:
        pos.append({
            "code": "visits_up", "severity": 0,
            "title": "More people are finding the shop",
            "detail": f"{visits_now} visits, {change:.0f}% more than the "
                      "previous period.",
        })

    if views_available and product_views > 0 and chats == 0:
        neg.append({
            "code": "views_no_chats", "severity": 3,
            "title": "People look but nobody writes",
            "detail": f"{product_views} product views and no conversations. "
                      "Check that prices and photos answer the obvious question "
                      "before a buyer has to ask it.",
        })

    if saves > 0 and chats == 0:
        neg.append({
            "code": "saves_no_chats", "severity": 2,
            "title": "Saved, but not bought",
            "detail": f"{saves} save{'s' if saves != 1 else ''} and no messages. "
                      "That gap is usually price — review the top product's.",
        })

    if products == 0:
        neg.append({
            "code": "empty_shop", "severity": 5,
            "title": "The shop has no products",
            "detail": "Add at least one product; a shop with an empty window "
                      "cannot be rated or found in category browsing.",
        })

    neg.sort(key=lambda c: -c["severity"])
    return {"positives": pos[:3], "negatives": neg[:4]}


# ── The endpoint payload ────────────────────────────────────────────────────

async def insights_for(db: AsyncSession, store: Store, days: int = 7) -> dict:
    """Everything the store dashboard draws, in one response.

    One request per refresh rather than a dozen: the screen opens on a
    phone connection, and each extra round trip is felt.
    """
    days = max(1, min(days, store_stats.MAX_STATS_DAYS))
    today = store_stats.today()
    start, end, prev_start, prev_end = _period_bounds(today, days)
    windows = [(start, end), (prev_start, prev_end)]

    visits, shares = await _visit_and_share_totals(db, store.id, windows)
    visits_now, visits_before = visits
    engagement = await _engagement_totals(db, store.id, windows)
    conversations = await _conversation_totals(db, store.id, windows)

    view_block = await _view_deltas(db, store.id, start, end)
    views_available = view_block is not None
    product_views = sum(d["count"] for d in view_block["by_day"]) if view_block else 0
    views_exact = bool(view_block and view_block["exact"])
    # The previous period's views are only comparable when the snapshot
    # history reaches back that far too; otherwise the delta is withheld.
    prev_view_block = await _view_deltas(db, store.id, prev_start, prev_end)
    views_before = (sum(d["count"] for d in prev_view_block["by_day"])
                    if view_block is not None and prev_view_block is not None else None)

    products = (await db.execute(
        select(func.count()).select_from(Listing).where(
            Listing.store_id == store.id,
            Listing.status == ListingStatus.active,
            live_clause(),
        )
    )).scalar_one()

    rating_block = await _rating_block(db, store)
    position, total = await _rank(db, store)
    top = await _top_products(db, store.id)
    live_now = await store_stats.live_visitors(store.id)

    def kpi(current: int, previous: Optional[int]) -> dict:
        return {
            "value": int(current),
            "previous": int(previous) if previous is not None else None,
            "change_percent": _pct_change(current, previous or 0)
                              if previous is not None else None,
        }

    series_visits = await _visit_series(db, store.id, start, end)
    series_chats = await _chat_series(db, store.id, start, end)

    advice = build_advice(
        rating=rating_block.get("rating"),
        review_count=int(rating_block.get("review_count") or 0),
        response_minutes=rating_block.get("response_minutes"),
        visits_now=visits_now,
        visits_before=visits_before,
        saves=engagement["saves"][0],
        chats=conversations["threads"][0],
        views_available=views_available,
        product_views=product_views,
        products=int(products or 0),
    )

    return {
        "store": {
            "id": store.id,
            "name": store.name,
            "slug": store.slug,
            "is_active": bool(store.is_active),
            "rating": rating_block.get("rating"),
            "rating_breakdown": rating_block.get("breakdown"),
            "rating_explanation": rating_block.get("explanation"),
            "review_count": int(rating_block.get("review_count") or 0),
            "response_minutes": rating_block.get("response_minutes"),
            "rank": position,
            "stores_total": total,
            "products": int(products or 0),
            "live_visitors": live_now,
        },
        "period": {
            "days": days,
            "from": start.isoformat(),
            "to": end.isoformat(),
            "previous_from": prev_start.isoformat(),
            "previous_to": prev_end.isoformat(),
        },
        "kpis": {
            "visits": kpi(visits_now, visits_before),
            "product_views": {
                **kpi(product_views, views_before),
                # False when the snapshot history does not cover every
                # listing: the app labels the figure "since tracking began"
                # rather than "this week".
                "exact": views_exact,
            },
            "saves": kpi(engagement["saves"][0], engagement["saves"][1]),
            "likes": kpi(engagement["likes"][0], engagement["likes"][1]),
            "interested_buyers": kpi(
                engagement["interested"][0], engagement["interested"][1]),
            "chats": kpi(conversations["threads"][0], conversations["threads"][1]),
            "messages": kpi(
                conversations["messages"][0], conversations["messages"][1]),
            "shares": kpi(shares[0], shares[1]),
        },
        "series": {
            "visits": series_visits,
            "product_views": view_block["by_day"] if view_block else None,
            "chats": series_chats,
        },
        "sources": await _sources(db, store.id, start, end),
        "top_products": top,
        "advice": advice,
        "generated_at": datetime.utcnow().isoformat(),
    }


async def _rating_block(db: AsyncSession, store: Store) -> dict:
    from .rating import rating_payload
    return await rating_payload(db, store, owner_view=True)


async def _sources(db: AsyncSession, store_id: str, start: date, end: date) -> dict:
    rows = (await db.execute(
        select(
            StoreDailyCount.kind, StoreDailyCount.surface,
            StoreDailyCount.source, func.sum(StoreDailyCount.count),
        )
        .where(
            StoreDailyCount.store_id == store_id,
            StoreDailyCount.day >= start, StoreDailyCount.day <= end,
        )
        .group_by(StoreDailyCount.kind, StoreDailyCount.surface, StoreDailyCount.source)
    )).all()
    by_source = {s: 0 for s in store_stats.VISIT_SOURCES}
    by_surface = {s: 0 for s in store_stats.SURFACES}
    by_channel = {c: 0 for c in store_stats.SHARE_CHANNELS}
    for kind, surface, source, count in rows:
        count = int(count or 0)
        if kind == "visit":
            by_source[source if source in by_source else "other"] += count
            if surface in by_surface:
                by_surface[surface] += count
        elif kind == "share":
            by_channel[source if source in by_channel else "other"] += count
    return {
        "visits_by_source": by_source,
        "visits_by_surface": by_surface,
        "shares_by_channel": by_channel,
    }
