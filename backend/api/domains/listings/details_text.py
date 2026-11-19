"""What the seller filled in on the Details step, as lines of a description.

"RAM: 8GB", "Storage: 128GB" - the details a buyer scans first, in the
"Label: value" lines Zeno writes too (sell_description_screen.dart). The
sell wizard puts them in the description box itself, for the seller to
keep, add to or edit (flutter_app/lib/utils/listing_details_text.dart);
ListingService.create_listing writes them here only when a listing arrives
with no description at all - an app build from before the box was filled
in - so the seller who skipped the description still says what the item
is, without typing it twice.
"""
from __future__ import annotations

from typing import Any, Optional

from .validation import MAX_DESCRIPTION_LEN

# Asked for with their own control and printed as one "Size" line, or
# derived by the server (land_size_acres) - never a line of their own.
_LAND_KEYS = {"land_size", "land_size_unit", "land_size_acres", "acreage"}

# Words a field name spells in lower case that a buyer reads in capitals.
_ACRONYMS = {"ram": "RAM", "tv": "TV", "ssd": "SSD", "hdd": "HDD", "gb": "GB",
             "tb": "TB", "id": "ID", "usb": "USB", "cc": "cc"}

# A unit at the end of a field name reads as one: "size_ml" -> "Size (ml)".
_UNITS = {"ml": "ml", "kg": "kg", "ft": "ft", "km": "km", "cm": "cm", "gb": "GB",
          "watts": "watts", "years": "years", "inches": "inches"}


def label(field_name: str) -> str:
    """"battery_health" -> "Battery health", "ram" -> "RAM",
    "bale_weight_kg" -> "Bale weight (kg)"."""
    words = [w for w in field_name.strip().lower().split("_") if w]
    if not words:
        return ""
    unit = _UNITS.get(words[-1]) if len(words) > 1 else None
    if unit:
        words = words[:-1]
    shown = [_ACRONYMS.get(w, w) for w in words]
    text = " ".join(shown)
    if shown[0] == words[0]:
        text = text[0].upper() + text[1:]
    return f"{text} ({unit})" if unit else text


def _value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, bool):
        return "Yes" if value else "No"
    if isinstance(value, float) and value.is_integer():
        return str(int(value))
    if isinstance(value, (list, tuple)):
        return ", ".join(str(v).strip() for v in value if str(v).strip())
    if isinstance(value, dict):
        return ""
    return str(value).strip()


def _land_size(attributes: dict) -> Optional[str]:
    size = _value(attributes.get("land_size"))
    unit = _value(attributes.get("land_size_unit"))
    if size and unit:
        # "2 plots (50x100)", not "2 50x100 plots".
        return f"{size} plots (50x100)" if unit == "50x100 plots" else f"{size} {unit}"
    acreage = _value(attributes.get("acreage"))
    return f"{acreage} acres" if acreage else None


def describe(condition: Optional[str], attributes: Optional[dict]) -> str:
    """The details as description lines, condition first; "" when there
    are none. Never longer than a description may be."""
    lines: list[str] = []
    if condition and condition.strip():
        lines.append(f"Condition: {condition.strip().capitalize()}")
    attributes = attributes or {}
    land = _land_size(attributes)
    if land:
        lines.append(f"Size: {land}")
    for key, value in attributes.items():
        if not isinstance(key, str) or key in _LAND_KEYS:
            continue
        name, text = label(key), _value(value)
        if name and text:
            lines.append(f"{name}: {text}")
    out = ""
    for line in lines:
        candidate = f"{out}\n{line}" if out else line
        if len(candidate) > MAX_DESCRIPTION_LEN:
            break
        out = candidate
    return out
