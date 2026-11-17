"""Store orders - see api/domains/store_orders/ and STORE_ORDERS.md.

Six tables, created by init_db()'s create_all (registered there):

  store_orders                   one buyer's request to one store, and its state
  store_order_items              the products in it, each with a snapshot of the
                                 listing as it was and what was asked, offered
                                 and finally agreed
  store_order_events             every change, who made it and from what to what
  store_order_payments           how the buyer chose to pay (one row per order)
  store_order_payment_reports    what the buyer or the store SAYS happened with
                                 the money - never a verification
  store_order_notifications      the in-app updates feed, and the push outbox

MONEY is integer minor units (cents) in BIGINT columns, suffixed `_minor`.
Nothing here holds, moves or verifies money (store_orders/__init__.py).

SNAPSHOTS. An item keeps the product's name, price unit and image as they
were when the order was made, so editing or archiving a listing later never
rewrites an order a buyer and a seller agreed.

STATUSES are plain strings, checked by store_orders/lifecycle.py - not a
database ENUM, so adding one never needs ALTER TYPE.

Columns that may hold something other than a row id (an event's actor can
be "system"; a provider id is a directory slug that may have no database
row) are deliberately not foreign keys.
"""
from __future__ import annotations

import uuid
from datetime import datetime

import sqlalchemy as sa

from api.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


class StoreOrder(Base):
    __tablename__ = "store_orders"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    # What people quote to each other ("BK-7K3F9QX2"). Random, not a counter:
    # a sequence would tell anyone how many orders a store gets. Access never
    # depends on it - every read checks the caller is the buyer or the owner.
    reference = sa.Column(sa.String(16), nullable=False, unique=True)
    store_id = sa.Column(sa.String, sa.ForeignKey("stores.id"), nullable=False, index=True)
    # The store's owner when the order was made: the listings' seller.
    seller_id = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    buyer_id = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False, index=True)
    status = sa.Column(sa.String(32), nullable=False, default="submitted", index=True)
    currency = sa.Column(sa.String(3), nullable=False, default="KES")

    # What the buyer asked for, at the listings' prices when they asked.
    requested_subtotal_minor = sa.Column(sa.BigInteger, nullable=False, default=0)
    # The store's current offer (accept or proposal): its subtotal, any
    # delivery charge and the total the buyer is asked to confirm. NULL until
    # the store answers; cleared when the buyer rejects a proposal.
    seller_subtotal_minor = sa.Column(sa.BigInteger, nullable=True)
    delivery_fee_minor = sa.Column(sa.BigInteger, nullable=True)
    total_minor = sa.Column(sa.BigInteger, nullable=True)

    # "delivery" | "collection": what the buyer asked for, and what the
    # store's offer (and, once confirmed, the order) says.
    requested_fulfilment = sa.Column(sa.String(16), nullable=False)
    fulfilment = sa.Column(sa.String(16), nullable=False)
    # Only the buyer and this store's owner ever see these.
    delivery_address = sa.Column(sa.String(300), nullable=True)
    contact_phone = sa.Column(sa.String(20), nullable=True)
    buyer_note = sa.Column(sa.String(500), nullable=True)
    seller_note = sa.Column(sa.String(500), nullable=True)
    # The store's handover details: where and when to collect, or the
    # delivery estimate; and what it said when it dispatched.
    fulfilment_note = sa.Column(sa.String(300), nullable=True)
    dispatch_note = sa.Column(sa.String(300), nullable=True)
    decline_reason = sa.Column(sa.String(300), nullable=True)
    cancel_reason = sa.Column(sa.String(300), nullable=True)
    cancelled_by = sa.Column(sa.String(16), nullable=True)
    problem_note = sa.Column(sa.String(500), nullable=True)
    problem_reported_at = sa.Column(sa.DateTime, nullable=True)

    # Each store offer is a revision. The buyer confirms a revision by
    # number, so a confirmation can never land on an offer they did not see.
    revision = sa.Column(sa.Integer, nullable=False, default=0)
    # Optimistic lock (__mapper_args__): two changes to one order cannot
    # both win, even on SQLite, which has no FOR UPDATE.
    version = sa.Column(sa.Integer, nullable=False, default=1)

    # The buyer's X-Idempotency-Key for the submission, and a fingerprint of
    # what it asked for: a retried request returns the order it made, and a
    # reused key with a different request is refused, never merged.
    idempotency_key = sa.Column(sa.String(64), nullable=False)
    request_fingerprint = sa.Column(sa.String(64), nullable=False)

    # Where the order came from: "web" | "app", the ?via= channel (whatsapp,
    # tiktok...) and the Marketing Studio campaign whose link brought it.
    source_surface = sa.Column(sa.String(8), nullable=False, default="web")
    source_channel = sa.Column(sa.String(16), nullable=True)
    campaign_id = sa.Column(sa.String, sa.ForeignKey("marketing_campaigns.id"), nullable=True, index=True)

    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow, index=True)
    updated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    # The deadline of an expirable status (lifecycle.EXPIRABLE): the store's
    # reply, or the buyer's confirmation while stock is reserved. NULL once
    # neither applies.
    expires_at = sa.Column(sa.DateTime, nullable=True, index=True)
    seller_responded_at = sa.Column(sa.DateTime, nullable=True)
    buyer_confirmed_at = sa.Column(sa.DateTime, nullable=True)
    handed_over_at = sa.Column(sa.DateTime, nullable=True)
    completed_at = sa.Column(sa.DateTime, nullable=True)
    closed_at = sa.Column(sa.DateTime, nullable=True)

    __table_args__ = (
        sa.UniqueConstraint("buyer_id", "idempotency_key", name="uq_store_orders_buyer_idempotency"),
        sa.Index("ix_store_orders_store_status", "store_id", "status"),
        sa.Index("ix_store_orders_store_created", "store_id", "created_at"),
        sa.Index("ix_store_orders_buyer_created", "buyer_id", "created_at"),
        sa.Index("ix_store_orders_status_expires", "status", "expires_at"),
    )
    __mapper_args__ = {"version_id_col": version}


