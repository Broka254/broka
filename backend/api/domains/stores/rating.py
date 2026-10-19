"""Store rating — a shop's own number, 0-10.

WHY A STORE RATING AND NOT THE OWNER'S
======================================
Trust has always been shown with a store from its OWNER's seller record
(verified badge, seller rating, deals done). That is the right thing for a
person, and the wrong thing for a shop in two cases the schema already
allows: an owner with two stores would have one record lifting both, and a
business that changes hands keeps a rating earned by someone else. A store
is a business identity with its own customers, its own reply speed and its
own reviews, so it gets its own number.

THE FOUR SIGNALS
================
Exactly the ones asked for, and nothing invented:

  Reviews        0.55  The star quality buyers gave THIS store. Bayesian
                       smoothed toward a prior, so three 5-star reviews do
                       not beat two years of 4.6.
  Response time  0.30  Measured from threads about THIS store's products.
                       Unanswered inbound counts (censored at 48 h) and a
                       burst of buyer messages is one wait — the same rules
                       as the seller record (trust/response_time.py), so
                       the two numbers cannot disagree about what a reply
                       is.
  Time on BROKA  0.15  `stores.created_at`, saturating at six months. It is
                       weak evidence of quality, but it is evidence: a
                       month-old shop has not had the chance to earn or lose
                       a record yet.
  Review volume  confidence  Shown to the owner, not another term in the
                       sum: five reviews move the average a lot, five
                       hundred barely move it.

THE NEUTRAL ANCHOR IS STILL 6.5
===============================
A brand-new store has no reviews (0.8 after the prior), no measured
response (0.7, the same placeholder the seller rating uses) and no tenure
(0). 0.55*0.8 + 0.30*0.7 + 0.15*0 = 6.5. That is deliberate: the store
rating and the seller rating start a newcomer at the same place, so
"unproven" does not read as "bad" and does not read as "proven" either.

WHY THE VALUE IS STORED
=======================
The directory orders by it, on every page. Computing it per request would
mean a 30-day message scan and a review aggregate per store per page. The
stored columns (`stores.rating`, ...) are the read path; the pure functions
below are the write path and are also what the dashboard's breakdown is
rendered from. They are pure so the ladder can be argued about with numbers
in a second — the same reason trust/seller_rating.py is.
"""
from __future__ import annotations

import logging
import math
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Dict, Iterable, Optional

from sqlalchemy import func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, NegotiationMessage, Review
from api.models.store import Store, StoreRatingSnapshot
from api.domains.trust.response_time import WINDOW_DAYS, compute_response_times_by

logger = logging.getLogger(__name__)

# ── Weights (sum to 1.0) ────────────────────────────────────────────────────
W_REVIEW   = 0.55
W_RESPONSE = 0.30
W_TENURE   = 0.15

# ── Normalisation ───────────────────────────────────────────────────────────

# Response time at which the response term scores 0.5: one hour, the same
# "attentive" threshold the seller rating uses. Imported values are kept in
# step by the constants below rather than by copy-paste.
from api.domains.trust.seller_rating import (  # noqa: E402  (documented link)
    RESPONSE_HALFLIFE_MINUTES, UNMEASURED_RESPONSE_SCORE,
)

# Tenure saturates at six months, like the seller rating's tenure term.
TENURE_SATURATION_DAYS = 180.0

# The review prior. 4.0 stars with a weight of five reviews means:
#   * no reviews -> 4.0/5 = 0.8, which with the other two neutral terms is
#     exactly 6.5/10;
#   * one 1-star review -> (1 + 20) / 6 / 5 = 0.70, a visible dent, not a
#     destroyed shop;
#   * one 5-star review -> (5 + 20) / 6 / 5 = 0.83, a nudge, not a trophy.
PRIOR_STARS = 4.0
PRIOR_WEIGHT = 5.0

# Reviews at which the average is treated as settled, for the owner's
# confidence bar. Not a weight: the Bayesian prior above does the work.
FULL_CONFIDENCE_REVIEWS = 10

NEUTRAL_RATING = 6.5


@dataclass(frozen=True)
class StoreRating:
    rating: float                 # 0-10, the headline
    review_component: float       # 0-1
    response_component: float     # 0-1
    tenure_component: float       # 0-1
    review_count: int
    response_minutes: Optional[float]
    confidence: float             # 0-1, how settled the review score is


def review_score(sum_stars: float, count: int) -> float:
    """Bayesian average stars, 0..1, smoothed toward PRIOR_STARS.

    Thin data is shrunk toward the prior instead of being taken at face
    value: without this, a shop with one 5-star review would outrank a shop
    with two hundred 4.8s. The prior is the evidence mechanism, so there is
    no second shrink applied on top of it.
    """
    count = max(int(count or 0), 0)
    stars = max(float(sum_stars or 0.0), 0.0)
    if count == 0:
        smoothed = PRIOR_STARS
    else:
        smoothed = (stars + PRIOR_WEIGHT * PRIOR_STARS) / (count + PRIOR_WEIGHT)
    return max(0.0, min(1.0, smoothed / 5.0))


