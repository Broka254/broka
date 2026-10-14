"""Buyers reporting a listing sold out, and its seller saying it isn't.

Buyers pay sellers outside BROKA, so the app never learns that an item sold;
the stock module no longer guesses it from agreed deals (stock.deals_hold_stock).
The person who learns it is a buyer who asks and hears "it's gone". Their
report marks the listing sold out - out of the feed, search, stores and
trending (paid.live_clause) - and tells the seller, who can revoke it if the
item is still there. A report can't be repeated by the same person once
revoked (models/sold_out_report.py), so one rival can't keep a seller's
listing down.
"""
from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing, ListingStatus
from api.models.sold_out_report import SoldOutReport

from .paid import is_live

logger = logging.getLogger(__name__)

# Reports one person can make in a day: enough for a buyer working down a
# list of dead ads, too few to sweep a rival's whole catalogue.
MAX_REPORTS_PER_DAY = 10


async def report(db: AsyncSession, listing_id: str, reporter_id: str) -> dict:
    listing = await db.get(Listing, listing_id)
    if listing is None or not is_live(listing):
        raise HTTPException(status_code=404, detail="Listing not found")
    if listing.seller_id == reporter_id:
        raise HTTPException(status_code=400, detail="Delete your own listing instead - it's under My listings.")
    if getattr(listing.status, "value", listing.status) != ListingStatus.active.value:
        raise HTTPException(status_code=409, detail="This listing is no longer for sale.")

    existing = (await db.execute(
        select(SoldOutReport).where(SoldOutReport.listing_id == listing_id,
                                    SoldOutReport.reporter_id == reporter_id)
    )).scalar_one_or_none()
    if existing is not None:
        if existing.revoked_at is not None:
            raise HTTPException(status_code=409, detail=(
                "The seller has said this item is still available. "
                "If it isn't, report the listing instead."))
        return _state(listing)

    today = (await db.execute(
        select(func.count(SoldOutReport.id)).where(
            SoldOutReport.reporter_id == reporter_id,
            SoldOutReport.created_at > datetime.utcnow() - timedelta(days=1))
    )).scalar() or 0
    if today >= MAX_REPORTS_PER_DAY:
        raise HTTPException(status_code=429, detail="You've reported enough listings for today. Thank you!")

    db.add(SoldOutReport(listing_id=listing_id, reporter_id=reporter_id))
    newly_marked = listing.sold_out_reported_at is None
    if newly_marked:
        listing.sold_out_reported_at = datetime.utcnow()
    try:
        await db.commit()
    except IntegrityError:
        # The same person's double tap: the other request recorded it.
        await db.rollback()
        listing = await db.get(Listing, listing_id)
        return _state(listing)
    if newly_marked:
        _tell_seller(listing.seller_id, listing.id, listing.name)
    return _state(listing)


async def revoke(db: AsyncSession, listing_id: str, seller_id: str) -> dict:
    """The seller says the item is still available: back on sale."""
    listing = await db.get(Listing, listing_id)
    if listing is None or listing.seller_id != seller_id:
        raise HTTPException(status_code=404, detail="Listing not found")
    now = datetime.utcnow()
    await db.execute(
        update(SoldOutReport)
        .where(SoldOutReport.listing_id == listing_id, SoldOutReport.revoked_at.is_(None))
        .values(revoked_at=now))
    listing.sold_out_reported_at = None
    await db.commit()
    return _state(listing)


def _state(listing: Listing) -> dict:
    at = listing.sold_out_reported_at
    return {"listing_id": listing.id, "reported_sold_out": at is not None,
            "reported_at": at.isoformat() if at else None}


def _tell_seller(seller_id: str, listing_id: str, name: str) -> None:
    """A push to the seller, after the commit and never in the way of it."""
    from api.core import push_devices

    async def send():
        await push_devices.push_user(
            seller_id,
            title="A buyer says this has sold",
            body=f'"{name}" is hidden from buyers. Still available? Open it and tap "Still available".',
            data={"type": "listing_sold_out_reported", "listing_id": listing_id},
        )

    try:
        asyncio.get_running_loop().create_task(send())
    except RuntimeError:  # no loop (a direct call in a test)
        logger.debug("[sold_out] no loop to push on")
