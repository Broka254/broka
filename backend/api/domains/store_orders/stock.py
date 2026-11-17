"""Stock for store orders: reserved when the store accepts, given back when
an order ends without a sale, taken off when it is handed over - for every
product, whether or not its seller counts the stock.

COUNTED OR NOT
==============
Listing.quantity has always been what the seller said they have ("100
bags"), and NULL has read as one (listings/stock.py). Either way the
listing's units are counted - for store orders and chat deals alike - by
listings/inventory.py:

  available = total - stock_reserved - units chat deals hold
              (- units store orders handed over, for a stated quantity)

A seller who counts the stock (Listing.stock_tracked) keeps `quantity` as
the units on hand; a handover takes its units off it. Without counting,
`quantity` stays the stated total, and handed-over units are counted from
their order lines (StoreOrderItem.deducted_quantity), the way chat deals'
sold units are counted from their Deal rows. Neither channel writes what the
other reads, so the two add up without double counting.

Before this, a product whose seller didn't count it reserved nothing, so one
phone could be promised to an order and sold in a chat deal as well.

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
   WHERE id = :id AND <total> - stock_reserved - :held >= :n

where <total> reads the listing's own columns as inventory.py does, and
:held is what chat deals (and, for a stated quantity, handed-over orders)
took, counted under the lock.

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


def request_limit(counted: Inventory) -> int:
    """The most of one product a buyer may ask for in one request: what the
    shared count leaves (0 = none left)."""
    return min(counted.available, MAX_QUANTITY)


def _total():
    """SQL: the listing's total, as inventory.from_counts reads it."""
    counted = (Listing.stock_tracked == True) & Listing.quantity.is_not(None)  # noqa: E712
    return case(
        (counted, Listing.quantity),
        (Listing.quantity > 0, Listing.quantity),
        else_=1,
    )


async def reserve(db: AsyncSession, listing_id: str, units: int, counted: Inventory) -> bool:
    """Reserve `units` more, atomically. The caller has locked the listing
    and taken `counted` under that lock. False when the units aren't there:
    nothing changed."""
    if units <= 0:
        return True
    held = int(counted.in_deals) + int(counted.gone_through_orders)
    result = await db.execute(
        update(Listing)
        .where(
            Listing.id == listing_id,
            (_total() - Listing.stock_reserved - held) >= int(units),
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
    """The order was handed over: its reserved units leave the shelf. For
    counted stock `quantity` - on hand plus what chat deals sold - goes down
    by as many. A stated quantity stays as it is: the caller records the
    units on the order line (deducted_quantity), and the count takes them
    off from there."""
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