def response_component(minutes: Optional[float]) -> float:
    """1.0 for instant, 0.5 at an hour, approaching 0 for very slow.

    Unmeasured scores 0.7 — the same value the seller rating uses for
    "replies not yet measured", so a store and its owner do not disagree
    about a shop nobody has messaged yet.
    """
    if minutes is None:
        return UNMEASURED_RESPONSE_SCORE
    if minutes <= 0:
        return 1.0
    return math.exp(-math.log(2) * minutes / RESPONSE_HALFLIFE_MINUTES)


def tenure_component(days: float) -> float:
    """Saturating within six months, then flat. Square-rooted so most of
    the value accrues early: a week and two months differ; a year and two
    do not."""
    if days <= 0:
        return 0.0
    return min(1.0, math.sqrt(days / TENURE_SATURATION_DAYS))


def compute_store_rating(
    *,
    review_sum: float,
    review_count: int,
    response_minutes: Optional[float],
    days_trading: float,
) -> StoreRating:
    """The whole formula. Pure: every input is a number."""
    review = review_score(review_sum, review_count)
    response = response_component(response_minutes)
    tenure = tenure_component(days_trading)
    value = (W_REVIEW * review + W_RESPONSE * response + W_TENURE * tenure) * 10.0
    return StoreRating(
        rating=round(max(0.0, min(10.0, value)), 2),
        review_component=round(review, 4),
        response_component=round(response, 4),
        tenure_component=round(tenure, 4),
        review_count=int(review_count or 0),
        response_minutes=(
            round(float(response_minutes), 1) if response_minutes is not None else None
        ),
        confidence=round(min(1.0, max(int(review_count or 0), 0) / FULL_CONFIDENCE_REVIEWS), 3),
    )


# ── Reading the signals ─────────────────────────────────────────────────────

async def store_response_minutes(
    db: AsyncSession, store_ids: Optional[Iterable[str]] = None,
) -> Dict[str, float]:
    """Store id -> average reply minutes over the rolling window.

    One query for every store (or the given ids), ordered so the pure walk
    can process one thread at a time. Threads are keyed by (listing, buyer)
    and the first column is the STORE id, so a seller who answers a second
    shop's buyers slowly cannot make this shop look slow, or vice versa.
    """
    since = datetime.utcnow() - timedelta(days=WINDOW_DAYS)
    q = (
        select(
            Listing.store_id,
            NegotiationMessage.listing_id,
            NegotiationMessage.buyer_id,
            NegotiationMessage.role,
            NegotiationMessage.recipient_role,
            NegotiationMessage.created_at,
        )
        .join(Listing, Listing.id == NegotiationMessage.listing_id)
        .where(
            Listing.store_id.is_not(None),
            NegotiationMessage.created_at >= since,
        )
        .order_by(
            Listing.store_id,
            NegotiationMessage.listing_id,
            NegotiationMessage.buyer_id,
            NegotiationMessage.created_at,
        )
    )
    ids = [i for i in (store_ids or []) if i]
    if ids:
        q = q.where(Listing.store_id.in_(ids))
    rows = (await db.execute(q)).all()
    if not rows:
        return {}
    return compute_response_times_by(rows, datetime.utcnow())


async def review_totals(
    db: AsyncSession, stores: Iterable[Store],
) -> Dict[str, tuple[int, float]]:
    """Store id -> (review count, sum of stars), using the same attribution
    rule the store page shows (stores/review_scope.py).

    Two buckets in three queries, never one per store:
      * reviews attached to the store by the deal's listing;
      * chat-only reviews, for an owner who has exactly ONE live store.
    A seller with two shops keeps those reviews on their profile: splitting
    them between the shops would be a guess, and giving both shops all of
    them would let one shop's record lift the other.
    """
    rows = [s for s in stores if s is not None and s.id]
    if not rows:
        return {}
    ids = [s.id for s in rows]
    owners = {s.owner_id for s in rows if s.owner_id}

    attributed = {
        row[0]: (int(row[1]), float(row[2] or 0))
        for row in (await db.execute(
            select(Review.store_id, func.count(Review.id),
                   func.coalesce(func.sum(Review.rating), 0))
            .where(Review.store_id.in_(ids))
            .group_by(Review.store_id)
        )).all()
    }

    # Which of these owners run exactly one live store. Same test as
    # review_scope.sole_store_ids, batched for the whole page.
    store_counts = dict((await db.execute(
        select(Store.owner_id, func.count(Store.id))
        .where(Store.owner_id.in_(owners), Store.deleted_at.is_(None))
        .group_by(Store.owner_id)
    )).all()) if owners else {}
    sole_owner_ids = {o for o in owners if int(store_counts.get(o, 0)) == 1}

    combined: Dict[str, tuple[int, float]] = dict(attributed)
    if sole_owner_ids:
        chat_only = {
            row[0]: (int(row[1]), float(row[2] or 0))
            for row in (await db.execute(
                select(Review.seller_id, func.count(Review.id),
                       func.coalesce(func.sum(Review.rating), 0))
                .where(
                    Review.store_id.is_(None),
                    Review.seller_id.in_(sole_owner_ids),
                )
                .group_by(Review.seller_id)
            )).all()
        }
        for store in rows:
            extra = chat_only.get(store.owner_id)
            if extra is None:
                continue
            count, stars = combined.get(store.id, (0, 0.0))
            combined[store.id] = (count + extra[0], stars + extra[1])

    return combined


