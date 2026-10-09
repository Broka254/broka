"""Daily seller metric snapshots — the data behind the history graphs.

Writes one SellerMetricSnapshot row per seller per day. Runs after
recompute_all_dcr in the nightly sweep, so DCR and rank_score are fresh
before they are recorded.

WHY THIS RUNS NOW, BEFORE THE SCREENS THAT READ IT
==================================================
None of this history is recoverable later. DCR is recency-weighted on a
45-day half-life (§3.2), so yesterday's value cannot be reconstructed from
today's deal table. Rank position depends on where every OTHER seller stood
at that moment. Every day this job does not run is a permanent hole in a
graph a seller will eventually open, so it ships in the first phase and
starts accumulating while the rest is built.

RESPONSE TIME
=============
Measured from message history by domains/trust/response_time, and NULL for
sellers with too few threads to measure. NULL rather than a placeholder on
purpose: a flat line at an invented value is indistinguishable from a real
trend, and this graph is meant to tell a seller whether they are getting
slower.
"""
from __future__ import annotations

import logging
import uuid
from datetime import date, datetime
from typing import Dict, List

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import (
    Deal, DealStatus, Listing, ListingStatus, SellerMetricSnapshot,
    SellerMetrics, User,
)
from api.domains.trust.completion_rate import _FUNDED_STATUSES
from api.domains.trust.response_time import compute_all_response_times
from api.domains.trust.seller_rating import (
    SellerSignals, credibility_score, overall_rating,
)

logger = logging.getLogger(__name__)

# Part XVI: deals below this do not count toward confidence.
from api.domains.trust.seller_rating import MIN_COUNTABLE_DEAL_VALUE_KES

# A deal that is live but not yet funded through BROKA. Anything in
# _FUNDED_STATUSES already went through escrow and is not "pending"; a
# cancelled deal is finished, not waiting.
_PENDING_STATUSES = (DealStatus.agreed,)


