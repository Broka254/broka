"""BROKA - Auction Router: place bids, leaderboard ranking.

The bid ENDPOINT is deliberately thin. Every rule about whether a bid is
allowed - is the auction open, does the amount clear the increment, who
gets outbid - lives in api/domains/auctions/lifecycle.py, under a row
lock, because those rules have to hold for a sweep or a test calling the
same function directly, not only for traffic arriving through this route.

What this file used to do instead is worth stating, because the shape is
the bug: it read the top bid in one statement, inserted in another with no
lock, never looked at a clock, accepted any raise above the current bid
however small, and rejected any bid below the seller's reserve - turning a
secret walk-away price into a public minimum bid.
"""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel, Field
from typing import List
from datetime import datetime

from api.database import get_db, Bid, Listing, User
from api.security import get_current_user
from api.core.events import publish, BidPlaced
from api.core.rate_limit import offer_limiter
from api.domains.auctions import events as auction_events
from api.domains.auctions import lifecycle
from api.domains.auctions.lifecycle import AuctionError
from api.domains.auctions.paused import require_auctions

router = APIRouter()


class BidIn(BaseModel):
    listing_id: str
    # Bounded here as well as in lifecycle.place_bid: the schema gives the
    # caller a 422 naming the field, the service enforces it for every
    # other entry point into bidding.
    amount: float = Field(gt=0)


class BidOut(BaseModel):
    rank: int
    bidder_name: str
    amount: float
    time_ago: str


@router.post("/bid", status_code=201, dependencies=[Depends(require_auctions)])
async def place_bid(
    data: BidIn,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Place a bid. All validation is server-side and atomic - see
    domains/auctions/lifecycle.place_bid."""
    # Bidding moves money-shaped obligations, so it gets the same
    # per-user limiter the offer path already uses rather than none at all.
    await offer_limiter.check_and_record(current_user["id"])

    try:
        result = await lifecycle.place_bid(
            db,
            listing_id=data.listing_id,
            bidder_id=current_user["id"],
            amount=data.amount,
        )
    except AuctionError as e:
        # Structured so Flutter can react to the specific case (show the
        # new minimum, refresh an auction it thought was still live)
        # instead of parsing English out of `detail`.
        raise HTTPException(
            status_code=e.status_code,
            detail={"code": e.code, "message": e.message},
        )

    listing = (await db.execute(
        select(Listing).where(Listing.id == data.listing_id)
    )).scalar_one_or_none()
    listing_name = listing.name if listing else "an item"

    # Published after commit, once the bid is durable - mirrors
    # ListingCreated's ordering in domains/listings/service.py. This is what
    # the auction WebSocket broadcast hangs off.
    await publish(BidPlaced(
        listing_id=data.listing_id,
        bidder_id=current_user["id"],
        amount=result.amount,
    ))

    # The person who just lost the lead. A push, not only a socket frame:
    # the whole point is that it reaches them with the app closed.
    if result.outbid_user_id:
        await auction_events.emit_outbid(
            listing_id=data.listing_id,
            listing_name=listing_name,
            outbid_user_id=result.outbid_user_id,
            new_amount=result.amount,
        )

    return {
        "message": f"Bid of KES {result.amount:,.0f} placed successfully",
        "bid_id": result.bid_id,
        "amount": result.amount,
        "bid_count": result.bid_count,
        "min_next_bid": result.min_next_bid,
        "status": result.status,
        "reserve_met": result.reserve_met,
    }


@router.get("/{listing_id}/leaderboard", response_model=List[BidOut])
async def get_leaderboard(listing_id: str, db: AsyncSession = Depends(get_db)):
    """Every bid on the listing, highest first; the earlier of two equal bids
    ranks higher, since it was there first.

    This used to try a C++ ranking engine (`broka_engine`) before falling
    back to a sort in Python. No such module was ever built or installed,
    so only the fallback ever ran - and the C++ branch, had it run, would
    have shown a missing bidder's user id as their name and "-" for every
    time. The database does the ordering now; the extension that does exist
    (backend/native) has nothing to add to a sort SQL already does.
    """
    result = await db.execute(
        select(Bid)
        .where(Bid.listing_id == listing_id)
        .order_by(Bid.amount.desc(), Bid.created_at.asc(), Bid.id.asc())
    )
    bids = result.scalars().all()
    if not bids:
        return []

    bidder_ids = list({b.bidder_id for b in bids})
    result = await db.execute(select(User).where(User.id.in_(bidder_ids)))
    users = {u.id: u.name for u in result.scalars().all()}

    now = datetime.utcnow()

    def _time_ago(created_at: datetime) -> str:
        age_s = (now - created_at).total_seconds()
        if age_s < 60:
            return "just now"
        if age_s < 3600:
            return f"{int(age_s // 60)}m ago"
        return f"{int(age_s // 3600)}h ago"

    return [
        BidOut(
            rank=i + 1,
            bidder_name=users.get(b.bidder_id, "Bidder"),
            amount=b.amount,
            time_ago=_time_ago(b.created_at),
        )
        for i, b in enumerate(bids)
    ]
