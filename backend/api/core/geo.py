"""Great-circle distance, for "near me" filters and "3.2 km away" labels.

The backend carried six copies of the haversine formula - in the listing,
trader, user and negotiation code - in two variants (atan2 and asin) that
disagreed in the last digit, and any of which raised "math domain error"
for antipodal points or an infinite coordinate. This is the one
implementation.

It runs in the Rust extension when that is loaded (api/core/native.py), and
the Python below otherwise: the same steps in the same order, so on one
platform the two agree to the bit (tests/test_native_parity.py). The gain is
in `distances_km`, which filters a whole candidate list in one call instead
of one interpreted formula per listing.
"""
from __future__ import annotations

import math
from typing import Optional, Sequence

from api.core import native

# Mean Earth radius, as every former copy used.
EARTH_RADIUS_KM = 6371.0

Point = tuple[Optional[float], Optional[float]]


def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Distance in km between two points given in degrees. NaN when any
    coordinate isn't a finite number - NaN compares false, so a filter like
    `d <= max_km` drops the point instead of raising."""
    if native.module is not None:
        return native.module.haversine_km(lat1, lng1, lat2, lng2)
    return _haversine_km(lat1, lng1, lat2, lng2)


def distances_km(lat: float, lng: float, points: Sequence[Point]) -> list[Optional[float]]:
    """`haversine_km` from one origin to each `(lat, lng)` in `points`, in
    order; None for a point missing either coordinate."""
    points = [(p_lat, p_lng) for p_lat, p_lng in points]
    if native.module is not None:
        return native.module.distances_km(lat, lng, points)
    return [
        None if p_lat is None or p_lng is None else _haversine_km(lat, lng, p_lat, p_lng)
        for p_lat, p_lng in points
    ]


def _haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """The Python reference - native/src/geo.rs, step for step."""
    if not (math.isfinite(lat1) and math.isfinite(lng1)
            and math.isfinite(lat2) and math.isfinite(lng2)):
        return math.nan
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    s_phi = math.sin(math.radians(lat2 - lat1) / 2.0)
    s_lambda = math.sin(math.radians(lng2 - lng1) / 2.0)
    a = s_phi * s_phi + math.cos(phi1) * math.cos(phi2) * s_lambda * s_lambda
    # Rounding can push `a` a hair past 1 for antipodal points, and asin of
    # anything above 1 raises.
    a = min(1.0, max(0.0, a))
    return 2.0 * EARTH_RADIUS_KM * math.asin(math.sqrt(a))
