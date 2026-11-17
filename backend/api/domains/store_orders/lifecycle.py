"""The store-order state machine, and the rules for payment reports.

Pure: no database and no web framework, so every rule here is tested on
its own (tests/test_store_order_lifecycle.py) and the service cannot drift
from it - it asks `check()` before every change it makes.

THE LIFECYCLE
=============
  submitted                    the buyer sent the request; the store has not answered
  seller_proposed_changes      the store changed a quantity, a price or how it is handed over
  awaiting_buyer_confirmation  the store accepted the request as asked (perhaps with a
                               delivery charge); the buyer must still confirm the total
  confirmed                    the buyer accepted the store's final details
  preparing                    the store is getting it ready
  ready_for_pickup             waiting at the store for the buyer to collect
  dispatched                   on its way to the buyer
  delivered                    the store reports it handed over
  completed                    the buyer confirmed they received it
  declined | cancelled | expired   ended without a sale

Nothing a client sends names a status. A client names an *action*; the
action, the caller's role in the order and the current status decide the
next status here. "completed" in particular is reachable only through the
buyer's `confirm_received`: a seller cannot complete an order for the
buyer, and nobody can set it directly.

PAYMENT IS NOT PART OF THIS MACHINE
===================================
Choosing how to pay and reporting a payment never changes an order's
status, and no status requires a payment report. BROKA does not see the
money, so a status gated on "paid" would be gated on someone's say-so.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import FrozenSet, Optional

# ── Statuses ────────────────────────────────────────────────────────────────

SUBMITTED = "submitted"
SELLER_PROPOSED_CHANGES = "seller_proposed_changes"
AWAITING_BUYER_CONFIRMATION = "awaiting_buyer_confirmation"
CONFIRMED = "confirmed"
PREPARING = "preparing"
READY_FOR_PICKUP = "ready_for_pickup"
DISPATCHED = "dispatched"
DELIVERED = "delivered"
COMPLETED = "completed"
DECLINED = "declined"
CANCELLED = "cancelled"
EXPIRED = "expired"

STATUSES: tuple[str, ...] = (
    SUBMITTED, SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION, CONFIRMED,
    PREPARING, READY_FOR_PICKUP, DISPATCHED, DELIVERED, COMPLETED,
    DECLINED, CANCELLED, EXPIRED,
)

TERMINAL: FrozenSet[str] = frozenset({COMPLETED, DECLINED, CANCELLED, EXPIRED})
# Ended without a sale: no payment may be reported on these, and their
# stock reservations are released.
UNSUCCESSFUL: FrozenSet[str] = frozenset({DECLINED, CANCELLED, EXPIRED})
AWAITING_BUYER: FrozenSet[str] = frozenset({SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION})
# The buyer has agreed the final details: the order is being fulfilled.
IN_FULFILMENT: FrozenSet[str] = frozenset({CONFIRMED, PREPARING, READY_FOR_PICKUP, DISPATCHED, DELIVERED})
# Statuses with a clock: the store must answer, or the buyer must confirm,
# before `expires_at`.
EXPIRABLE: FrozenSet[str] = frozenset({SUBMITTED, SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION})
OPEN: FrozenSet[str] = frozenset(STATUSES) - TERMINAL

# How the buyer gets the goods.
DELIVERY = "delivery"
COLLECTION = "collection"
FULFILMENT_METHODS: tuple[str, ...] = (DELIVERY, COLLECTION)

BUYER = "buyer"
SELLER = "seller"
SYSTEM = "system"


# ── Actions ─────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Action:
    name: str
    role: str
    from_statuses: FrozenSet[str]
    # None: the action records something without moving the order.
    to_status: Optional[str]
    # Only for orders handed over this way (None: either).
    fulfilment: Optional[str] = None
    # Shown on a button, and in the confirmation the app asks for first.
    label: str = ""


def _a(name: str, role: str, froms, to: Optional[str], fulfilment: Optional[str] = None,
       label: str = "") -> Action:
    return Action(name, role, frozenset(froms), to, fulfilment, label)


ACTIONS: dict[str, Action] = {a.name: a for a in (
    # The store answers a request. `accept` keeps every quantity and price the
    # buyer asked for; `propose` changes at least one, or how it is handed
    # over. Both reserve tracked stock and wait for the buyer.
    _a("accept", SELLER, {SUBMITTED}, AWAITING_BUYER_CONFIRMATION, label="Accept order"),
    _a("propose", SELLER, {SUBMITTED, SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION},
       SELLER_PROPOSED_CHANGES, label="Propose changes"),
    _a("decline", SELLER, {SUBMITTED, SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION},
       DECLINED, label="Decline order"),
    # The buyer answers the store.
    _a("confirm", BUYER, AWAITING_BUYER, CONFIRMED, label="Confirm order"),
    _a("reject_proposal", BUYER, AWAITING_BUYER, SUBMITTED, label="Reject changes"),
    # Cancelling. The buyer may withdraw until the store starts preparing;
    # after that only the store can call it off (it has the goods), and it
    # must say why. Neither may once the store reports it handed over.
    _a("buyer_cancel", BUYER, {SUBMITTED, SELLER_PROPOSED_CHANGES, AWAITING_BUYER_CONFIRMATION, CONFIRMED},
       CANCELLED, label="Cancel order"),
    _a("seller_cancel", SELLER, {CONFIRMED, PREPARING, READY_FOR_PICKUP, DISPATCHED},
       CANCELLED, label="Cancel order"),
    # Fulfilment: only after the buyer confirmed the final details.
    _a("start_preparing", SELLER, {CONFIRMED}, PREPARING, label="Start preparing"),
    _a("mark_ready", SELLER, {CONFIRMED, PREPARING}, READY_FOR_PICKUP, fulfilment=COLLECTION,
       label="Mark ready for pickup"),
    _a("dispatch", SELLER, {CONFIRMED, PREPARING}, DISPATCHED, fulfilment=DELIVERY, label="Dispatch"),
    _a("mark_delivered", SELLER, {READY_FOR_PICKUP, DISPATCHED}, DELIVERED, label="Report delivered"),
    # Only the buyer completes an order: "I have it".
    _a("confirm_received", BUYER, {READY_FOR_PICKUP, DISPATCHED, DELIVERED}, COMPLETED,
       label="Confirm received"),
    _a("report_problem", BUYER, {READY_FOR_PICKUP, DISPATCHED, DELIVERED, COMPLETED}, None,
       label="Report a problem"),
    # The clock, never a person.
    _a("expire", SYSTEM, EXPIRABLE, EXPIRED),
)}

# One public "cancel" button maps onto the role's own rule.
CANCEL_BY_ROLE = {BUYER: "buyer_cancel", SELLER: "seller_cancel"}


class TransitionError(Exception):
    """An action the order's rules do not allow. `code` is stable for
    clients (X-Error-Code); `message` is written for the person."""

    def __init__(self, code: str, message: str, status_code: int = 409):
        super().__init__(message)
        self.code = code
        self.message = message
        self.status_code = status_code


def check(action_name: str, *, status: str, role: str, fulfilment: str) -> Action:
    """The action, if `role` may take it on an order in `status` handed
    over by `fulfilment`. Raises TransitionError otherwise."""
    action = ACTIONS.get(action_name)
    if action is None:
        raise TransitionError("ORDER_ACTION_UNKNOWN", "That isn't something an order can do.", 400)
    if action.role != role:
        who = {BUYER: "the buyer", SELLER: "the store", SYSTEM: "BROKA"}[action.role]
        raise TransitionError(
            "ORDER_ACTION_FORBIDDEN", f"Only {who} can do that on this order.", 403)
    if status not in action.from_statuses:
        raise TransitionError(
            "ORDER_STATE_CONFLICT",
            f"That can't be done while the order is at \"{status_label(status, role)}\". "
            "Reload it to see where it is now.",
        )
    if action.fulfilment is not None and action.fulfilment != fulfilment:
        raise TransitionError(
            "ORDER_FULFILMENT_MISMATCH",
            "This order is for collection." if fulfilment == COLLECTION
            else "This order is for delivery.",
        )
    return action


def allowed_actions(status: str, role: str, fulfilment: str) -> list[str]:
    """The actions `role` may take now, in the order a screen shows them.
    Cancelling appears once, as "cancel"."""
    names = []
    for action in ACTIONS.values():
        if action.role != role or status not in action.from_statuses:
            continue
        if action.fulfilment is not None and action.fulfilment != fulfilment:
            continue
        names.append("cancel" if action.name in CANCEL_BY_ROLE.values() else action.name)
    return names


# ── What a status is called ──────────────────────────────────────────────────

_LABELS = {
    SUBMITTED: ("Waiting for the store to reply", "New order request"),
    SELLER_PROPOSED_CHANGES: ("The store proposed changes", "Waiting for the buyer to review your changes"),
    AWAITING_BUYER_CONFIRMATION: ("The store confirmed - your turn to confirm",
                                  "Waiting for the buyer to confirm"),
    CONFIRMED: ("Confirmed - the store is next", "Confirmed - ready to prepare"),
    PREPARING: ("Being prepared", "Being prepared"),
    READY_FOR_PICKUP: ("Ready for collection", "Ready for collection"),
    DISPATCHED: ("On its way", "Dispatched"),
    DELIVERED: ("Delivered - confirm you received it", "Delivered - waiting for the buyer to confirm"),
    COMPLETED: ("Completed", "Completed"),
    DECLINED: ("Declined by the store", "Declined"),
    CANCELLED: ("Cancelled", "Cancelled"),
    EXPIRED: ("Expired", "Expired"),
}


def status_label(status: str, role: str) -> str:
    buyer, seller = _LABELS.get(status, (status, status))
    return seller if role == SELLER else buyer


# The seller's order list is grouped by what the store has to do.
SELLER_GROUPS: dict[str, FrozenSet[str]] = {
    "needs_action": frozenset({SUBMITTED, CONFIRMED, PREPARING}),
    "awaiting_buyer": AWAITING_BUYER | frozenset({DELIVERED}),
    "new": frozenset({SUBMITTED}),
    "to_fulfil": frozenset({CONFIRMED, PREPARING}),
    "ready_or_dispatched": frozenset({READY_FOR_PICKUP, DISPATCHED}),
    "delivered": frozenset({DELIVERED}),
    "completed": frozenset({COMPLETED}),
    "closed": UNSUCCESSFUL,
    "open": OPEN,
    "all": frozenset(STATUSES),
}


# ── Payment arrangements and reports ────────────────────────────────────────
# A record of what people chose and what they say happened. BROKA receives,
# holds, verifies and releases nothing; the labels say who said it.

DIRECT_TO_SELLER = "direct_to_seller"
INDEPENDENT_ESCROW = "independent_escrow"
ARRANGEMENTS: tuple[str, ...] = (DIRECT_TO_SELLER, INDEPENDENT_ESCROW)

ARRANGEMENT_LABELS = {
    DIRECT_TO_SELLER: "Direct payment to the store",
    INDEPENDENT_ESCROW: "Independent escrow provider",
}

BUYER_REPORTED_PAYMENT_SENT = "buyer_reported_payment_sent"
SELLER_CONFIRMED_RECEIPT = "seller_confirmed_receipt"
BUYER_REPORTED_ESCROW_INITIATED = "buyer_reported_escrow_initiated"
SELLER_REPORTED_ESCROW_RELEASE = "seller_reported_escrow_release"


@dataclass(frozen=True)
class ReportKind:
    kind: str
    role: str
    arrangement: str
    label: str


REPORT_KINDS: dict[str, ReportKind] = {k.kind: k for k in (
    ReportKind(BUYER_REPORTED_PAYMENT_SENT, BUYER, DIRECT_TO_SELLER, "Buyer reported payment sent"),
    ReportKind(SELLER_CONFIRMED_RECEIPT, SELLER, DIRECT_TO_SELLER, "Seller confirmed receipt"),
    ReportKind(BUYER_REPORTED_ESCROW_INITIATED, BUYER, INDEPENDENT_ESCROW, "Buyer reported escrow initiated"),
    ReportKind(SELLER_REPORTED_ESCROW_RELEASE, SELLER, INDEPENDENT_ESCROW,
               "Seller reported escrow release received"),
)}

AWAITING_EXTERNAL_CONFIRMATION = "Awaiting external confirmation"

# Shown wherever an order's payment record is: what the record is, and is not.
PAYMENT_NOTICE = (
    "BROKA does not receive, hold, verify or release payments for store orders. "
    "These are reports made by the buyer or the store, not confirmations from BROKA "
    "or from any payment provider."
)
ESCROW_PROVIDER_NOTICE = (
    "This escrow provider is independent of BROKA. Check its own fees, terms, "
    "protections and process on its official website before you pay."
)

# A payment can be arranged until the order ends without a sale, and
# reported once the final amount is agreed - before or after delivery,
# since paying on collection is common.
ARRANGEMENT_SELECTABLE: FrozenSet[str] = frozenset(STATUSES) - UNSUCCESSFUL
PAYMENT_REPORTABLE: FrozenSet[str] = IN_FULFILMENT | frozenset({COMPLETED})


def check_report(kind: str, *, role: str, status: str, arrangement: Optional[str]) -> ReportKind:
    """The report kind, if `role` may make it now. A store confirming it
    was paid directly may do so before any arrangement was chosen (cash on
    collection is often never chosen in advance); every other report needs
    the matching arrangement."""
    spec = REPORT_KINDS.get(kind)
    if spec is None:
        raise TransitionError("PAYMENT_REPORT_UNKNOWN", "That isn't a payment report BROKA records.", 400)
    if spec.role != role:
        raise TransitionError(
            "PAYMENT_REPORT_FORBIDDEN",
            "Only the buyer can report that." if spec.role == BUYER else "Only the store can report that.",
            403,
        )
    if status not in PAYMENT_REPORTABLE:
        raise TransitionError(
            "PAYMENT_REPORT_TOO_EARLY" if status not in UNSUCCESSFUL else "PAYMENT_REPORT_CLOSED",
            "A payment can be reported once the buyer has confirmed the final order."
            if status not in UNSUCCESSFUL else "This order has ended; there is no payment to report.",
        )
    allowed_without = kind == SELLER_CONFIRMED_RECEIPT and arrangement is None
    if arrangement != spec.arrangement and not allowed_without:
        raise TransitionError(
            "PAYMENT_ARRANGEMENT_MISMATCH",
            "That report doesn't match how this order is being paid. "
            f"It is set to: {ARRANGEMENT_LABELS.get(arrangement or '', 'not chosen yet')}.",
        )
    return spec


def payment_summary(arrangement: Optional[str], reported: set[str],
                    provider_name: Optional[str] = None) -> dict:
    """One line for the order's payment state, and whether it is waiting on
    something BROKA cannot see. Never "verified": nothing here is."""
    if arrangement == INDEPENDENT_ESCROW:
        via = f" via {provider_name}" if provider_name else ""
        if SELLER_REPORTED_ESCROW_RELEASE in reported:
            label = REPORT_KINDS[SELLER_REPORTED_ESCROW_RELEASE].label
            waiting = False
        elif BUYER_REPORTED_ESCROW_INITIATED in reported:
            label = f"{REPORT_KINDS[BUYER_REPORTED_ESCROW_INITIATED].label}{via}"
            waiting = True
        else:
            label = f"Independent escrow{via} - nothing reported yet"
            waiting = False
    elif arrangement == DIRECT_TO_SELLER or SELLER_CONFIRMED_RECEIPT in reported:
        if SELLER_CONFIRMED_RECEIPT in reported:
            label = REPORT_KINDS[SELLER_CONFIRMED_RECEIPT].label
            waiting = False
        elif BUYER_REPORTED_PAYMENT_SENT in reported:
            label = REPORT_KINDS[BUYER_REPORTED_PAYMENT_SENT].label
            waiting = True
        else:
            label = "Direct payment to the store - nothing reported yet"
            waiting = False
    else:
        label = "No payment arrangement chosen yet"
        waiting = False
    return {
        "label": label,
        "awaiting_external_confirmation": waiting,
        "status_note": AWAITING_EXTERNAL_CONFIRMATION if waiting else None,
        "verified": False,
    }
