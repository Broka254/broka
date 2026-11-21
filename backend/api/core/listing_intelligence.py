"""Listing intelligence: what is popular, what is growing, what is stuck.

Every number here is a count of rows that exist, per listing, inside a window.
Two honesty rules shape the code:

* `Listing.views` is a lifetime counter with no history, so a *windowed* view
  count cannot come from it. Windowed "views" are `listing_views` rows - the
  first time an account saw the listing - which is a unique-viewer count, not
  a pageview count. Repeat views are not stored anywhere and are not claimed.
* A negotiation is a conversation, not a sale. Nothing here reports conversion
  from engagement alone; `deals` is only present when a real Deal row links the
  listing.

The trending score is deliberately simple and disclosed in the response:
weighted engagement in the window, multiplied by growth against the window
immediately before it. Weights are constants, not learned, and every input is
a distinct-actor count so one buyer cannot inflate a listing by clicking.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import (
    Interest,
    Listing,
    ListingLike,
    ListingView,
    NegotiationMessage,
    User,
    Wishlist,
)

# Disclosed in every response (`model.weights`), so a ranking can be explained
# rather than asserted.
WEIGHTS = {
    "unique_viewers": 1.0,
    "saves": 3.0,
    "likes": 2.0,
    "contacts": 4.0,
    "negotiations": 5.0,
}

WINDOWS = {"24h": 1, "7d": 7, "30d": 30}
DEFAULT_LIMIT = 25
MAX_LIMIT = 100

# Growth is clamped: a listing going 0 -> 3 is interesting, not infinite, and
# one that collapsed must not produce a negative score that outranks nothing.
GROWTH_MIN = -0.9
GROWTH_MAX = 3.0

# Insight thresholds. Named, fixed and visible in the payload so an operator
# can see why a listing was flagged rather than trusting an opaque score.
LOW_ENGAGEMENT_RATE = 0.02      # interactions per unique viewer
HIGH_INTEREST_VIEWERS = 20      # enough viewers to make the rate meaningful
DECLINING_GROWTH = -0.5         # lost more than half its engagement


def _now() -> datetime:
    return datetime.utcnow()


def parse_range(
    *, window: str = "7d", from_raw: Optional[str] = None, to_raw: Optional[str] = None
) -> tuple[datetime, datetime, str]:
    """Half-open UTC [start, end), plus the label the UI should show."""
    from api.core.timeutil import parse_iso_to_naive_utc

    if from_raw or to_raw:
        end = parse_iso_to_naive_utc(to_raw) if to_raw else _now()
        start = (
            parse_iso_to_naive_utc(from_raw)
            if from_raw
            else end - timedelta(days=WINDOWS.get(window, 7))
        )
        if start >= end:
            raise ValueError("from must be before to")
        if end - start > timedelta(days=366):
            raise ValueError("the range may be at most 366 days")
        return start, end, "custom"
    days = WINDOWS.get(window)
    if days is None:
        raise ValueError("window must be one of 24h, 7d, 30d")
    end = _now()
    return end - timedelta(days=days), end, window


async def _counts(
    db: AsyncSession, model, timestamp_column, actor_column, start: datetime, end: datetime
) -> dict[str, int]:
    """Distinct actors per listing in the window."""
    rows = (
        await db.execute(
            select(model.listing_id, func.count(func.distinct(actor_column)))
            .where(timestamp_column >= start, timestamp_column < end)
            .group_by(model.listing_id)
        )
    ).all()
    return {listing_id: int(count or 0) for listing_id, count in rows if listing_id}


async def _window_counts(
    db: AsyncSession, start: datetime, end: datetime
) -> dict[str, dict[str, int]]:
    from api.database import ListingView as View, Wishlist as Saved

    return {
        "unique_viewers": await _counts(db, View, View.created_at, View.viewer_id, start, end),
        "saves": await _counts(db, Saved, Saved.created_at, Saved.user_id, start, end),
        "likes": await _counts(db, ListingLike, ListingLike.created_at, ListingLike.user_id, start, end),
        "contacts": await _counts(db, Interest, Interest.created_at, Interest.buyer_id, start, end),
        "negotiations": await _counts(
            db,
            NegotiationMessage,
            NegotiationMessage.created_at,
            NegotiationMessage.buyer_id,
            start,
            end,
        ),
    }


def _score(metrics: dict[str, int]) -> float:
    return round(
        sum(WEIGHTS[key] * metrics.get(key, 0) for key in WEIGHTS), 2
    )


def _growth(current: float, previous: float) -> float:
    if previous <= 0:
        # Nothing before: growth is undefined, and "infinitely viral" is not a
        # claim this system makes. A listing with no prior activity grows by
        # at most the clamp's upper bound, never by a division-by-zero.
        return 1.0 if current > 0 else 0.0
    value = (current - previous) / previous
    return round(max(GROWTH_MIN, min(GROWTH_MAX, value)), 3)


async def rankings(
    db: AsyncSession,
    *,
    start: datetime,
    end: datetime,
    sort: str = "trending",
    limit: int = DEFAULT_LIMIT,
) -> dict:
    """Rank listings by one engagement signal, or by the documented score."""
    limit = max(1, min(limit, MAX_LIMIT))
    if sort not in (*WEIGHTS.keys(), "trending"):
        raise ValueError("sort must be one of trending, unique_viewers, saves, likes, contacts, negotiations")

    current = await _window_counts(db, start, end)
    previous: Optional[dict[str, dict[str, int]]] = None
    if sort == "trending":
        # Same-width window immediately before, so growth compares like with
        # like rather than a weekday against a weekend.
        previous = await _window_counts(db, start - (end - start), start)

    listing_ids: set[str] = set()
    for series in current.values():
        listing_ids.update(series)
    if not listing_ids:
        return _empty(start, end, sort)

    scored = []
    for listing_id in listing_ids:
        metrics = {key: current[key].get(listing_id, 0) for key in WEIGHTS}
        score = _score(metrics)
        row = {"listing_id": listing_id, "score": score, **metrics}
        if previous is not None:
            before = {
                key: previous[key].get(listing_id, 0) for key in WEIGHTS
            }
            growth = _growth(score, _score(before))
            row["previous_score"] = _score(before)
            row["growth"] = growth
            row["trending_score"] = round(max(0.0, score * (1 + growth)), 2)
        scored.append(row)

    key = "trending_score" if sort == "trending" else sort
    scored.sort(key=lambda item: (-item.get(key, 0), -item["score"], item["listing_id"]))
    top = scored[:limit]

    details = await _listing_rows(db, [row["listing_id"] for row in top])
    items = []
    for position, row in enumerate(top, start=1):
        listing = details.get(row["listing_id"])
        if listing is None:
            continue
        items.append(
            {
                "rank": position,
                **row,
                "listing": listing,
            }
        )

    return {
        "from": start.isoformat() + "Z",
        "to": end.isoformat() + "Z",
        "window_seconds": int((end - start).total_seconds()),
        "sort": sort,
        "limit": limit,
        "considered": len(scored),
        "model": {
            "weights": WEIGHTS,
            "formula": "score = sum(weight * distinct actors in window); trending_score = score * (1 + growth), growth clamped to [-0.9, 3]",
            "view_counting": "listing_views rows count the first time an account saw the listing; repeat views are not stored and are not counted.",
            "notes": "A negotiation is a conversation, not a sale. Engagement is never reported as conversion.",
        },
        "items": items,
    }


def _empty(start: datetime, end: datetime, sort: str) -> dict:
    return {
        "from": start.isoformat() + "Z",
        "to": end.isoformat() + "Z",
        "window_seconds": int((end - start).total_seconds()),
        "sort": sort,
        "limit": DEFAULT_LIMIT,
        "considered": 0,
        "model": {
            "weights": WEIGHTS,
            "formula": "score = sum(weight * distinct actors in window); trending_score = score * (1 + growth), growth clamped to [-0.9, 3]",
            "view_counting": "listing_views rows count the first time an account saw the listing; repeat views are not stored and are not counted.",
            "notes": "A negotiation is a conversation, not a sale. Engagement is never reported as conversion.",
        },
        "items": [],
    }


async def _listing_rows(db: AsyncSession, ids: list[str]) -> dict[str, dict]:
    if not ids:
        return {}
    rows = (
        await db.execute(
            select(Listing, User.name)
            .join(User, User.id == Listing.seller_id, isouter=True)
            .where(Listing.id.in_(ids))
        )
    ).all()
    out = {}
    for listing, seller_name in rows:
        out[listing.id] = {
            "id": listing.id,
            "name": listing.name,
            "seller_id": listing.seller_id,
            "seller_name": seller_name,
            "category": listing.category,
            "price": float(listing.price or 0),
            "status": getattr(listing.status, "value", listing.status),
            "location_county": listing.location_county,
            "lifetime_views": int(listing.views or 0),
            "created_at": listing.created_at.isoformat() + "Z" if listing.created_at else None,
        }
    return out


async def listing_detail(
    db: AsyncSession, listing_id: str, *, days: int = 30
) -> Optional[dict]:
    """One listing's engagement, its history where it exists, and its flags."""
    listing = (
        await db.execute(select(Listing).where(Listing.id == listing_id))
    ).scalar_one_or_none()
    if listing is None:
        return None

    now = _now()
    start = now - timedelta(days=days)
    current = await _window_counts(db, start, now)
    metrics = {key: current[key].get(listing_id, 0) for key in WEIGHTS}
    score = _score(metrics)

    previous = await _window_counts(db, start - timedelta(days=days), start)
    before = {key: previous[key].get(listing_id, 0) for key in WEIGHTS}
    growth = _growth(score, _score(before))

    seller = (
        await db.execute(select(User.name).where(User.id == listing.seller_id))
    ).scalar_one_or_none()

    # Per-day history only where snapshots exist. Views are cumulative in
    # those rows, so a delta is only reported between two consecutive days;
    # a gap is a gap, never an interpolated line.
    from api.database import ListingMetricSnapshot

    snapshots = (
        await db.execute(
            select(ListingMetricSnapshot)
            .where(
                ListingMetricSnapshot.listing_id == listing_id,
                ListingMetricSnapshot.snapshot_date >= (now - timedelta(days=days)).date(),
            )
            .order_by(ListingMetricSnapshot.snapshot_date)
        )
    ).scalars().all()

    history = []
    previous_views: Optional[int] = None
    for row in snapshots:
        views = row.views
        delta = None
        if views is not None and previous_views is not None:
            delta = max(0, int(views) - int(previous_views))
        if views is not None:
            previous_views = int(views)
        history.append(
            {
                "date": row.snapshot_date.isoformat(),
                "views_cumulative": views,
                "views_delta": delta,
                "likes": row.likes,
                "interested_buyers": row.interested_buyers,
            }
        )

    engagement_rate = (
        round((metrics["saves"] + metrics["likes"] + metrics["contacts"]) / metrics["unique_viewers"], 4)
        if metrics["unique_viewers"]
        else None
    )

    return {
        "generated_at": now.isoformat() + "Z",
        "window_days": days,
        "listing": {
            "id": listing.id,
            "name": listing.name,
            "seller_id": listing.seller_id,
            "seller_name": seller,
            "category": listing.category,
            "price": float(listing.price or 0),
            "status": getattr(listing.status, "value", listing.status),
            "location_county": listing.location_county,
            "location_name": listing.location_name,
            "listing_type": getattr(listing.listing_type, "value", listing.listing_type),
            "created_at": listing.created_at.isoformat() + "Z" if listing.created_at else None,
            "lifetime_views": int(listing.views or 0),
        },
        "engagement": {
            **metrics,
            "score": score,
            "previous_score": _score(before),
            "growth": growth,
            "engagement_rate": engagement_rate,
        },
        "flags": _flags(metrics, growth, engagement_rate),
        "history": history,
        "history_note": (
            "Per-day history starts at the first listing_metric_snapshots row. "
            "Days before that are absent, not zero."
            if history
            else "No daily snapshots exist for this listing yet, so no per-day trend is shown."
        ),
        "model": {"weights": WEIGHTS},
    }


