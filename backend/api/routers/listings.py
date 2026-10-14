# ==========================================================================
# DEAD CODE - NOT MOUNTED, NOT IMPORTED.
#
# Verified 2026-09-14 by reading main.py directly rather than trusting
# comments: this module's name does not appear in main.py's
# `from api.routers import (...)` tuple, and no `app.include_router(...)`
# call references it. Nothing in the backend imports it either. None of
# its routes are reachable at runtime.
#
# Canonical replacement: api/domains/listings/router.py  (mounted at /listings)
#
# QUARANTINED, NOT DELETED (spec section 21). Deleting it is a separate,
# reversible commit that should be made once someone has confirmed no
# out-of-tree consumer (a script, a notebook, an ops runbook) imports it.
# Leaving it importable but clearly marked costs nothing; deleting it
# blind is the failure mode that section warns about.
#
# Do not add routes here. Do not mount this module.
# ==========================================================================
"""
⚠️  NOT MOUNTED — LEGACY / DEAD CODE  ⚠️
─────────────────────────────────────────────────────────────────────
Verified during the Store hardening pass (2026-09): this router is never
imported or registered anywhere in this repository. Checked directly -
grepped the whole codebase for "routers.listings" / "routers/listings" -
zero results, including in main.py's router registrations.

THE CANONICAL, ACTUALLY-MOUNTED LISTINGS IMPLEMENTATION IS:
    api/domains/listings/router.py  (registered in main.py as
    `app.include_router(listings_router, prefix="/listings", ...)`)
    api/domains/listings/service.py

If you're looking for where to add or fix listing behavior (including
Store integration - Listing.store_id, store-filtered feeds, etc.), that's
where it lives, not here.

This file is left in place rather than deleted (a genuine, working
implementation, including a C++ buyer-matching engine integration -
`broka_engine` - that was never ported to the canonical router and may be
worth revisiting on its own someday) - but it should NOT be edited as
part of ordinary Store/Listings work, since changes here have no effect
on the running application.
─────────────────────────────────────────────────────────────────────

BROKA - Listings Router: CRUD + optional C++ buyer matching.
"""

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select, func
from typing import Optional
import math

from api.database import get_db, Listing, User, Interest, ListingStatus, Deal
from api.schemas import ListingCreate, InterestCreate
from api.security import get_current_user

try:
    import broka_engine as engine
    CPP_ENGINE_AVAILABLE = True
except ImportError:
    CPP_ENGINE_AVAILABLE = False

router = APIRouter()


def _haversine_km(lat1, lng1, lat2, lng2):
    """Calculate distance between two coordinates in km."""
    R = 6371
    dlat = math.radians(lat2 - lat1)
    dlng = math.radians(lng2 - lng1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlng/2)**2
    return R * 2 * math.asin(math.sqrt(a))


@router.get("/stats")
async def get_stats(db: AsyncSession = Depends(get_db)):
    """Return live marketplace stats - no hardcoded values."""
    listing_count = await db.execute(
        select(func.count(Listing.id)).where(Listing.status == ListingStatus.active)
    )
    auction_count = await db.execute(
        select(func.count(Listing.id)).where(
            Listing.status == ListingStatus.active,
            Listing.listing_type == "auction"
        )
    )
    volume_result = await db.execute(
        select(func.sum(Deal.agreed_price)).where(Deal.status == "agreed")
    )
    total_listings = listing_count.scalar() or 0
    total_auctions = auction_count.scalar() or 0
    market_volume  = volume_result.scalar() or 0.0

    return {
        "total_listings": total_listings,
        "live_auctions":  total_auctions,
        "market_volume":  market_volume,
    }


