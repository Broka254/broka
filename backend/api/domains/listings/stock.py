"""How many of a listing's units are left, and whether buyers still see it.

A listing says how many units the seller has (Listing.quantity: 100 bags;
NULL reads as one). Each deal on it takes Deal.quantity of them (NULL reads
as one) from the moment the price is agreed - the buyer is on their way to
paying for those units, so nobody else is sold them - until the deal is
refunded or cancelled, which hands them back.

WHAT THIS REPLACED
==================
Agreeing any deal set the listing to "pending", which every buyer-facing
query leaves out. A seller of 100 bags disappeared from Home, search and
their store when the first buyer agreed to one; nothing ever set a listing
back to "active" when that deal was refunded or cancelled; and nothing set
a sold listing "completed". Now:

  active     units left: buyers see it
  pending    every unit is in a deal still under way: hidden
  completed  every unit has been sold and paid out: hidden
  cancelled  the seller deleted it (or it was taken off sale): never
             changed here

The listing moves when a deal is agreed (EscrowService.finalize_deal, under
the listing's row lock) and in the five-minute sweep (sync_listing_stock),
which catches every other way a deal ends - refunds, cancellations, payouts
- without touching the money paths that end them.

Auctions are left alone: one item, sold through its own lifecycle
(domains/auctions/lifecycle.py), which already sets these statuses itself.
"""
from __future__ import annotations

import logging
from typing import Optional

from sqlalchemy import case, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus, Listing, ListingStatus, ListingType

logger = logging.getLogger(__name__)

# A deal in one of these holds its units. Refunded and cancelled deals gave
# them back; "negotiating" is not an agreement (every Deal row is created at
# agreed, so this is belt and braces).
_RELEASING_STATUSES = (DealStatus.refunded, DealStatus.cancelled, DealStatus.negotiating)

# Statuses this module moves a listing between. Anything else - cancelled
# above all, a listing the seller deleted - is not stock's to change.
_STOCK_STATUSES = (ListingStatus.active, ListingStatus.pending, ListingStatus.completed)


def units_total(listing: Listing) -> int:
    q = getattr(listing, "quantity", None)
    return q if q and q > 0 else 1


def is_stocked(listing: Listing) -> bool:
    """Whether stock decides this listing's status: direct sales only."""
    t = getattr(listing.listing_type, "value", listing.listing_type)
    return t != ListingType.auction.value


async def units_taken(db: AsyncSession, listing_id: str) -> tuple[int, int]:
    """(units in deals that hold them, of which sold and paid out)."""
    units = func.coalesce(Deal.quantity, 1)
    row = (await db.execute(
        select(
            func.coalesce(func.sum(units), 0),
            # CASE rather than a FILTER clause: older SQLite has none.
            func.coalesce(func.sum(
                case((Deal.status == DealStatus.released, units), else_=0)), 0),
        ).where(
            Deal.listing_id == listing_id,
            Deal.status.not_in(_RELEASING_STATUSES),
        )
    )).one()
    return int(row[0] or 0), int(row[1] or 0)


async def units_left(db: AsyncSession, listing: Listing) -> int:
    taken, _ = await units_taken(db, listing.id)
    return max(units_total(listing) - taken, 0)


def status_for(listing: Listing, taken: int, sold: int) -> Optional[ListingStatus]:
    """The status stock says a direct listing should have, or None when it
    isn't stock's to decide."""
    current = getattr(listing.status, "value", listing.status)
    if not is_stocked(listing) or current not in {s.value for s in _STOCK_STATUSES}:
        return None
    total = units_total(listing)
    if sold >= total:
        return ListingStatus.completed
    if taken >= total:
        return ListingStatus.pending
    return ListingStatus.active


async def sync_listing_stock(db: AsyncSession, now=None) -> int:
    """The sweep: bring every direct listing's status in line with its
    deals. Returns how many listings changed.

    Looks only at listings stock has hidden (pending, completed) and at
    active ones that have any deal - a listing no one has agreed to buy
    has all its units by definition. One grouped query for the units,
    then one UPDATE per listing that actually changes."""
    units = func.coalesce(Deal.quantity, 1)
    taken_q = (
        select(Deal.listing_id.label("listing_id"),
               func.sum(units).label("taken"))
        .where(Deal.status.not_in(_RELEASING_STATUSES))
        .group_by(Deal.listing_id)
        .subquery()
    )
    sold_q = (
        select(Deal.listing_id.label("listing_id"),
               func.sum(units).label("sold"))
        .where(Deal.status == DealStatus.released)
        .group_by(Deal.listing_id)
        .subquery()
    )
    rows = (await db.execute(
        select(Listing, func.coalesce(taken_q.c.taken, 0), func.coalesce(sold_q.c.sold, 0))
        .outerjoin(taken_q, taken_q.c.listing_id == Listing.id)
        .outerjoin(sold_q, sold_q.c.listing_id == Listing.id)
        .where(
            or_(Listing.listing_type.is_(None), Listing.listing_type != ListingType.auction),
            (Listing.status.in_((ListingStatus.pending, ListingStatus.completed)))
            | ((Listing.status == ListingStatus.active) & taken_q.c.taken.is_not(None)),
        )
    )).all()

    changed = 0
    for listing, taken, sold in rows:
        target = status_for(listing, int(taken or 0), int(sold or 0))
        current = getattr(listing.status, "value", listing.status)
        if target is None or target.value == current:
            continue
        # Compare-and-set on the status read above: a seller deleting the
        # listing in the meantime (status -> cancelled) is not undone.
        result = await db.execute(
            Listing.__table__.update()
            .where(Listing.id == listing.id, Listing.status == listing.status)
            .values(status=target)
        )
        if result.rowcount:
            changed += 1
            logger.info("[stock] listing %s %s -> %s (taken=%s sold=%s of %s)",
                        listing.id, current, target.value, taken, sold,
                        units_total(listing))
    await db.commit()
    return changed
