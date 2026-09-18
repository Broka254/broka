"""Listings Router v3.0"""
from __future__ import annotations

import json
from typing import Any, Dict, Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import ListingService

router = APIRouter()


class ListingIn(BaseModel):
    name: str
    category: str
    subcategory_id: Optional[str] = None
    condition: Optional[str] = None  # "new" | "used" | "refurbished"
    attributes: Optional[Dict[str, Any]] = None  # dynamic category fields, e.g. {"make": "Toyota"}
    price: float
    lat: float
    lng: float
    description: Optional[str] = None
    location_name: Optional[str] = None
    # Structured location (2026-08-29). location_county/location_subcounty
    # are the new 3-part location step's real inputs; location_country
    # isn't sent by the client at all right now (fixed to Kenya - see
    # sell_location_screen.dart), so it's not exposed here. location_name
    # above is kept for backward compatibility - ListingService derives it
    # from county+subcounty when they're present rather than trusting a
    # client-sent value, so existing readers (search, negotiate prompts,
    # buy_agent matching...) keep seeing a normal display string either way.
    location_county: Optional[str] = None
    location_subcounty: Optional[str] = None
    listing_type: str = "direct"
    verified_photos: Optional[str] = None
    verified_video: Optional[str] = None
    advert_video: Optional[str] = None
    target_bidders: Optional[int] = None
    auction_date: Optional[str] = None
    reserve_price: Optional[float] = None
    # Auction lifecycle (0021). The window bidding is open for. Both
    # optional: omitted, bidding opens now and closes at auction_date,
    # which is what the sell wizard already collects. See
    # ListingService._create_auction_meta.
    auction_starts_at: Optional[str] = None
    auction_ends_at: Optional[str] = None
    # Minimum raise between bids. Defaults to AUCTION_DEFAULT_MIN_INCREMENT.
    min_bid_increment: Optional[float] = None
    # AI Showcase/Cover Image (2026-08-29). Optional - set only when the
    # wizard's Showcase step produced one (gallery pick or an AI preview
    # the seller explicitly chose "Use This Image" on client-side; see
    # SellWizardData.showcaseImageDataUri). Both must be given together or
    # not at all - validated in create_listing, not here, so the error can
    # reference both fields by name in one message.
    showcase_image_url: Optional[str] = None
    showcase_image_source: Optional[str] = None  # "gallery" | "ai"
    # Store feature. None = personal listing (unchanged default behavior);
    # set = create this listing directly under a store the seller owns
    # (ownership verified server-side in ListingService.create_listing).
    store_id: Optional[str] = None


class InterestIn(BaseModel):
    offer_price: Optional[float] = None


class ListingStoreIn(BaseModel):
    store_id: str


@router.get("/stats")
async def get_stats(db: AsyncSession = Depends(get_db)):
    svc = ListingService(db)
    return await svc.get_stats()


