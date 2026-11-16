"""What a provider's published pricing makes the buyer pay - and when BROKA
refuses to say.

The rule, from the brief and from ordinary decency: a figure is shown only
when the provider's own published formula is in the record AND this module
has a tested way to evaluate it. Otherwise the answer is "unavailable" with
the reason, never a guess. In particular:

  * quote_required / not_disclosed / under_review  -> no number at all;
  * a charge the provider says exists but whose numbers are not loaded (an
    "estimated M-Pesa payout reserve" with no bands) -> "partial": the
    charges we do have are shown separately, the total is withheld, because
    a total with a missing part is a wrong total;
  * an amount outside the provider's limits, or between two published bands
    -> "out_of_range", never the nearest band.

MONEY IS DECIMAL, NEVER FLOAT. 5,000 x 5.4% is exactly 270 in Decimal and
270.00000000000006 in a float, which rounds up to the wrong shilling.

ROUNDING. Every charge is rounded UP to a whole shilling, each on its own,
and the total is the sum of the rounded lines, so what is shown always adds
up. Up, because an M-Pesa prompt is in whole shillings and no provider here
publishes how it rounds: a buyer who budgets for an estimate that is a
fraction high is not hurt; one who budgets for a fraction low is. The checkout
quotation is authoritative and the estimate says so.

ASSUMPTION. The calculator answers "the seller should receive X, what does
the buyer pay?", so every charge is treated as added on top of X and paid by
the buyer. Some providers let the seller pay; that is stated on the result,
and the same assumption applies to every provider so the numbers compare.
"""
from __future__ import annotations

from decimal import ROUND_CEILING, ROUND_HALF_UP, Decimal, InvalidOperation
from typing import Optional

CURRENCY = "KES"

# The calculator's own bounds. A typo of a few extra zeros is refused rather
# than priced; no provider here handles more than a fraction of this.
MAX_AMOUNT_KES = 10_000_000

# Result statuses.
ESTIMATED = "estimated"            # every charge calculated: a total is shown
PARTIAL = "partial"                # some charges calculated, some not: no total
UNAVAILABLE = "unavailable"        # nothing published to calculate from
OUT_OF_RANGE = "out_of_range"      # the amount is outside what the provider takes
INVALID_AMOUNT = "invalid_amount"

# What the calculator can be asked about where the seller is paid.
PAYOUT_DESTINATIONS = ("phone", "till", "paybill", "bank")

DISCLOSURES = (
    "published_fixed",
    "published_percentage",
    "published_tiered",
    "quote_required",
    "not_disclosed",
    "under_review",
)
CALCULABLE_DISCLOSURES = ("published_fixed", "published_percentage", "published_tiered")

PAYERS = ("buyer", "seller", "either", "not_stated")

_MAX_PLACES = 4


# ── Numbers ──────────────────────────────────────────────────────────────

def parse_decimal(value: object, *, low: Decimal = Decimal(0), high: Optional[Decimal] = None,
                  max_places: int = _MAX_PLACES) -> Optional[Decimal]:
    """[value] as a finite Decimal within bounds, else None.

    Accepts an int, a numeric string, or a float (read through its shortest
    repr, so 5.4 is 5.4 and not 5.4000000000000003553). Never a bool, NaN,
    Infinity, or a number with more than [max_places] decimal places - those
    are how a typo or an attack gets into arithmetic."""
    if isinstance(value, bool) or value is None:
        return None
    try:
        if isinstance(value, float):
            number = Decimal(repr(value))
        elif isinstance(value, (int, str)):
            number = Decimal(str(value).strip())
        else:
            return None
    except (InvalidOperation, ValueError):
        return None
    if not number.is_finite() or number < low:
        return None
    # An upper bound is always applied. "1e5000" is a finite Decimal; with
    # no bound it would reach the arithmetic below and take seconds to
    # multiply out, which is a way to hold a request open.
    if number > (high if high is not None else Decimal(MAX_AMOUNT_KES)):
        return None
    exponent = number.as_tuple().exponent
    if isinstance(exponent, int) and -exponent > max_places:
        return None
    return number


def parse_whole_kes(value: object) -> Optional[int]:
    """A whole number of shillings >= 0. 5000, "5000" and 5000.0 are all
    5,000; 5000.5 is not a whole number of shillings and is refused."""
    number = parse_decimal(value, low=Decimal(0), high=Decimal(MAX_AMOUNT_KES))
    if number is None or number != number.to_integral_value():
        return None
    return int(number)


