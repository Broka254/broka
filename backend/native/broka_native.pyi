"""Type stub for the Rust extension (backend/native/src/python.rs).

Import it through api.core.native, never directly: that module checks the
build matches this checkout and falls back to Python when it doesn't.
"""

__version__: str
API_VERSION: int
CONTACT_RULES_JSON: str
MAX_FINDINGS: int
EARTH_RADIUS_KM: float

def normalize_text(text: str) -> str: ...
def scan_contact_leaks(text: str) -> list[tuple[str, int, int, str]]: ...
def haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float: ...
def distances_km(
    lat: float, lng: float, points: list[tuple[float | None, float | None]]
) -> list[float | None]: ...
