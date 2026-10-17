"""Approximate points for a store's declared county / subcounty.

A store's precise location is its pin (Store.lat/lng), set when the owner
stands at the shop. Stores opened before pins existed - and owners who
skip the pin - carry only the county/subcounty they typed at setup. Those
names still say where the shop is, just coarsely: this table gives each
county its county town and the best-known subcounties (constituencies) a
point, so a pin-less shop can be found "near you" and put on the map.

Every point here is approximate by construction and is only ever handed
out rounded to two decimals (~1 km) with the payload's
`distance_approximate` flag set - it must never be presented as the
shop's exact spot. County points are county towns; a subcounty point,
when known, wins over its county's.
"""
from __future__ import annotations

import re
from typing import Optional

Point = tuple[float, float]

# County town (or the county's main town) per county, in the official
# county order the app's KenyaLocations lists.
COUNTY_POINTS: dict[str, Point] = {
    "Mombasa": (-4.050, 39.667),
    "Kwale": (-4.181, 39.450),
    "Kilifi": (-3.631, 39.850),
    "Tana River": (-1.498, 40.030),
    "Lamu": (-2.269, 40.902),
    "Taita Taveta": (-3.396, 38.556),
    "Garissa": (-0.449, 39.646),
    "Wajir": (1.747, 40.057),
    "Mandera": (3.925, 41.867),
    "Marsabit": (2.334, 37.990),
    "Isiolo": (0.355, 37.582),
    "Meru": (0.047, 37.650),
    "Tharaka Nithi": (-0.333, 37.650),
    "Embu": (-0.539, 37.457),
    "Kitui": (-1.367, 38.010),
    "Machakos": (-1.518, 37.266),
    "Makueni": (-1.783, 37.633),
    "Nyandarua": (-0.264, 36.378),
    "Nyeri": (-0.420, 36.947),
    "Kirinyaga": (-0.499, 37.280),
    "Murang'a": (-0.721, 37.152),
    "Kiambu": (-1.171, 36.835),
    "Turkana": (3.119, 35.597),
    "West Pokot": (1.237, 35.112),
    "Samburu": (0.615, 36.822),
    "Trans Nzoia": (0.999, 34.999),
    "Uasin Gishu": (0.515, 35.270),
    "Elgeyo Marakwet": (0.672, 35.508),
    "Nandi": (0.203, 35.105),
    "Baringo": (0.494, 35.743),
    "Laikipia": (0.008, 37.073),
    "Nakuru": (-0.303, 36.080),
    "Narok": (-1.083, 35.871),
    "Kajiado": (-1.852, 36.776),
    "Kericho": (-0.368, 35.286),
    "Bomet": (-0.782, 35.339),
    "Kakamega": (0.282, 34.751),
    "Vihiga": (0.083, 34.722),
    "Bungoma": (0.569, 34.561),
    "Busia": (0.460, 34.111),
    "Siaya": (-0.061, 34.287),
    "Kisumu": (-0.092, 34.768),
    "Homa Bay": (-0.527, 34.457),
    "Migori": (-1.063, 34.473),
    "Kisii": (-0.677, 34.772),
    "Nyamira": (-0.563, 34.914),
    "Nairobi": (-1.286, 36.817),
}

# Subcounties whose point is worth more than their county town's: the
# Nairobi metropolitan constituencies, the Kiambu towns buyers name, and
# a few others from the screenshots' own geography. Names are the app's
# constituency spellings (flutter KenyaLocations).
SUBCOUNTY_POINTS: dict[str, Point] = {
    "Westlands": (-1.263, 36.808),
    "Dagoretti North": (-1.278, 36.755),
    "Dagoretti South": (-1.295, 36.738),
    "Lang'ata": (-1.355, 36.738),
    "Kibra": (-1.313, 36.782),
    "Roysambu": (-1.219, 36.886),
    "Kasarani": (-1.223, 36.897),
    "Ruaraka": (-1.254, 36.884),
    "Embakasi South": (-1.322, 36.880),
    "Embakasi North": (-1.263, 36.879),
    "Embakasi Central": (-1.309, 36.870),
    "Embakasi East": (-1.282, 36.894),
    "Embakasi West": (-1.283, 36.871),
    "Makadara": (-1.296, 36.843),
    "Kamukunji": (-1.285, 36.832),
    "Starehe": (-1.281, 36.828),
    "Mathare": (-1.262, 36.855),
    "Kabete": (-1.263, 36.727),
    "Ruiru": (-1.149, 36.961),
    "Juja": (-1.104, 37.014),
    "Thika Town": (-1.033, 37.069),
    "Kikuyu": (-1.246, 36.664),
    "Limuru": (-1.107, 36.642),
    "Kiambaa": (-1.189, 36.826),
    "Kiambu": (-1.171, 36.835),
    "Githunguri": (-1.059, 36.779),
    "Kisumu Central": (-0.092, 34.768),
    "Kisumu East": (-0.077, 34.799),
    "Kisumu West": (-0.099, 34.721),
    "Mvita": (-4.054, 39.668),
    "Nyali": (-4.019, 39.703),
    "Ugunja": (0.180, 34.300),
    "Ugenya": (0.090, 34.220),
    "Nakuru Town East": (-0.303, 36.080),
    "Nakuru Town West": (-0.289, 36.047),
    "Eldoret": (0.515, 35.270),
}


def _key(value: Optional[str]) -> str:
    """Name matching the way the app's KenyaLocations compares: case and
    punctuation gone, so 'Muranga', \"Murang'a\" and 'THARAKA-NITHI' all
    find their row."""
    return re.sub(r"[^a-z]", "", (value or "").lower())


_COUNTY_BY_KEY = {_key(name): point for name, point in COUNTY_POINTS.items()}
_SUBCOUNTY_BY_KEY = {_key(name): point for name, point in SUBCOUNTY_POINTS.items()}


def county_point(county: Optional[str]) -> Optional[Point]:
    """The county town's point, or None for an unknown county."""
    return _COUNTY_BY_KEY.get(_key(county))


def subcounty_point(subcounty: Optional[str]) -> Optional[Point]:
    """A known subcounty's point, or None when this table has none."""
    return _SUBCOUNTY_BY_KEY.get(_key(subcounty))


def area_point(county: Optional[str], subcounty: Optional[str]) -> Optional[Point]:
    """The best approximate point for a declared area: the subcounty's
    when known, else the county town's, else None."""
    return subcounty_point(subcounty) or county_point(county)
