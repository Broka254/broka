"""Auctions Service — merges Listing + auction_meta + bid history for the
Auction House and the auction detail screen.

Bidding and closing live in lifecycle.py (Ch.6 keeps bidding out of this
file; the lifecycle module is where the rules that must hold for every
caller live). This service is the READ side, and it deliberately builds
its payload from lifecycle.public_state so a client can never be shown a
status this service derived differently from the one the bid endpoint
enforces - that divergence is how a UI ends up offering a "Place bid"
button on an auction the server has already closed.
"""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AuctionMeta, Bid, Listing, User
from . import lifecycle


class AuctionsService:
    def __init__(self, db: AsyncSession):
        self.db = db

    async def list_auctions(
        self, status: Optional[str] = None, limit: int = 20,
    ) -> list[dict]:
        """Auctions for the grid.

        `status` filters on the DERIVED status, not the cached column: an
        auction whose ends_at passed a minute ago is ENDED and must not come
        back under status=live just because the close sweep hasn't run. The
        cached column narrows the SQL; the derived status decides.
        """
        query = select(Listing, AuctionMeta).join(
            AuctionMeta, AuctionMeta.listing_id == Listing.id
        )
        # Over-fetch when filtering, since some rows will be dropped by the
        # derived-status check below.
        rows = (await self.db.execute(
            query.limit(limit * 3 if status else limit)
        )).all()

        now = datetime.utcnow()
        out = []
        for listing, meta in rows:
            if status and lifecycle.effective_status(meta, now) != status:
                continue
            out.append(self._summary(listing, meta, now))
            if len(out) >= limit:
                break
        return out

    async def get_auction(self, listing_id: str) -> Optional[dict]:
        row = (await self.db.execute(
            select(Listing, AuctionMeta)
            .join(AuctionMeta, AuctionMeta.listing_id == Listing.id)
            .where(Listing.id == listing_id)
        )).first()
        if not row:
            return None
        listing, meta = row

        bids = (await self.db.execute(
            select(Bid).where(Bid.listing_id == listing_id)
            .order_by(Bid.amount.desc(), Bid.created_at.asc())
        )).scalars().all()
        names = {}
        if bids:
            bidder_ids = {b.bidder_id for b in bids}
            names = {
                u.id: u.name for u in (await self.db.execute(
                    select(User).where(User.id.in_(bidder_ids))
                )).scalars().all()
            }

        out = await lifecycle.public_state(self.db, listing, meta)
        out.update(self._identity(listing, meta))
        out["bid_history"] = [
            {
                "bidder_id": b.bidder_id,
                "bidder_name": names.get(b.bidder_id, "Bidder"),
                "amount": b.amount,
                "created_at": b.created_at.isoformat() if b.created_at else None,
            }
            for b in bids
        ]
        return out

    def _identity(self, listing: Listing, meta: AuctionMeta) -> dict:
        return {
            "id": listing.id,
            "listing_id": listing.id,
            "name": listing.name,
            "seller_id": listing.seller_id,
            "target_bidders": listing.target_bidders,
            "location_name": listing.location_name,
            # Kept for older clients that still read it. ends_at is the real
            # closing time; this is the legacy single timestamp it was
            # backfilled from (see migration 0021).
            "auction_date": listing.auction_date.isoformat() if listing.auction_date else None,
        }

    def _summary(self, listing: Listing, meta: AuctionMeta, now: datetime) -> dict:
        """Grid payload. Deliberately does NOT carry reserve_price - see
        lifecycle.public_state on why a reserve is never sent to a client."""
        out = self._identity(listing, meta)
        out.update({
            "status": lifecycle.effective_status(meta, now),
            "current_bid": meta.current_bid,
            "bid_count": meta.bid_count or 0,
            "min_bid_increment": meta.min_bid_increment,
            "min_next_bid": lifecycle.minimum_next_bid(meta),
            "starting_price": meta.starting_price,
            "starts_at": meta.starts_at.isoformat() if meta.starts_at else None,
            "ends_at": meta.ends_at.isoformat() if meta.ends_at else None,
            "server_time": now.isoformat(),
            "seconds_remaining": (
                max(0, int((meta.ends_at - now).total_seconds())) if meta.ends_at else None
            ),
            "has_reserve": bool(listing.reserve_price),
            "reserve_met": lifecycle.reserve_met(meta, listing.reserve_price),
            "outcome": meta.outcome,
            "winner_id": meta.winner_id,
            "winning_amount": meta.winning_amount,
        })
        return out
