"""Where a listing sits on the map, and the county it is filed under.

The coordinates a listing used to be saved with had two problems:

  * They were the seller's phone, to seven decimal places, returned by the
    unauthenticated GET /listings - roughly the seller's front door, for
    anyone selling a phone or a car. Image processing strips GPS from
    photos for exactly this reason (api/core/image_processing.py); the
    listing row then published it anyway.
  * Mostly they weren't where the item is at all. The app sends the
    position saved at signup, and signup sends a fixed point in central
    Nairobi, so a listing in Mombasa sat on the map - and in every
    distance filter - in Nairobi CBD.

The seller already says where the item is: the county and area on the
sell wizard's Location step. A listing's point is now that county's main
town. The phone's position is used only when the county isn't one of
Kenya's 47, and then rounded to two decimal places (about a kilometre).
"""
from __future__ import annotations

import re
from typing import Optional

# Kenya's 47 counties (official order, 001 Mombasa to 047 Nairobi), spelt
# as flutter_app/lib/features/stores/domain/kenya_locations.dart spells
# them, each with its main town's position.
COUNTY_POINTS: dict[str, tuple[float, float]] = {
    "Mombasa": (-4.0435, 39.6682),
    "Kwale": (-4.1737, 39.4521),
    "Kilifi": (-3.6305, 39.8499),
    "Tana River": (-1.4989, 40.0296),        # Hola
    "Lamu": (-2.2717, 40.9020),
    "Taita Taveta": (-3.3961, 38.5561),      # Voi
    "Garissa": (-0.4532, 39.6460),
    "Wajir": (1.7471, 40.0573),
    "Mandera": (3.9366, 41.8670),
    "Marsabit": (2.3284, 37.9899),
    "Isiolo": (0.3546, 37.5822),
    "Meru": (0.0463, 37.6559),
    "Tharaka Nithi": (-0.3333, 37.6500),     # Chuka
    "Embu": (-0.5390, 37.4574),
    "Kitui": (-1.3670, 38.0106),
    "Machakos": (-1.5177, 37.2634),
    "Makueni": (-1.7833, 37.6333),           # Wote
    "Nyandarua": (-0.2667, 36.3833),         # Ol Kalou
    "Nyeri": (-0.4201, 36.9476),
    "Kirinyaga": (-0.4989, 37.2803),         # Kerugoya
    "Murang'a": (-0.7210, 37.1526),
    "Kiambu": (-1.1714, 36.8356),
    "Turkana": (3.1191, 35.5973),            # Lodwar
    "West Pokot": (1.2389, 35.1119),         # Kapenguria
    "Samburu": (1.0968, 36.6980),            # Maralal
    "Trans Nzoia": (1.0157, 35.0062),        # Kitale
    "Uasin Gishu": (0.5143, 35.2698),        # Eldoret
    "Elgeyo Marakwet": (0.6703, 35.5081),    # Iten
    "Nandi": (0.2039, 35.1050),              # Kapsabet
    "Baringo": (0.4919, 35.7430),            # Kabarnet
    "Laikipia": (0.0167, 37.0722),           # Nanyuki
    "Nakuru": (-0.3031, 36.0800),
    "Narok": (-1.0788, 35.8601),
    "Kajiado": (-1.8524, 36.7768),
    "Kericho": (-0.3689, 35.2863),
    "Bomet": (-0.7813, 35.3416),
    "Kakamega": (0.2827, 34.7519),
    "Vihiga": (0.0833, 34.7167),             # Mbale
    "Bungoma": (0.5635, 34.5606),
    "Busia": (0.4608, 34.1115),
    "Siaya": (0.0607, 34.2881),
    "Kisumu": (-0.0917, 34.7680),
    "Homa Bay": (-0.5273, 34.4571),
    "Migori": (-1.0634, 34.4731),
    "Kisii": (-0.6817, 34.7667),
    "Nyamira": (-0.5669, 34.9341),
    "Nairobi": (-1.2864, 36.8172),
}

# Two decimal places: ~1.1 km at Kenya's latitude. Close enough for "near
# me", too coarse to find a house.
FALLBACK_DECIMALS = 2


def _key(value: Optional[str]) -> str:
    """Letters only, lower case, without a trailing "county" - so "nairobi",
    "Nairobi County", "Tharaka-Nithi" and "Muranga" all find their county.
    (The app's KenyaLocations._key, plus the suffix.)"""
    key = re.sub(r"[^a-z]", "", (value or "").lower())
    for suffix in ("citycounty", "county"):
        if key.endswith(suffix) and len(key) > len(suffix):
            key = key[: -len(suffix)]
            break
    return key


_BY_KEY = {_key(name): name for name in COUNTY_POINTS}
_BY_KEY["nairobicity"] = "Nairobi"     # its official name is Nairobi City


def canonical_county(value: Optional[str]) -> Optional[str]:
    """The official spelling of the county `value` names, or None."""
    return _BY_KEY.get(_key(value))


def tidy_place(value: Optional[str]) -> Optional[str]:
    """A county or area name as typed, with whitespace runs collapsed.
    Blank is None."""
    if value is None:
        return None
    tidy = " ".join(value.split())
    return tidy or None


def listing_point(county: Optional[str], lat: float, lng: float) -> tuple[float, float]:
    """The position a listing is saved and shown at. See the module
    docstring: the county's main town when the county is known, else the
    sent position rounded to about a kilometre."""
    known = canonical_county(county)
    if known is not None:
        return COUNTY_POINTS[known]
    return round(lat, FALLBACK_DECIMALS), round(lng, FALLBACK_DECIMALS)
