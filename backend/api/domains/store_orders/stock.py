"""Tracked stock for store orders: reserved when the store accepts, given
back when an order ends without a sale, taken off when it is handed over.

WHAT "TRACKED" MEANS
====================
Listing.quantity has always been what the seller said they have ("100
bags"), and NULL has read as one (listings/stock.py). Nothing ever counted
it down. A seller now opts a store product into tracking
(Listing.stock_tracked), and from then on `quantity` is the units on hand:

  available = quantity - stock_reserved - units held by deals

Deals agreed in chat count units without touching `quantity`
(listings/stock.units_taken); orders reserve and then deduct. The two add
up without double counting, because neither writes what the other reads.

An untracked product is never treated as out of stock - its availability
is the seller's to confirm on each order, as it always was. Its quantity
caps how many a buyer can ask for, the same cap the storefront's cart has
always had.

WHY SINGLE CONDITIONAL UPDATES
==============================
Two buyers' orders accepted at the same moment must not both get the last
unit. Each reservation is one UPDATE whose WHERE re-checks what is left:

  UPDATE listings SET stock_reserved = stock_reserved + :n
   WHERE id = :id AND stock_tracked AND quantity - stock_reserved - :held >= :n

PostgreSQL re-evaluates that WHERE against the row as the first writer left
it, so the second sees the unit gone and changes nothing (rowcount 0); on
SQLite, writes are serialised outright. No read-then-write window exists to
race through. Releases and deductions clamp at zero rather than going
negative if something upstream ever double-counted.

Callers sort the listings they touch, so two orders over the same products
always take the rows' locks in the same order and cannot deadlock.
"""
from __future__ import annotations

from typing import Optional

from sqlalchemy import case, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Listing

from .pricing import MAX_QUANTITY


def is_tracked(listing) -> bool:
    return (bool(getattr(listing, "stock_tracked", False))
            and getattr(listing, "quantity", None) is not None)


async def deal_units(db: AsyncSession, listing_id: str) -> int:
    """Units of the listing held by deals agreed in chat (listings/stock.py)."""
    from api.domains.listings.stock import units_taken
    taken, _ = await units_taken(db, listing_id)
    return int(taken or 0)


def available(listing, held_by_deals: int = 0) -> Optional[int]:
    """Units a new order could still be accepted for; None when untracked."""
    if not is_tracked(listing):
        return None
    left = int(listing.quantity or 0) - int(getattr(listing, "stock_reserved", 0) or 0) - int(held_by_deals or 0)
    return max(left, 0)


def request_limit(listing, held_by_deals: int = 0) -> int:
    """The most of one product a buyer may ask for in one request: what is
    left of tracked stock (0 = out of stock), or the seller's stated
    quantity (one when they gave none) for an untracked product."""
    left = available(listing, held_by_deals)
    if left is not None:
        return min(left, MAX_QUANTITY)
    stated = getattr(listing, "quantity", None)
    return min(max(int(stated), 1), MAX_QUANTITY) if stated else 1


async def reserve(db: AsyncSession, listing_id: str, units: int, held_by_deals: int = 0) -> bool:
    """Reserve `units` more, atomically. False when they aren't there (or
    the product stopped being tracked): nothing changed."""
    if units <= 0:
        return True
    result = await db.execute(
        update(Listing)
        .where(
            Listing.id == listing_id,
            Listing.stock_tracked == True,  # noqa: E712 - SQL comparison
            Listing.quantity.is_not(None),
            (Listing.quantity - Listing.stock_reserved - int(held_by_deals)) >= int(units),
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
    `quantity` - the units on hand - goes down by as many. A product whose
    seller stopped tracking it in the meantime keeps its stated quantity;
    only the reservation is cleared."""
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


async def current(db: AsyncSession, listing_id: str) -> tuple[bool, Optional[int], int]:
    """(tracked, quantity, reserved) as the database has them now - for the
    message after a reservation was refused."""
    row = (await db.execute(
        select(Listing.stock_tracked, Listing.quantity, Listing.stock_reserved)
        .where(Listing.id == listing_id)
    )).one_or_none()
    if row is None:
        return False, None, 0
    return bool(row[0]), row[1], int(row[2] or 0)
