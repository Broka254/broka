"""The one count of a listing's units, for every way they are sold.

Two channels sell the same shelf:

  chat deals    a buyer and the seller agree in chat, and
                EscrowService.finalize_deal opens a Deal for Deal.quantity
                units (listings/stock.py)
  store orders  a buyer sends a store an order request; accepting it
                reserves units on the listing (store_orders/stock.py)

Each used to count on its own. An accepted order's reservation was invisible
to finalize_deal, so a chat buyer could be sold units already promised to an
order; an order counted chat deals before it locked anything, so a deal
agreed in that gap was missed; and a product whose seller didn't count its
stock reserved nothing at all, so one phone could be promised to an order
and sold in chat. Every product now counts here, the same way, under the
same lock.

WHAT IS COUNTED
===============
  total        Counted stock (Listing.stock_tracked): Listing.quantity,
               exactly - 0 means none. Not counted: the listing's stated
               quantity, NULL or 0 reading as one, as it always has
               (stock.units_total).
  reserved     Listing.stock_reserved: units accepted store orders hold
               until they are handed over or end without a sale.
  in deals     Units of the chat deals that hold stock (stock.units_taken):
               every deal from agreement until refunded or cancelled, sold
               ones included, while buyers pay through BROKA; only paid-out
               ones while payments are off (stock.deals_hold_stock).
  sold through Units store orders handed over (StoreOrderItem.
  orders       deducted_quantity). Counted stock had them taken off its
               quantity at handover. A stated quantity is everything the
               listing ever had, so they are taken off here - the way chat
               deals' sold units are.
  available    total - reserved - in deals (- sold through orders, for a
               stated quantity), never below zero. The number every
               decision and every screen uses.

COUNTED OR NOT
==============
Both are counted; the seller chooses how. Counting stock (stock_tracked),
they keep an on-hand number and restock it, and with none left the product
stays listed as out of stock. Not counting, the stated quantity is what
there is, and once every unit is sold or promised the listing goes the way a
chat deal takes it: pending while one is promised, completed when all are
sold (stock.status_for, settle_status below).

ON HAND
=======
What a counted product's seller sees and sets is the units they still have:
quantity less the units chat deals sold. A chat sale never touched quantity -
it is counted from its Deal row for as long as the deal stands, so a refund
gives it back - while an order's handover takes its units off quantity.
Setting on hand to N therefore stores N + the units chat deals sold
(stored_quantity_for). Stopping counting stores on hand plus everything sold
as the stated quantity (stated_quantity), and starting from a stated
quantity takes everything sold off it (unsold): `available` is the same
either side of the switch, and so is every reservation.

THE LOCK
========
Every path that takes units first locks the listing row (lock(): SELECT ...
FOR UPDATE, in id order when there are several), then counts, then writes,
in one transaction:

  finalize_deal          a chat deal
  store order accept /   a reservation (store_orders/service._offer)
  propose
  the stock controls     on hand, counting on or off (store_orders/service.set_stock)

A Deal is only ever created inside finalize_deal, under this lock, and while
buyers pay through BROKA every status from agreement to payout holds its
units, so a deal's later moves never add to the count. A reservation is only
ever made in _offer, under this lock, and a handover moves its units from
reserved to sold, never adding to what is gone. Nothing can add units
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
stock controls and finalize_deal lock only the listing. Nothing that holds a
listing lock waits for an order lock, so the paths cannot deadlock each
other.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Optional

from sqlalchemy import case, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Deal, DealStatus, Listing
from api.models.store_order import StoreOrderItem

from . import stock


def is_tracked(listing) -> bool:
    """The seller counts this product's stock: Listing.stock_tracked, with a
    quantity to count from."""
    return (bool(getattr(listing, "stock_tracked", False))
            and getattr(listing, "quantity", None) is not None)


def shows_availability(listing) -> bool:
    """Whether the listing says how many are left (`available_quantity`): a
    store's product - store orders take from every one's count - or stock
    its seller counts. Other listings say it on their own page (units_left)
    and drop out of sight when sold out, as they always have."""
    return stock.is_stocked(listing) and (
        is_tracked(listing) or getattr(listing, "store_id", None) is not None)


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
    sold_in_orders: int

    @property
    def gone_through_orders(self) -> int:
        """Units store orders handed over that `total` still includes: all
        of them for a stated quantity, none for counted stock (its handovers
        came off quantity)."""
        return 0 if self.tracked else self.sold_in_orders

    @property
    def available(self) -> int:
        """Units a new chat deal or store-order reservation may take."""
        return max(self.total - self.reserved - self.in_deals - self.gone_through_orders, 0)

    @property
    def taken(self) -> int:
        """Units sold or promised, through either channel - what
        stock.status_for reads as taken."""
        return self.in_deals + self.reserved + self.gone_through_orders

    @property
    def sold(self) -> int:
        """Units sold, through either channel - stock.status_for's sold."""
        return self.sold_in_deals + self.gone_through_orders

    @property
    def committed_to_deals(self) -> int:
        """Chat deals agreed and not yet paid out: still on the shelf, but
        promised."""
        return max(self.in_deals - self.sold_in_deals, 0)

    @property
    def unsold(self) -> int:
        """Units neither channel has sold: on hand, for counted stock."""
        return max(self.total - self.sold_in_deals - self.gone_through_orders, 0)

    @property
    def on_hand(self) -> Optional[int]:
        """Counted: the units the seller still has. None when not counted."""
        return self.unsold if self.tracked else None

    def stored_quantity_for(self, on_hand: int) -> int:
        """The Listing.quantity that makes counted stock's on hand read
        `on_hand`."""
        return int(on_hand) + self.sold_in_deals

    def stated_quantity(self) -> int:
        """Counting stops: the stated quantity that leaves `available` where
        it is - quantity (on hand plus what chat deals sold) plus what store
        orders sold."""
        return self.total + self.sold_in_orders


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