def _days_trading(store: Store, now: Optional[datetime] = None) -> float:
    if not store or not store.created_at:
        return 0.0
    return max(0.0, ((now or datetime.utcnow()) - store.created_at).total_seconds() / 86400.0)


def rating_for(
    store: Store,
    *,
    review_count: int,
    review_sum: float,
    response_minutes: Optional[float],
    now: Optional[datetime] = None,
) -> StoreRating:
    """`compute_store_rating` with a Store row's own dates filled in."""
    return compute_store_rating(
        review_sum=review_sum,
        review_count=review_count,
        response_minutes=response_minutes,
        days_trading=_days_trading(store, now),
    )


async def compute_ratings(
    db: AsyncSession, stores: Iterable[Store],
) -> Dict[str, StoreRating]:
    """Every store's rating from fresh signals, in two queries total."""
    rows = [s for s in stores if s is not None]
    if not rows:
        return {}
    ids = [s.id for s in rows]
    responses = await store_response_minutes(db, ids)
    reviews = await review_totals(db, rows)
    now = datetime.utcnow()
    out: Dict[str, StoreRating] = {}
    for store in rows:
        count, stars = reviews.get(store.id, (0, 0.0))
        out[store.id] = rating_for(
            store,
            review_count=count,
            review_sum=stars,
            response_minutes=responses.get(store.id),
            now=now,
        )
    return out


# ── Writing ─────────────────────────────────────────────────────────────────

def _apply(store: Store, rating: StoreRating, now: Optional[datetime] = None) -> None:
    store.rating = rating.rating
    store.rating_reviews = rating.review_count
    store.rating_response_minutes = rating.response_minutes
    store.rating_review_component = rating.review_component
    store.rating_response_component = rating.response_component
    store.rating_tenure_component = rating.tenure_component
    store.rating_updated_at = now or datetime.utcnow()


async def refresh_store_rating(db: AsyncSession, store_id: str) -> Optional[StoreRating]:
    """Recompute one store's stored rating and commit it.

    Called when a review lands (the one signal that changes on a user
    action) and by the daily pass. Returns None when the store is gone.
    """
    store = await db.get(Store, store_id)
    if store is None or store.deleted_at is not None:
        return None
    ratings = await compute_ratings(db, [store])
    rating = ratings.get(store.id)
    if rating is None:
        return None
    _apply(store, rating)
    await db.commit()
    return rating


async def refresh_all_store_ratings(
    db: AsyncSession, on_date: Optional[date] = None,
) -> int:
    """Recompute every live store and write today's snapshot.

    Batched: one query for stores, one for response times, one for review
    totals — never one per store. Returns how many stores were written.
    """
    stores = (await db.execute(
        select(Store).where(Store.deleted_at.is_(None))
    )).scalars().all()
    if not stores:
        return 0

    ratings = await compute_ratings(db, stores)
    now = datetime.utcnow()
    day = on_date or now.date()

    existing_rows = (await db.execute(
        select(StoreRatingSnapshot).where(StoreRatingSnapshot.snapshot_date == day)
    )).scalars().all()
    existing = {row.store_id: row for row in existing_rows}

    written = 0
    for store in stores:
        rating = ratings.get(store.id)
        if rating is None:
            continue
        _apply(store, rating, now)
        row = existing.get(store.id)
        if row is None:
            row = StoreRatingSnapshot(
                id=str(uuid.uuid4()), store_id=store.id, snapshot_date=day)
            db.add(row)
        row.rating = rating.rating
        row.review_component = rating.review_component
        row.response_component = rating.response_component
        row.tenure_component = rating.tenure_component
        row.review_count = rating.review_count
        row.response_minutes = rating.response_minutes
        written += 1

    await db.commit()
    logger.info("[store-rating] refreshed %d stores for %s", written, day)
    return written


