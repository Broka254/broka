"""The one count of a listing's units, for every way they are sold.

Two channels sell the same shelf:

  chat deals    a buyer and the seller agree in chat, and
                EscrowService.finalize_deal opens a Deal for Deal.quantity
                units (listings/stock.py)
  store orders  a buyer sends a store an order request; accepting it
                reserves units on the listing (store_orders/stock.py)

Each used to count on its own. An accepted order's reservation was invisible
to finalize_deal, so a chat buyer could be sold units already promised to an
order; and an order counted chat deals before it locked anything, so a deal
agreed in that gap was missed. Both now count here, the same way, under the
same lock.

WHAT IS COUNTED
===============
  total      Tracked (Listing.stock_tracked): Listing.quantity, exactly - 0
             means none. Untracked: Listing.quantity, NULL or 0 reading as
             one, as it always has (stock.units_total).
  reserved   Listing.stock_reserved: units accepted store orders hold until
             they are handed over (then deducted from quantity) or end
             without a sale (then released).
  in deals   Units of the chat deals that hold stock (stock.units_taken):
             every deal from agreement until refunded or cancelled, sold
             ones included, while buyers pay through BROKA; only paid-out
             ones while payments are off (stock.deals_hold_stock).
  available  total - reserved - in deals, never below zero. The number every
             decision and every screen uses.

ON HAND
=======
What a tracked product's seller sees and sets is the units they still have:
quantity less the units chat deals sold. A chat sale never touched quantity -
it is counted from its Deal row for as long as the deal stands, so a refund
gives it back - while an order's handover takes its units off quantity.
Setting on hand to N therefore stores N + the units chat deals sold
(stored_quantity_for), which keeps `available` exact, and keeps quantity
meaning the same thing for the untracked count if tracking is switched off.

THE LOCK
========
Every path that takes units first locks the listing row (lock(): SELECT ...
FOR UPDATE, in id order when there are several), then counts, then writes,
in one transaction:

  finalize_deal          a chat deal
  store order accept /   a reservation (store_orders/service._offer)
  propose
  the stock controls     on hand, tracking on or off (store_orders/service.set_stock)

A Deal is only ever created inside finalize_deal, under this lock, and while
buyers pay through BROKA every status from agreement to payout holds its
units, so a deal's later moves never add to the count. Nothing can add units
between counting and writing: two buyers on two channels cannot both be
given the last unit. On PostgreSQL the second waits for the first to commit,
then counts again; SQLite serialises writers. Giving units back (an order
released, a deal refunded or cancelled) only ever makes more available, and
needs no lock beyond the row's own.

(With payments off only paid-out deals hold units - stock.deals_hold_stock.
New deals can't be paid then, but one paid before payments were switched
off starts counting when it is paid out, outside this lock. That is the
established rule for chat deals, unchanged here.)

Lock order: an order action locks its order row, then its listings; the
stock controls lock the orders they convert, then the listing; finalize_deal
locks only the listing. Nothing that holds a listing lock waits for an order
lock, so the paths cannot deadlock each other.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Optional

from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus, Listing

from . import stock


def is_tracked(listing) -> bool:
    """The seller counts this product's stock: Listing.stock_tracked, with a
    quantity to count from."""
    return (bool(getattr(listing, "stock_tracked", False))
            and getattr(listing, "quantity", None) is not None)


@dataclass(frozen=True)
class Inventory:
    listing_id: str
    # A direct sale. False for an auction: one item, sold through its own
    # lifecycle (domains/auctions/lifecycle.py), and never counted here.
    stocked: bool
    tracked: bool
    total: int
    reserved: int
    in_deals: int
    sold_in_deals: int

    @property
    def available(self) -> int:
        """Units a new chat deal or store-order reservation may take."""
        return max(self.total - self.reserved - self.in_deals, 0)

    @property
    def committed_to_deals(self) -> int:
        """Chat deals agreed and not yet paid out: still on the shelf, but
        promised."""
        return max(self.in_deals - self.sold_in_deals, 0)

    @property
    def on_hand(self) -> Optional[int]:
        """Tracked: the units the seller still has. None when untracked."""
        if not self.tracked:
            return None
        return max(self.total - self.sold_in_deals, 0)

    def stored_quantity_for(self, on_hand: int) -> int:
        """The Listing.quantity that makes on hand read `on_hand`."""
        return int(on_hand) + self.sold_in_deals


def _units():
    return func.coalesce(Deal.quantity, 1)


async def deal_units(db: AsyncSession, listing_ids: Iterable[str]) -> dict[str, tuple[int, int]]:
    """(units chat deals hold, of which sold and paid out) per listing - one
    grouped query for all of them. The same rule as stock.units_taken."""
    ids = sorted({i for i in listing_ids if i})
    if not ids:
        return {}
    rows = (await db.execute(
        select(
            Deal.listing_id,
            func.coalesce(func.sum(_units()), 0),
            # CASE rather than a FILTER clause: older SQLite has none.
            func.coalesce(func.sum(case((Deal.status == DealStatus.released, _units()), else_=0)), 0),
        )
        .where(Deal.listing_id.in_(ids), stock.holding_deal())
        .group_by(Deal.listing_id)
    )).all()
    return {listing_id: (int(taken or 0), int(sold or 0)) for listing_id, taken, sold in rows}


def _inventory(listing: Listing, taken: int, sold: int) -> Inventory:
    stocked = stock.is_stocked(listing)
    tracked = stocked and is_tracked(listing)
    if tracked:
        total = max(int(listing.quantity or 0), 0)
    else:
        total = stock.units_total(listing)
    return Inventory(
        listing_id=listing.id,
        stocked=stocked,
        tracked=tracked,
        total=total,
        reserved=max(int(getattr(listing, "stock_reserved", 0) or 0), 0) if stocked else 0,
        in_deals=int(taken) if stocked else 0,
        sold_in_deals=int(sold) if stocked else 0,
    )


async def count(db: AsyncSession, listing: Listing) -> Inventory:
    """The listing's units now. To take units, lock the listing first
    (lock()) and count in the same transaction; a count without the lock is
    only good for showing."""
    if not stock.is_stocked(listing):
        return _inventory(listing, 0, 0)
    # Looked up on the module each time: the one function every chat-deal
    # count has always used (and the seam the cross-channel race tests hold).
    taken, sold = await stock.units_taken(db, listing.id)
    return _inventory(listing, taken, sold)


async def counts(db: AsyncSession, listings: Iterable[Listing]) -> dict[str, Inventory]:
    """Each listing's units, for showing a page of them: one query for the
    deal units of the whole page, none when it has no direct sales."""
    rows = [l for l in listings if l is not None]
    stocked_ids = [l.id for l in rows if stock.is_stocked(l)]
    units = await deal_units(db, stocked_ids) if stocked_ids else {}
    return {l.id: _inventory(l, *units.get(l.id, (0, 0))) for l in rows}


def recount(listing: Listing, before: Inventory) -> Inventory:
    """The count after this transaction changed the listing's own columns
    (quantity, tracking, reservations), its chat deals as `before` found
    them - for answering with the figures just saved."""
    return _inventory(listing, before.in_deals, before.sold_in_deals)


async def tracked_counts(db: AsyncSession, listings: Iterable[Listing]) -> dict[str, Inventory]:
    """counts() for the tracked listings among these - what a page of cards
    needs for `available_quantity`. No query when none is tracked, which is
    most pages."""
    return await counts(db, [l for l in listings if l is not None and is_tracked(l)])


def owner_fields(counted: Optional[Inventory]) -> dict:
    """The seller's own stock figures for a product, beside the public ones:
    on hand, what accepted orders and open chat deals hold, what chat deals
    sold. Nothing for an untracked product."""
    if counted is None or not counted.tracked:
        return {"stock_on_hand": None, "stock_committed_to_deals": None, "stock_sold_through_deals": None}
    return {
        "stock_on_hand": counted.on_hand,
        "stock_committed_to_deals": counted.committed_to_deals,
        "stock_sold_through_deals": counted.sold_in_deals,
    }


async def lock(db: AsyncSession, listing_ids: Iterable[str]) -> dict[str, Listing]:
    """Lock these listings' rows for this transaction (PostgreSQL; SQLite
    serialises writers anyway), in id order so that two transactions over
    the same listings always take them in the same order, and read them
    fresh. Listings that don't exist are left out."""
    ids = sorted({i for i in listing_ids if i})
    if not ids:
        return {}
    rows = (await db.execute(
        select(Listing).where(Listing.id.in_(ids)).order_by(Listing.id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalars().all()
    return {row.id: row for row in rows}


def card_available(listing: Listing, inv: Optional[Inventory]) -> Optional[int]:
    """`available_quantity` on a listing card: what is left of tracked stock,
    chat deals and accepted orders taken off; None when untracked. Without
    a count (a caller that built none) it is what orders leave, an upper
    bound - every list buyers browse passes one."""
    if not is_tracked(listing):
        return None
    if inv is not None:
        return inv.available
    return max(int(listing.quantity or 0) - int(getattr(listing, "stock_reserved", 0) or 0), 0)