def plain(number: Decimal) -> str:
    """[number] as plain digits: 10, 5.4, 0.3 - never "1E+1"."""
    text = format(number.normalize(), "f")
    return text if text != "-0" else "0"


def ceil_kes(amount: Decimal) -> int:
    """Up to the next whole shilling (a whole number stays as it is)."""
    return int(amount.to_integral_value(rounding=ROUND_CEILING))


def percent_of(amount: int, percent: Decimal) -> Decimal:
    """[percent]% of [amount], exactly."""
    return Decimal(amount) * percent / Decimal(100)


def effective_percent(total_fees: int, seller_receives: int) -> float:
    """What the fees are as a share of what the seller receives, to 2 places."""
    share = (Decimal(total_fees) * 100 / Decimal(seller_receives)).quantize(
        Decimal("0.01"), rounding=ROUND_HALF_UP)
    return float(share)


# ── Bands ────────────────────────────────────────────────────────────────

def validate_tiers(tiers: object, label: str) -> list[str]:
    """Why [tiers] is not a usable band table, or [] when it is.

    Bands are inclusive whole-shilling ranges. They must be in order and
    touch exactly (next min = previous max + 1): a gap would let an amount
    fall through to no fee, an overlap would make two answers possible."""
    if not isinstance(tiers, list) or not tiers:
        return [f"{label}: tiers must be a non-empty list"]
    problems: list[str] = []
    previous_max: Optional[int] = None
    for i, tier in enumerate(tiers, 1):
        where = f"{label} tier {i}"
        if not isinstance(tier, dict):
            problems.append(f"{where}: must be an object")
            continue
        low, high = tier.get("min"), tier.get("max")
        if not (isinstance(low, int) and not isinstance(low, bool) and low >= 0):
            problems.append(f"{where}: min must be a whole number of shillings")
            continue
        if not (isinstance(high, int) and not isinstance(high, bool) and high >= low):
            problems.append(f"{where}: max must be a whole number not below min")
            continue
        percent, fixed = tier.get("percent"), tier.get("fixed")
        if percent is None and fixed is None:
            problems.append(f"{where}: needs a percent, a fixed charge, or both")
        if percent is not None and parse_decimal(percent, high=Decimal(100)) is None:
            problems.append(f"{where}: percent must be a number from 0 to 100")
        if fixed is not None and parse_decimal(fixed, high=Decimal(MAX_AMOUNT_KES)) is None:
            problems.append(f"{where}: fixed must be a non-negative number of shillings")
        if previous_max is not None and low != previous_max + 1:
            problems.append(f"{where}: starts at {low} but the previous band ended at "
                            f"{previous_max} (bands must touch with no gap or overlap)")
        previous_max = high
    return problems


def find_tier(tiers: list[dict], amount: int) -> Optional[dict]:
    for tier in tiers:
        if tier["min"] <= amount <= tier["max"]:
            return tier
    return None


# ── One charge ───────────────────────────────────────────────────────────

def _body_of(rule: dict, payout_destination: Optional[str]) -> tuple[Optional[dict], Optional[str]]:
    """The percent/fixed/tiers body that applies to this payout, or
    (None, why not). A rule with per-destination bands needs the destination."""
    by_destination = rule.get("by_destination")
    if not by_destination:
        return rule, None
    if payout_destination is None:
        return None, "needs_destination"
    body = by_destination.get(payout_destination)
    if not isinstance(body, dict) or not body:
        return None, "destination_not_loaded"
    return body, None


