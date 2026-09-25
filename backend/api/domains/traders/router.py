"""Traders Router v1 — GET /traders, GET /traders/{id}."""
from __future__ import annotations

from typing import Optional
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import get_db
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