def _flags(metrics: dict[str, int], growth: float, engagement_rate: Optional[float]) -> list[dict]:
    out: list[dict] = []
    viewers = metrics["unique_viewers"]
    interactions = metrics["saves"] + metrics["likes"] + metrics["contacts"]

    if viewers >= HIGH_INTEREST_VIEWERS and engagement_rate is not None and engagement_rate < LOW_ENGAGEMENT_RATE:
        out.append(
            {
                "code": "high_views_low_engagement",
                "severity": "warning",
                "detail": (
                    f"{viewers} unique viewers but only {interactions} saves/likes/contacts "
                    f"({engagement_rate:.1%}). The photos, price or description may not match what buyers expect."
                ),
            }
        )
    if metrics["contacts"] >= 5 and metrics["negotiations"] == 0:
        out.append(
            {
                "code": "interest_without_conversation",
                "severity": "warning",
                "detail": f"{metrics['contacts']} buyers expressed interest but no conversation was opened.",
            }
        )
    if growth >= 1.0 and metrics["unique_viewers"] >= 5:
        out.append(
            {
                "code": "fast_growing",
                "severity": "info",
                "detail": f"Engagement score grew {growth:+.0%} against the previous window of equal length.",
            }
        )
    if growth <= DECLINING_GROWTH and metrics["unique_viewers"] >= 5:
        out.append(
            {
                "code": "losing_attention",
                "severity": "warning",
                "detail": f"Engagement score fell {growth:+.0%} against the previous window of equal length.",
            }
        )
    if metrics["unique_viewers"] == 0:
        out.append(
            {
                "code": "no_views_in_window",
                "severity": "info",
                "detail": "No account viewed this listing in the window; that is measured, not inferred.",
            }
        )
    return out


async def listing_insights(db: AsyncSession, *, start: datetime, end: datetime, limit: int = 20) -> dict:
    """The handful of listings worth an administrator's attention, with reasons."""
    table = await rankings(db, start=start, end=end, sort="trending", limit=MAX_LIMIT)
    insights = []
    for item in table["items"]:
        flags = _flags(
            {key: item[key] for key in WEIGHTS},
            item.get("growth", 0.0),
            (item["saves"] + item["likes"] + item["contacts"]) / item["unique_viewers"]
            if item["unique_viewers"]
            else None,
        )
        for flag in flags:
            if flag["severity"] != "warning":
                continue
            insights.append(
                {
                    "listing_id": item["listing_id"],
                    "listing_name": item["listing"]["name"],
                    "seller_name": item["listing"]["seller_name"],
                    **flag,
                    "metrics": {key: item[key] for key in WEIGHTS},
                }
            )
    return {
        "from": start.isoformat() + "Z",
        "to": end.isoformat() + "Z",
        "generated_at": _now().isoformat() + "Z",
        "insights": insights[:limit],
        "considered": table["considered"],
    }
