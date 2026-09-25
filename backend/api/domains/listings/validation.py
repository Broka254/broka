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
import re
from typing import Any, Optional

from pydantic_core import PydanticCustomError

from api.domains.escrow.service import MAX_AGREED_PRICE_KES

MIN_NAME_LEN = 3
MAX_NAME_LEN = 120
MAX_DESCRIPTION_LEN = 2000
# A description is required (2026-09-25). Twenty characters is one short
# sentence - "Used 2 years, works well" - enough to say something a photo
# can't, not an essay.
MIN_DESCRIPTION_LEN = 20
MIN_CATEGORY_LEN = 2
MAX_CATEGORY_LEN = 60
MAX_LOCATION_NAME_LEN = 100
MAX_PLACE_LEN = 80            # county, subcounty - same as a store's
MAX_ATTRIBUTES = 30
MAX_ATTRIBUTE_KEY_LEN = 40
MAX_ATTRIBUTE_VALUE_LEN = 200

CONDITIONS = ("new", "used", "refurbished")

# What one unit of the price is: "bag" for KES 3,500 per bag of maize.
# None means the price is for the whole listing. Short, one word or two,
# because it is printed after the price on every card ("KES 3,500 / bag").
MAX_PRICE_UNIT_LEN = 24
_PRICE_UNIT = re.compile(r"[a-z0-9][a-z0-9 .()/x×-]*")
# Words that mean "the price is for the item itself": stored as no unit.
_WHOLE_ITEM_UNITS = {"item", "each", "unit", "whole", "total", "lot"}

MAX_QUANTITY = 1_000_000
MAX_DELIVERY_NOTE_LEN = 120

# Land (2026-09-25): a plot without a size can't be compared or priced, so
# a Land listing must give one. Stored as the seller gave it plus
# land_size_acres, the same size in acres, which the Land zone's size
# filter compares on whatever unit each listing used. Factors are exact
# (a 50x100 ft plot is 5,000 sq ft).
LAND_CATEGORY = "Land"
MAX_LAND_SIZE = 1_000_000
LAND_SIZE_UNITS: dict[str, float] = {
    "acres": 1.0,
    "hectares": 10_000 / 4046.8564224,
    "50x100 plots": 5_000 / 43_560,
    "square metres": 1 / 4046.8564224,
    "square feet": 1 / 43_560,
}
_LAND_UNIT_ALIASES = {
    "acre": "acres", "ac": "acres",
    "hectare": "hectares", "ha": "hectares",
    "plot": "50x100 plots", "plots": "50x100 plots", "50x100 plot": "50x100 plots",
    "50 x 100 plots": "50x100 plots", "50×100 plots": "50x100 plots",
    "square metre": "square metres", "square meters": "square metres",
    "square meter": "square metres", "sq metres": "square metres", "sqm": "square metres",
    "m2": "square metres", "m²": "square metres",
    "square foot": "square feet", "sq feet": "square feet", "sq ft": "square feet",
    "sqft": "square feet", "ft2": "square feet", "ft²": "square feet",
}

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
    from api.domains.categories.seed import canonical_category_name

    category = " ".join(value.split())
    if not MIN_CATEGORY_LEN <= len(category) <= MAX_CATEGORY_LEN:
        raise invalid("Choose a category for the listing.")
    # A draft saved before "Vehicles" became "Automobiles" still says
    # "Vehicles"; it is filed under the category's current name.
    return canonical_category_name(category)


def clean_condition(value: Optional[str]) -> Optional[str]:
    if value is None or not value.strip():
        return None
    condition = value.strip().lower()
    if condition not in CONDITIONS:
        raise invalid("Condition must be new, used or refurbished.")
    return condition


def clean_description(value: Optional[str]) -> str:
    """Required. The buyer's first question - what condition, what's
    included, why it's being sold - and what a "not as described" dispute
    is decided against, with the photos."""
    text = (value or "").strip()
    if len(text) < MIN_DESCRIPTION_LEN:
        raise invalid(
            f"Describe the item in at least {MIN_DESCRIPTION_LEN} characters - its "
            f"condition, what's included and why you're selling."
        )
    if len(text) > MAX_DESCRIPTION_LEN:
        raise invalid(f"Keep the description to {MAX_DESCRIPTION_LEN} characters or fewer.")
    return text


def clean_price_unit(value: Optional[str]) -> Optional[str]:
    """ "per bag", "Bag", " bag " -> "bag"; "item"/"each" -> None (the
    price is for the whole listing)."""
    if value is None:
        return None
    unit = " ".join(value.split()).lower()
    for prefix in ("per ", "/"):
        if unit.startswith(prefix):
            unit = unit[len(prefix):].strip()
    if not unit or unit in _WHOLE_ITEM_UNITS:
        return None
    if len(unit) > MAX_PRICE_UNIT_LEN or not _PRICE_UNIT.fullmatch(unit):
        raise invalid(
            'The price unit should be a short word like "bag", "kg" or "piece".'
        )
    return unit


def clean_quantity(value: Optional[int]) -> Optional[int]:
    if value is None:
        return None
    if value < 1:
        raise invalid("The quantity must be at least 1.")
    if value > MAX_QUANTITY:
        raise invalid(f"The quantity can't be more than {MAX_QUANTITY:,}.")
    return value


def clean_land_details(attributes: Optional[dict]) -> dict:
    """A Land listing's attributes with its size checked and normalised:
    land_size (a number), land_size_unit (one of LAND_SIZE_UNITS) and the
    derived land_size_acres. Raises when either is missing or unusable.

    Accepts the size as a number or as the text an app's form field holds
    ("2.5", "1,000"), since app builds send every attribute as text."""
    attrs = dict(attributes or {})
    raw = attrs.get("land_size")
    size: Optional[float] = None
    if isinstance(raw, bool):
        size = None
    elif isinstance(raw, (int, float)):
        size = float(raw)
    elif isinstance(raw, str) and raw.strip():
        try:
            size = float(raw.replace(",", "").strip())
        except ValueError:
            size = None
    if size is None or not math.isfinite(size) or size <= 0:
        raise invalid("Enter the size of the land - how many acres, hectares or plots.")
    if size > MAX_LAND_SIZE:
        raise invalid("That land size is too large. Check the number and the unit.")

    unit_raw = " ".join(str(attrs.get("land_size_unit") or "").split()).lower()
    unit = _LAND_UNIT_ALIASES.get(unit_raw, unit_raw)
    if unit not in LAND_SIZE_UNITS:
        raise invalid(
            "Choose the unit the land is measured in: acres, hectares, 50x100 plots, "
            "square metres or square feet."
        )
    attrs["land_size"] = int(size) if size.is_integer() else round(size, 4)
    attrs["land_size_unit"] = unit
    attrs["land_size_acres"] = round(size * LAND_SIZE_UNITS[unit], 4)
    return attrs


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
