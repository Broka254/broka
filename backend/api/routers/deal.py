"""BROKA - Deal Router: finalise agreed deals and reveal contacts."""

import logging
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import select
from pydantic import BaseModel

from api.database import get_db, Deal, Listing, User, ListingStatus
from api.security import get_current_user

router = APIRouter()
logger = logging.getLogger(__name__)

COMMISSION_RATE = 0.03


class DealIn(BaseModel):
    listing_id:   str
    buyer_id:     str
    agreed_price: float


class DealOut(BaseModel):
    id:                str = ""
    deal_id:           str
    agreed_price:      float
    commission:        float
    savings_vs_broker: float
    seller_name:       str
    seller_phone:      str
    buyer_name:        str
    buyer_phone:       str


@router.post("/finalize", response_model=DealOut)
async def finalize_deal(
    data: DealIn,
    current_user=Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    result = await db.execute(select(Listing).where(Listing.id == data.listing_id))
    listing = result.scalar_one_or_none()
    if not listing:
        raise HTTPException(status_code=404, detail="Listing not found")
    # Either the buyer or the seller can finalise
    logger.info(
        "[deal.finalize] current_user=%s listing.seller_id=%s data.buyer_id=%s listing_id=%s",
        current_user["id"], listing.seller_id, data.buyer_id, data.listing_id,
    )
    if current_user["id"] not in (listing.seller_id, data.buyer_id):
        raise HTTPException(status_code=403, detail="Not authorised to finalise this deal")

    commission = round(data.agreed_price * COMMISSION_RATE, 2)
    savings    = round(data.agreed_price * 0.10 - commission, 2)

    deal = Deal(
        listing_id=data.listing_id,
        seller_id=listing.seller_id,
        buyer_id=data.buyer_id,
        agreed_price=data.agreed_price,
        commission=commission,
    )
    db.add(deal)

    listing.status = ListingStatus.completed
    await db.commit()
    await db.refresh(deal)

    sr = await db.execute(select(User).where(User.id == listing.seller_id))
    seller = sr.scalar_one_or_none()
    br = await db.execute(select(User).where(User.id == data.buyer_id))
    buyer = br.scalar_one_or_none()

    result_out = DealOut(
        deal_id=deal.id,
        id=deal.id,
        agreed_price=data.agreed_price,
        commission=commission,
        savings_vs_broker=savings,
        seller_name=seller.name  if seller else "Seller",
        seller_phone=seller.phone if seller and seller.phone else "N/A",
        buyer_name=buyer.name    if buyer  else "Buyer",
        buyer_phone=buyer.phone  if buyer and buyer.phone else "N/A",
    )
    logger.info("[deal.finalize] returning: %s", result_out.model_dump())
    return result_out
