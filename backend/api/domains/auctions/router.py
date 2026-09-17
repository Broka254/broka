"""Auctions Router v1 — GET /auctions, GET /auctions/{listing_id}."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from .service import AuctionsService

router = APIRouter()


@router.get("")
async def list_auctions(status: Optional[str] = None, db: AsyncSession = Depends(get_db)):
    return await AuctionsService(db).list_auctions(status=status)


@router.get("/{listing_id}")
async def get_auction(listing_id: str, db: AsyncSession = Depends(get_db)):
    auction = await AuctionsService(db).get_auction(listing_id)
    if not auction:
        raise HTTPException(status_code=404, detail="Auction not found")
    return auction
