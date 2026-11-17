"""Store orders: creating them, applying actions, and what each side sees.

ONE TRANSACTION PER CHANGE
==========================
Every change - a submission, an action, a payment report, an expiry - is
one transaction: the order row (locked FOR UPDATE on PostgreSQL, and
version-checked everywhere, store_order.StoreOrder.version), its items, the
stock reservations it takes or gives back (stock.py), the event that
records it and the notifications that announce it. Either all of it
commits or none of it does; a refused reservation rolls the whole action
back. Pushes go out only after the commit (notify.py).

WHO MAY DO WHAT
===============
An order belongs to two people: its buyer, and the owner of its store. Any
other caller gets 404 - not 403 - for an order id, so an id is never
confirmed to someone who could not see it. The role comes from the order
and the store rows, never from the request; lifecycle.check() then decides
whether that role may take that action in the order's current status.

WHAT IS TRUSTED
===============
Nothing about money or ownership from the client. Prices are read from the
listing (submission) or set by the store (its proposal); totals are
computed in pricing.py; the store, the seller and the buyer come from the
database and the signed-in user. The request names listings and quantities,
how to hand over, and free text - all of it checked here.
"""
from __future__ import annotations

import functools
import hashlib
import json
import logging
import re
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Iterable, Optional

from fastapi import HTTPException
from sqlalchemy import exists, func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm.exc import StaleDataError

from api.core.config import settings
from api.database import Listing, ListingStatus, ListingType, User
from api.domains.listings import inventory
from api.domains.listings.stock import status_for
from api.models.store import Store
from api.models.store_order import (
    StoreOrder, StoreOrderEvent, StoreOrderItem, StoreOrderNotification,
    StoreOrderPayment, StoreOrderPaymentReport,
)

from . import lifecycle as lc
from . import messages as msg
from . import pricing
from . import stock

logger = logging.getLogger(__name__)

_PAGE_MAX = 50


def _uuid() -> str:
    return str(uuid.uuid4())


def _iso(value: Optional[datetime]) -> Optional[str]:
    return value.isoformat() + "Z" if value else None


def order_error(status_code: int, code: str, message: str, **extra: Any) -> HTTPException:
    """A refusal a client can act on: a stable code (also X-Error-Code, which
    the app reads first) and a sentence for the person."""
    return HTTPException(
        status_code=status_code,
        detail={"code": code, "message": message, **extra},
        headers={"X-Error-Code": code},
    )


def _transition_error(exc: lc.TransitionError) -> HTTPException:
    return order_error(exc.status_code, exc.code, exc.message)


def require_enabled() -> None:
    if not settings.store_orders_enabled:
        raise order_error(
            409, "ORDERS_OFF",
            "Ordering online isn't switched on yet. Message the store, or agree the deal in the BROKA app.",
        )


# ── Cleaning what people type ─────────────────────────────────────────────

_CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_SPACES = re.compile(r"[ \t]+")


def clean_text(value: object, limit: int) -> Optional[str]:
    """Free text as stored: control characters dropped, runs of spaces
    collapsed, trimmed and capped. Stored as plain text and rendered as
    plain text by both clients (React and Flutter escape it); no markup is
    ever interpreted, so none is stripped."""
    if value is None:
        return None
    text = _SPACES.sub(" ", _CONTROL.sub("", str(value))).strip()
    return text[:limit] or None


_PHONE = re.compile(r"^\+[1-9][0-9]{8,14}$")


def clean_phone(raw: object) -> Optional[str]:
    """A contact number in +E.164, with the Kenyan local forms accepted
    (0712 345 678, 254712345678). None when nothing was given."""
    if raw is None or not str(raw).strip():
        return None
    p = re.sub(r"[\s\-().]", "", str(raw))
    if p.startswith("0") and len(p) == 10:
        p = "+254" + p[1:]
    elif p.startswith("254"):
        p = "+" + p
    elif not p.startswith("+"):
        p = "+" + p
    if not _PHONE.match(p):
        raise order_error(400, "ORDER_PHONE_INVALID",
                          "Enter a phone number the store can reach you on, like 0712 345 678.")
    return p


_KEY = re.compile(r"^[A-Za-z0-9_-]{8,64}$")
_REFERENCE_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"   # no 0/O, 1/I/L
_PAYMENT_REFERENCE = re.compile(r"^[A-Za-z0-9 ._/#:-]{1,64}$")


def new_reference() -> str:
    return "BK-" + "".join(secrets.choice(_REFERENCE_ALPHABET) for _ in range(8))


# ── Submission ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class RequestedItem:
    listing_id: str
    quantity: int


def fingerprint(store_id: str, items: Iterable[RequestedItem], fulfilment: str,
                address: Optional[str], phone: Optional[str], note: Optional[str]) -> str:
    """What a submission asked for, so a replayed key can be told from a
    reused one. Order-independent over the items."""
    payload = {
        "store": store_id,
        "items": sorted([i.listing_id, int(i.quantity)] for i in items),
        "fulfilment": fulfilment,
        "address": address or "",
        "phone": phone or "",
        "note": note or "",
    }
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def _cover_asset(listing: Listing) -> Optional[str]:
    from api.domains.media.service import parse_id_list
    if getattr(listing, "showcase_id", None):
        return listing.showcase_id
    ids = parse_id_list(getattr(listing, "photo_ids", None))
    return ids[0] if ids else None


def _listing_problem(listing: Optional[Listing], store: Store) -> Optional[str]:
    """Why a product can't be ordered from this store now, or None."""
    if listing is None:
        return "isn't on BROKA any more"
    if listing.store_id != store.id or listing.seller_id != store.owner_id:
        return "isn't sold by this store"
    if getattr(listing.status, "value", listing.status) != ListingStatus.active.value:
        return "is no longer for sale"
    if getattr(listing.listing_type, "value", listing.listing_type) == ListingType.auction.value:
        return "is an auction - bid on it in the BROKA app"
    if getattr(listing, "sold_out_reported_at", None) is not None:
        return "was reported sold out"
    if getattr(listing, "temporarily_unavailable", False):
        return "is temporarily unavailable"
    return None


async def _orderable_store(db: AsyncSession, store_id: str) -> Store:
    from api.domains.stores import billing as store_billing

    store = await db.get(Store, store_id)
    if store is None or store.deleted_at is not None:
        raise order_error(404, "STORE_NOT_FOUND", "Store not found")
    if not await store_billing.store_live(db, store):
        raise order_error(409, "STORE_NOT_OPEN", f"{store.name} isn't open for orders right now.")
    if not getattr(store, "accepting_orders", True):
        note = (store.orders_pause_note or "").strip()
        raise order_error(409, "STORE_ORDERS_PAUSED",
                          f"{store.name} isn't taking new orders right now." + (f" {note}" if note else ""))
    return store