class StoreOrderItem(Base):
    __tablename__ = "store_order_items"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    order_id = sa.Column(sa.String, sa.ForeignKey("store_orders.id"), nullable=False, index=True)
    listing_id = sa.Column(sa.String, sa.ForeignKey("listings.id"), nullable=False, index=True)
    position = sa.Column(sa.Integer, nullable=False, default=0)

    # The listing as it was when the order was made.
    name = sa.Column(sa.String(200), nullable=False)
    price_unit = sa.Column(sa.String(24), nullable=True)
    image_asset_id = sa.Column(sa.String, nullable=True)

    requested_quantity = sa.Column(sa.Integer, nullable=False)
    requested_unit_price_minor = sa.Column(sa.BigInteger, nullable=False)
    # The store's current offer for this line (0 = the store can't supply it).
    proposed_quantity = sa.Column(sa.Integer, nullable=True)
    proposed_unit_price_minor = sa.Column(sa.BigInteger, nullable=True)
    # Agreed: copied from the offer the buyer confirmed.
    final_quantity = sa.Column(sa.Integer, nullable=True)
    final_unit_price_minor = sa.Column(sa.BigInteger, nullable=True)

    # Tracked stock this line holds on the listing (Listing.stock_reserved),
    # and what it finally took off the shelf. stock_state:
    #   none      nothing reserved (untracked product, or not accepted yet)
    #   reserved  holding reserved_quantity units
    #   released  gave them back (rejected, cancelled, declined, expired)
    #   deducted  handed over: deducted_quantity came off Listing.quantity
    reserved_quantity = sa.Column(sa.Integer, nullable=False, default=0)
    deducted_quantity = sa.Column(sa.Integer, nullable=False, default=0)
    stock_state = sa.Column(sa.String(12), nullable=False, default="none")

    __table_args__ = (
        sa.UniqueConstraint("order_id", "listing_id", name="uq_store_order_items_order_listing"),
    )


class StoreOrderEvent(Base):
    __tablename__ = "store_order_events"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    order_id = sa.Column(sa.String, sa.ForeignKey("store_orders.id"), nullable=False, index=True)
    kind = sa.Column(sa.String(40), nullable=False)
    # A user id, or "system" for the clock - so not a foreign key.
    actor_id = sa.Column(sa.String, nullable=True)
    actor_role = sa.Column(sa.String(16), nullable=False)
    from_status = sa.Column(sa.String(32), nullable=True)
    to_status = sa.Column(sa.String(32), nullable=True)
    revision = sa.Column(sa.Integer, nullable=True)
    # JSON, non-sensitive: what changed (quantities, prices, reasons). Never
    # an address, a phone number or anything a payment report was given.
    detail = sa.Column(sa.Text, nullable=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow, index=True)

    __table_args__ = (
        sa.Index("ix_store_order_events_order_created", "order_id", "created_at"),
        sa.Index("ix_store_order_events_kind_created", "kind", "created_at"),
    )