async def order_units(db: AsyncSession, listing_ids: Iterable[str]) -> dict[str, int]:
    """Units store orders handed over, per listing - one grouped query.
    A handover can't be undone (store_orders/lifecycle.py), so every
    deducted unit stays sold."""
    ids = sorted({i for i in listing_ids if i})
    if not ids:
        return {}
    rows = (await db.execute(
        select(StoreOrderItem.listing_id, func.coalesce(func.sum(StoreOrderItem.deducted_quantity), 0))
        .where(StoreOrderItem.listing_id.in_(ids), StoreOrderItem.deducted_quantity > 0)
        .group_by(StoreOrderItem.listing_id)
    )).all()
    return {listing_id: int(sold or 0) for listing_id, sold in rows}


def from_counts(listing: Listing, taken: int, sold: int, sold_in_orders: int) -> Inventory:
    """The count from figures already queried: units chat deals hold and
    sold, and units store orders sold (the stock sweep's grouped query)."""
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
        sold_in_orders=int(sold_in_orders) if stocked else 0,
    )


async def count(db: AsyncSession, listing: Listing) -> Inventory:
    """The listing's units now. To take units, lock the listing first
    (lock()) and count in the same transaction; a count without the lock is
    only good for showing."""
    if not stock.is_stocked(listing):
        return from_counts(listing, 0, 0, 0)
    # Looked up on the module each time: the one function every chat-deal
    # count has always used (and the seam the cross-channel race tests hold).
    taken, sold = await stock.units_taken(db, listing.id)
    sold_in_orders = (await order_units(db, [listing.id])).get(listing.id, 0)
    return from_counts(listing, taken, sold, sold_in_orders)


async def counts(db: AsyncSession, listings: Iterable[Listing]) -> dict[str, Inventory]:
    """Each listing's units, for showing a page of them: two grouped
    queries for the whole page, none when it has no direct sales."""
    rows = [l for l in listings if l is not None]
    stocked_ids = [l.id for l in rows if stock.is_stocked(l)]
    deals = await deal_units(db, stocked_ids) if stocked_ids else {}
    orders = await order_units(db, stocked_ids) if stocked_ids else {}
    return {l.id: from_counts(l, *deals.get(l.id, (0, 0)), orders.get(l.id, 0)) for l in rows}


def recount(listing: Listing, before: Inventory) -> Inventory:
    """The count after this transaction changed the listing's own columns
    (quantity, counting, reservations), its deals and handed-over orders as
    `before` found them - for answering with the figures just saved."""
    return from_counts(listing, before.in_deals, before.sold_in_deals, before.sold_in_orders)


async def card_counts(db: AsyncSession, listings: Iterable[Listing]) -> dict[str, Inventory]:
    """counts() for the listings among these that say how many are left
    (shows_availability) - what a page of cards needs for
    `available_quantity`. No query when there are none."""
    return await counts(db, [l for l in listings if l is not None and shows_availability(l)])


def owner_fields(counted: Optional[Inventory]) -> dict:
    """The seller's own stock figures for a product, beside the public ones:
    on hand (counted stock only), what open chat deals hold and what chat
    deals sold. Nothing without a count."""
    if counted is None or not counted.stocked:
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


async def settle_status(db: AsyncSession, listing_ids: Iterable[str]) -> None:
    """After a store order took units or gave them back in this
    transaction: each listing's status as its count says (stock.status_for)
    - a stated quantity with every unit promised goes pending, completed
    once all are sold, and back on sale when units return; counted stock
    stays listed. The listings are locked (an order action already holds
    them: its order's lock, then its listings')."""
    rows = await lock(db, listing_ids)
    for listing in rows.values():
        counted = await count(db, listing)
        target = stock.status_for(listing, counted.taken, counted.sold)
        current = getattr(listing.status, "value", listing.status)
        if target is not None and target.value != current:
            listing.status = target


def card_available(listing: Listing, inv: Optional[Inventory]) -> Optional[int]:
    """`available_quantity` on a listing: what an order or a chat deal may
    still take of a store's product or of counted stock; None for other
    listings. Without a count (a caller that built none) counted stock
    gives what orders leave, an upper bound, and a stated quantity gives
    None - every list buyers browse passes one (card_counts)."""
    if not shows_availability(listing):
        return None
    if inv is not None:
        return inv.available
    if is_tracked(listing):
        return max(int(listing.quantity or 0) - int(getattr(listing, "stock_reserved", 0) or 0), 0)
    return None
