"""BROKA - Auction Router: place bids, leaderboard ranking."""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel
from typing import List
from datetime import datetime

from api.database import get_db, Bid, Listing, User, ListingType, AuctionMeta
from api.security import get_current_user
from api.core.events import publish, BidPlaced
import uuid

try:
    import broka_engine as engine
    CPP_ENGINE_AVAILABLE = True
except ImportError:
    CPP_ENGINE_AVAILABLE = False

router = APIRouter()


class BidIn(BaseModel):
    listing_id: str
    amount: float


class BidOut(BaseModel):
    rank: int
    bidder_name: str
    amount: float
    time_ago: str


@router.post("/bid", status_code=201)
async def place_bid(
    data: BidIn,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Listing).where(Listing.id == data.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")
    if listing.listing_type != ListingType.auction:
        raise HTTPException(status_code=400, detail="This listing is not an auction")

    if listing.reserve_price and data.amount < listing.reserve_price:
        raise HTTPException(
            status_code=400,
            detail=f"Bid must be at least KES {listing.reserve_price:,.0f} (reserve price)",
        )

    result = await db.execute(
        select(Bid)
        .where(Bid.listing_id == data.listing_id)
        .order_by(Bid.amount.desc())
        .limit(1)
    )
    top_bid = result.scalar_one_or_none()
    if top_bid and data.amount <= top_bid.amount:
        raise HTTPException(
            status_code=400,
            detail=f"Bid must exceed current highest: KES {top_bid.amount:,.0f}",
        )

    bid = Bid(
        listing_id=data.listing_id,
        bidder_id=current_user["id"],
        amount=data.amount,
    )
    db.add(bid)

    # Every auction-type Listing should have a one-to-one AuctionMeta row,
    # but nothing creates one at listing-creation time today, and this
    # table postdates any listings created before this migration - so the
    # first bid on such a listing lazily creates it rather than crashing.
    meta = (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == data.listing_id)
    )).scalar_one_or_none()
    if meta is None:
        meta = AuctionMeta(id=str(uuid.uuid4()), listing_id=data.listing_id, status="live")
        db.add(meta)
    meta.current_bid = data.amount
    meta.bid_count = (meta.bid_count or 0) + 1

    await db.commit()

    # Published after commit, once the bid is durable - mirrors
    # ListingCreated's ordering in domains/listings/service.py.
    await publish(BidPlaced(
        listing_id=data.listing_id,
        bidder_id=current_user["id"],
        amount=data.amount,
    ))

    return {"message": f"Bid of KES {data.amount:,.0f} placed successfully"}


@router.get("/{listing_id}/leaderboard", response_model=List[BidOut])
async def get_leaderboard(listing_id: str, db: AsyncSession = Depends(get_db)):
    result = await db.execute(select(Bid).where(Bid.listing_id == listing_id))
    bids = result.scalars().all()
    if not bids:
        return []

    bidder_ids = list({b.bidder_id for b in bids})
    result = await db.execute(select(User).where(User.id.in_(bidder_ids)))
    users = {u.id: u.name for u in result.scalars().all()}

    def _time_ago(created_at: datetime) -> str:
        age_s = (datetime.utcnow() - created_at).total_seconds()
        if age_s < 60:
            return "just now"
        if age_s < 3600:
            return f"{int(age_s // 60)}m ago"
        return f"{int(age_s // 3600)}h ago"

    if CPP_ENGINE_AVAILABLE:
        cpp_bids = []
        for b in bids:
            cb = engine.Bid()
            cb.bidder_id   = b.bidder_id
            cb.bidder_name = users.get(b.bidder_id, b.bidder_id)
            cb.amount      = b.amount
            cb.timestamp   = int(b.created_at.timestamp() * 1000)
            cpp_bids.append(cb)
        ranked = engine.rank_bids(cpp_bids)
        return [
            BidOut(
                rank=i + 1,
                bidder_name=b.bidder_name,
                amount=b.amount,
                time_ago="-",
            )
            for i, b in enumerate(ranked)
        ]
    else:
        sorted_bids = sorted(bids, key=lambda b: (-b.amount, b.created_at))
        return [
            BidOut(
                rank=i + 1,
                bidder_name=users.get(b.bidder_id, "Bidder"),
                amount=b.amount,
                time_ago=_time_ago(b.created_at),
            )
            for i, b in enumerate(sorted_bids)
        ]