@router.post("/", status_code=201)
async def create_listing(
    data: ListingCreate,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    listing = Listing(
        seller_id=current_user["id"],
        name=data.name,
        description=data.description,
        category=data.category,
        price=data.price,
        lat=data.lat,
        lng=data.lng,
        location_name=data.location_name,
        listing_type=data.listing_type,
        target_bidders=data.target_bidders,
        reserve_price=data.reserve_price,
        verified_photos=data.verified_photos,
        verified_video=data.verified_video,
        advert_video=data.advert_video,
    )
    db.add(listing)
    await db.commit()
    await db.refresh(listing)
    return {"message": "Listing created", "listing_id": listing.id}


@router.get("/")
async def get_listings(
    category: Optional[str] = Query(default=None),
    listing_type: Optional[str] = Query(default=None),
    seller_id: Optional[str] = Query(default=None),
    limit: int = Query(default=20, le=100),
    offset: int = Query(default=0, ge=0),
    db: AsyncSession = Depends(get_db),
):
    q = select(Listing, User).join(User, Listing.seller_id == User.id).where(
        Listing.status == ListingStatus.active
    )
    if category:
        q = q.where(Listing.category == category)
    if listing_type:
        q = q.where(Listing.listing_type == listing_type)
    if seller_id:
        q = q.where(Listing.seller_id == seller_id)
    q = q.order_by(Listing.created_at.desc()).offset(offset).limit(limit)
    result = await db.execute(q)
    rows = result.all()
    return [
        {
            "id": l.id,
            "name": l.name,
            "category": l.category,
            "price": l.price,
            "location_name": l.location_name,
            "lat": l.lat,
            "lng": l.lng,
            "listing_type": l.listing_type,
            "status": l.status,
            "views": l.views,
            "verified_photos": l.verified_photos,
            "verified_video": l.verified_video,
            "advert_video": l.advert_video,
            "seller_id": l.seller_id,
            "seller_name": u.name,
            "seller_rating": u.rating,
            "seller_completed_deals": u.completed_deals,
            "seller_lat": u.lat,
            "seller_lng": u.lng,
        }
        for l, u in rows
    ]


@router.get("/{listing_id}")
async def get_listing(listing_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(
        select(Listing, User).join(User, Listing.seller_id == User.id).where(Listing.id == listing_id)
    )
    row = result.one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Listing not found")
    l, u = row
    return {
        "id": l.id,
        "name": l.name,
        "category": l.category,
        "price": l.price,
        "description": l.description,
        "location_name": l.location_name,
        "lat": l.lat,
        "lng": l.lng,
        "listing_type": l.listing_type,
        "status": l.status,
        "views": l.views,
        "verified_photos": l.verified_photos,
        "verified_video": l.verified_video,
        "advert_video": l.advert_video,
        "seller_id": l.seller_id,
        "seller_name": u.name,
        "seller_rating": u.rating,
        "seller_completed_deals": u.completed_deals,
        "seller_lat": u.lat,
        "seller_lng": u.lng,
    }


@router.get("/{listing_id}/matches")
async def get_matches(
    listing_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Use C++ engine to find top buyers for a listing (falls back to empty list)."""
    result = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    if not CPP_ENGINE_AVAILABLE:
        return []

    result = await db.execute(
        select(User).where(User.id != listing.seller_id, User.lat.isnot(None))
    )
    users = result.scalars().all()
    if not users:
        return []

    cpp_listing = engine.Listing()
    cpp_listing.id       = listing.id
    cpp_listing.name     = listing.name
    cpp_listing.category = listing.category
    cpp_listing.price    = listing.price
    cpp_listing.lat      = listing.lat
    cpp_listing.lng      = listing.lng

    cpp_buyers = []
    for u in users:
        b = engine.Buyer()
        b.id       = u.id
        b.name     = u.name
        b.lat      = u.lat
        b.lng      = u.lng
        b.budget   = listing.price * 1.2
        b.category = listing.category
        b.rating   = u.rating
        cpp_buyers.append(b)

    matches = engine.find_matches(cpp_listing, cpp_buyers, 10)
    return [
        {
            "buyer_id":    m.buyer_id,
            "buyer_name":  m.buyer_name,
            "score":       round(m.score, 1),
            "distance_km": round(m.distance_km, 2),
            "price_gap":   round(m.price_gap, 0),
        }
        for m in matches
    ]


@router.post("/{listing_id}/interest", status_code=201)
async def express_interest(
    listing_id: str,
    body: InterestCreate,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    interest = Interest(
        listing_id=listing_id,
        buyer_id=current_user["id"],
        offer_price=body.offer_price,
    )
    db.add(interest)
    await db.commit()
    return {"message": "Interest registered"}


def _name_similarity(a: str, b: str) -> float:
    """Lightweight word-overlap similarity (0-1). Good enough for matching
    short product names ('Xpon router' vs 'TP-Link router') without needing
    an embeddings model - cheap, no extra dependency, runs in Python."""
    wa = set(w for w in a.lower().split() if len(w) > 2)
    wb = set(w for w in b.lower().split() if len(w) > 2)
    if not wa or not wb:
        return 0.0
    return len(wa & wb) / len(wa | wb)


@router.get("/{listing_id}/price-comparison")
async def get_price_comparison(
    listing_id: str,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """
    Real on-platform price comparison: finds other ACTIVE listings in the
    same category with similar names, and computes a genuine average from
    that actual data - not a fixed heuristic multiplier.

    Returns has_enough_data=False when fewer than MIN_SAMPLES comparable
    listings exist, so the client/Zeno can fall back to general market
    knowledge instead of presenting a misleading "average" from 1-2 items.
    """
    MIN_SAMPLES = 3
    NAME_SIMILARITY_THRESHOLD = 0.25

    result = await db.execute(select(Listing).where(Listing.id == listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")

    candidates_result = await db.execute(
        select(Listing).where(
            Listing.category == listing.category,
            Listing.id != listing.id,
            Listing.status == ListingStatus.active,
        )
    )
    candidates = candidates_result.scalars().all()

    similar = [
        c for c in candidates
        if _name_similarity(listing.name, c.name) >= NAME_SIMILARITY_THRESHOLD
    ]

    if len(similar) < MIN_SAMPLES:
        return {
            "has_enough_data": False,
            "sample_size": len(similar),
            "min_samples_needed": MIN_SAMPLES,
            "platform_avg_price": None,
            "diff_pct": None,
            "similar_listings": [
                {"id": c.id, "name": c.name, "price": c.price} for c in similar
            ],
        }

    prices = [c.price for c in similar]
    avg_price = sum(prices) / len(prices)
    diff_pct = ((listing.price - avg_price) / avg_price * 100) if avg_price > 0 else 0.0

    return {
        "has_enough_data": True,
        "sample_size": len(similar),
        "platform_avg_price": round(avg_price, 2),
        "diff_pct": round(diff_pct, 1),
        "similar_listings": [
            {"id": c.id, "name": c.name, "price": c.price}
            for c in sorted(similar, key=lambda c: _name_similarity(listing.name, c.name), reverse=True)[:5]
        ],
    }