def evaluate_rule(rule: dict, amount: int, payout_destination: Optional[str] = None) -> dict:
    """One charge, as {label, kind, status, percent_part, fixed_part, ...}.

    status: "calculated" (percent_part and fixed_part are whole shillings),
    "not_available" (the provider has this charge but its numbers are not
    loaded, or we need the payout destination), or "out_of_range"."""
    line = {
        "label": rule.get("label") or "Charge",
        "kind": rule.get("kind", "commission"),
        "payer": rule.get("payer", "not_stated"),
        "estimated": bool(rule.get("estimated", False)),
        "status": "not_available",
        "percent_part": None,
        "fixed_part": None,
        "note": "",
    }
    if rule.get("documented") is False:
        line["note"] = "The provider charges this, but its published figures are not loaded yet."
        return line
    body, problem = _body_of(rule, payout_destination)
    if body is None:
        line["note"] = ("Choose where the seller will be paid to include this charge."
                        if problem == "needs_destination"
                        else "Figures for this payout destination are not loaded yet.")
        line["needs_destination"] = problem == "needs_destination"
        return line

    tiers = body.get("tiers")
    if tiers:
        tier = find_tier(tiers, amount)
        if tier is None:
            line["status"] = "out_of_range"
            line["note"] = "This amount is outside the published bands."
            return line
        percent, fixed = tier.get("percent"), tier.get("fixed")
        line["band"] = {"min": tier["min"], "max": tier["max"]}
    else:
        percent, fixed = body.get("percent"), body.get("fixed")

    percent_value = parse_decimal(percent, high=Decimal(100)) if percent is not None else Decimal(0)
    fixed_value = parse_decimal(fixed, high=Decimal(MAX_AMOUNT_KES)) if fixed is not None else Decimal(0)
    if percent_value is None or fixed_value is None:
        return line
    line["status"] = "calculated"
    # A component the provider does not publish stays None - "no fixed
    # charge published" is not "a fixed charge of zero". The sums below
    # count a None as nothing, but the result says which parts exist.
    line["percent_part"] = ceil_kes(percent_of(amount, percent_value)) if percent is not None else None
    line["fixed_part"] = ceil_kes(fixed_value) if fixed is not None else None
    if percent is not None:
        line["percent"] = plain(percent_value)
    return line


# ── A provider ───────────────────────────────────────────────────────────

_ASSUMPTIONS = [
    "Calculated as if the buyer pays every charge on top of the amount the seller should "
    "receive. Some providers let the seller pay instead: confirm who pays at checkout.",
    "Each charge is rounded up to a whole shilling. The provider's own rounding is not published.",
    "This is an estimate. The quotation on the provider's own checkout is the amount you "
    "actually pay.",
]


def _blank(record: dict, seller_receives: int, status: str, message: str) -> dict:
    pricing = record.get("pricing") or {}
    return {
        "provider_id": record.get("id"),
        "status": status,
        "seller_receives": seller_receives,
        "currency": CURRENCY,
        "commission": None,
        "fixed_charges": None,
        "mpesa_or_payout_charges": None,
        "mpesa_or_payout_note": "",
        "total_fees": None,
        "total_buyer_payment": None,
        "effective_fee_percent": None,
        "lines": [],
        "message": message,
        "assumptions": list(_ASSUMPTIONS),
        "disclosure": pricing.get("disclosure"),
        "includes_estimated_charges": False,
        "needs_payout_destination": False,
        "stale": True,
        "comparable": False,
        "not_comparable_reason": message,
    }


_UNAVAILABLE_MESSAGES = {
    "quote_required": "Live quotation required. This provider shows its fee in its own checkout "
                      "before you pay, so BROKA does not estimate it.",
    "not_disclosed": "Fee not publicly specified. Confirm it with the provider before paying.",
    "under_review": "Pricing is under review. Confirm it with the provider before paying.",
}


