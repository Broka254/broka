"""The words of every store-order notification, and who receives each one.

Pure, so the wording is tested once and both the in-app feed and the push
say the same thing. Each event names its recipients, and whether it is
worth a push or only a line in the order's updates: a store starting to
prepare is good to know when the buyer looks, not worth buzzing a phone.

Payment wording follows lifecycle.py: a report is what a person said,
never what BROKA saw.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from . import lifecycle as lc
from .pricing import format_minor

# Event kinds (store_order_events.kind). The notifications below key on them.
SUBMITTED = "submitted"
SELLER_ACCEPTED = "seller_accepted"
SELLER_PROPOSED_CHANGES = "seller_proposed_changes"
SELLER_DECLINED = "seller_declined"
BUYER_CONFIRMED = "buyer_confirmed"
BUYER_REJECTED_PROPOSAL = "buyer_rejected_proposal"
BUYER_CANCELLED = "buyer_cancelled"
SELLER_CANCELLED = "seller_cancelled"
PREPARING = "preparing"
READY_FOR_PICKUP = "ready_for_pickup"
DISPATCHED = "dispatched"
DELIVERED = "delivered"
COMPLETED = "completed"
PROBLEM_REPORTED = "problem_reported"
EXPIRED = "expired"
PAYMENT_ARRANGEMENT_SELECTED = "payment_arrangement_selected"
PAYMENT_REPORTED = "payment_reported"

# What each event is called in an order's history.
EVENT_LABELS = {
    SUBMITTED: "Order request sent",
    SELLER_ACCEPTED: "Store accepted the order",
    SELLER_PROPOSED_CHANGES: "Store proposed changes",
    SELLER_DECLINED: "Store declined the order",
    BUYER_CONFIRMED: "Buyer confirmed the order",
    BUYER_REJECTED_PROPOSAL: "Buyer rejected the changes",
    BUYER_CANCELLED: "Buyer cancelled the order",
    SELLER_CANCELLED: "Store cancelled the order",
    PREPARING: "Store started preparing",
    READY_FOR_PICKUP: "Ready for collection",
    DISPATCHED: "Dispatched",
    DELIVERED: "Store reported it delivered",
    COMPLETED: "Buyer confirmed receipt",
    PROBLEM_REPORTED: "Buyer reported a problem",
    EXPIRED: "Order expired",
    PAYMENT_ARRANGEMENT_SELECTED: "Payment arrangement chosen",
    PAYMENT_REPORTED: "Payment reported",
}


@dataclass(frozen=True)
class Note:
    recipient_role: str
    title: str
    body: str
    push: bool


def _items(n: int) -> str:
    return f"{n} item{'s' if n != 1 else ''}"


def _first_name(name: Optional[str]) -> str:
    first = (name or "").strip().split(" ")[0]
    return first or "A buyer"


def notes_for(
    kind: str,
    *,
    reference: str,
    store_name: str,
    buyer_name: Optional[str],
    item_count: int,
    total_minor: Optional[int],
    detail: Optional[dict] = None,
) -> list[Note]:
    """Who hears about `kind`, and what they are told."""
    detail = detail or {}
    total = format_minor(total_minor) if total_minor is not None else ""
    buyer = _first_name(buyer_name)
    if kind == SUBMITTED:
        return [Note(lc.SELLER, "New order request",
                     f"{buyer} wants {_items(item_count)} ({total}). Check availability and reply.", True)]
    if kind == SELLER_ACCEPTED:
        return [Note(lc.BUYER, f"{store_name} accepted your order",
                     f"Order {reference}: {total}. Confirm the final details to go ahead.", True)]
    if kind == SELLER_PROPOSED_CHANGES:
        return [Note(lc.BUYER, f"{store_name} proposed changes",
                     f"Order {reference}: review the new details ({total}) and confirm or reject them.", True)]
    if kind == SELLER_DECLINED:
        reason = detail.get("reason")
        return [Note(lc.BUYER, f"{store_name} declined your order",
                     f"Order {reference}" + (f": {reason}" if reason else "."), True)]
    if kind == BUYER_CONFIRMED:
        return [Note(lc.SELLER, f"Order {reference} confirmed",
                     f"{buyer} confirmed {total}. You can start preparing it.", True)]
    if kind == BUYER_REJECTED_PROPOSAL:
        return [Note(lc.SELLER, f"Changes rejected on {reference}",
                     f"{buyer} didn't accept your changes. The request is back with you.", True)]
    if kind == BUYER_CANCELLED:
        return [Note(lc.SELLER, f"Order {reference} cancelled", f"{buyer} cancelled the order.", True)]
    if kind == SELLER_CANCELLED:
        reason = detail.get("reason")
        return [Note(lc.BUYER, f"{store_name} cancelled your order",
                     f"Order {reference}" + (f": {reason}" if reason else "."), True)]
    if kind == PREPARING:
        return [Note(lc.BUYER, f"{store_name} is preparing your order", f"Order {reference}.", False)]
    if kind == READY_FOR_PICKUP:
        return [Note(lc.BUYER, "Your order is ready for collection",
                     f"Order {reference} from {store_name}.", True)]
    if kind == DISPATCHED:
        return [Note(lc.BUYER, "Your order is on its way", f"Order {reference} from {store_name}.", True)]
    if kind == DELIVERED:
        return [Note(lc.BUYER, f"{store_name} reports your order delivered",
                     f"Order {reference}: confirm you received it, or report a problem.", True)]
    if kind == COMPLETED:
        return [Note(lc.SELLER, f"Order {reference} completed",
                     f"{buyer} confirmed they received it.", True)]
    if kind == PROBLEM_REPORTED:
        return [Note(lc.SELLER, f"Problem reported on {reference}",
                     f"{buyer} reported a problem with this order. Open it to see what they said.", True)]
    if kind == EXPIRED:
        stage = detail.get("stage")
        buyer_body = (f"{store_name} didn't reply in time to order {reference}."
                      if stage == "seller_response"
                      else f"Order {reference} wasn't confirmed in time, so the store's offer lapsed.")
        return [
            Note(lc.BUYER, "Your order request expired", buyer_body, True),
            Note(lc.SELLER, f"Order {reference} expired",
                 "No reply came in time." if stage == "seller_response"
                 else "The buyer didn't confirm in time; reserved stock is available again.", False),
        ]
    if kind == PAYMENT_ARRANGEMENT_SELECTED:
        label = lc.ARRANGEMENT_LABELS.get(detail.get("arrangement") or "", "a payment arrangement")
        provider = detail.get("provider_name")
        return [Note(lc.SELLER, f"Payment arrangement on {reference}",
                     f"{buyer} chose: {label}" + (f" ({provider})." if provider else "."), False)]
    if kind == PAYMENT_REPORTED:
        spec = lc.REPORT_KINDS.get(detail.get("report_kind") or "")
        if spec is None:
            return []
        if spec.role == lc.BUYER:
            return [Note(lc.SELLER, f"{spec.label} on {reference}",
                         "Reported by the buyer. BROKA does not see or verify payments - "
                         "check your own records before you hand anything over.", True)]
        return [Note(lc.BUYER, f"{store_name}: {spec.label.lower()}",
                     f"Order {reference}. Reported by the store; BROKA does not see or verify payments.", True)]
    return []
