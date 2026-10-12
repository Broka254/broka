"""Traders Router v1 — GET /traders, GET /traders/{id}."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
from api.security import get_current_user
from .service import TradersService

router = APIRouter()


@router.get("")
async def list_traders(
    category_id: Optional[str] = None,
    # The Traders screen's search box. Matches the trader's business and
    # display name only - never email or phone.
    search: Optional[str] = Query(None, max_length=100),
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    db: AsyncSession = Depends(get_db),
):
    # lat/lng are optional viewer coordinates for distance_km (Design v2
    # §30 lists "distance" as a trader-card element) - same pattern as
    # every other location-aware endpoint (listings, buy-agent action).
    return await TradersService(db).list_traders(
        category_id=category_id, search=search, viewer_lat=lat, viewer_lng=lng)


class TraderCoverIn(BaseModel):
    # An image uploaded through POST /media/images (purpose trader_cover, or
    # a store cover or photo); null removes the background.
    asset_id: Optional[str] = Field(None, max_length=64)


@router.post("/me/cover")
async def set_trader_cover(
    body: TraderCoverIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The signed-in trader's optional card background."""
    return await TradersService(db).set_cover(current_user["id"], body.asset_id)


@router.get("/{trader_id}")
async def get_trader(
    trader_id: str,
    lat: Optional[float] = None,
    lng: Optional[float] = None,
    db: AsyncSession = Depends(get_db),
):
    trader = await TradersService(db).get_trader(trader_id, viewer_lat=lat, viewer_lng=lng)
    if not trader:
        raise HTTPException(status_code=404, detail="Trader not found")
    return trader
