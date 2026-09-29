"""A seller's standing as buyers see it: on a listing's screen, and to Zeno
when a buyer asks it about a listing.

Three of the seller dashboard's figures, published: the overall rating, the
deal completion rate and the response time - the first three charts of the
dashboard's "performance over time". Nothing else from the metrics goes out.
Rank position tells a rival exactly how far they have to climb, and the
backlog can be inflated by anyone willing to open conversations with a
seller (listings/router.py, seller_metrics), so both stay the owner's.

Read from the seller's newest nightly snapshot (metric_snapshots.py), not
computed live. A listing is opened far more often than a dashboard, and the
live response time is a scan of every message on the platform in the last
30 days (response_time.compute_all_response_times) - one indexed row
instead, at most a day old. A snapshot older than STALE_AFTER_DAYS gives
nothing: those are the numbers of a job that has stopped running, not the
seller's standing today.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import SellerMetricSnapshot

STALE_AFTER_DAYS = 7

# Part XVI's bar for a settled track record. Under it the completion rate is
# real but still moves a lot with each deal, and is marked provisional - the
# dashboard's rule (seller_dashboard_screen.dart, _dcrIsProvisional).
SETTLED_DEALS = 10


async def public_seller_standing(db: AsyncSession, seller_id: str) -> Optional[dict]:
    """{overall_rating, dcr, dcr_provisional, median_response_minutes,
    completed_deals, as_of}, or None for someone with no recent snapshot -
    a buyer who has never listed anything, or a seller whose figures are
    stale."""
    since = datetime.utcnow().date() - timedelta(days=STALE_AFTER_DAYS)
    row = (await db.execute(
        select(
            SellerMetricSnapshot.snapshot_date,
            SellerMetricSnapshot.overall_rating,
            SellerMetricSnapshot.dcr_score,
            SellerMetricSnapshot.median_response_min,
            SellerMetricSnapshot.completed_deals,
        )
        .where(
            SellerMetricSnapshot.seller_id == seller_id,
            SellerMetricSnapshot.snapshot_date >= since,
        )
        .order_by(SellerMetricSnapshot.snapshot_date.desc())
        .limit(1)
    )).first()
    if row is None:
        return None

    completed = int(row.completed_deals or 0)
    return {
        "overall_rating": round(row.overall_rating, 1) if row.overall_rating is not None else None,
        # DCR is smoothed toward a prior of 80% (§3.2), so a seller who has
        # never completed a deal would show 80% - to a buyer, a track record
        # that does not exist. Withheld until the first funded deal, as the
        # dashboard withholds it from the seller.
        "dcr": round(row.dcr_score, 1) if completed > 0 and row.dcr_score is not None else None,
        "dcr_provisional": 0 < completed < SETTLED_DEALS,
        # None when there were too few threads to measure: "unmeasured" is
        # not "fast", and the app must not show it as a time.
        "median_response_minutes": (
            round(row.median_response_min, 1) if row.median_response_min is not None else None
        ),
        "completed_deals": completed,
        "as_of": row.snapshot_date.isoformat(),
    }
