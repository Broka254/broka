"""Auctions Service v1 — merges Listing + auction_meta + bid history for
the Auction House. Bidding itself stays in routers/auction.py (Ch.6).
"""
from __future__ import annotations

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, AuctionMeta, Bid


class AuctionsService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_auctions(self, status: str | None = None, limit: int = 20) -> list[dict]:
        query = select(Listing, AuctionMeta).join(AuctionMeta, AuctionMeta.listing_id == Listing.id)
        if status:
            query = query.where(AuctionMeta.status == status)
        rows = (await self.db.execute(query.limit(limit))).all()
        return [self._summary(l, m) for l, m in rows]

    async def get_auction(self, listing_id: str) -> dict | None:
        row = (await self.db.execute(
            select(Listing, AuctionMeta).join(AuctionMeta, AuctionMeta.listing_id == Listing.id)
            .where(Listing.id == listing_id)
        )).first()
        if not row:
            return None
        listing, meta = row
        bids = (await self.db.execute(
            select(Bid).where(Bid.listing_id == listing_id).order_by(Bid.created_at.desc())
        )).scalars().all()
        out = self._summary(listing, meta)
        out["bid_history"] = [{"bidder_id": b.bidder_id, "amount": b.amount} for b in bids]
        return out

    def _summary(self, listing: Listing, meta: AuctionMeta) -> dict:
        return {
            "id": listing.id, "name": listing.name, "status": meta.status,
            "current_bid": meta.current_bid, "bid_count": meta.bid_count,
            "min_bid_increment": meta.min_bid_increment, "winner_id": meta.winner_id,
            "auction_date": listing.auction_date.isoformat() if listing.auction_date else None,
            "reserve_price": listing.reserve_price, "target_bidders": listing.target_bidders,
            "location_name": listing.location_name,
        }
