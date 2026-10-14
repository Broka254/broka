"""Auctions Router — GET /auctions, GET /auctions/{listing_id},
PATCH /auctions/{listing_id}/terms."""
from __future__ import annotations

from datetime import datetime
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import AuctionMeta, Listing, get_db
from api.security import get_current_user
from . import lifecycle
from .lifecycle import AuctionError
from .paused import auctions_enabled, require_auctions
from .service import AuctionsService

router = APIRouter()


@router.get("")
async def list_auctions(status: Optional[str] = None, db: AsyncSession = Depends(get_db)):
    # Empty rather than refused while auctions are off (auctions/paused.py):
    # an older build's Auction House then shows its "No auctions here yet"
    # instead of an error.
    if not auctions_enabled():
        return []
    return await AuctionsService(db).list_auctions(status=status)


class AuctionTermsIn(BaseModel):
    """The auction's contract with its bidders.

    Every field optional - a seller adjusting only the end time sends only
    the end time. Omitted means unchanged, not cleared, with one deliberate
    exception noted on reserve_price.
    """
    starting_price: Optional[float] = Field(default=None, gt=0)
    min_bid_increment: Optional[float] = Field(default=None, gt=0)
    starts_at: Optional[datetime] = None
    ends_at: Optional[datetime] = None
    reserve_price: Optional[float] = Field(default=None, gt=0)
    # The only way to REMOVE a reserve, since a plain null means "unchanged"
    # for every other field and quietly dropping a reserve because a field
    # was omitted would be the worst possible interpretation.
    clear_reserve: bool = False

    @field_validator("starts_at", "ends_at")
    @classmethod
    def _as_naive_utc(cls, v: Optional[datetime]) -> Optional[datetime]:
        # Clients send "...Z" (the Flutter app always does). Pydantic parses
        # that as timezone-aware, and an aware value compared against the
        # stored naive-UTC window raised a TypeError - every such request
        # was a 500. Convert to the stored convention at the boundary.
        from api.core.timeutil import to_naive_utc
        return to_naive_utc(v) if v is not None else None


@router.patch("/{listing_id}/terms", dependencies=[Depends(require_auctions)])
async def update_auction_terms(
    listing_id: str,
    body: AuctionTermsIn,
    db: AsyncSession = Depends(get_db),
    current_user: dict = Depends(get_current_user),
):
    """Configure an auction before bidding opens.

    Locked the moment the auction goes live or takes its first bid, and
    after it closes: these terms are what bidders committed money against,
    and moving them afterwards changes the deal underneath people who
    already bid. Photos and other listing media stay editable through
    PATCH /listings/{id} throughout - see lifecycle.assert_terms_editable.
    """
    listing = await db.get(Listing, listing_id)
    if listing is None:
        raise HTTPException(status_code=404, detail="Listing not found.")
    if listing.seller_id != current_user["id"]:
        raise HTTPException(
            status_code=403, detail="You can only change your own auction.")

    meta = (await db.execute(
        select(AuctionMeta).where(AuctionMeta.listing_id == listing_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if meta is None:
        raise HTTPException(status_code=404, detail="This listing is not an auction.")

    try:
        lifecycle.assert_terms_editable(meta)

        # Validate the RESULTING terms, not just the submitted ones - an
        # end time is only valid against whatever start time the auction
        # will actually have once this request is applied.
        starts_at = body.starts_at or meta.starts_at
        ends_at = body.ends_at or meta.ends_at
        starting_price = body.starting_price or meta.starting_price
        reserve = (
            None if body.clear_reserve
            else (body.reserve_price if body.reserve_price is not None
                  else listing.reserve_price)
        )
        lifecycle.validate_terms(
            starting_price=starting_price,
            min_bid_increment=body.min_bid_increment or meta.min_bid_increment,
            starts_at=starts_at,
            ends_at=ends_at,
            reserve_price=reserve,
            now=datetime.utcnow(),
        )
    except AuctionError as e:
        raise HTTPException(
            status_code=e.status_code,
            detail={"code": e.code, "message": e.message},
        )

    if body.starting_price is not None:
        meta.starting_price = body.starting_price
        # listing.price IS the auction's opening number everywhere it is
        # displayed, so the two must move together or the grid and the
        # auction disagree about what the auction opens at.
        listing.price = body.starting_price
    if body.min_bid_increment is not None:
        meta.min_bid_increment = body.min_bid_increment
    if body.starts_at is not None:
        meta.starts_at = body.starts_at
    if body.ends_at is not None:
        meta.ends_at = body.ends_at
        listing.auction_date = body.ends_at
    if body.clear_reserve:
        listing.reserve_price = None
    elif body.reserve_price is not None:
        listing.reserve_price = body.reserve_price

    meta.status = lifecycle.effective_status(meta)
    await db.commit()
    await db.refresh(meta)
    await db.refresh(listing)

    return await lifecycle.public_state(db, listing, meta)


@router.get("/{listing_id}")
async def get_auction(listing_id: str, db: AsyncSession = Depends(get_db)):
    auction = await AuctionsService(db).get_auction(listing_id)
    if not auction:
        raise HTTPException(status_code=404, detail="Auction not found")
    return auction