async def _by_key(db: AsyncSession, buyer_id: str, key: str) -> Optional[StoreOrder]:
    return (await db.execute(
        select(StoreOrder).where(StoreOrder.buyer_id == buyer_id, StoreOrder.idempotency_key == key)
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()


def _replayed(existing: StoreOrder, fp: str) -> StoreOrder:
    if existing.request_fingerprint != fp:
        raise order_error(
            409, "IDEMPOTENCY_KEY_REUSED",
            "This request key was already used for a different order. Start a new checkout.",
        )
    return existing


async def _unique_reference(db: AsyncSession) -> str:
    for _ in range(5):
        ref = new_reference()
        taken = (await db.execute(select(StoreOrder.id).where(StoreOrder.reference == ref))).first()
        if taken is None:
            return ref
    raise order_error(503, "ORDER_REFERENCE_BUSY", "Couldn't create the order just now. Try again.")


async def _campaign_id(db: AsyncSession, store_id: str, token: Optional[str]) -> Optional[str]:
    """The Marketing Studio campaign a tracked link names - of this store,
    not deleted - or None. An unknown token is ignored, never an error."""
    if not token or not re.fullmatch(r"[A-Za-z0-9_-]{8,32}", token):
        return None
    from api.domains.stores.marketing import MarketingService
    campaign = await MarketingService(db).campaign_for_token(store_id, token)
    return campaign.id if campaign is not None else None


def _channel(via: Optional[str]) -> Optional[str]:
    if not via:
        return None
    from api.domains.stores import stats as store_stats
    return store_stats.visit_source(via)


async def submit(
    db: AsyncSession,
    *,
    buyer_id: str,
    store_id: str,
    items: list[RequestedItem],
    fulfilment: str,
    delivery_address: Optional[str],
    contact_phone: Optional[str],
    note: Optional[str],
    idempotency_key: Optional[str],
    surface: str = "web",
    via: Optional[str] = None,
    campaign: Optional[str] = None,
) -> tuple[StoreOrder, bool, list[str]]:
    """Create the order request. Returns (order, created, notification ids
    to push). A replay of the same key and request returns the order the
    first attempt made, with created=False and nothing to push."""
    require_enabled()
    key = (idempotency_key or "").strip()
    if not _KEY.match(key):
        raise order_error(400, "IDEMPOTENCY_KEY_REQUIRED",
                          "Send an X-Idempotency-Key of 8-64 letters, digits, '-' or '_' with every order.")
    if fulfilment not in lc.FULFILMENT_METHODS:
        raise order_error(400, "ORDER_FULFILMENT_INVALID", "Choose delivery or collection.")
    address = clean_text(delivery_address, 300) if fulfilment == lc.DELIVERY else None
    if fulfilment == lc.DELIVERY and (not address or len(address) < 5):
        raise order_error(400, "ORDER_ADDRESS_REQUIRED",
                          "Add a delivery address the store can find - an area and a landmark is enough.")
    phone = clean_phone(contact_phone)
    note_text = clean_text(note, 500)
    if not items:
        raise order_error(400, "ORDER_EMPTY", "Add at least one product.")
    if len(items) > pricing.MAX_ITEMS:
        raise order_error(400, "ORDER_TOO_MANY_ITEMS",
                          f"An order can hold up to {pricing.MAX_ITEMS} different products.")
    seen: set[str] = set()
    for item in items:
        if item.listing_id in seen:
            raise order_error(400, "ORDER_DUPLICATE_ITEM", "Each product can appear once; change its quantity instead.")
        seen.add(item.listing_id)
        if not 1 <= int(item.quantity) <= pricing.MAX_QUANTITY:
            raise order_error(400, "ORDER_QUANTITY_INVALID",
                              f"Quantities must be between 1 and {pricing.MAX_QUANTITY}.")
    fp = fingerprint(store_id, items, fulfilment, address, phone, note_text)

    existing = await _by_key(db, buyer_id, key)
    if existing is not None:
        return _replayed(existing, fp), False, []

    store = await _orderable_store(db, store_id)
    if store.owner_id == buyer_id:
        raise order_error(400, "ORDER_OWN_STORE", "You can't order from your own store.")
    open_count = (await db.execute(
        select(func.count()).select_from(StoreOrder).where(
            StoreOrder.buyer_id == buyer_id, StoreOrder.store_id == store.id,
            StoreOrder.status.in_(lc.OPEN),
        )
    )).scalar_one()
    if open_count >= settings.store_order_max_open_per_store:
        raise order_error(
            429, "ORDER_TOO_MANY_OPEN",
            f"You already have {open_count} open orders with {store.name}. "
            "Finish or cancel one before sending another.",
        )
    buyer = await db.get(User, buyer_id)
    if buyer is None:
        raise order_error(401, "ACCOUNT_NOT_FOUND", "Sign in again to place this order.")
    if phone is None:
        phone = buyer.phone

    listings = {
        row.id: row for row in (await db.execute(
            select(Listing).where(Listing.id.in_([i.listing_id for i in items]))
            .execution_options(populate_existing=True)
        )).scalars().all()
    }
    lines: list[tuple[Listing, int, int]] = []
    for item in items:
        listing = listings.get(item.listing_id)
        problem = _listing_problem(listing, store)
        name = listing.name if listing is not None else "A product in your cart"
        if problem:
            raise order_error(409, "ORDER_ITEM_UNAVAILABLE", f"{name} {problem}.", listing_id=item.listing_id)
        # A cap, not an allocation: nothing is reserved until the store
        # accepts, which counts again under the listing's lock (_offer).
        limit = stock.request_limit(listing, await inventory.count(db, listing))
        if limit <= 0:
            raise order_error(409, "ORDER_ITEM_OUT_OF_STOCK", f"{name} is out of stock.",
                              listing_id=listing.id, available=0)
        if item.quantity > limit:
            raise order_error(
                409, "ORDER_ITEM_QUANTITY",
                (f"Only {limit} of {name} available." if stock.is_tracked(listing)
                 else f"{name}: you can ask for up to {limit}. Message the store if you need more."),
                listing_id=listing.id, available=limit,
            )
        try:
            unit = pricing.check_unit_price(pricing.to_minor(listing.price))
        except pricing.PriceError:
            raise order_error(409, "ORDER_ITEM_UNPRICED",
                              f"{name} has no price yet - ask the store about it.", listing_id=listing.id)
        lines.append((listing, int(item.quantity), unit))

    now = datetime.utcnow()
    order = StoreOrder(
        id=_uuid(),
        reference=await _unique_reference(db),
        store_id=store.id,
        seller_id=store.owner_id,
        buyer_id=buyer_id,
        status=lc.SUBMITTED,
        currency=pricing.CURRENCY,
        requested_subtotal_minor=pricing.subtotal((q, p) for _, q, p in lines),
        requested_fulfilment=fulfilment,
        fulfilment=fulfilment,
        delivery_address=address,
        contact_phone=phone,
        buyer_note=note_text,
        revision=0,
        idempotency_key=key,
        request_fingerprint=fp,
        source_surface="app" if surface == "app" else "web",
        source_channel=_channel(via),
        campaign_id=await _campaign_id(db, store.id, campaign),
        created_at=now,
        updated_at=now,
        expires_at=now + timedelta(hours=settings.store_order_seller_response_hours),
    )
    db.add(order)
    # Flushed one level at a time: these tables are related only by
    # foreign keys (no relationship()), so each parent row is written
    # before the rows that point at it.
    await db.flush()
    for position, (listing, qty, unit) in enumerate(lines):
        db.add(StoreOrderItem(
            id=_uuid(), order_id=order.id, listing_id=listing.id, position=position,
            name=(listing.name or "Product")[:200], price_unit=listing.price_unit,
            image_asset_id=_cover_asset(listing),
            requested_quantity=qty, requested_unit_price_minor=unit,
        ))
    await db.flush()
    note_ids = await _record(
        db, order, store_name=store.name, buyer_name=buyer.name, item_count=len(lines),
        kind=msg.SUBMITTED, actor_id=buyer_id, actor_role=lc.BUYER,
        from_status=None, to_status=lc.SUBMITTED,
        detail={"items": len(lines), "surface": order.source_surface},
    )
    try:
        await db.commit()
    except IntegrityError:
        # The same key submitted twice at once: the unique (buyer, key)
        # index let one in. Answer with that one.
        await db.rollback()
        existing = await _by_key(db, buyer_id, key)
        if existing is not None:
            return _replayed(existing, fp), False, []
        raise
    return order, True, note_ids


# ── Events and notifications ──────────────────────────────────────────────

async def _record(
    db: AsyncSession, order: StoreOrder, *, store_name: str, buyer_name: Optional[str],
    item_count: int, kind: str, actor_id: Optional[str], actor_role: str,
    from_status: Optional[str], to_status: Optional[str], detail: Optional[dict] = None,
) -> list[str]:
    """The event, and a notification for everyone it concerns. Returns the
    ids of those to push (in-app-only ones are written as 'skipped')."""
    now = datetime.utcnow()
    event = StoreOrderEvent(
        id=_uuid(), order_id=order.id, kind=kind, actor_id=actor_id, actor_role=actor_role,
        from_status=from_status, to_status=to_status, revision=order.revision,
        detail=json.dumps(detail, separators=(",", ":")) if detail else None,
        created_at=now,
    )
    db.add(event)
    await db.flush()
    total = order.total_minor if order.total_minor is not None else order.requested_subtotal_minor
    push_ids: list[str] = []
    for note in msg.notes_for(
        kind, reference=order.reference, store_name=store_name, buyer_name=buyer_name,
        item_count=item_count, total_minor=total, detail=detail,
    ):
        nid = _uuid()
        db.add(StoreOrderNotification(
            id=nid, order_id=order.id, event_id=event.id,
            recipient_id=order.buyer_id if note.recipient_role == lc.BUYER else order.seller_id,
            recipient_role=note.recipient_role, kind=kind,
            title=note.title[:160], body=note.body[:400],
            push_state="pending" if note.push else "skipped",
            created_at=now,
        ))
        if note.push:
            push_ids.append(nid)
    return push_ids


# ── Loading an order for a change ─────────────────────────────────────────

async def _lock(db: AsyncSession, order_id: str) -> StoreOrder:
    order = (await db.execute(
        select(StoreOrder).where(StoreOrder.id == order_id)
        .with_for_update()
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if order is None:
        raise order_error(404, "ORDER_NOT_FOUND", "Order not found")
    return order


async def get_for(db: AsyncSession, order_id: str, user_id: str) -> tuple[StoreOrder, str]:
    """The order and the caller's role in it; 404 for anyone else."""
    order = (await db.execute(
        select(StoreOrder).where(StoreOrder.id == order_id).execution_options(populate_existing=True)
    )).scalar_one_or_none()
    if order is None:
        raise order_error(404, "ORDER_NOT_FOUND", "Order not found")
    return order, await _role(db, order, user_id)


async def _role(db: AsyncSession, order: StoreOrder, user_id: str) -> str:
    if user_id == order.buyer_id:
        return lc.BUYER
    if user_id == order.seller_id:
        store = await db.get(Store, order.store_id)
        if store is not None and store.owner_id == user_id:
            return lc.SELLER
    raise order_error(404, "ORDER_NOT_FOUND", "Order not found")


async def _items(db: AsyncSession, order_id: str) -> list[StoreOrderItem]:
    return list((await db.execute(
        select(StoreOrderItem).where(StoreOrderItem.order_id == order_id)
        .order_by(StoreOrderItem.position)
        .execution_options(populate_existing=True)
    )).scalars().all())


async def _listings_for(db: AsyncSession, items: list[StoreOrderItem]) -> dict[str, Listing]:
    ids = [i.listing_id for i in items]
    if not ids:
        return {}
    rows = (await db.execute(
        select(Listing).where(Listing.id.in_(ids)).execution_options(populate_existing=True)
    )).scalars().all()
    return {row.id: row for row in rows}


# ── Stock on an order's items ─────────────────────────────────────────────

async def _hold(db: AsyncSession, item: StoreOrderItem, listing: Optional[Listing], target: int) -> None:
    """Make this line hold exactly `target` reserved units. The caller has
    locked `listing` (inventory.lock), so what is counted here - chat deals
    and other orders alike - can't change before the reservation is written."""
    have = int(item.reserved_quantity or 0)
    if target > have:
        counted = await inventory.count(db, listing)
        need = target - have
        if counted.available < need or not await stock.reserve(db, item.listing_id, need, counted.in_deals):
            left = counted.available + have
            raise order_error(
                409, "ORDER_STOCK_SHORT",
                (f"Only {left} of {item.name} in stock - offer {left} or fewer." if left
                 else f"{item.name} is out of stock - offer the order without it."),
                item_id=item.id, listing_id=item.listing_id, available=left,
            )
    elif target < have:
        await stock.release(db, item.listing_id, have - target)
    item.reserved_quantity = target
    if target > 0:
        item.stock_state = "reserved"
    elif have > 0:
        item.stock_state = "released"


async def _release_all(db: AsyncSession, items: list[StoreOrderItem]) -> None:
    for item in sorted(items, key=lambda i: i.listing_id):
        if item.reserved_quantity:
            await stock.release(db, item.listing_id, item.reserved_quantity)
            item.reserved_quantity = 0
            item.stock_state = "released"


async def _deduct_all(db: AsyncSession, items: list[StoreOrderItem]) -> None:
    for item in sorted(items, key=lambda i: i.listing_id):
        if item.reserved_quantity:
            await stock.deduct(db, item.listing_id, item.reserved_quantity)
            item.deducted_quantity = int(item.deducted_quantity or 0) + int(item.reserved_quantity)
            item.reserved_quantity = 0
            item.stock_state = "deducted"


# ── Actions ───────────────────────────────────────────────────────────────

def _current_offer(item: StoreOrderItem) -> tuple[int, int]:
    q = item.proposed_quantity if item.proposed_quantity is not None else item.requested_quantity
    p = item.proposed_unit_price_minor if item.proposed_unit_price_minor is not None \
        else item.requested_unit_price_minor
    return int(q), int(p)


async def _offer(db: AsyncSession, order: StoreOrder, items: list[StoreOrderItem],
                 offered: dict[str, tuple[int, int]], *, fulfilment: str, payload: dict,
                 now: datetime) -> None:
    """Put the store's offer on the order: quantities, prices, handover,
    delivery charge, notes - reserving tracked stock for it. A revision that
    leaves the delivery charge out keeps the one already offered."""
    if "delivery_fee_minor" in payload:
        fee = payload.get("delivery_fee_minor")
        if fee is not None:
            try:
                fee = pricing.check_delivery_fee(fee)
            except pricing.PriceError as exc:
                raise order_error(400, "ORDER_DELIVERY_FEE_INVALID", str(exc))
    else:
        fee = order.delivery_fee_minor
    if fulfilment == lc.COLLECTION:
        fee = None
    # Locked before anything is counted, in id order: the lock a chat deal
    # takes on the same listing (EscrowService.finalize_deal), so the two
    # channels take units one after the other (listings/inventory.py).
    # Untracked products too - their row is where tracking is switched on.
    listings = await inventory.lock(db, [i.listing_id for i in items])
    for item in sorted(items, key=lambda i: i.listing_id):
        qty, price = offered[item.id]
        listing = listings.get(item.listing_id)
        if qty > 0 and (listing is None
                        or getattr(listing.status, "value", listing.status) == ListingStatus.cancelled.value):
            raise order_error(409, "ORDER_ITEM_GONE",
                              f"{item.name} is no longer listed - offer the order without it.",
                              item_id=item.id)
        item.proposed_quantity = qty
        item.proposed_unit_price_minor = price
        await _hold(db, item, listing, qty if (listing is not None and stock.is_tracked(listing)) else 0)
    subtotal = pricing.subtotal(offered[i.id] for i in items if offered[i.id][0] > 0)
    order.seller_subtotal_minor = subtotal
    order.delivery_fee_minor = fee
    order.total_minor = pricing.total(subtotal, fee)
    order.fulfilment = fulfilment
    if "seller_note" in payload:
        order.seller_note = clean_text(payload.get("seller_note"), 500)
    if "fulfilment_note" in payload:
        order.fulfilment_note = clean_text(payload.get("fulfilment_note"), 300)
    order.revision = int(order.revision or 0) + 1
    order.seller_responded_at = order.seller_responded_at or now
    order.expires_at = now + timedelta(hours=settings.store_order_reservation_hours)


def _offer_detail(order: StoreOrder, items: list[StoreOrderItem]) -> dict:
    changes = []
    for i in items:
        q, p = _current_offer(i)
        if q != i.requested_quantity or p != i.requested_unit_price_minor:
            changes.append({
                "item": i.name[:80],
                "from_quantity": i.requested_quantity, "to_quantity": q,
                "from_unit_price_minor": i.requested_unit_price_minor, "to_unit_price_minor": p,
            })
    return {
        "revision": order.revision,
        "total_minor": order.total_minor,
        "delivery_fee_minor": order.delivery_fee_minor,
        "fulfilment": order.fulfilment,
        "fulfilment_changed": order.fulfilment != order.requested_fulfilment,
        "changes": changes,
    }


def _reason(payload: dict, *, required: bool) -> Optional[str]:
    reason = clean_text(payload.get("reason"), 300)
    if required and (not reason or len(reason) < 3):
        raise order_error(400, "ORDER_REASON_REQUIRED", "Say why, in a few words - the buyer will see it.")
    return reason


async def _do_accept(db, order, items, payload, now):
    offered = {i.id: (i.requested_quantity, i.requested_unit_price_minor) for i in items}
    await _offer(db, order, items, offered, fulfilment=order.requested_fulfilment, payload=payload, now=now)
    return msg.SELLER_ACCEPTED, _offer_detail(order, items), lc.AWAITING_BUYER_CONFIRMATION


async def _do_propose(db, order, items, payload, now):
    by_id = {i.id: i for i in items}
    offered = {i.id: _current_offer(i) for i in items}
    for change in payload.get("items") or []:
        item = by_id.get(change.get("item_id"))
        if item is None:
            raise order_error(400, "ORDER_ITEM_UNKNOWN", "That product isn't in this order.")
        qty = int(change.get("quantity"))
        if not 0 <= qty <= pricing.MAX_QUANTITY:
            raise order_error(400, "ORDER_QUANTITY_INVALID",
                              f"Quantities must be between 0 and {pricing.MAX_QUANTITY}.")
        price = change.get("unit_price_minor")
        if price is None:
            price = offered[item.id][1]
        try:
            price = pricing.check_unit_price(price)
        except pricing.PriceError as exc:
            raise order_error(400, "ORDER_PRICE_INVALID", f"{item.name}: {exc}")
        offered[item.id] = (qty, price)
    if not any(q > 0 for q, _ in offered.values()):
        raise order_error(400, "ORDER_EMPTY_PROPOSAL",
                          "Keep at least one product in the order, or decline it instead.")
    fulfilment = payload.get("fulfilment") or order.fulfilment
    if fulfilment not in lc.FULFILMENT_METHODS:
        raise order_error(400, "ORDER_FULFILMENT_INVALID", "Choose delivery or collection.")
    if fulfilment == lc.DELIVERY and not order.delivery_address:
        raise order_error(400, "ORDER_ADDRESS_MISSING",
                          "The buyer asked to collect and gave no delivery address. Agree the details "
                          "in chat, or keep it as collection.")
    await _offer(db, order, items, offered, fulfilment=fulfilment, payload=payload, now=now)
    material = pricing.is_material_change(
        [(i.id, i.requested_quantity, i.requested_unit_price_minor) for i in items],
        [(i.id, *offered[i.id]) for i in items],
        order.requested_fulfilment, fulfilment,
    )
    if material:
        return msg.SELLER_PROPOSED_CHANGES, _offer_detail(order, items), lc.SELLER_PROPOSED_CHANGES
    return msg.SELLER_ACCEPTED, _offer_detail(order, items), lc.AWAITING_BUYER_CONFIRMATION


async def _do_decline(db, order, items, payload, now):
    reason = _reason(payload, required=True)
    await _release_all(db, items)
    order.decline_reason = reason
    return msg.SELLER_DECLINED, {"reason": reason}, lc.DECLINED


async def _do_confirm(db, order, items, payload, now):
    revision = payload.get("revision")
    if revision != order.revision:
        raise order_error(409, "ORDER_REVISION_STALE",
                          "The store updated its offer. Review the latest details before you confirm.",
                          revision=order.revision)
    for item in items:
        q, p = _current_offer(item)
        item.final_quantity = q
        item.final_unit_price_minor = p
    order.buyer_confirmed_at = now
    order.expires_at = None
    return msg.BUYER_CONFIRMED, {"revision": order.revision, "total_minor": order.total_minor}, lc.CONFIRMED


async def _do_reject_proposal(db, order, items, payload, now):
    await _release_all(db, items)
    for item in items:
        item.proposed_quantity = None
        item.proposed_unit_price_minor = None
    order.seller_subtotal_minor = None
    order.delivery_fee_minor = None
    order.total_minor = None
    order.fulfilment = order.requested_fulfilment
    order.expires_at = now + timedelta(hours=settings.store_order_seller_response_hours)
    note = clean_text(payload.get("note"), 300)
    return msg.BUYER_REJECTED_PROPOSAL, ({"note": note} if note else None), lc.SUBMITTED


async def _do_buyer_cancel(db, order, items, payload, now):
    reason = _reason(payload, required=False)
    await _release_all(db, items)
    order.cancel_reason = reason
    order.cancelled_by = lc.BUYER
    return msg.BUYER_CANCELLED, ({"reason": reason} if reason else None), lc.CANCELLED


async def _do_seller_cancel(db, order, items, payload, now):
    reason = _reason(payload, required=True)
    await _release_all(db, items)
    order.cancel_reason = reason
    order.cancelled_by = lc.SELLER
    return msg.SELLER_CANCELLED, {"reason": reason}, lc.CANCELLED


async def _do_start_preparing(db, order, items, payload, now):
    return msg.PREPARING, None, lc.PREPARING


async def _do_mark_ready(db, order, items, payload, now):
    if payload.get("fulfilment_note") is not None:
        order.fulfilment_note = clean_text(payload.get("fulfilment_note"), 300)
    return msg.READY_FOR_PICKUP, None, lc.READY_FOR_PICKUP


async def _do_dispatch(db, order, items, payload, now):
    if payload.get("dispatch_note") is not None:
        order.dispatch_note = clean_text(payload.get("dispatch_note"), 300)
    return msg.DISPATCHED, None, lc.DISPATCHED


async def _do_mark_delivered(db, order, items, payload, now):
    await _deduct_all(db, items)
    order.handed_over_at = order.handed_over_at or now
    return msg.DELIVERED, None, lc.DELIVERED


async def _do_confirm_received(db, order, items, payload, now):
    # Handed over, whether or not the store reported it first.
    await _deduct_all(db, items)
    order.handed_over_at = order.handed_over_at or now
    order.completed_at = now
    return msg.COMPLETED, None, lc.COMPLETED


async def _do_report_problem(db, order, items, payload, now):
    note = clean_text(payload.get("note"), 500)
    if not note or len(note) < 5:
        raise order_error(400, "ORDER_PROBLEM_NOTE_REQUIRED", "Say what went wrong, so the store can put it right.")
    order.problem_note = note
    order.problem_reported_at = now
    return msg.PROBLEM_REPORTED, {"status": order.status}, None


_HANDLERS = {
    "accept": _do_accept,
    "propose": _do_propose,
    "decline": _do_decline,
    "confirm": _do_confirm,
    "reject_proposal": _do_reject_proposal,
    "buyer_cancel": _do_buyer_cancel,
    "seller_cancel": _do_seller_cancel,
    "start_preparing": _do_start_preparing,
    "mark_ready": _do_mark_ready,
    "dispatch": _do_dispatch,
    "mark_delivered": _do_mark_delivered,
    "confirm_received": _do_confirm_received,
    "report_problem": _do_report_problem,
}


async def _names(db: AsyncSession, order: StoreOrder) -> tuple[str, Optional[str], int]:
    store = await db.get(Store, order.store_id)
    buyer = await db.get(User, order.buyer_id)
    count = (await db.execute(
        select(func.count()).select_from(StoreOrderItem).where(StoreOrderItem.order_id == order.id)
    )).scalar_one()
    return (store.name if store else "The store"), (buyer.name if buyer else None), int(count or 0)


_CHANGED = ("ORDER_CHANGED", "Someone else changed this order at the same moment. Reload it and try again.")


async def _commit(db: AsyncSession) -> None:
    try:
        await db.commit()
    except StaleDataError:
        await db.rollback()
        raise order_error(409, *_CHANGED)


def _conflict_safe(fn):
    """A change that lost a race - another request changed the order
    between this one reading it and writing it, which the version check
    catches on SQLite and the row lock prevents on PostgreSQL - answers 409
    with nothing written, wherever in the change the flush noticed it."""
    @functools.wraps(fn)
    async def wrapper(db: AsyncSession, *args, **kwargs):
        try:
            return await fn(db, *args, **kwargs)
        except StaleDataError:
            await db.rollback()
            raise order_error(409, *_CHANGED)
    return wrapper


@_conflict_safe
async def act(db: AsyncSession, order_id: str, user_id: str, action: str,
              payload: Optional[dict] = None) -> tuple[StoreOrder, str, list[str]]:
    """Apply one action to one order, as `user_id`. Returns the order, the
    caller's role in it and the notification ids to push once the caller
    has been answered."""
    require_enabled()
    payload = payload or {}
    order = await _lock(db, order_id)
    role = await _role(db, order, user_id)
    now = datetime.utcnow()
    if order.status in lc.EXPIRABLE and order.expires_at is not None and order.expires_at <= now:
        # Due but not yet swept: it expires now, and the action is refused.
        # Its notifications stay pending for the sweep to send.
        await _expire_locked(db, order, now)
        raise order_error(409, "ORDER_EXPIRED", "This order expired before that could be done.")
    name = lc.CANCEL_BY_ROLE.get(role, action) if action == "cancel" else action
    try:
        lc.check(name, status=order.status, role=role, fulfilment=order.fulfilment)
    except lc.TransitionError as exc:
        raise _transition_error(exc)
    items = await _items(db, order.id)
    from_status = order.status
    kind, detail, to_status = await _HANDLERS[name](db, order, items, payload, now)
    if to_status is not None:
        order.status = to_status
    if order.status in lc.TERMINAL:
        order.closed_at = order.closed_at or now
        order.expires_at = None
    order.updated_at = now
    store_name, buyer_name, count = await _names(db, order)
    ids = await _record(
        db, order, store_name=store_name, buyer_name=buyer_name, item_count=count,
        kind=kind, actor_id=user_id, actor_role=role,
        from_status=from_status, to_status=order.status, detail=detail,
    )
    await _commit(db)
    return order, role, ids


# ── Expiry ────────────────────────────────────────────────────────────────

@_conflict_safe
async def expire_if_due(db: AsyncSession, order: StoreOrder) -> list[str]:
    """Expire `order` now if its deadline has passed and the sweep has not
    got to it yet - so nobody is shown an offer that has already lapsed.
    Returns the notification ids to push."""
    now = datetime.utcnow()
    if order.status not in lc.EXPIRABLE or order.expires_at is None or order.expires_at > now:
        return []
    locked = await _lock(db, order.id)
    if locked.status not in lc.EXPIRABLE or locked.expires_at is None or locked.expires_at > now:
        await db.rollback()
        return []
    return await _expire_locked(db, locked, now)

async def _expire_locked(db: AsyncSession, order: StoreOrder, now: datetime) -> list[str]:
    """Expire an order already locked by this transaction, and commit."""
    stage = "seller_response" if order.status == lc.SUBMITTED else "buyer_confirmation"
    items = await _items(db, order.id)
    await _release_all(db, items)
    from_status = order.status
    order.status = lc.EXPIRED
    order.closed_at = now
    order.expires_at = None
    order.updated_at = now
    store_name, buyer_name, count = await _names(db, order)
    ids = await _record(
        db, order, store_name=store_name, buyer_name=buyer_name, item_count=count,
        kind=msg.EXPIRED, actor_id=lc.SYSTEM, actor_role=lc.SYSTEM,
        from_status=from_status, to_status=lc.EXPIRED, detail={"stage": stage},
    )
    await _commit(db)
    return ids


async def expire_due(db: AsyncSession, now: Optional[datetime] = None, limit: int = 200) -> list[str]:
    """The sweep: expire every order whose deadline has passed. Each one is
    its own short transaction, re-checked under its lock, so an action that
    got there first wins and a second replica finds nothing to do."""
    now = now or datetime.utcnow()
    ids = (await db.execute(
        select(StoreOrder.id).where(
            StoreOrder.status.in_(lc.EXPIRABLE),
            StoreOrder.expires_at.is_not(None),
            StoreOrder.expires_at <= now,
        ).order_by(StoreOrder.expires_at).limit(limit)
    )).scalars().all()
    await db.commit()
    push: list[str] = []
    for order_id in ids:
        try:
            order = await _lock(db, order_id)
            if (order.status not in lc.EXPIRABLE or order.expires_at is None
                    or order.expires_at > now):
                await db.rollback()
                continue
            push.extend(await _expire_locked(db, order, now))
        except HTTPException:
            await db.rollback()
        except Exception:  # noqa: BLE001 - one order must not stop the sweep
            logger.exception("[store_orders] could not expire %s", order_id)
            await db.rollback()
    return push


# ── Payment arrangement and reports ───────────────────────────────────────

async def _provider(db: AsyncSession, provider_id: Optional[str]) -> dict:
    """The directory's record for an escrow provider a buyer chose: listed
    (approved or under review) and with an address BROKA accepts as its
    official site. Nothing about the provider comes from the request but
    its id."""
    from api.domains.escrow_directory import catalogue, links, repository, schema

    if not provider_id:
        raise order_error(400, "PAYMENT_PROVIDER_REQUIRED", "Choose one of the escrow providers BROKA lists.")
    records = await catalogue.refresh(lambda: repository.load_stored(db))
    record = next((r for r in records if r.get("id") == provider_id), None)
    if record is None or record.get("status") not in schema.LISTED_STATUSES:
        raise order_error(400, "PAYMENT_PROVIDER_UNKNOWN", "Choose one of the escrow providers BROKA lists.")
    identity = record.get("identity") or {}
    domain = identity.get("canonical_domain") or ""
    url = links.official_url(identity.get("website_url"), domain)
    if not url:
        raise order_error(409, "PAYMENT_PROVIDER_LINK",
                          "BROKA can't confirm this provider's official website right now. "
                          "Choose another, or pay the store directly.")
    return {"id": record["id"], "name": (record.get("display_name") or record["id"])[:80],
            "url": url[:300], "domain": domain[:120]}


async def _payment_rows(db: AsyncSession, order_id: str) -> tuple[Optional[StoreOrderPayment],
                                                                   list[StoreOrderPaymentReport]]:
    payment = (await db.execute(
        select(StoreOrderPayment).where(StoreOrderPayment.order_id == order_id)
        .execution_options(populate_existing=True)
    )).scalar_one_or_none()
    reports = list((await db.execute(
        select(StoreOrderPaymentReport).where(StoreOrderPaymentReport.order_id == order_id)
        .order_by(StoreOrderPaymentReport.created_at)
    )).scalars().all())
    return payment, reports


@_conflict_safe
async def choose_payment(db: AsyncSession, order_id: str, user_id: str, arrangement: str,
                         provider_id: Optional[str]) -> tuple[StoreOrder, str, list[str]]:
    """The buyer says how they will pay. Choosing an escrow provider is a
    choice, not a payment: nothing about the order's progress changes."""
    require_enabled()
    if arrangement not in lc.ARRANGEMENTS:
        raise order_error(400, "PAYMENT_ARRANGEMENT_INVALID", "Choose direct payment or an escrow provider.")
    provider = await _provider(db, provider_id) if arrangement == lc.INDEPENDENT_ESCROW else None
    order = await _lock(db, order_id)
    role = await _role(db, order, user_id)
    if role != lc.BUYER:
        raise order_error(403, "PAYMENT_ARRANGEMENT_FORBIDDEN", "Only the buyer chooses how to pay.")
    if order.status not in lc.ARRANGEMENT_SELECTABLE:
        raise order_error(409, "PAYMENT_ARRANGEMENT_CLOSED", "This order has ended; there is nothing to pay.")
    payment, reports = await _payment_rows(db, order.id)
    if reports:
        raise order_error(409, "PAYMENT_ARRANGEMENT_LOCKED",
                          "A payment has already been reported on this order, so how it is paid can't change.")
    now = datetime.utcnow()
    if payment is None:
        payment = StoreOrderPayment(id=_uuid(), order_id=order.id, selected_at=now)
        db.add(payment)
    payment.arrangement = arrangement
    payment.provider_id = provider["id"] if provider else None
    payment.provider_name = provider["name"] if provider else None
    payment.provider_url = provider["url"] if provider else None
    payment.provider_domain = provider["domain"] if provider else None
    payment.selected_by = user_id
    payment.selected_by_role = role
    payment.updated_at = now
    order.updated_at = now
    await db.flush()
    store_name, buyer_name, count = await _names(db, order)
    ids = await _record(
        db, order, store_name=store_name, buyer_name=buyer_name, item_count=count,
        kind=msg.PAYMENT_ARRANGEMENT_SELECTED, actor_id=user_id, actor_role=role,
        from_status=order.status, to_status=order.status,
        detail={"arrangement": arrangement,
                **({"provider_id": provider["id"], "provider_name": provider["name"]} if provider else {})},
    )
    await _commit(db)
    return order, role, ids


@_conflict_safe
async def report_payment(db: AsyncSession, order_id: str, user_id: str, kind: str,
                         reference: Optional[str], note: Optional[str]) -> tuple[StoreOrder, str, list[str]]:
    """Record what the buyer or the store says happened with the money.
    Recorded as said, labelled as reported, and never moves the order."""
    require_enabled()
    ref = clean_text(reference, 64)
    if ref is not None and not _PAYMENT_REFERENCE.match(ref):
        raise order_error(400, "PAYMENT_REFERENCE_INVALID",
                          "A reference can use letters, numbers, spaces and . _ / # : - only.")
    note_text = clean_text(note, 300)
    order = await _lock(db, order_id)
    role = await _role(db, order, user_id)
    payment, reports = await _payment_rows(db, order.id)
    try:
        spec = lc.check_report(kind, role=role, status=order.status,
                               arrangement=payment.arrangement if payment else None)
    except lc.TransitionError as exc:
        raise _transition_error(exc)
    if any(r.kind == kind for r in reports):
        raise order_error(409, "PAYMENT_ALREADY_REPORTED", "That has already been reported on this order.")
    now = datetime.utcnow()
    if payment is None:
        # Only a store confirming a direct payment gets here without an
        # arrangement (lifecycle.check_report): it is one, so say so.
        payment = StoreOrderPayment(
            id=_uuid(), order_id=order.id, arrangement=lc.DIRECT_TO_SELLER,
            selected_by=user_id, selected_by_role=role, selected_at=now, updated_at=now,
        )
        db.add(payment)
        await db.flush()
    db.add(StoreOrderPaymentReport(
        id=_uuid(), order_id=order.id, kind=spec.kind, actor_id=user_id, actor_role=role,
        arrangement=payment.arrangement, provider_id=payment.provider_id,
        reference=ref, note=note_text, created_at=now,
    ))
    order.updated_at = now
    try:
        # The unique (order, kind) index is the real guard against the same
        # report twice at once; the check above is only the fast answer.
        await db.flush()
    except IntegrityError:
        await db.rollback()
        raise order_error(409, "PAYMENT_ALREADY_REPORTED", "That has already been reported on this order.")
    store_name, buyer_name, count = await _names(db, order)
    ids = await _record(
        db, order, store_name=store_name, buyer_name=buyer_name, item_count=count,
        kind=msg.PAYMENT_REPORTED, actor_id=user_id, actor_role=role,
        from_status=order.status, to_status=order.status,
        # The kind and its label only: the reference and the note stay on
        # the report row, out of the shared event history.
        detail={"report_kind": spec.kind, "label": spec.label, "verified": False},
    )
    await _commit(db)
    return order, role, ids


# ── What each side sees ───────────────────────────────────────────────────

def _expiry_stage(order: StoreOrder) -> Optional[str]:
    if order.status == lc.SUBMITTED:
        return "seller_response"
    if order.status in lc.AWAITING_BUYER:
        return "buyer_confirmation"
    return None


def _payment_view(order: StoreOrder, role: str, payment: Optional[StoreOrderPayment],
                  reports: list[StoreOrderPaymentReport]) -> dict:
    arrangement = payment.arrangement if payment else None
    reported = {r.kind for r in reports}
    allowed_reports = []
    for kind in lc.REPORT_KINDS:
        if kind in reported:
            continue
        try:
            lc.check_report(kind, role=role, status=order.status, arrangement=arrangement)
        except lc.TransitionError:
            continue
        allowed_reports.append(kind)
    return {
        "arrangement": arrangement,
        "arrangement_label": lc.ARRANGEMENT_LABELS.get(arrangement or "") if arrangement else None,
        "provider": ({
            "id": payment.provider_id, "name": payment.provider_name,
            "url": payment.provider_url, "domain": payment.provider_domain,
            "independent": True, "notice": lc.ESCROW_PROVIDER_NOTICE,
        } if payment and payment.provider_id else None),
        "selected_at": _iso(payment.selected_at) if payment else None,
        "reports": [{
            "kind": r.kind,
            "label": lc.REPORT_KINDS[r.kind].label if r.kind in lc.REPORT_KINDS else r.kind,
            "actor_role": r.actor_role,
            "reference": r.reference,
            "note": r.note,
            "created_at": _iso(r.created_at),
            "verified": False,
        } for r in reports],
        "summary": lc.payment_summary(arrangement, reported, payment.provider_name if payment else None),
        "can_choose": role == lc.BUYER and order.status in lc.ARRANGEMENT_SELECTABLE and not reports,
        "allowed_reports": allowed_reports,
        "notice": lc.PAYMENT_NOTICE,
    }


def _item_view(item: StoreOrderItem, assets: dict, role: str,
               counted: Optional[inventory.Inventory]) -> dict:
    from api.domains.media.service import asset_urls

    q, p = _current_offer(item)
    if item.final_quantity is not None:
        q, p = int(item.final_quantity), int(item.final_unit_price_minor or p)
    view = {
        "id": item.id,
        "listing_id": item.listing_id,
        "name": item.name,
        "price_unit": item.price_unit,
        "image": asset_urls(assets.get(item.image_asset_id)) if item.image_asset_id else None,
        "requested_quantity": item.requested_quantity,
        "requested_unit_price_minor": item.requested_unit_price_minor,
        "requested_line_total_minor": pricing.line_total(item.requested_quantity, item.requested_unit_price_minor),
        "proposed_quantity": item.proposed_quantity,
        "proposed_unit_price_minor": item.proposed_unit_price_minor,
        "final_quantity": item.final_quantity,
        "final_unit_price_minor": item.final_unit_price_minor,
        "quantity": q,
        "unit_price_minor": p,
        "line_total_minor": pricing.line_total(q, p),
        "changed": item.proposed_quantity is not None and (
            item.proposed_quantity != item.requested_quantity
            or item.proposed_unit_price_minor != item.requested_unit_price_minor),
        "removed": q == 0,
    }
    if role == lc.SELLER:
        # The shared count (listings/inventory.py): "free to order" is what
        # the next acceptance - or a chat deal - may take, with units in
        # chat deals taken off as well as other orders' reservations.
        tracked = bool(counted is not None and counted.tracked)
        view.update({
            "stock_tracked": tracked,
            "stock_on_hand": counted.on_hand if tracked else None,
            "stock_available": counted.available if tracked else None,
            "stock_committed_to_deals": counted.committed_to_deals if tracked else None,
            "reserved_quantity": int(item.reserved_quantity or 0),
            "stock_state": item.stock_state,
        })
    return view


def _event_view(e: StoreOrderEvent) -> dict:
    try:
        detail = json.loads(e.detail) if e.detail else None
    except (TypeError, ValueError):
        detail = None
    return {
        "id": e.id,
        "kind": e.kind,
        "label": msg.EVENT_LABELS.get(e.kind, e.kind.replace("_", " ").capitalize()),
        "actor_role": e.actor_role,
        "from_status": e.from_status,
        "to_status": e.to_status,
        "revision": e.revision,
        "detail": detail,
        "created_at": _iso(e.created_at),
    }


async def view(db: AsyncSession, order: StoreOrder, role: str) -> dict:
    """The order as `role` sees it. Contact details are the buyer's own and
    the store owner's to see; nothing here is ever public."""
    from api.domains.media.service import load_assets
    from api.domains.stores.service import store_link

    items = await _items(db, order.id)
    store = await db.get(Store, order.store_id)
    payment, reports = await _payment_rows(db, order.id)
    events = (await db.execute(
        select(StoreOrderEvent).where(StoreOrderEvent.order_id == order.id)
        .order_by(StoreOrderEvent.created_at, StoreOrderEvent.id)
    )).scalars().all()
    assets = await load_assets(db, {i.image_asset_id for i in items if i.image_asset_id})
    # The store's view counts each product's stock; the buyer's has none.
    counted = (await inventory.counts(db, (await _listings_for(db, items)).values())
               if role == lc.SELLER else {})
    now = datetime.utcnow()
    expires_in = (int((order.expires_at - now).total_seconds())
                  if order.expires_at is not None and order.status in lc.EXPIRABLE else None)
    out = {
        "id": order.id,
        "reference": order.reference,
        "role": role,
        "status": order.status,
        "status_label": lc.status_label(order.status, role),
        "open": order.status in lc.OPEN,
        "store": {
            "id": order.store_id,
            "name": store.name if store else None,
            "slug": store.slug if store else None,
            "url": store_link(store.slug) if store else None,
        },
        "currency": order.currency,
        "items": [_item_view(i, assets, role, counted.get(i.listing_id)) for i in items],
        "totals": {
            "requested_subtotal_minor": order.requested_subtotal_minor,
            "seller_subtotal_minor": order.seller_subtotal_minor,
            "delivery_fee_minor": order.delivery_fee_minor,
            "total_minor": order.total_minor,
            # The figure to show: the store's offer once it has answered,
            # what the buyer asked for until then.
            "display_total_minor": (order.total_minor if order.total_minor is not None
                                    else order.requested_subtotal_minor),
            "final": order.buyer_confirmed_at is not None,
        },
        "fulfilment": {
            "method": order.fulfilment,
            "requested_method": order.requested_fulfilment,
            "address": order.delivery_address,
            "contact_phone": order.contact_phone,
            "note": order.fulfilment_note,
            "dispatch_note": order.dispatch_note,
        },
        "buyer_note": order.buyer_note,
        "seller_note": order.seller_note,
        "decline_reason": order.decline_reason,
        "cancel_reason": order.cancel_reason,
        "cancelled_by": order.cancelled_by,
        "problem": ({"note": order.problem_note, "reported_at": _iso(order.problem_reported_at)}
                    if order.problem_reported_at else None),
        "revision": order.revision,
        "expires_at": _iso(order.expires_at) if order.status in lc.EXPIRABLE else None,
        "expires_in_seconds": max(expires_in, 0) if expires_in is not None else None,
        "expiry_stage": _expiry_stage(order),
        "allowed_actions": lc.allowed_actions(order.status, role, order.fulfilment),
        "payment": _payment_view(order, role, payment, reports),
        "events": [_event_view(e) for e in events],
        "created_at": _iso(order.created_at),
        "updated_at": _iso(order.updated_at),
        "seller_responded_at": _iso(order.seller_responded_at),
        "buyer_confirmed_at": _iso(order.buyer_confirmed_at),
        "handed_over_at": _iso(order.handed_over_at),
        "completed_at": _iso(order.completed_at),
    }
    if role == lc.SELLER:
        buyer = await db.get(User, order.buyer_id)
        campaign_title = None
        if order.campaign_id:
            from api.models.marketing import MarketingCampaign
            campaign_title = (await db.execute(
                select(MarketingCampaign.title).where(MarketingCampaign.id == order.campaign_id)
            )).scalar_one_or_none()
        out["buyer"] = {"name": buyer.name if buyer else None, "phone_verified": bool(buyer and buyer.phone_verified)}
        out["attribution"] = {
            "surface": order.source_surface,
            "source": order.source_channel,
            "campaign": {"id": order.campaign_id, "title": campaign_title} if order.campaign_id else None,
        }
    return out


def _summary(order: StoreOrder, role: str, *, item_count: int, first_item: Optional[str],
             store: Optional[Store], buyer_name: Optional[str]) -> dict:
    needs = set(lc.allowed_actions(order.status, role, order.fulfilment)) - {"cancel", "report_problem"}
    out = {
        "id": order.id,
        "reference": order.reference,
        "status": order.status,
        "status_label": lc.status_label(order.status, role),
        "open": order.status in lc.OPEN,
        "needs_action": bool(needs),
        "item_count": item_count,
        "first_item": first_item,
        "currency": order.currency,
        "total_minor": order.total_minor if order.total_minor is not None else order.requested_subtotal_minor,
        "final": order.buyer_confirmed_at is not None,
        "fulfilment": order.fulfilment,
        "created_at": _iso(order.created_at),
        "updated_at": _iso(order.updated_at),
        "expires_at": _iso(order.expires_at) if order.status in lc.EXPIRABLE else None,
        "store": {"id": order.store_id, "name": store.name if store else None,
                  "slug": store.slug if store else None},
    }
    if role == lc.SELLER:
        out["buyer_name"] = buyer_name
        out["problem_reported"] = order.problem_reported_at is not None
    return out


async def _summaries(db: AsyncSession, orders: list[StoreOrder], role: str) -> list[dict]:
    if not orders:
        return []
    ids = [o.id for o in orders]
    counts = dict((await db.execute(
        select(StoreOrderItem.order_id, func.count(StoreOrderItem.id))
        .where(StoreOrderItem.order_id.in_(ids)).group_by(StoreOrderItem.order_id)
    )).all())
    firsts: dict[str, str] = {}
    for order_id, name in (await db.execute(
        select(StoreOrderItem.order_id, StoreOrderItem.name)
        .where(StoreOrderItem.order_id.in_(ids), StoreOrderItem.position == 0)
    )).all():
        firsts[order_id] = name
    stores = {s.id: s for s in (await db.execute(
        select(Store).where(Store.id.in_(sorted({o.store_id for o in orders})))
    )).scalars().all()}
    buyers: dict[str, str] = {}
    if role == lc.SELLER:
        buyers = dict((await db.execute(
            select(User.id, User.name).where(User.id.in_(sorted({o.buyer_id for o in orders})))
        )).all())
    return [
        _summary(o, role, item_count=int(counts.get(o.id, 0)), first_item=firsts.get(o.id),
                 store=stores.get(o.store_id), buyer_name=buyers.get(o.buyer_id))
        for o in orders
    ]


async def list_for_buyer(db: AsyncSession, buyer_id: str, *, scope: str = "all",
                         limit: int = 20, offset: int = 0) -> dict:
    q = select(StoreOrder).where(StoreOrder.buyer_id == buyer_id)
    if scope == "open":
        q = q.where(StoreOrder.status.in_(lc.OPEN))
    elif scope == "closed":
        q = q.where(StoreOrder.status.in_(lc.TERMINAL))
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar_one()
    rows = (await db.execute(
        q.order_by(StoreOrder.updated_at.desc(), StoreOrder.id)
        .offset(offset).limit(max(1, min(limit, _PAGE_MAX)))
    )).scalars().all()
    return {"items": await _summaries(db, list(rows), lc.BUYER), "total": int(total or 0)}


_SORTS = {
    "newest": (StoreOrder.created_at.desc(), StoreOrder.id),
    "oldest": (StoreOrder.created_at.asc(), StoreOrder.id),
    "updated": (StoreOrder.updated_at.desc(), StoreOrder.id),
    "value_high": (func.coalesce(StoreOrder.total_minor, StoreOrder.requested_subtotal_minor).desc(), StoreOrder.id),
    "value_low": (func.coalesce(StoreOrder.total_minor, StoreOrder.requested_subtotal_minor).asc(), StoreOrder.id),
    # Soonest deadline first; orders without one after them.
    "expiring": (StoreOrder.expires_at.is_(None), StoreOrder.expires_at.asc(), StoreOrder.id),
}


async def group_counts(db: AsyncSession, store_id: str) -> dict:
    rows = dict((await db.execute(
        select(StoreOrder.status, func.count()).where(StoreOrder.store_id == store_id)
        .group_by(StoreOrder.status)
    )).all())
    counts = {group: sum(int(rows.get(s, 0)) for s in statuses)
              for group, statuses in lc.SELLER_GROUPS.items()}
    counts["by_status"] = {s: int(rows.get(s, 0)) for s in lc.STATUSES}
    return counts


async def list_for_store(db: AsyncSession, store: Store, *, group: str = "open",
                         status: Optional[str] = None, search: Optional[str] = None,
                         sort: str = "newest", limit: int = 20, offset: int = 0) -> dict:
    """The store's orders for its owner (the caller has been checked as the
    owner by the router), filtered by group or exact status and searched by
    reference, buyer name or product."""
    q = select(StoreOrder).where(StoreOrder.store_id == store.id)
    if status:
        if status not in lc.STATUSES:
            raise order_error(400, "ORDER_STATUS_UNKNOWN", "Unknown order status.")
        q = q.where(StoreOrder.status == status)
    elif group:
        statuses = lc.SELLER_GROUPS.get(group)
        if statuses is None:
            raise order_error(400, "ORDER_GROUP_UNKNOWN", "Unknown order filter.")
        q = q.where(StoreOrder.status.in_(statuses))
    term = clean_text(search, 60)
    if term:
        like = f"%{term.lower()}%"
        q = q.where(or_(
            func.lower(StoreOrder.reference).like(like),
            exists().where(User.id == StoreOrder.buyer_id, func.lower(User.name).like(like)),
            exists().where(StoreOrderItem.order_id == StoreOrder.id,
                           func.lower(StoreOrderItem.name).like(like)),
        ))
    total = (await db.execute(select(func.count()).select_from(q.subquery()))).scalar_one()
    order_by = _SORTS.get(sort)
    if order_by is None:
        raise order_error(400, "ORDER_SORT_UNKNOWN", "Unknown sort.")
    rows = (await db.execute(
        q.order_by(*order_by).offset(offset).limit(max(1, min(limit, _PAGE_MAX)))
    )).scalars().all()
    return {
        "items": await _summaries(db, list(rows), lc.SELLER),
        "total": int(total or 0),
        "counts": await group_counts(db, store.id),
    }


# ── Inventory controls for the store's products ───────────────────────────

def _check_product(listing: Optional[Listing], store: Store) -> Listing:
    if (listing is None or listing.store_id != store.id or listing.seller_id != store.owner_id
            or (getattr(listing.status, "value", listing.status) == ListingStatus.cancelled.value
                and listing.archived_at is None)):
        raise order_error(404, "LISTING_NOT_FOUND", "That product isn't in this store.")
    if getattr(listing.listing_type, "value", listing.listing_type) == ListingType.auction.value:
        raise order_error(400, "LISTING_IS_AUCTION", "Auctions sell one item through bidding; stock doesn't apply.")
    return listing


def _line_quantity(item: StoreOrderItem) -> int:
    """The units an accepted order's line is for: what the buyer confirmed,
    or else what the store offered."""
    if item.final_quantity is not None:
        return int(item.final_quantity)
    return _current_offer(item)[0]


async def _unreserved_accepted(db: AsyncSession, listing_id: str) -> list[StoreOrderItem]:
    """Lines of this product in orders the store accepted while it didn't
    count stock - still to be handed over, holding no units."""
    rows = (await db.execute(
        select(StoreOrderItem)
        .join(StoreOrder, StoreOrder.id == StoreOrderItem.order_id)
        .where(
            StoreOrderItem.listing_id == listing_id,
            StoreOrder.status.in_(sorted(lc.HOLDS_STOCK)),
            StoreOrderItem.reserved_quantity == 0,
        )
        .order_by(StoreOrderItem.order_id)
        .execution_options(populate_existing=True)
    )).scalars().all()
    return [item for item in rows if _line_quantity(item) > 0]


def _check_promised(on_hand: int, *, orders: int, deals: int) -> None:
    """On hand can't go below what has been promised: units accepted orders
    hold and units in chat deals still under way."""
    floor = orders + deals
    if on_hand >= floor:
        return
    if orders and deals:
        message = (f"{floor} of these are promised: {orders} to accepted orders and {deals} "
                   f"to chat deals still under way. Set at least {floor}.")
    elif orders:
        message = (f"{orders} of these are reserved by accepted orders. Set at least {orders}, "
                   "or cancel those orders first.")
    else:
        message = f"{deals} of these are in chat deals still under way. Set at least {deals}."
    raise order_error(409, "STOCK_BELOW_RESERVED", message,
                      reserved=orders, in_deals=deals, minimum=floor)


async def set_stock(db: AsyncSession, store: Store, listing_id: str, *, tracked: Optional[bool],
                    quantity: Optional[int], temporarily_unavailable: Optional[bool]) -> dict:
    """The owner's stock switches for one product of this store (the router
    has checked ownership): whether its stock is counted, how many are on
    hand, and a pause on new orders for it.

    `quantity` means what the answer's `quantity` will show. Counted: the
    units on hand, stored as on hand plus the units chat deals sold
    (listings/inventory.py), and never below what is promised - accepted
    orders and chat deals still under way. Not counted: the listing's
    stated quantity, stored as given, as it always was - the cap on what a
    buyer may ask for, which chat deals count against.

    Switching counting off is refused while accepted orders hold units:
    their handover is what takes those units off the stock, and with
    counting off nothing would. Switching it on reserves the units of every
    order the store accepted while it didn't count and hasn't handed over -
    or is refused when on hand can't cover them - so those orders are
    fulfilled from the count instead of being sold to someone else.

    Locks: the orders being converted, then the listing - the order an
    order action takes them in - so the two can't deadlock."""
    if quantity is not None and not 0 <= int(quantity) <= 1_000_000:
        raise order_error(400, "STOCK_QUANTITY_INVALID", "Stock must be between 0 and 1,000,000.")
    peek = _check_product((await db.execute(
        select(Listing).where(Listing.id == listing_id).execution_options(populate_existing=True)
    )).scalar_one_or_none(), store)
    starting = tracked is True and not peek.stock_tracked
    locked_orders: set[str] = set()
    if starting:
        locked_orders = {i.order_id for i in await _unreserved_accepted(db, listing_id)}
        if locked_orders:
            await db.execute(
                select(StoreOrder.id).where(StoreOrder.id.in_(sorted(locked_orders)))
                .order_by(StoreOrder.id).with_for_update()
            )
    listing = _check_product((await inventory.lock(db, [listing_id])).get(listing_id), store)
    was_tracked = bool(listing.stock_tracked)
    want_tracked = was_tracked if tracked is None else bool(tracked)
    counted = await inventory.count(db, listing)

    if want_tracked and not was_tracked:
        convert = await _unreserved_accepted(db, listing_id)
        if {i.order_id for i in convert} - locked_orders:
            # An order was accepted between the look above and the locks:
            # its row isn't locked, so it could move on while it is counted.
            raise order_error(409, "STOCK_CHANGED",
                              "An order for this product was answered at the same moment. Try again.")
        needed = sum(_line_quantity(i) for i in convert)
        if quantity is not None:
            on_hand = int(quantity)
        elif listing.quantity is not None:
            on_hand = max(int(listing.quantity) - counted.sold_in_deals, 0)
        else:
            raise order_error(400, "STOCK_QUANTITY_REQUIRED", "Say how many you have to start tracking stock.")
        _check_promised(on_hand, orders=counted.reserved + needed, deals=counted.committed_to_deals)
        listing.stock_tracked = True
        listing.quantity = counted.stored_quantity_for(on_hand)
        listing.stock_reserved = counted.reserved + needed
        for item in convert:
            item.reserved_quantity = _line_quantity(item)
            item.stock_state = "reserved"
    elif want_tracked:
        if quantity is not None:
            _check_promised(int(quantity), orders=counted.reserved, deals=counted.committed_to_deals)
            listing.quantity = counted.stored_quantity_for(int(quantity))
    else:
        if was_tracked and counted.reserved > 0:
            raise order_error(
                409, "STOCK_TRACKING_IN_USE",
                f"{counted.reserved} of these are set aside for accepted orders, and come off your "
                "stock when you hand them over. Hand over or cancel those orders before you stop "
                "counting stock.",
                reserved=counted.reserved,
            )
        if quantity is not None:
            if int(quantity) < 1:
                # Untracked, the quantity is what the listing says the seller
                # has; the listing editor has never accepted 0 for that.
                raise order_error(400, "STOCK_QUANTITY_INVALID",
                                  "Turn stock tracking on to record that none are left, or mark it unavailable.")
            listing.quantity = int(quantity)
        elif was_tracked and int(listing.quantity or 0) < 1:
            # Untracked, 0 would read as one (listings/stock.units_total): a
            # unit nobody has would go back on sale.
            raise order_error(400, "STOCK_QUANTITY_REQUIRED",
                              "None are left. Set how many you have before you stop counting stock.")
        # Without a new quantity the stored one stays: on hand plus what
        # chat deals sold, which is what the untracked count reads.
        listing.stock_tracked = False

    if temporarily_unavailable is not None:
        listing.temporarily_unavailable = bool(temporarily_unavailable)
    after = inventory.recount(listing, counted)
    # Whether stock keeps it listed (stock.status_for): a counted product
    # never hides; one no longer counted follows its chat deals again.
    target = status_for(listing, after.in_deals, after.sold_in_deals)
    if target is not None:
        listing.status = target
    await db.commit()
    return stock_view(listing, after)


def stock_view(listing: Listing, counted: inventory.Inventory) -> dict:
    """A product's stock as its owner sees it, from the shared count - the
    same figures as the store's product list (inventory.owner_fields)."""
    tracked = counted.tracked
    return {
        "listing_id": listing.id,
        "stock_tracked": tracked,
        # On hand while counted; the stated quantity otherwise.
        "quantity": counted.on_hand if tracked else listing.quantity,
        "stock_reserved": counted.reserved,
        # stock_on_hand, stock_committed_to_deals, stock_sold_through_deals.
        **inventory.owner_fields(counted),
        "available_quantity": counted.available if tracked else None,
        "temporarily_unavailable": bool(getattr(listing, "temporarily_unavailable", False)),
    }