def estimate(record: dict, seller_receives: object, payout_destination: Optional[str] = None,
             freshness: Optional[dict] = None) -> dict:
    """What the buyer pays so that the seller receives [seller_receives],
    from [record]'s published pricing - or why that cannot be said.

    [freshness] is freshness.evaluate(...) for the record; without it the
    pricing is treated as unverified, which keeps the estimate out of any
    ranking."""
    amount = parse_whole_kes(seller_receives)
    if amount is None or amount < 1:
        return _blank(record, 0, INVALID_AMOUNT, "Enter the amount in whole shillings, more than zero.")

    pricing = record.get("pricing") or {}
    conditions = record.get("conditions") or {}
    disclosure = pricing.get("disclosure")

    if disclosure not in CALCULABLE_DISCLOSURES:
        return _blank(record, amount, UNAVAILABLE, _UNAVAILABLE_MESSAGES.get(
            disclosure, "No published fee to calculate from. Confirm it with the provider."))

    # The provider's limits first: a fee for an amount it will not take is
    # a number that invites someone to try.
    low, high = conditions.get("min_amount"), conditions.get("max_amount")
    if isinstance(low, int) and amount < low:
        return _blank(record, amount, OUT_OF_RANGE,
                      f"{record.get('display_name', 'This provider')} takes amounts from "
                      f"KSh {low:,}. Nothing is calculated below that.")
    if isinstance(high, int) and amount > high:
        return _blank(record, amount, OUT_OF_RANGE,
                      f"{record.get('display_name', 'This provider')} takes amounts up to "
                      f"KSh {high:,}. Nothing is calculated above that.")

    lines: list[dict] = []
    commission_rule = pricing.get("commission")
    if commission_rule:
        lines.append(evaluate_rule({**commission_rule, "kind": "commission"}, amount))
    for rule in pricing.get("processing_fees") or []:
        lines.append(evaluate_rule({**rule, "kind": "processing"}, amount, payout_destination))
    for rule in pricing.get("payout_fees") or []:
        lines.append(evaluate_rule({**rule, "kind": "payout"}, amount, payout_destination))

    if not lines:
        return _blank(record, amount, UNAVAILABLE,
                      "No fee formula is recorded for this provider. Confirm its fee before paying.")
    if any(line["status"] == "out_of_range" for line in lines):
        return _blank(record, amount, OUT_OF_RANGE,
                      "This amount falls outside the provider's published fee bands. Confirm the "
                      "fee with the provider.")

    commission = fixed = other = 0
    has_percent = has_fixed = False
    for line in lines:
        if line["status"] != "calculated":
            continue
        if line["kind"] == "commission":
            commission += line["percent_part"] or 0
            fixed += line["fixed_part"] or 0
            has_percent = has_percent or line["percent_part"] is not None
            has_fixed = has_fixed or line["fixed_part"] is not None
        else:
            other += (line["percent_part"] or 0) + (line["fixed_part"] or 0)

    # M-Pesa / payout charges: documented lines, or the provider's own
    # statement that it absorbs them. Silence is not a zero.
    absorbs = pricing.get("absorbs_mpesa_fees")
    has_other_rule = any(line["kind"] != "commission" for line in lines)
    other_note = ""
    other_known = True
    if has_other_rule:
        other_known = all(line["status"] == "calculated" for line in lines if line["kind"] != "commission")
        other_note = ("Estimated: the provider publishes this as an estimate."
                      if any(line["estimated"] and line["kind"] != "commission" for line in lines) else "")
    elif absorbs is True:
        other_note = "Included by the provider: it says it pays the M-Pesa charges."
    else:
        other_known = False
        other_note = "The provider does not say whether M-Pesa or payout charges are extra."

    commission_known = all(line["status"] == "calculated" for line in lines if line["kind"] == "commission")
    needs_destination = any(line.get("needs_destination") for line in lines)
    complete = commission_known and other_known

    result = _blank(record, amount, ESTIMATED if complete else PARTIAL, "")
    result.update({
        "commission": commission if commission_known and has_percent else None,
        "fixed_charges": fixed if commission_known and has_fixed else None,
        "mpesa_or_payout_charges": (other if other_known else None),
        "mpesa_or_payout_note": other_note,
        "lines": lines,
        "needs_payout_destination": needs_destination,
        "includes_estimated_charges": any(
            line["estimated"] and line["status"] == "calculated" for line in lines),
    })
    if complete:
        total_fees = commission + fixed + other
        result["total_fees"] = total_fees
        result["total_buyer_payment"] = amount + total_fees
        result["effective_fee_percent"] = effective_percent(total_fees, amount)
        result["message"] = ("Estimate. The quotation on the provider's own checkout is the amount "
                             "you actually pay.")
    else:
        result["message"] = ("Some charges cannot be calculated, so no total is shown. "
                             + ("Choose where the seller is paid to include the payout charge. "
                                if needs_destination else
                                "Check the provider's own quotation for the rest. ")
                             + "The charges listed are estimates.")

    # Only a current, verified, complete estimate may be compared with
    # another provider's: see compare.rank.
    verdict = freshness.get("state") if isinstance(freshness, dict) else "unverified"
    result["stale"] = verdict != "current"
    reason = None
    if not complete:
        reason = "not every charge could be calculated"
    elif result["stale"]:
        reason = ("pricing has not been verified by BROKA" if verdict == "unverified"
                  else "pricing is out of date")
    elif pricing.get("additional_fees_may_apply") is not False:
        reason = "the provider has not confirmed that no other fees apply"
    result["comparable"] = reason is None
    result["not_comparable_reason"] = reason
    return result
