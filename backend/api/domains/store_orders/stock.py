"""Tracked stock for store orders: reserved when the store accepts, given
back when an order ends without a sale, taken off when it is handed over.

WHAT "TRACKED" MEANS
====================
Listing.quantity has always been what the seller said they have ("100
bags"), and NULL has read as one (listings/stock.py). A seller now opts a
store product into tracking (Listing.stock_tracked), and from then on the
listing's units are counted - for store orders and chat deals alike - by
listings/inventory.py:

  available = quantity - stock_reserved - units chat deals hold

Deals agreed in chat count their units from their Deal rows without touching
`quantity`; orders reserve, then deduct at handover. Neither writes what the
other reads, so the two add up without double counting.

An untracked product is never treated as out of stock - its availability
is the seller's to confirm on each order, as it always was. Its quantity
caps how many a buyer can ask for, the same cap the storefront's cart has
always had.

THE LOCK, THEN ONE CONDITIONAL UPDATE
=====================================
Before reserving, the caller locks the listing rows and counts them
(inventory.lock, inventory.count) in the same transaction - the same lock
finalize_deal takes before it opens a chat deal. While it is held no other
order and no chat deal can take a unit, so the count cannot go stale before
the write.

The reservation itself is still one UPDATE whose WHERE re-checks what is
left, as a second line of defence:

  UPDATE listings SET stock_reserved = stock_reserved + :n
   WHERE id = :id AND stock_tracked AND quantity - stock_reserved - :in_deals >= :n

Releases and deductions clamp at zero rather than going negative if
something upstream ever double-counted. Callers sort the listings they touch
(inventory.lock does), so two orders over the same products always take the
rows' locks in the same order and cannot deadlock.
"""
from __future__ import annotations

from sqlalchemy import case, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing
from api.domains.listings import inventory
from api.domains.listings.inventory import Inventory

from .pricing import MAX_QUANTITY


def is_tracked(listing) -> bool:
    return inventory.is_tracked(listing)


def request_limit(listing, counted: Inventory) -> int:
    """The most of one product a buyer may ask for in one request: what is
    left of tracked stock (0 = out of stock), or the seller's stated
    quantity (one when they gave none) for an untracked product."""
    if counted.tracked:
        return min(counted.available, MAX_QUANTITY)
    stated = getattr(listing, "quantity", None)
    return min(max(int(stated), 1), MAX_QUANTITY) if stated else 1


async def reserve(db: AsyncSession, listing_id: str, units: int, in_deals: int) -> bool:
    """Reserve `units` more, atomically. The caller has locked the listing
    and counted `in_deals` (the units chat deals hold) under that lock.
    False when the units aren't there, or the product stopped being
    tracked: nothing changed."""
    if units <= 0:
        return True
    result = await db.execute(
        update(Listing)
        .where(
            Listing.id == listing_id,
            Listing.stock_tracked == True,  # noqa: E712 - SQL comparison
            Listing.quantity.is_not(None),
            (Listing.quantity - Listing.stock_reserved - int(in_deals)) >= int(units),
        )
        .values(stock_reserved=Listing.stock_reserved + int(units))
        .execution_options(synchronize_session=False)
    )
    return result.rowcount == 1


async def release(db: AsyncSession, listing_id: str, units: int) -> None:
    """Give `units` back to the shelf."""
    if units <= 0:
        return
    n = int(units)
    await db.execute(
        update(Listing)
        .where(Listing.id == listing_id)
        .values(stock_reserved=case((Listing.stock_reserved >= n, Listing.stock_reserved - n), else_=0))
        .execution_options(synchronize_session=False)
    )


async def deduct(db: AsyncSession, listing_id: str, units: int) -> None:
    """The order was handed over: its reserved units leave the shelf, and
    `quantity` - the units on hand - goes down by as many. Tracking can't be
    switched off while an order holds units (store_orders/service.set_stock),
    so a reservation always comes off a counted quantity."""
    if units <= 0:
        return
    n = int(units)
    tracked = Listing.stock_tracked == True  # noqa: E712 - SQL comparison
    await db.execute(
        update(Listing)
        .where(Listing.id == listing_id)
        .values(
            stock_reserved=case((Listing.stock_reserved >= n, Listing.stock_reserved - n), else_=0),
            quantity=case(
                (tracked & (Listing.quantity >= n), Listing.quantity - n),
                (tracked & Listing.quantity.is_not(None), 0),
                else_=Listing.quantity,
            ),
        )
        .execution_options(synchronize_session=False)
    )
