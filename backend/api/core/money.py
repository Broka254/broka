"""Monetary arithmetic that does not drift.

WHY THIS EXISTS RATHER THAN A SCHEMA MIGRATION
==============================================
Almost every monetary column in this codebase is a Float: Listing.price,
Listing.reserve_price, Bid.amount, AuctionMeta.starting_price /
min_bid_increment / current_bid / winning_amount, Deal.agreed_price /
commission, MpesaTransaction.amount, FeaturedPayment.amount,
VerificationPayment.amount. The one exception is the place it matters
most - LedgerEntry.amount_kes is already Numeric(18,2). Converting the
rest to Numeric is the textbook answer and it is NOT what this module
does, for a reason worth stating plainly:

  * Python raises TypeError on Decimal + float. A partial migration
    therefore does not degrade gracefully - it produces a runtime error the
    first time a migrated column meets an un-migrated one, somewhere in
    escrow, M-Pesa reconciliation, disputes or commission. The dangerous
    version of this change is the incremental one.
  * The full version touches every payment path at once, which is exactly
    the code the brief says not to break.

So the columns stay Float and this module removes the reason they hurt.
Float is exact for integers up to 2^53, and Kenyan marketplace prices are
whole shillings, so the storage itself is not where error creeps in -
arithmetic is: 0.1 + 0.2, a 3% commission on an odd number, a sum of three
rounded values. Quantizing through Decimal at every point where a monetary
value is PRODUCED means what gets stored and shown is always a clean
2-decimal number, and the float that holds it is the nearest double to
that - which is the same guarantee a Numeric column would give for values
of this size.

WHAT IS STILL WORTH DOING LATER
===============================
A real Numeric migration, done in one pass across every column listed
above with the arithmetic converted at the same time - the ledger already
shows the shape it should take. Documented in AUCTIONS.md ("Money") rather
than half-done here.

USAGE
    from api.core.money import money, add_money, pct_of

    bid     = money(raw_amount)                 # clean 2dp float
    total   = add_money(price, commission, fee) # no accumulated drift
    commiss = pct_of(price, settings.commission_rate)
    entry   = money_decimal(amount)             # for a Numeric column
"""
from __future__ import annotations

from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from typing import Union

Number = Union[int, float, str, Decimal]

# Two decimal places: KES has cents, and every existing round() call in the
# payment path already settles on 2.
_CENTS = Decimal("0.01")


def to_decimal(value: Number) -> Decimal:
    """Exact Decimal for a monetary value.

    Routed through str() for floats on purpose: Decimal(0.1) is
    0.1000000000000000055511151231257827021181583404541015625, while
    Decimal("0.1") is 0.1. Converting via the repr is what stops the
    float's own representation error from being carried into the Decimal
    arithmetic meant to avoid it.
    """
    if isinstance(value, Decimal):
        return value
    if isinstance(value, float):
        return Decimal(repr(value))
    return Decimal(str(value))


def money(value: Number) -> float:
    """Quantize to 2dp, half-up, and hand back a float for a Float column.

    Half-up rather than Python's default banker's rounding: money rounding
    conventions - and everyone's expectation of them - round .005 up, and
    the existing round() calls in the escrow path do too on the values that
    matter. Consistency with what is already stored beats statistical
    neutrality here.
    """
    try:
        return float(to_decimal(value).quantize(_CENTS, rounding=ROUND_HALF_UP))
    except (InvalidOperation, ValueError, TypeError):
        # NaN/inf/garbage. Callers validate before this point; returning
        # the input unchanged keeps this helper from being the thing that
        # raises on data it was only meant to tidy.
        return float(value)


def add_money(*values: Number) -> float:
    """Sum monetary values without accumulating float error.

    `agreed_price + commission + provider_fee` computed in float and then
    rounded once is usually right; summed in Decimal it is always right,
    and it costs nothing.
    """
    total = Decimal("0")
    for v in values:
        if v is None:
            continue
        total += to_decimal(v)
    return float(total.quantize(_CENTS, rounding=ROUND_HALF_UP))


def pct_of(value: Number, rate: Number) -> float:
    """A percentage of a monetary value, quantized - e.g. commission."""
    return float(
        (to_decimal(value) * to_decimal(rate)).quantize(_CENTS, rounding=ROUND_HALF_UP)
    )


def money_decimal(value: Number) -> Decimal:
    """Same quantization as `money()`, but stays a Decimal.

    For the one place that genuinely has a Numeric column - the escrow
    ledger's `amount_kes` (Numeric(18,2), see api/models/escrow_ledger.py).
    Postgres would round an over-precise value into the column's scale
    anyway, but SQLAlchemy's Numeric falls back to float on SQLite, so
    quantizing here rather than trusting the column is what makes the
    ledger store the same number on the dialect CI runs and the one
    production runs.
    """
    try:
        return to_decimal(value).quantize(_CENTS, rounding=ROUND_HALF_UP)
    except (InvalidOperation, ValueError, TypeError):
        return to_decimal(value)
