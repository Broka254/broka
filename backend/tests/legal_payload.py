"""The declarations a legal registration carries in its request body.

Every test that registers a user needs the same three declarations, and a
test that deliberately omits one should say so explicitly - hence a dict
that is spread or overridden, rather than a client-level shim that would
make "missing declaration" untestable.
"""
from __future__ import annotations

from typing import Any

from api.core.legal_documents import PRIVACY, TERMS

SIGNUP_LEGAL: dict[str, Any] = {
    "age_confirmed": True,
    "terms_accepted": True,
    "privacy_acknowledged": True,
    "terms_version": TERMS.version,
    "privacy_version": PRIVACY.version,
}


def legal_payload(**overrides: Any) -> dict[str, Any]:
    """The current declarations, with any field overridden for a test."""
    return {**SIGNUP_LEGAL, **overrides}
