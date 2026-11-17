"""HTTP contracts for store orders, and web enquiries to a store.

Two routers, mounted in main.py:

  /orders  (orders_router) - one order, for its buyer or its store's owner
    POST   /orders                          submit a request (X-Idempotency-Key required)
    GET    /orders                          the caller's own orders as a buyer
    GET    /orders/notifications            the caller's order updates (buyer and seller)
    GET    /orders/notifications/unread-count
    POST   /orders/notifications/read
    GET    /orders/{id}                     one order, as the caller's role sees it
    POST   /orders/{id}/accept | propose | decline                    the store
    POST   /orders/{id}/confirm | reject-proposal                     the buyer
    POST   /orders/{id}/preparing | ready | dispatch | delivered      the store
    POST   /orders/{id}/received | problem                            the buyer
    POST   /orders/{id}/cancel                                        either, by the rules
    POST   /orders/{id}/payment-arrangement                           the buyer
    POST   /orders/{id}/payment-reports                               either: what they SAY happened

  /stores  (stores_router) - the store owner's views, and a buyer's questions
    GET    /stores/{id}/orders                     the store's orders (owner)
    GET    /stores/{id}/orders/summary             counts for badges (owner)
    PATCH  /stores/{id}/manage/listings/{lid}/stock  stock tracking and pause (owner)
    POST   /stores/{id}/enquiries                  a buyer's question to the store or about one product

Every route needs a signed-in user. Which of an order's two people the
caller is comes from the database (service._role); a client never says.
No route here takes, holds, verifies or releases money (store_orders/).
"""
from __future__ import annotations

import logging
from typing import List, Literal, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, Header, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy.ext.asyncio import AsyncSession

from api.core.client_ip import client_ip
from api.core.rate_limit import (
    store_enquiry_ip_limiter, store_enquiry_limiter, store_order_action_limiter,
    store_order_submit_ip_limiter, store_order_submit_limiter,
)
from api.database import get_db
from api.security import get_current_user

from . import analytics, notify, pricing
from . import lifecycle as lc
from . import service

logger = logging.getLogger(__name__)
orders_router = APIRouter()
stores_router = APIRouter()


# ── Request bodies ────────────────────────────────────────────────────────
# Only what a person decides. No price, total, status, buyer or seller field
# exists on any of these, and OrderIn forbids unknown fields outright, so a
# client that sends "price" is told no rather than quietly ignored.

class OrderItemIn(BaseModel):
    listing_id: str = Field(min_length=1, max_length=64)
    quantity: int = Field(ge=1, le=pricing.MAX_QUANTITY)


class OrderIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    store_id: str = Field(min_length=1, max_length=64)
    items: List[OrderItemIn] = Field(min_length=1, max_length=pricing.MAX_ITEMS)
    fulfilment: Literal["delivery", "collection"]
    delivery_address: Optional[str] = Field(default=None, max_length=300)
    contact_phone: Optional[str] = Field(default=None, max_length=24)
    note: Optional[str] = Field(default=None, max_length=500)
    surface: Literal["web", "app"] = "web"
    # Attribution, as the storefront link carried it (?via= and ?c=). The
    # campaign token is resolved against this store's campaigns; an unknown
    # one is ignored.
    via: Optional[str] = Field(default=None, max_length=32)
    campaign: Optional[str] = Field(default=None, max_length=32)


class AcceptIn(BaseModel):
    delivery_fee_minor: Optional[int] = Field(default=None, ge=0, le=pricing.MAX_DELIVERY_FEE_MINOR)
    seller_note: Optional[str] = Field(default=None, max_length=500)
    fulfilment_note: Optional[str] = Field(default=None, max_length=300)


class ProposedItemIn(BaseModel):
    item_id: str = Field(min_length=1, max_length=64)
    # 0: the store can't supply this product.
    quantity: int = Field(ge=0, le=pricing.MAX_QUANTITY)
    unit_price_minor: Optional[int] = Field(default=None, ge=1, le=pricing.MAX_UNIT_PRICE_MINOR)


class ProposeIn(AcceptIn):
    items: List[ProposedItemIn] = Field(default_factory=list, max_length=pricing.MAX_ITEMS)
    fulfilment: Optional[Literal["delivery", "collection"]] = None


class ReasonIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=300)


class ConfirmIn(BaseModel):
    # The offer being confirmed (order.revision): a confirmation can never
    # land on an offer the buyer did not see.
    revision: int = Field(ge=1)


class NoteIn(BaseModel):
    note: Optional[str] = Field(default=None, max_length=300)


class ReadyIn(BaseModel):
    fulfilment_note: Optional[str] = Field(default=None, max_length=300)


class DispatchIn(BaseModel):
    dispatch_note: Optional[str] = Field(default=None, max_length=300)


