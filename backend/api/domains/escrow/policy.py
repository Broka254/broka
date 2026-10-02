"""The buyer-protection rules: when money moves without anyone tapping a button.

One place for the numbers that the escrow service, the five-minute sweep
(api/core/workers.py) and the deal API all have to agree on. Rendered to
the app as deadlines (auto_release_at, refund_respond_by), so a buyer or
seller sees the same clock the sweep acts on.

ESCROW_AUDIT.md ("Release, reminders and refund requests") explains the
design.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

# ── Release after the seller says the item was delivered ──────────────────
# The buyer has this long to confirm or report a problem once the seller
# marks the deal delivered. The clock starts at the seller's claim, never at
# payment: started at payment, a seller who never delivered would be paid
# when it ran out.
DELIVERY_GRACE_HOURS = 72
# Zeno reminds the buyer (chat message + push) at each of these hours after
# the claim: every 12 hours until the release.
DELIVERY_REMINDER_HOURS = (12, 24, 36, 48, 60)
# ...and texts them at these: the start of day 2 and of day 3.
DELIVERY_SMS_HOURS = (24, 48)

# ── Refund request before delivery ────────────────────────────────────────
# The seller has this long to accept or contest a refund request. Silence
# refunds the buyer: nothing has left the seller's hands yet (a seller who
# had claimed delivery is sent to a dispute instead), so waiting costs the
# seller nothing and a seller who has disappeared cannot hold the money.
REFUND_RESPONSE_HOURS = 48
# Hours after the request at which the seller is texted: at once, then a
# day before the deadline.
REFUND_SMS_HOURS = (0, 24)
# Zeno's in-app reminder to the seller (the request itself is announced at 0).
REFUND_REMINDER_HOURS = (24,)

# ── Partial payments ──────────────────────────────────────────────────────
# Smallest part payment, in KES. Each payment is its own escrow transaction
# with its own provider fee; a few shillings at a time would spend more on
# fees than they move. The payment that clears the balance can be smaller.
MIN_PART_PAYMENT_KES = 100.0

# Categories where "delivered" means a transfer of ownership (title deed,
# logbook), so the buyer is asked about the documents before releasing.
# Top-level category names (api/domains/categories/seed.py), lower-cased.
OWNERSHIP_TRANSFER_CATEGORIES = frozenset({"property", "land", "automobiles", "vehicles"})


def requires_ownership_transfer(category: Optional[str]) -> bool:
    return bool(category) and category.strip().lower() in OWNERSHIP_TRANSFER_CATEGORIES


def hours_since(start: datetime, now: datetime) -> float:
    return (now - start).total_seconds() / 3600


def auto_release_at(deal) -> Optional[datetime]:
    """When the running delivery claim releases the money, or None."""
    if (deal.timer_type == "seller_claimed_delivery"
            and deal.seller_claimed_delivery_at is not None
            and deal.timer_cancelled_at is None
            and deal.timer_fired_at is None):
        return deal.seller_claimed_delivery_at + timedelta(hours=DELIVERY_GRACE_HOURS)
    return None


def refund_request_open(deal) -> bool:
    return deal.refund_requested_at is not None and deal.refund_resolved_at is None


def refund_respond_by(deal) -> Optional[datetime]:
    """The seller's deadline on an open refund request, or None."""
    if not refund_request_open(deal):
        return None
    return deal.refund_requested_at + timedelta(hours=REFUND_RESPONSE_HOURS)


def due_count(marks, elapsed_hours: float) -> int:
    """How many of the scheduled hours `marks` have passed."""
    return sum(1 for h in marks if h <= elapsed_hours)