async def backfill_review_store_ids() -> int:
    """Attach existing deal reviews to the store their product was sold in.

    Run once on startup; safe to repeat (it only touches rows still NULL).
    A chat-only review (no deal) has no listing to name and stays seller-
    level: attributing it to a shop would be a guess.
    """
    from api.database import AsyncSessionLocal

    async with AsyncSessionLocal() as db:
        result = await db.execute(text(
            "UPDATE reviews SET store_id = ("
            "  SELECT listings.store_id FROM deals"
            "  JOIN listings ON listings.id = deals.listing_id"
            "  WHERE deals.id = reviews.deal_id"
            ") WHERE reviews.store_id IS NULL AND reviews.deal_id IS NOT NULL"
        ))
        changed = int(result.rowcount or 0)
        await db.commit()
    if changed:
        logger.info("[store-rating] attributed %d reviews to stores", changed)
    return changed


async def backfill_store_ratings() -> int:
    """Give every store that predates the rating a real value.

    Without this the directory's rating order would put every existing shop
    below every new one (NULL sorts last), which reads as "the old shops are
    worse" when it only means "not measured yet".
    """
    from api.database import AsyncSessionLocal

    async with AsyncSessionLocal() as db:
        missing = (await db.execute(
            select(func.count()).select_from(Store)
            .where(Store.deleted_at.is_(None), Store.rating.is_(None))
        )).scalar_one()
        if not missing:
            return 0
    # Compute through the normal pass so the snapshots start on day one too.
    async with AsyncSessionLocal() as db:
        return await refresh_all_store_ratings(db)


async def rating_payload(db: AsyncSession, store: Store, *, owner_view: bool = False) -> dict:
    """The rating block for a store payload.

    Read straight from the store's stored columns: the directory renders a
    whole page at once, and a review aggregate per store here would be the
    N+1 the rest of this service is careful to avoid. The stored value is
    refreshed when a review lands and by the daily pass, so it is at most a
    day stale - and the components beside it are the same ones the number
    was computed from, so the explanation cannot disagree with it.

    `breakdown` is added for the owner only: it is their to-do list. The
    public payload carries the number, the review count and the response
    time - the facts a buyer needs to judge the shop.
    """
    rating: Optional[StoreRating] = None
    if store.rating is not None:
        rating = StoreRating(
            rating=round(float(store.rating), 2),
            review_component=round(float(store.rating_review_component or 0.0), 4),
            response_component=round(float(store.rating_response_component or 0.0), 4),
            tenure_component=round(float(store.rating_tenure_component or 0.0), 4),
            review_count=int(store.rating_reviews or 0),
            response_minutes=(
                round(float(store.rating_response_minutes), 1)
                if store.rating_response_minutes is not None else None
            ),
            confidence=round(
                min(1.0, int(store.rating_reviews or 0) / FULL_CONFIDENCE_REVIEWS), 3),
        )
    else:
        # A row that predates the startup backfill, or whose write failed: a
        # live number beats a blank. Rare (once per such store), so the cost
        # is not on the directory's hot path.
        ratings = await compute_ratings(db, [store])
        rating = ratings.get(store.id)

    payload = {
        "rating": rating.rating if rating else None,
        "review_count": rating.review_count if rating else 0,
        "response_minutes": rating.response_minutes if rating else None,
        "as_of": store.rating_updated_at.isoformat() if store.rating_updated_at else None,
    }
    if owner_view and rating is not None:
        payload["breakdown"] = {
            "review": rating.review_component,
            "response": rating.response_component,
            "tenure": rating.tenure_component,
            "confidence": rating.confidence,
            "weights": {"review": W_REVIEW, "response": W_RESPONSE, "tenure": W_TENURE},
        }
        payload["explanation"] = explain(rating)
    return payload


def explain(rating: StoreRating) -> str:
    """One sentence citing the two strongest and weakest levers.

    Deterministic, no model call - the owner's card says WHY the number is
    where it is, and every clause is backed by a stored component.
    """
    parts: list[str] = []
    if rating.review_count == 0:
        parts.append("no reviews yet, so the review score sits at the neutral prior")
    else:
        pct = round(rating.review_component * 100)
        parts.append(f"reviews score {pct}/100 across {rating.review_count} review"
                     f"{'s' if rating.review_count != 1 else ''}")
    if rating.response_minutes is None:
        parts.append("reply time is not measured yet")
    else:
        parts.append(f"you reply in about {round(rating.response_minutes)} min")
    parts.append(f"time on BROKA contributes {round(rating.tenure_component * 100)}/100")
    return "; ".join(parts) + "."