class ProblemIn(BaseModel):
    note: str = Field(min_length=5, max_length=500)


class ArrangementIn(BaseModel):
    arrangement: Literal["direct_to_seller", "independent_escrow"]
    # A directory provider id (GET /escrow-providers); its name and official
    # address are taken from the directory, never from the request.
    provider_id: Optional[str] = Field(default=None, max_length=40)


class PaymentReportIn(BaseModel):
    kind: Literal[
        "buyer_reported_payment_sent", "seller_confirmed_receipt",
        "buyer_reported_escrow_initiated", "seller_reported_escrow_release",
    ]
    # Optional, whatever the person chooses to note - a receipt number, a
    # provider's transaction id. Never a PIN or password; it proves nothing.
    reference: Optional[str] = Field(default=None, max_length=64)
    note: Optional[str] = Field(default=None, max_length=300)


class ReadIn(BaseModel):
    ids: Optional[List[str]] = Field(default=None, max_length=100)
    order_id: Optional[str] = Field(default=None, max_length=64)
    all: bool = False


class StockIn(BaseModel):
    stock_tracked: Optional[bool] = None
    quantity: Optional[int] = Field(default=None, ge=0, le=1_000_000)
    temporarily_unavailable: Optional[bool] = None


class EnquiryIn(BaseModel):
    content: str = Field(min_length=1, max_length=2000)
    # Set: a question about this product (the product's own thread).
    # Unset: a question to the store (its store-wide thread).
    listing_id: Optional[str] = Field(default=None, max_length=64)
    client_msg_id: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9_-]{8,64}$")


# ── Orders ────────────────────────────────────────────────────────────────