@router.get("/")
async def list_listings(
    category: Optional[str] = None,
    category_id: Optional[str] = None,
    subcategory_id: Optional[str] = None,
    condition: Optional[str] = None,
    listing_type: Optional[str] = None,
    seller_id: Optional[str] = None,
    store_id: Optional[str] = None,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    max_km: Optional[float] = None,
    min_price: Optional[float] = None,
    max_price: Optional[float] = None,
    search: Optional[str] = None,
    location: Optional[str] = None,
    attributes: Optional[str] = None,  # JSON-encoded dict, e.g. '{"brand":"Samsung"}'
    sort: Optional[str] = None,
    with_total: bool = False,
    # Bounded. This was a bare `int = 20` with no ceiling, so any caller
    # could ask for limit=1000000 and have the database assemble it - an
    # unauthenticated endpoint doing unbounded work on request. 200 is the
    # seller dashboard's catalogue ceiling, which is the largest legitimate
    # ask on this route.
    limit: int = Query(20, ge=1, le=200),
    offset: int = Query(0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    parsed_attributes = None
    if attributes:
        try:
            parsed_attributes = json.loads(attributes)
        except (TypeError, ValueError):
            raise HTTPException(status_code=400, detail="attributes must be valid JSON")
    return await svc.list_listings(
        category=category,
        category_id=category_id,
        subcategory_id=subcategory_id,
        condition=condition,
        listing_type=listing_type,
        seller_id=seller_id,
        store_id=store_id,
        viewer_lat=lat,
        viewer_lng=lng,
        max_km=max_km,
        min_price=min_price,
        max_price=max_price,
        search=search,
        location=location,
        attributes=parsed_attributes,
        sort=sort,
        with_total=with_total,
        limit=limit,
        offset=offset,
    )


@router.post("/", status_code=201)
async def create_listing(
    body: ListingIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.create_listing(current_user["id"], body.model_dump())


# ── Seller edits ────────────────────────────────────────────────────────────
#
# Sellers can change price and photos. Photos are unrestricted; price is not,
# and the asymmetry is deliberate.
#
# A price that moves while someone is negotiating breaks the negotiation:
# a buyer who agreed KES 3,000 yesterday and opens the thread to find 3,800
# has no reason to believe the next number either. And a listing whose price
# visibly oscillates teaches every buyer watching it to wait rather than buy.
# Neither is a hypothetical - they are the two failure modes of letting an
# edit field loose on a marketplace.
#
# So: two rules, and both of them explain themselves when they fire, because
# a limit a seller does not understand feels like a bug.

# Changes allowed in a rolling week. Two is enough to correct a mistake and
# then respond to the market once; a third within seven days is oscillation.
MAX_PRICE_CHANGES_PER_WEEK = 2
PRICE_CHANGE_WINDOW_DAYS = 7

# Minimum gap between changes, so the two allowances cannot be spent in the
# same minute.
MIN_HOURS_BETWEEN_PRICE_CHANGES = 12


class ListingEdit(BaseModel):
    price: Optional[float] = None
    verified_photos: Optional[str] = None      # comma-separated base64
    showcase_image_url: Optional[str] = None


@router.patch("/{listing_id}")
async def update_listing(
    listing_id: str,
    body: ListingEdit,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Update price and/or photos on your own listing.

    Returns the accepted changes plus how many price edits remain, so the
    client can show the allowance BEFORE the seller types a new number
    rather than rejecting them after.
    """
    from datetime import datetime, timedelta
    from api.database import Deal, DealStatus, ListingPriceChange
    from sqlalchemy import func
    import uuid as _uuid

    listing = await db.get(Listing, listing_id)
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found.")
    if listing.seller_id != current_user["id"]:
        raise HTTPException(status_code=403,
                            detail="You can only edit your own listings.")

    changed: Dict[str, Any] = {}

    # ── Photos: unrestricted ────────────────────────────────────────────
    if body.verified_photos is not None:
        listing.verified_photos = body.verified_photos
        changed["verified_photos"] = True
    if body.showcase_image_url is not None:
        listing.showcase_image_url = body.showcase_image_url
        changed["showcase_image_url"] = True

    # ── Price: gated ────────────────────────────────────────────────────
    now = datetime.utcnow()
    window_start = now - timedelta(days=PRICE_CHANGE_WINDOW_DAYS)

    recent_r = await db.execute(
        select(ListingPriceChange)
        .where(ListingPriceChange.listing_id == listing_id,
               ListingPriceChange.changed_at >= window_start)
        .order_by(ListingPriceChange.changed_at.desc()))
    recent = recent_r.scalars().all()

    if body.price is not None and float(body.price) != float(listing.price or 0):
        if body.price <= 0:
            raise HTTPException(status_code=400, detail="Price must be above zero.")

        # A live negotiation outranks the allowance. This is the rule that
        # actually protects buyers: changing the number mid-thread is what
        # makes a seller look like they are moving the goalposts, and no
        # amount of remaining quota makes that acceptable.
        live_r = await db.execute(
            select(func.count(Deal.id)).where(
                Deal.listing_id == listing_id,
                Deal.status.in_((DealStatus.agreed,)),
            ))
        if int(live_r.scalar() or 0) > 0:
            raise HTTPException(
                status_code=409,
                detail="There is an open deal on this listing. Finish or cancel "
                       "it before changing the price - buyers who have already "
                       "agreed a number should not see it move.")

        if len(recent) >= MAX_PRICE_CHANGES_PER_WEEK:
            nxt = recent[-1].changed_at + timedelta(days=PRICE_CHANGE_WINDOW_DAYS)
            raise HTTPException(
                status_code=429,
                detail=f"You have used both price changes for this listing this "
                       f"week. The next one is available "
                       f"{nxt.strftime('%d %b')}. Frequent changes make buyers "
                       f"wait for the next drop instead of buying.")

        if recent:
            gap = (now - recent[0].changed_at).total_seconds() / 3600.0
            if gap < MIN_HOURS_BETWEEN_PRICE_CHANGES:
                wait = MIN_HOURS_BETWEEN_PRICE_CHANGES - gap
                raise HTTPException(
                    status_code=429,
                    detail=f"You changed this price {gap:.0f} hours ago. Give it "
                           f"{wait:.0f} more hours - a price that moves twice in "
                           f"a day reads as uncertainty, not a deal.")

        db.add(ListingPriceChange(
            id=str(_uuid.uuid4()),
            listing_id=listing_id,
            seller_id=listing.seller_id,
            old_price=listing.price,
            new_price=float(body.price),
            changed_at=now,
        ))
        changed["price"] = {"from": listing.price, "to": float(body.price)}
        listing.price = float(body.price)
        recent = [None] + list(recent)   # count this one toward the allowance

    await db.commit()

    return {
        "updated": changed,
        "price_changes_used": len(recent),
        "price_changes_allowed": MAX_PRICE_CHANGES_PER_WEEK,
        "price_changes_remaining":
            max(0, MAX_PRICE_CHANGES_PER_WEEK - len(recent)),
        "window_days": PRICE_CHANGE_WINDOW_DAYS,
    }


@router.get("/{listing_id}/metrics")
async def listing_metrics(
    listing_id: str,
    days: int = Query(60, ge=7, le=365),
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Per-listing performance, history and advice. Seller's own listings only.

    Views, likes and like/view ratio are commercially sensitive - they tell a
    competitor exactly which of your products are moving and which are dead
    stock, which is precisely what a rival would price against.
    """
    from datetime import date, datetime, timedelta
    from api.database import Interest, Listing, ListingMetricSnapshot, SellerMetrics, Wishlist
    from api.domains.listings.sell_probability import (
        ListingSignals, compute_sell_probability, listing_advice,
    )
    from api.domains.trust.response_time import compute_all_response_times
    from sqlalchemy import func

    listing = await db.get(Listing, listing_id)
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found.")
    if listing.seller_id != current_user["id"]:
        raise HTTPException(status_code=403,
                            detail="You can only view metrics for your own listings.")

    likes_r = await db.execute(
        select(func.count(Wishlist.id)).where(Wishlist.listing_id == listing_id))
    likes = int(likes_r.scalar() or 0)

    interest_r = await db.execute(
        select(func.count(func.distinct(Interest.buyer_id)))
        .where(Interest.listing_id == listing_id))
    interested = int(interest_r.scalar() or 0)

    # Category median, from OTHER sellers' active listings in this category.
    #
    # Two exclusions that were both missing:
    #
    #   * the listing itself. Without it, a category containing one listing
    #     compared that listing against its own price - 0% off the median,
    #     "your price is competitive". A router listed at KES 30,000 against
    #     a real value near KES 2,000 was told it was priced correctly,
    #     because the only thing being measured was the seller's own guess
    #     handed back to them.
    #   * the same seller's other listings. Otherwise anyone can set their
    #     own benchmark by posting the same item five times, which is a
    #     cheaper attack than it sounds.
    median_r = await db.execute(
        select(Listing.price).where(
            Listing.category == listing.category,
            Listing.status == listing.status,
            Listing.price.isnot(None),
            Listing.id != listing_id,
            Listing.seller_id != listing.seller_id,
        ))
    prices = sorted(float(p) for (p,) in median_r.all() if p)
    comparable_count = len(prices)
    category_median = prices[len(prices) // 2] if prices else None

    metrics = await db.get(SellerMetrics, listing.seller_id)
    try:
        response_minutes = (await compute_all_response_times(db)).get(listing.seller_id)
    except Exception:
        response_minutes = None

    days_listed = ((datetime.utcnow() - listing.created_at).total_seconds() / 86400.0
                   if listing.created_at else 1.0)

    signals = ListingSignals(
        views=int(listing.views or 0),
        likes=likes,
        interested_buyers=interested,
        days_listed=max(days_listed, 1.0),
        seller_dcr_percent=metrics.dcr_score if metrics else None,
        seller_response_minutes=response_minutes,
        price=float(listing.price) if listing.price else None,
        category_median_price=category_median,
        comparable_count=comparable_count,
    )
    prob = compute_sell_probability(signals)

    since = date.today() - timedelta(days=days)
    hist_r = await db.execute(
        select(ListingMetricSnapshot)
        .where(ListingMetricSnapshot.listing_id == listing_id,
               ListingMetricSnapshot.snapshot_date >= since)
        .order_by(ListingMetricSnapshot.snapshot_date.asc()))
    rows = hist_r.scalars().all()

    # Daily view deltas, derived from the cumulative counter. First day has
    # no predecessor, so it is omitted rather than reported as its own total -
    # which would show a spike on day one of every listing.
    history = []
    prev_views = None
    for row in rows:
        history.append({
            "date": row.snapshot_date.isoformat(),
            "views": row.views,
            "views_today": (row.views - prev_views) if prev_views is not None else None,
            "likes": row.likes,
            "interested_buyers": row.interested_buyers,
            "sell_probability": row.sell_probability,
        })
        prev_views = row.views

    return {
        "listing_id": listing_id,
        "current": {
            "views": signals.views,
            "likes": likes,
            "like_to_view_ratio": round(likes / signals.views, 4) if signals.views else None,
            "interested_buyers": interested,
            "views_per_day": round(signals.views / max(days_listed, 1.0), 2),
            "days_listed": round(days_listed, 1),
            "sell_probability": prob.probability,
            "confidence": prob.confidence,
            "price": signals.price,
            "category_median_price": category_median,
            "price_delta_percent": prob.price_delta_percent,
            # Lets the screen say "not enough comparable listings" instead
            # of showing a percentage computed against nothing.
            "comparable_count": comparable_count,
            "has_price_benchmark": prob.price_delta_percent is not None,
            "components": {
                "demand": prob.demand, "intent": prob.intent,
                "commitment": prob.commitment, "seller": prob.seller,
                "price_fit": prob.price_fit,
            },
        },
        "history": history,
        "advice": listing_advice(signals, prob),
    }


@router.get("/seller/{seller_id}/receipts")
async def seller_receipts(
    seller_id: str,
    limit: int = Query(50, ge=1, le=200),
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Completed payments for this seller's deals.

    Provider-neutral in shape. The underlying table is named for M-Pesa
    because that is the rail that exists today, but the response exposes a
    generic `provider` and `reference` rather than `mpesa_receipt` - Airtel
    Money and anything added later settle into the same escrow, and a client
    written against `mpesa_receipt` would have to be rewritten to show them.
    """
    from api.database import Deal, Listing as L, MpesaStatus, MpesaTransaction, User

    if seller_id != current_user["id"]:
        raise HTTPException(status_code=403,
                            detail="You can only view your own receipts.")

    rows_r = await db.execute(
        select(MpesaTransaction, Deal, L.name, User.name)
        .join(Deal, Deal.id == MpesaTransaction.deal_id)
        .join(L, L.id == Deal.listing_id)
        .join(User, User.id == MpesaTransaction.buyer_id)
        .where(Deal.seller_id == seller_id,
               MpesaTransaction.status == MpesaStatus.success)
        .order_by(MpesaTransaction.created_at.desc())
        .limit(limit))

    receipts = []
    total = 0.0
    for txn, deal, listing_name, buyer_name in rows_r.all():
        total += float(txn.amount or 0)
        receipts.append({
            "id":          txn.id,
            "deal_id":     txn.deal_id,
            "listing":     listing_name,
            "buyer":       buyer_name,
            "amount":      float(txn.amount or 0),
            "provider":    "M-Pesa",
            "reference":   txn.mpesa_receipt,
            "paid_at":     txn.created_at.isoformat() if txn.created_at else None,
            "deal_status": deal.status.value if deal.status else None,
        })

    return {"receipts": receipts, "total": round(total, 2),
            "count": len(receipts)}


@router.get("/seller/{seller_id}/metrics")
async def seller_metrics(
    seller_id: str,
    days: int = Query(90, ge=7, le=730),
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Current standing plus the history series behind the dashboard graphs.

    Own metrics only. A seller's response time, backlog and rank position
    are competitive information - publishing them would let anyone profile
    every other seller on the platform, and rank position in particular
    tells a rival exactly how far they have to climb.

    `history` is one point per day from SellerMetricSnapshot. Days with no
    snapshot are simply absent rather than zero-filled: a gap in the line is
    honest about a job that did not run, while a zero is a false claim that
    the seller scored nothing that day.
    """
    if seller_id != current_user["id"]:
        raise HTTPException(status_code=403, detail="You can only view your own metrics.")

    from datetime import date, datetime, timedelta
    from api.database import Deal, DealStatus, SellerMetricSnapshot, SellerMetrics, User
    from api.domains.trust.completion_rate import _FUNDED_STATUSES
    from api.domains.trust.response_time import compute_all_response_times
    from api.domains.trust.seller_rating import (
        MIN_COUNTABLE_DEAL_VALUE_KES, SellerSignals, credibility_score,
        overall_rating,
    )
    from sqlalchemy import func

    user = await db.get(User, seller_id)
    if not user:
        raise HTTPException(status_code=404, detail="Seller not found.")

    metrics = await db.get(SellerMetrics, seller_id)
    dcr = metrics.dcr_score if metrics else None

    async def _count(*conds) -> int:
        r = await db.execute(select(func.count(Deal.id)).where(Deal.seller_id == seller_id, *conds))
        return int(r.scalar() or 0)

    completed = await _count(Deal.status.in_(_FUNDED_STATUSES))

    # Backlog counts only deals the SELLER is the blocker on.
    #
    # `status == agreed` counted every open thread, including ones the buyer
    # abandoned, ones where the seller already replied and is waiting, and
    # ones opened by someone with no intention of buying. A competitor could
    # inflate a rival's backlog just by starting conversations. See
    # domains/trust/deal_lifecycle - the attribution is a timestamp
    # comparison, not a model call.
    from api.domains.trust.deal_lifecycle import (
        assess_seller_deals, fair_backlog_count,
    )
    try:
        assessments = await assess_seller_deals(db, seller_id)
        pending = fair_backlog_count(assessments)
        open_total = len([a for a in assessments if a.stall.value != "closed"])
    except Exception as exc:
        # Falls back to the old definition rather than dropping the term.
        # An over-counted backlog is unfair; a missing one is wrong.
        import logging
        logging.getLogger(__name__).warning(
            "[metrics] deal lifecycle assessment failed (%s) - falling back "
            "to the raw open-deal count", exc)
        pending = await _count(Deal.status == DealStatus.agreed)
        open_total = pending
        assessments = []
    countable = await _count(Deal.status.in_(_FUNDED_STATUSES),
                             Deal.agreed_price >= MIN_COUNTABLE_DEAL_VALUE_KES)
    uniq_r = await db.execute(
        select(func.count(func.distinct(Deal.buyer_id)))
        .where(Deal.seller_id == seller_id, Deal.status.in_(_FUNDED_STATUSES)))
    unique_counterparties = int(uniq_r.scalar() or 0)

    # Live rather than from last night's snapshot: a seller who just closed
    # a deal should see it, not be told to come back tomorrow.
    try:
        median_minutes = (await compute_all_response_times(db)).get(seller_id)
    except Exception:
        median_minutes = None

    days_on = ((datetime.utcnow() - user.created_at).total_seconds() / 86400.0
               if user.created_at else 0.0)

    signals = SellerSignals(
        dcr_percent=dcr,
        median_response_minutes=median_minutes,
        completed_deals=completed,
        pending_deals=pending,
        days_on_broka=days_on,
        unique_counterparties=unique_counterparties,
        countable_value_deals=countable,
    )
    breakdown = overall_rating(signals)

    since = date.today() - timedelta(days=days)
    hist_r = await db.execute(
        select(SellerMetricSnapshot)
        .where(SellerMetricSnapshot.seller_id == seller_id,
               SellerMetricSnapshot.snapshot_date >= since)
        .order_by(SellerMetricSnapshot.snapshot_date.asc())
    )
    history = [{
        "date":            row.snapshot_date.isoformat(),
        "overall_rating":  row.overall_rating,
        "dcr":             row.dcr_score,
        "rank_position":   row.rank_position,
        "response_minutes": row.median_response_min,
        "completed_deals": row.completed_deals,
        "pending_deals":   row.pending_deals,
        "total_views":     row.total_views,
    } for row in hist_r.scalars().all()]

    current_block = {
            "overall_rating":        breakdown.rating,
            "dcr":                   dcr,
            "median_response_minutes": median_minutes,
            "completed_deals":       completed,
            "pending_deals":         pending,
            # Everything still open, including deals that do NOT count
            # against the seller - so the screen can show "8 open, 1 waiting
            # on you" rather than implying all eight are their fault.
            "open_deals":            open_total,
            "deal_breakdown": [
                {"deal_id": a.deal_id, "stage": a.stage.value,
                 "stall": a.stall.value, "counts": a.counts_against_seller,
                 "reason": a.reason}
                for a in assessments
            ],
            "days_on_broka":         round(days_on, 1),
            "unique_counterparties": unique_counterparties,
            # The breakdown is what lets the dashboard say WHY the number
            # moved instead of just showing it - Phase 3's "working for
            # you / against you" panel reads these directly.
            "components": {
                "dcr":      breakdown.dcr_component,
                "response": breakdown.response_component,
                "volume":   breakdown.volume_component,
                "tenure":   breakdown.tenure_component,
                "backlog":  breakdown.backlog_component,
            },
            "confidence": breakdown.confidence,
            "raw_rating": breakdown.raw_rating,
            # Track record rather than current form - see credibility_score.
            "credibility": credibility_score(signals),
    }
    # Rank position comes from last night's snapshot - it is a property of
    # the whole seller population, so recomputing it live for one request
    # would mean ranking every seller on the platform on a screen load.
    current_block["rank_position"] = history[-1]["rank_position"] if history else None

    from api.domains.trust.seller_advice import build_advice

    return {
        "current": current_block,
        # Absent days are gaps, not zeroes - see docstring.
        "history": history,
        "history_days": days,
        # Deterministic rules over the deltas above, not a model call:
        # Zeno cannot see a trend, and a fluent guess about one is worse
        # than no guess. See domains/trust/seller_advice.
        "advice": build_advice(current_block, history),
    }


@router.get("/seller/{seller_id}/revenue")
async def get_seller_revenue(
    seller_id: str,
    period: str = "week",
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Real revenue-over-time for the seller dashboard chart, aggregated
    from actually-completed (released) deals - a seller may only see their
    own revenue breakdown."""
    from fastapi import HTTPException
    if current_user["id"] != seller_id:
        raise HTTPException(status_code=403, detail="Not authorized for this seller's revenue")
    svc = ListingService(db)
    return await svc.get_seller_revenue(seller_id, period if period in ("week", "month") else "week")


@router.get("/{listing_id}")
async def get_listing(listing_id: str, db: AsyncSession = Depends(get_db)):
    svc = ListingService(db)
    return await svc.get_listing(listing_id)


@router.post("/{listing_id}/store")
async def set_listing_store(
    listing_id: str,
    body: ListingStoreIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Associate an existing listing with a store the caller owns."""
    svc = ListingService(db)
    return await svc.set_listing_store(listing_id, current_user["id"], body.store_id)


@router.delete("/{listing_id}/store")
async def remove_listing_store(
    listing_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Return a listing to personal (store_id=NULL)."""
    svc = ListingService(db)
    return await svc.remove_listing_store(listing_id, current_user["id"])


@router.post("/{listing_id}/interest")
async def express_interest(
    listing_id: str,
    body: InterestIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.express_interest(listing_id, current_user["id"], body.offer_price)


@router.get("/{listing_id}/matches")
async def get_matches(
    listing_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    svc = ListingService(db)
    return await svc.get_matches(listing_id)
