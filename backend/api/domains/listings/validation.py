"""What a listing may contain - the checks behind POST /listings,
PATCH /listings/{id} and POST /listings/{id}/interest.

The live listings router had lost every bound the older ListingCreate
schema (api/schemas.py) carried, so the only check left was the type. A
price of 0, -5 or NaN, a latitude of 500, a 100,000-character name all
saved. NaN was the worst: Python's json module accepts the bare literals
NaN and Infinity, PostgreSQL stores them in a float column, and every
later response that contains the row fails to serialise - one request
took GET /listings/ (the Home feed) down for every visitor.

Messages are written for the seller: the app shows them as they are.
"""
from __future__ import annotations

import json
import math
from typing import Any, Optional

from pydantic_core import PydanticCustomError

from api.domains.escrow.service import MAX_AGREED_PRICE_KES

MIN_NAME_LEN = 3
MAX_NAME_LEN = 120
MAX_DESCRIPTION_LEN = 2000
MIN_CATEGORY_LEN = 2
MAX_CATEGORY_LEN = 60
MAX_LOCATION_NAME_LEN = 100
MAX_PLACE_LEN = 80            # county, subcounty - same as a store's
MAX_ATTRIBUTES = 30
MAX_ATTRIBUTE_KEY_LEN = 40
MAX_ATTRIBUTE_VALUE_LEN = 200

CONDITIONS = ("new", "used", "refurbished")

# A listing priced above what BROKA can hold in escrow could be negotiated
# for and then never paid for: finalising the deal refuses it. Refusing it
# here tells the seller at the one point they can do something about it.
MAX_PRICE_KES = MAX_AGREED_PRICE_KES


def invalid(message: str) -> PydanticCustomError:
    """A validation error whose message reaches the client unprefixed.
    (A plain ValueError comes out as "Value error, <message>".)"""
    return PydanticCustomError("listing_field", message)


def check_price(value: float, label: str = "The price") -> float:
    # Non-finite values are refused before this runs (allow_inf_nan=False
    # on the models); NaN fails every comparison, so a range check alone
    # would wave it through.
    if not math.isfinite(value):
        raise invalid(f"{label} must be a number.")
    if value <= 0:
        raise invalid(f"{label} must be above zero.")
    if value > MAX_PRICE_KES:
        raise invalid(
            f"{label} can't be more than KES {MAX_PRICE_KES:,.0f} - the most BROKA "
            f"can hold in escrow for one deal."
        )
    return value


def clean_name(value: str) -> str:
    # Whitespace runs (newlines included) collapse to one space: a name is
    # one line on every card, and a pasted newline pushes the price off it.
    name = " ".join(value.split())
    if len(name) < MIN_NAME_LEN:
        raise invalid(f"Give the listing a name of at least {MIN_NAME_LEN} characters.")
    if len(name) > MAX_NAME_LEN:
        raise invalid(f"Keep the name to {MAX_NAME_LEN} characters or fewer.")
    return name


def clean_category(value: str) -> str:
    category = " ".join(value.split())
    if not MIN_CATEGORY_LEN <= len(category) <= MAX_CATEGORY_LEN:
        raise invalid("Choose a category for the listing.")
    return category


def clean_condition(value: Optional[str]) -> Optional[str]:
    if value is None or not value.strip():
        return None
    condition = value.strip().lower()
    if condition not in CONDITIONS:
        raise invalid("Condition must be new, used or refurbished.")
    return condition


def bounded_text(value: Optional[str], limit: int, what: str) -> Optional[str]:
    if value is None:
        return None
    text = value.strip()
    if len(text) > limit:
        raise invalid(f"Keep the {what} to {limit} characters or fewer.")
    return text


def clean_attributes(value: Optional[dict]) -> Optional[dict]:
    """Category details ("make": "Toyota", "mileage": 45000). Flat, bounded,
    and only values JSON can hold: the dict is stored as JSON text and put
    in every card, so a NaN inside it breaks the feed exactly like a NaN
    price does."""
    if value is None:
        return None
    if len(value) > MAX_ATTRIBUTES:
        raise invalid(f"A listing can have at most {MAX_ATTRIBUTES} details.")
    cleaned: dict[str, Any] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not key.strip() or len(key) > MAX_ATTRIBUTE_KEY_LEN:
            raise invalid("One of the listing's details has an invalid name.")
        if item is None or isinstance(item, bool):
            cleaned[key] = item
        elif isinstance(item, (int, float)):
            if not math.isfinite(item):
                raise invalid(f"'{key}' must be a number.")
            cleaned[key] = item
        elif isinstance(item, str):
            if len(item) > MAX_ATTRIBUTE_VALUE_LEN:
                raise invalid(f"Keep '{key}' to {MAX_ATTRIBUTE_VALUE_LEN} characters or fewer.")
            cleaned[key] = item.strip()
        else:
            raise invalid(f"'{key}' must be text or a number.")
    return cleaned or None


def load_attributes(raw: Optional[str]) -> Optional[dict]:
    """Listing.attributes as a dict, for a response or a filter.

    Never raises, and never returns NaN or Infinity: rows written before
    clean_attributes existed may hold either, and one of them in a page of
    results used to fail the whole page. A corrupt value reads as none."""
    if not raw:
        return None
    try:
        value = json.loads(raw, parse_constant=lambda _constant: None)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, dict) else None
