"""How far one price change may move a listing, and what a raise does to its fee.

PATCH /listings/{id} already limits how OFTEN a price moves (two changes a
week, 12 hours apart, none while a deal stands). These are the limits on
how FAR, and the fee side of a change.

How far. A raise of more than MAX_RAISE_SHARE in one step is refused: a
listing found at KES 20,000 that reads KES 35,000 the next day is a bait
and switch to the buyers who saved it. Cuts are not limited - a lower
price only helps buyers, and the fee paid is not refunded. The limit does
not apply while the listing is new (CORRECTION_WINDOW) or not yet in front
of buyers: then a raise is fixing a typo ("1500" for "15000"), not moving
the goalposts.

The fee. The listing fee is priced on the listing's price (PRICING.md,
f = C x R), and the rate is locked for the months paid. Without this, a
seller lists a car at KES 10,000, pays the fee for KES 10,000, and raises
it to KES 800,000 the next week - the fee would never see the real price.
So a raise on a listing with paid time left shortens that time in
proportion: the days left are worth what they were paid for, at the new
monthly fee. No money moves; the seller renews sooner. A cut leaves the
paid time alone.
"""
from __future__ import annotations

from datetime import datetime, timedelta
from typing import Optional

# The most one change may raise a listing's price: 25%.
MAX_RAISE_SHARE = 0.25

# For this long after posting, any raise is a correction.
CORRECTION_WINDOW = timedelta(hours=24)


def raise_limit(old_price: float) -> float:
    """The highest price one change may set, from `old_price`."""
    return old_price * (1.0 + MAX_RAISE_SHARE)


def raise_is_limited(created_at: Optional[datetime], live: bool, now: datetime) -> bool:
    """Whether MAX_RAISE_SHARE applies: buyers have seen this price."""
    if not live:
        return False
    return created_at is None or now - created_at >= CORRECTION_WINDOW


def shortened_paid_until(
    paid_until: Optional[datetime], now: datetime, fee_before: float, fee_after: float,
) -> Optional[datetime]:
    """When the paid time ends after a price change moves the monthly fee
    from `fee_before` to `fee_after`.

    Unchanged when nothing is paid ahead or the fee did not go up. Otherwise
    the time left is scaled by fee_before / fee_after: three weeks paid at
    KES 100 a month are two weeks at KES 150.
    """
    if paid_until is None or paid_until <= now or fee_after <= fee_before or fee_before <= 0:
        return paid_until
    left = paid_until - now
    return now + left * (fee_before / fee_after)