class StoreOrderPayment(Base):
    """How the buyer chose to pay. A choice, not a payment."""
    __tablename__ = "store_order_payments"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    order_id = sa.Column(sa.String, sa.ForeignKey("store_orders.id"), nullable=False, unique=True)
    # "direct_to_seller" | "independent_escrow"
    arrangement = sa.Column(sa.String(24), nullable=False)
    # The directory's provider at the time it was chosen. A slug (seed
    # providers have no database row), so not a foreign key; the name and
    # official address are kept so the order still says who it was after
    # the directory changes.
    provider_id = sa.Column(sa.String(40), nullable=True)
    provider_name = sa.Column(sa.String(80), nullable=True)
    provider_url = sa.Column(sa.String(300), nullable=True)
    provider_domain = sa.Column(sa.String(120), nullable=True)
    selected_by = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False)
    selected_by_role = sa.Column(sa.String(16), nullable=False)
    selected_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)


class StoreOrderPaymentReport(Base):
    """Something the buyer or the store says happened with the money.

    Recorded as said. A reference typed here is whatever the person chose
    to type - a receipt number, a provider's transaction id - and proves
    nothing; it is kept so the two sides can match it against their own
    records. Never a PIN, a password or card details: the API accepts only
    a short reference and a note, and says not to put secrets in either."""
    __tablename__ = "store_order_payment_reports"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    order_id = sa.Column(sa.String, sa.ForeignKey("store_orders.id"), nullable=False, index=True)
    kind = sa.Column(sa.String(40), nullable=False)
    actor_id = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False)
    actor_role = sa.Column(sa.String(16), nullable=False)
    arrangement = sa.Column(sa.String(24), nullable=True)
    provider_id = sa.Column(sa.String(40), nullable=True)
    reference = sa.Column(sa.String(64), nullable=True)
    note = sa.Column(sa.String(300), nullable=True)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)

    __table_args__ = (
        # Each kind of report once per order: a second "I paid" is not a
        # second payment, and a store cannot be told twice.
        sa.UniqueConstraint("order_id", "kind", name="uq_store_order_payment_reports_order_kind"),
    )


class StoreOrderNotification(Base):
    """One update for one person about one order event: the in-app feed,
    and the outbox its push is sent from after the event commits.

    One row per (event, recipient), enforced: a retried request, a second
    replica's sweep or a re-run of the sender cannot make a second row, and
    the push is claimed (push_claimed_at) before it is sent, so it goes out
    at most once per claim window."""
    __tablename__ = "store_order_notifications"

    id = sa.Column(sa.String, primary_key=True, default=_uuid)
    order_id = sa.Column(sa.String, sa.ForeignKey("store_orders.id"), nullable=False, index=True)
    event_id = sa.Column(sa.String, sa.ForeignKey("store_order_events.id"), nullable=False)
    recipient_id = sa.Column(sa.String, sa.ForeignKey("users.id"), nullable=False)
    recipient_role = sa.Column(sa.String(16), nullable=False)
    kind = sa.Column(sa.String(40), nullable=False)
    title = sa.Column(sa.String(160), nullable=False)
    body = sa.Column(sa.String(400), nullable=False)
    created_at = sa.Column(sa.DateTime, nullable=False, default=datetime.utcnow)
    read_at = sa.Column(sa.DateTime, nullable=True)
    # pending | sent | no_device | failed | skipped (in-app only)
    push_state = sa.Column(sa.String(12), nullable=False, default="pending")
    push_attempts = sa.Column(sa.Integer, nullable=False, default=0)
    push_claimed_at = sa.Column(sa.DateTime, nullable=True)
    pushed_at = sa.Column(sa.DateTime, nullable=True)

    __table_args__ = (
        sa.UniqueConstraint("event_id", "recipient_id", name="uq_store_order_notifications_event_recipient"),
        sa.Index("ix_store_order_notifications_recipient_created", "recipient_id", "created_at"),
        sa.Index("ix_store_order_notifications_push_state", "push_state", "created_at"),
    )