@orders_router.post("", status_code=201)
async def submit_order(
    body: OrderIn,
    request: Request,
    response: Response,
    background: BackgroundTasks,
    x_idempotency_key: Optional[str] = Header(default=None, alias="X-Idempotency-Key"),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Send a store an order request. The store must confirm availability,
    quantities, prices and the handover before the buyer confirms; nothing
    is reserved or paid by sending it. Prices and totals come from the
    listings. A retry with the same X-Idempotency-Key returns the same
    order (200, replayed: true); the key with a different request is a 409."""
    # Keyed on who is really calling - the signed-in buyer and their
    # address - never on anything in the body.
    await store_order_submit_limiter.check_and_record(f"user:{current_user['id']}")
    await store_order_submit_ip_limiter.check_and_record(f"ip:{client_ip(request)}")
    order, created, push_ids = await service.submit(
        db,
        buyer_id=current_user["id"],
        store_id=body.store_id,
        items=[service.RequestedItem(i.listing_id, i.quantity) for i in body.items],
        fulfilment=body.fulfilment,
        delivery_address=body.delivery_address,
        contact_phone=body.contact_phone,
        note=body.note,
        idempotency_key=x_idempotency_key,
        surface=body.surface,
        via=body.via,
        campaign=body.campaign,
    )
    if push_ids:
        background.add_task(notify.deliver, push_ids)
    if not created:
        response.status_code = 200
    return {**await service.view(db, order, lc.BUYER), "replayed": not created}


@orders_router.get("")
async def my_orders(
    scope: Literal["open", "closed", "all"] = "all",
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The caller's orders as a buyer, most recently changed first."""
    return await service.list_for_buyer(db, current_user["id"], scope=scope, limit=limit, offset=offset)


@orders_router.get("/notifications")
async def my_order_updates(
    unread_only: bool = False,
    order_id: Optional[str] = Query(None, max_length=64),
    limit: int = Query(30, ge=1, le=100),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Order updates addressed to the caller, as a buyer or as a store owner."""
    return await notify.feed(db, current_user["id"], unread_only=unread_only, order_id=order_id,
                             limit=limit, offset=offset)


@orders_router.get("/notifications/unread-count")
async def my_unread_order_updates(
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return {"unread": await notify.unread_count(db, current_user["id"])}


@orders_router.post("/notifications/read")
async def mark_order_updates_read(
    body: ReadIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    marked = await notify.mark_read(db, current_user["id"], ids=body.ids, order_id=body.order_id,
                                    everything=body.all)
    return {"marked": marked, "unread": await notify.unread_count(db, current_user["id"])}


@orders_router.get("/{order_id}")
async def get_order(
    order_id: str,
    background: BackgroundTasks,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """One order, for its buyer or its store's owner; 404 for anyone else."""
    order, role = await service.get_for(db, order_id, current_user["id"])
    push_ids = await service.expire_if_due(db, order)
    if push_ids:
        background.add_task(notify.deliver, push_ids)
    return await service.view(db, order, role)


async def _act(order_id: str, action: str, payload: dict, current_user: dict,
               db: AsyncSession, background: BackgroundTasks) -> dict:
    await store_order_action_limiter.check_and_record(f"user:{current_user['id']}")
    order, role, push_ids = await service.act(db, order_id, current_user["id"], action, payload)
    if push_ids:
        background.add_task(notify.deliver, push_ids)
    return await service.view(db, order, role)


@orders_router.post("/{order_id}/accept")
async def accept_order(order_id: str, background: BackgroundTasks, body: Optional[AcceptIn] = None,
                       current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The store accepts the request as asked - optionally with a delivery
    charge and handover details. Tracked stock is reserved for the buyer
    while they confirm (STORE_ORDER_RESERVATION_HOURS)."""
    return await _act(order_id, "accept", (body or AcceptIn()).model_dump(exclude_unset=True),
                      current_user, db, background)


@orders_router.post("/{order_id}/propose")
async def propose_changes(order_id: str, body: ProposeIn, background: BackgroundTasks,
                          current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The store offers different quantities, prices or handover. The buyer
    must accept the changes explicitly before anything else happens."""
    payload = body.model_dump(exclude_unset=True)
    payload["items"] = [i.model_dump() for i in body.items]
    return await _act(order_id, "propose", payload, current_user, db, background)


@orders_router.post("/{order_id}/decline")
async def decline_order(order_id: str, body: ReasonIn, background: BackgroundTasks,
                        current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await _act(order_id, "decline", body.model_dump(), current_user, db, background)


@orders_router.post("/{order_id}/confirm")
async def confirm_order(order_id: str, body: ConfirmIn, background: BackgroundTasks,
                        current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The buyer accepts the store's final details (by revision)."""
    return await _act(order_id, "confirm", body.model_dump(), current_user, db, background)


@orders_router.post("/{order_id}/reject-proposal")
async def reject_proposal(order_id: str, background: BackgroundTasks, body: Optional[NoteIn] = None,
                          current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The buyer turns the store's offer down; the request goes back to the
    store, and anything it reserved is released."""
    return await _act(order_id, "reject_proposal", (body or NoteIn()).model_dump(), current_user, db, background)


@orders_router.post("/{order_id}/cancel")
async def cancel_order(order_id: str, background: BackgroundTasks, body: Optional[ReasonIn] = None,
                       current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The buyer, until the store starts preparing; the store, with a reason,
    until it reports the order handed over."""
    return await _act(order_id, "cancel", (body or ReasonIn()).model_dump(), current_user, db, background)


@orders_router.post("/{order_id}/preparing")
async def start_preparing(order_id: str, background: BackgroundTasks,
                          current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await _act(order_id, "start_preparing", {}, current_user, db, background)


@orders_router.post("/{order_id}/ready")
async def mark_ready(order_id: str, background: BackgroundTasks, body: Optional[ReadyIn] = None,
                     current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await _act(order_id, "mark_ready", (body or ReadyIn()).model_dump(exclude_unset=True),
                      current_user, db, background)


@orders_router.post("/{order_id}/dispatch")
async def dispatch_order(order_id: str, background: BackgroundTasks, body: Optional[DispatchIn] = None,
                         current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await _act(order_id, "dispatch", (body or DispatchIn()).model_dump(exclude_unset=True),
                      current_user, db, background)


@orders_router.post("/{order_id}/delivered")
async def mark_delivered(order_id: str, background: BackgroundTasks,
                         current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The store reports it handed the order over. Only the buyer completes it."""
    return await _act(order_id, "mark_delivered", {}, current_user, db, background)


@orders_router.post("/{order_id}/received")
async def confirm_received(order_id: str, background: BackgroundTasks,
                           current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """The buyer confirms they have it: the order is completed."""
    return await _act(order_id, "confirm_received", {}, current_user, db, background)


@orders_router.post("/{order_id}/problem")
async def report_problem(order_id: str, body: ProblemIn, background: BackgroundTasks,
                         current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await _act(order_id, "report_problem", body.model_dump(), current_user, db, background)


@orders_router.post("/{order_id}/payment-arrangement")
async def choose_payment_arrangement(order_id: str, body: ArrangementIn, background: BackgroundTasks,
                                     current_user: dict = Depends(get_current_user),
                                     db: AsyncSession = Depends(get_db)):
    """The buyer says how they will pay: the store directly, or through an
    independent escrow provider from BROKA's directory. A choice, recorded -
    not a payment, and not proof of one."""
    await store_order_action_limiter.check_and_record(f"user:{current_user['id']}")
    order, role, push_ids = await service.choose_payment(
        db, order_id, current_user["id"], body.arrangement, body.provider_id)
    if push_ids:
        background.add_task(notify.deliver, push_ids)
    return await service.view(db, order, role)


@orders_router.post("/{order_id}/payment-reports", status_code=201)
async def report_payment(order_id: str, body: PaymentReportIn, background: BackgroundTasks,
                         current_user: dict = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    """Record what the buyer or the store says happened with the money. It is
    labelled as reported by them, never as verified, and never moves the
    order forward."""
    await store_order_action_limiter.check_and_record(f"user:{current_user['id']}")
    order, role, push_ids = await service.report_payment(
        db, order_id, current_user["id"], body.kind, body.reference, body.note)
    if push_ids:
        background.add_task(notify.deliver, push_ids)
    return await service.view(db, order, role)


# ── The store owner's side ────────────────────────────────────────────────

async def _owned_store(db: AsyncSession, store_id: str, user_id: str):
    from api.domains.stores.service import StoreService
    return await StoreService(db).get_owned(store_id, user_id)


@stores_router.get("/{store_id}/orders")
async def store_orders(
    store_id: str,
    group: str = Query("open", max_length=24),
    status: Optional[str] = Query(None, max_length=32),
    q: Optional[str] = Query(None, max_length=60),
    sort: str = Query("newest", max_length=16),
    limit: int = Query(20, ge=1, le=50),
    offset: int = Query(0, ge=0),
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """The store's orders, for its owner only. `group` is one of
    lifecycle.SELLER_GROUPS (open, needs_action, awaiting_buyer, new,
    to_fulfil, ready_or_dispatched, delivered, completed, closed, all);
    `status` narrows to one status; `q` searches reference, buyer and product."""
    store = await _owned_store(db, store_id, current_user["id"])
    return await service.list_for_store(db, store, group=group, status=status, search=q,
                                        sort=sort, limit=limit, offset=offset)


@stores_router.get("/{store_id}/orders/summary")
async def store_orders_summary(
    store_id: str,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Counts for the dashboard's badges: by group and status, what is
    waiting on whom, and the owner's unread order updates."""
    store = await _owned_store(db, store_id, current_user["id"])
    return {
        "counts": await service.group_counts(db, store.id),
        "pipeline": await analytics.pipeline(db, store.id),
        "unread": await notify.unread_count(db, current_user["id"]),
        "accepting_orders": bool(getattr(store, "accepting_orders", True)),
    }


@stores_router.patch("/{store_id}/manage/listings/{listing_id}/stock")
async def set_listing_stock(
    store_id: str,
    listing_id: str,
    body: StockIn,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """Track a product's stock (how many are on hand), stop tracking it, or
    pause new orders for it. Owner only. Listing details, photos and price
    stay with the listing editor (PATCH /listings/{id})."""
    store = await _owned_store(db, store_id, current_user["id"])
    return await service.set_stock(
        db, store, listing_id, tracked=body.stock_tracked, quantity=body.quantity,
        temporarily_unavailable=body.temporarily_unavailable,
    )


@stores_router.post("/{store_id}/enquiries", status_code=201)
async def send_enquiry(
    store_id: str,
    body: EnquiryIn,
    request: Request,
    current_user: dict = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    """A signed-in buyer's question to a store, or about one of its products,
    from the web storefront. The same conversation the app shows - stored,
    scanned and pushed to the seller by the chat engine
    (routers/negotiate.direct_message) - with limits of its own: a web form
    is the easiest thing on BROKA to script."""
    from api.database import Listing
    from api.domains.stores import billing as store_billing
    from api.domains.stores.service import StoreService
    from api.routers.negotiate import DirectMessageIn, direct_message

    uid = current_user["id"]
    await store_enquiry_limiter.check_and_record(f"user:{uid}")
    await store_enquiry_ip_limiter.check_and_record(f"ip:{client_ip(request)}")
    store = await StoreService(db).get_row(store_id)
    if not await store_billing.store_live(db, store):
        raise service.order_error(409, "STORE_NOT_OPEN", f"{store.name} isn't open right now.")
    if store.owner_id == uid:
        raise service.order_error(400, "ENQUIRY_OWN_STORE", "This is your own store.")
    content = service.clean_text(body.content, 2000)
    if not content or len(content) < 2:
        raise service.order_error(400, "ENQUIRY_EMPTY", "Write your question first.")
    listing_id = None
    if body.listing_id:
        listing = await db.get(Listing, body.listing_id)
        if listing is None or listing.store_id != store.id:
            raise service.order_error(404, "LISTING_NOT_FOUND", "That product isn't in this store.")
        listing_id = listing.id
    return await direct_message(
        DirectMessageIn(
            listing_id=listing_id,
            store_id=None if listing_id else store.id,
            sender_role="buyer",
            sender_id=uid,
            content=content,
            client_msg_id=body.client_msg_id,
        ),
        db=db,
        current_user=current_user,
    )