async def write_daily_snapshots(db: AsyncSession, on_date: date | None = None) -> int:
    """Upsert today's snapshot for every seller with at least one listing.

    Idempotent per (seller, day) - a re-run after a crash updates the row
    instead of adding a second one. That matters more than it sounds: a
    duplicated day silently doubles a point on every graph that reads it,
    and nobody would notice until a seller asked why one Tuesday spiked.
    """
    snapshot_day = on_date or datetime.utcnow().date()

    sellers_r = await db.execute(
        select(User.id, User.created_at)
        .join(Listing, Listing.seller_id == User.id)
        .distinct()
    )
    sellers = sellers_r.all()
    if not sellers:
        return 0

    seller_ids = [s[0] for s in sellers]

    # ── Batched aggregates: one query each, not one per seller ────────────
    completed_r = await db.execute(
        select(Deal.seller_id, func.count(Deal.id))
        .where(Deal.seller_id.in_(seller_ids), Deal.status.in_(_FUNDED_STATUSES))
        .group_by(Deal.seller_id)
    )
    completed: Dict[str, int] = dict(completed_r.all())

    pending_r = await db.execute(
        select(Deal.seller_id, func.count(Deal.id))
        .where(Deal.seller_id.in_(seller_ids), Deal.status.in_(_PENDING_STATUSES))
        .group_by(Deal.seller_id)
    )
    pending: Dict[str, int] = dict(pending_r.all())

    # §3.3 confidence input: distinct buyers among funded deals.
    uniq_r = await db.execute(
        select(Deal.seller_id, func.count(func.distinct(Deal.buyer_id)))
        .where(Deal.seller_id.in_(seller_ids), Deal.status.in_(_FUNDED_STATUSES))
        .group_by(Deal.seller_id)
    )
    uniq: Dict[str, int] = dict(uniq_r.all())

    # §3.3 confidence input: funded deals clearing Part XVI's KSh 500 floor.
    value_r = await db.execute(
        select(Deal.seller_id, func.count(Deal.id))
        .where(
            Deal.seller_id.in_(seller_ids),
            Deal.status.in_(_FUNDED_STATUSES),
            Deal.agreed_price >= MIN_COUNTABLE_DEAL_VALUE_KES,
        )
        .group_by(Deal.seller_id)
    )
    countable: Dict[str, int] = dict(value_r.all())

    listings_r = await db.execute(
        select(Listing.seller_id, func.count(Listing.id), func.sum(Listing.views))
        .where(Listing.seller_id.in_(seller_ids))
        .group_by(Listing.seller_id)
    )
    listing_stats = {r[0]: (r[1], r[2] or 0) for r in listings_r.all()}

    metrics_r = await db.execute(
        select(SellerMetrics.user_id, SellerMetrics.dcr_score, SellerMetrics.rank_score)
        .where(SellerMetrics.user_id.in_(seller_ids))
    )
    metrics = {r[0]: (r[1], r[2]) for r in metrics_r.all()}

    # Measured medians, or absent where there is too little history.
    try:
        response_medians = await compute_all_response_times(db)
    except Exception as exc:
        logger.warning("[snapshots] response-time measurement failed: %s", exc)
        response_medians = {}

    # ── Rank position: where each seller sits platform-wide today ─────────
    #
    # Computed here rather than stored on SellerMetrics because it is a
    # property of the whole population, not of one seller - it changes when
    # anyone else's score changes, so it is only meaningful as of a date.
    # That is exactly why it has to be snapshotted to be graphable at all.
    ranked = sorted(
        (sid for sid in seller_ids if metrics.get(sid, (None, None))[1] is not None),
        key=lambda sid: metrics[sid][1],
        reverse=True,
    )
    rank_position = {sid: i + 1 for i, sid in enumerate(ranked)}

    existing_r = await db.execute(
        select(SellerMetricSnapshot)
        .where(
            SellerMetricSnapshot.seller_id.in_(seller_ids),
            SellerMetricSnapshot.snapshot_date == snapshot_day,
        )
    )
    existing = {row.seller_id: row for row in existing_r.scalars().all()}

    written = 0
    for seller_id, created_at in sellers:
        dcr, rank_score = metrics.get(seller_id, (None, None))
        n_listings, views = listing_stats.get(seller_id, (0, 0))
        days_on = ((datetime.utcnow() - created_at).total_seconds() / 86400.0
                   if created_at else 0.0)

        signals = SellerSignals(
            dcr_percent=dcr,
            median_response_minutes=response_medians.get(seller_id),
            completed_deals=completed.get(seller_id, 0),
            pending_deals=pending.get(seller_id, 0),
            days_on_broka=days_on,
            unique_counterparties=uniq.get(seller_id, 0),
            countable_value_deals=countable.get(seller_id, 0),
        )
        breakdown = overall_rating(signals)

        row = existing.get(seller_id)
        if row is None:
            row = SellerMetricSnapshot(
                id=str(uuid.uuid4()),
                seller_id=seller_id,
                snapshot_date=snapshot_day,
            )
            db.add(row)

        row.overall_rating      = breakdown.rating
        row.credibility         = credibility_score(signals)
        row.dcr_score           = dcr
        row.rank_score          = rank_score
        row.rank_position       = rank_position.get(seller_id)
        row.median_response_min = response_medians.get(seller_id)
        row.completed_deals     = completed.get(seller_id, 0)
        row.pending_deals       = pending.get(seller_id, 0)
        row.total_views         = int(views)
        row.active_listings     = int(n_listings)
        written += 1

    await db.commit()
    logger.info("[snapshots] wrote %d seller snapshots for %s", written, snapshot_day)
    return written


