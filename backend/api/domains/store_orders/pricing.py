"""Money for store orders: integer minor units (cents), never floats.

Listing.price is a Float column (KES) - every other part of BROKA reads it
that way - so an order converts it once, at the moment the order reads the
listing, through Decimal(str(price)): the float's shortest round-trip
representation, rounded half up to the cent. From then on every amount is
an int, and every total is a sum of ints. The browser's figures are never
read: an order's prices come from the listing row (submission) or from the
store (its proposal), and its totals are computed here.

Pure, like lifecycle.py, so the arithmetic is tested on its own.
"""
from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Iterable, Optional

CURRENCY = "KES"
MINOR_PER_UNIT = 100

# Bounds on what one order may say. Generous for a shop, and small enough
# that no total can overflow a BIGINT or turn into nonsense on a screen.
MAX_ITEMS = 20
MAX_QUANTITY = 1000
MAX_UNIT_PRICE_MINOR = 1_000_000_000 * MINOR_PER_UNIT      # KES 1,000,000,000
MAX_DELIVERY_FEE_MINOR = 1_000_000 * MINOR_PER_UNIT        # KES 1,000,000


class PriceError(ValueError):
    """An amount that cannot be an order's price."""


def to_minor(amount: object) -> int:
    """KES - a float from the listings table, a Decimal or a numeric
    string - as integer cents, rounded half up. Refuses booleans, NaN,
    infinities and negatives rather than guessing."""
    if isinstance(amount, bool) or amount is None:
        raise PriceError("not an amount")
    try:
        value = Decimal(str(amount))
    except (InvalidOperation, ValueError) as exc:
        raise PriceError("not an amount") from exc
    if not value.is_finite() or value < 0:
        raise PriceError("not a usable amount")
    return int((value * MINOR_PER_UNIT).quantize(Decimal("1"), rounding=ROUND_HALF_UP))


def check_unit_price(minor: object) -> int:
    """A unit price in cents, as an order may hold it: a positive int
    within MAX_UNIT_PRICE_MINOR."""
    if isinstance(minor, bool) or not isinstance(minor, int):
        raise PriceError("A price must be a whole number of cents.")
    if minor <= 0:
        raise PriceError("A price must be more than zero.")
    if minor > MAX_UNIT_PRICE_MINOR:
        raise PriceError("That price is too high for an order.")
    return minor


def check_delivery_fee(minor: object) -> int:
    if isinstance(minor, bool) or not isinstance(minor, int):
        raise PriceError("A delivery charge must be a whole number of cents.")
    if minor < 0:
        raise PriceError("A delivery charge can't be negative.")
    if minor > MAX_DELIVERY_FEE_MINOR:
        raise PriceError("That delivery charge is too high.")
    return minor


def line_total(quantity: int, unit_price_minor: int) -> int:
    return int(quantity) * int(unit_price_minor)


def subtotal(lines: Iterable[tuple[int, int]]) -> int:
    """Sum of quantity x unit price over (quantity, unit_price_minor) pairs."""
    return sum(line_total(q, p) for q, p in lines)


def total(subtotal_minor: int, delivery_fee_minor: Optional[int]) -> int:
    return int(subtotal_minor) + int(delivery_fee_minor or 0)


def format_minor(amount_minor: Optional[int], currency: str = CURRENCY) -> str:
    """"KES 12,500", or "KES 12,500.50" when there are cents. For
    notification text; clients format amounts themselves."""
    if amount_minor is None:
        return ""
    sign = "-" if amount_minor < 0 else ""
    whole, cents = divmod(abs(int(amount_minor)), MINOR_PER_UNIT)
    text = f"{whole:,}" + (f".{cents:02d}" if cents else "")
    return f"{currency} {sign}{text}"


def is_material_change(
    requested: Iterable[tuple[str, int, int]],
    offered: Iterable[tuple[str, int, int]],
    requested_fulfilment: str,
    offered_fulfilment: str,
) -> bool:
    """Whether the store's offer differs from what the buyer asked for in
    anything the buyer must explicitly accept: a quantity, a unit price, a
    product dropped, or how it is handed over. Each line is (item id,
    quantity, unit price in cents). A delivery charge is not a "change" -
    the buyer confirms every total anyway - but it is shown to them."""
    if requested_fulfilment != offered_fulfilment:
        return True
    want = {item: (q, p) for item, q, p in requested}
    got = {item: (q, p) for item, q, p in offered}
    if want.keys() != got.keys():
        return True
    return any(want[item] != got[item] for item in want)
