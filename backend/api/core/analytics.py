"""Admin analytics timeseries — cheap counts bucketed in Python.

Every series is a plain COUNT over an existing indexed timestamp column, so
each costs one bounded query. Omitted deliberately:
  - auctions (AUCTIONS_ENABLED is off; bids would mislead),
  - per-listing views (no durable per-day view table exists),
  - push/SMS delivery funnels (provider-side data, not in the DB).
revenue_minor reuses the revenue aggregation's per-bucket income so the two
endpoints can never disagree.
"""
from __future__ import annotations

import bisect
from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.revenue import _iter_buckets, _parse_range
from api.core.timeutil import to_naive_utc


async def timeseries_report(
    db: AsyncSession,
    *,
    from_raw: Optional[str] = None,
    to_raw: Optional[str] = None,
    bucket: str = "day",
) -> dict:
    from api.database import Deal, Listing, User
    from api.models.dispute import DisputeCase

    if bucket not in ("day", "week", "month"):
        raise ValueError("bucket must be one of day, week, month")
    start, end = _parse_range(from_raw, to_raw)
    buckets = _iter_buckets(start, end, bucket)

    async def _stamps(model, column) -> list[datetime]:
        rows = (
            await db.execute(
                select(column).where(column >= start, column < end)
            )
        ).all()
        return [to_naive_utc(value) for (value,) in rows if value is not None]

    signups = await _stamps(User, User.created_at)
    listings = await _stamps(Listing, Listing.created_at)

    deal_rows = (
        await db.execute(
            select(Deal.created_at, Deal.agreed_price, Deal.status).where(
                Deal.created_at >= start, Deal.created_at < end
            )
        )
    ).all()
    # Deals actually agreed (not negotiating/cancelled): anything past
    # negotiation had a meeting of minds on the price. Both series use this
    # rule - "deals_agreed" used to count every deal row, so a cancelled or
    # still-negotiating deal showed up as agreed while GMV left it out.
    agreed_rows = [
        (to_naive_utc(c), float(p or 0))
        for c, p, s in deal_rows
        if c is not None
        and getattr(s, "value", s)
        not in ("negotiating", "cancelled", None)
    ]
    agreed = [stamp for stamp, _ in agreed_rows]
    gmv = agreed_rows

    dispute_rows = (
        await db.execute(
            select(DisputeCase.created_at).where(
                DisputeCase.created_at >= start, DisputeCase.created_at < end
            )
        )
    ).all()
    disputes = [to_naive_utc(c) for (c,) in dispute_rows if c is not None]

    from api.core.revenue import revenue_report

    revenue = await revenue_report(
        db,
        from_raw=start.isoformat(),
        to_raw=end.isoformat(),
        bucket=bucket,
    )
    revenue_by_bucket = {
        point["bucket_start"]: point["income_minor"]
        for point in revenue["series"]
    }

    # One sort and a binary search per bucket boundary, instead of a scan
    # of every row for every bucket (a year by day was 365 passes).
    def _points(stamps: list[datetime]) -> list[dict]:
        ordered = sorted(stamps)
        return [
            {
                "t": b_start.isoformat() + "Z",
                "v": bisect.bisect_left(ordered, b_end) - bisect.bisect_left(ordered, b_start),
            }
            for b_start, b_end in buckets
        ]

    def _money_points(pairs: list[tuple[datetime, float]]) -> list[dict]:
        ordered = sorted(pairs, key=lambda pair: pair[0])
        stamps = [stamp for stamp, _ in ordered]
        out = []
        for b_start, b_end in buckets:
            lo = bisect.bisect_left(stamps, b_start)
            hi = bisect.bisect_left(stamps, b_end)
            total = sum(amount for _, amount in ordered[lo:hi])
            out.append({"t": b_start.isoformat() + "Z", "v": int(round(total * 100))})
        return out

    def _iso(value: datetime) -> str:
        return value.isoformat() + "Z"

    return {
        "from": _iso(start),
        "to": _iso(end),
        "bucket": bucket,
        "series": {
            "signups": _points(signups),
            "listings_created": _points(listings),
            "deals_agreed": _points(agreed),
            "gmv_minor": _money_points(gmv),
            "disputes_opened": _points(disputes),
            "revenue_minor": [
                {
                    "t": b_start.isoformat() + "Z",
                    "v": revenue_by_bucket.get(
                        b_start.isoformat() + "Z", 0
                    ),
                }
                for b_start, b_end in buckets
            ],
        },
    }