async def write_listing_snapshots(db: AsyncSession, on_date: date | None = None) -> int:
    """One row per active listing per day: views, likes, interested buyers.

    Views are the reason this exists. Likes (Wishlist.created_at) and
    interested buyers (Interest.created_at) both carry timestamps and can be
    reconstructed after the fact; Listing.views is a bare running counter, so
    views-per-day and the traffic trend are unrecoverable for any day this
    does not run.

    Stores the CUMULATIVE counter rather than a daily delta. A delta written
    directly would be wrong for any missed day - it would attribute two days
    of traffic to one, and nothing downstream could tell.
    """
    from api.database import ListingMetricSnapshot
    from api.domains.listings.sell_probability import (
        MIN_COMPARABLE_LISTINGS, ListingSignals, compute_sell_probability,
    )
    from api.domains.listings.sell_signals import engagement_signals

    snapshot_day = on_date or datetime.utcnow().date()

    listings_r = await db.execute(
        select(Listing)
        # ListingStatus.active, not the string "active" - status is an Enum
        # column, and comparing it to a bare string matches nothing on
        # Postgres while quietly working on SQLite. That mismatch would have
        # produced an empty snapshot table in production and a green test
        # suite locally.
        .where(Listing.status == ListingStatus.active)
    )
    listings = listings_r.scalars().all()
    if not listings:
        return 0

    ids = [l.id for l in listings]
    engagement = await engagement_signals(db, listings)

    # Category prices, for the price-position term. One pass over active
    # listings rather than a query per listing. Each listing is compared
    # with OTHER sellers' listings only, as on its screen: counting its own
    # price (or its seller's other listings) made a category of one say
    # "competitively priced" - and the snapshot never passed a comparable
    # count at all, so this term silently never applied here.
    by_category: Dict[str, List[tuple]] = {}
    for l in listings:
        if l.price:
            by_category.setdefault(l.category or "", []).append((l.seller_id, float(l.price)))

    def _benchmark(l) -> tuple:
        prices = sorted(p for sid, p in by_category.get(l.category or "", [])
                        if sid != l.seller_id)
        if len(prices) < MIN_COMPARABLE_LISTINGS:
            return None, len(prices)
        return prices[len(prices) // 2], len(prices)

    seller_dcr_r = await db.execute(
        select(SellerMetrics.user_id, SellerMetrics.dcr_score)
        .where(SellerMetrics.user_id.in_({l.seller_id for l in listings})))
    seller_dcr = dict(seller_dcr_r.all())

    try:
        response_medians = await compute_all_response_times(db)
    except Exception:
        response_medians = {}

    existing_r = await db.execute(
        select(ListingMetricSnapshot).where(
            ListingMetricSnapshot.listing_id.in_(ids),
            ListingMetricSnapshot.snapshot_date == snapshot_day,
        ))
    existing = {row.listing_id: row for row in existing_r.scalars().all()}

    written = 0
    for l in listings:
        lid, sid, views = l.id, l.seller_id, l.views
        days_listed = ((datetime.utcnow() - l.created_at).total_seconds() / 86400.0
                       if l.created_at else 1.0)
        e = engagement[lid]
        median, comparable = _benchmark(l)
        prob = compute_sell_probability(ListingSignals(
            views=int(views or 0),
            likes=e["likes"],
            interested_buyers=e["interested_buyers"],
            days_listed=max(days_listed, 1.0),
            seller_dcr_percent=seller_dcr.get(sid),
            seller_response_minutes=response_medians.get(sid),
            price=float(l.price) if l.price else None,
            category_median_price=median,
            comparable_count=comparable,
            best_offer=e["best_offer"],
            photo_count=e["photo_count"],
            description_chars=e["description_chars"],
        ))

        row = existing.get(lid)
        if row is None:
            row = ListingMetricSnapshot(
                id=str(uuid.uuid4()), listing_id=lid, snapshot_date=snapshot_day)
            db.add(row)
        row.views             = int(views or 0)
        row.likes             = e["likes"]
        row.interested_buyers = e["interested_buyers"]
        row.sell_probability  = prob.probability
        written += 1

    await db.commit()
    logger.info("[snapshots] wrote %d listing snapshots for %s", written, snapshot_day)
    return written
