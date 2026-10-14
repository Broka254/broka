"""The Rust extension (backend/native), and whether this process uses it.

`broka_native` does the few jobs Python is the wrong tool for - scanning
every chat message with a regex engine that can't be made to backtrack
(api/core/text_guard.py) and bulk distance math (api/core/geo.py). Each of
those modules also holds a Python reference implementation with identical
output (tests/test_native_parity.py holds them to it), so the backend runs
without the extension - in a checkout nobody has compiled, or with the
extension switched off.

This is the only module that imports `broka_native`. It hands out the
module when, and only when, it can be trusted:

  * BROKA_NATIVE isn't "off" (settings.native_mode);
  * it imports;
  * its API_VERSION is the one this code calls - a stale build left in
    site-packages is never called with arguments it doesn't understand;
  * the contact-leak rules compiled into it are byte-for-byte the ones in
    native/rules/contact_leaks.json - otherwise the Rust and Python engines
    would silently disagree about what a leak is;
  * a first scan works, which compiles those rules.

Otherwise `module` is None and REASON says why; validate_startup() logs it,
or refuses to start when BROKA_NATIVE=required.
"""
from __future__ import annotations

import logging
from pathlib import Path
from types import ModuleType

from api.core.config import settings

logger = logging.getLogger(__name__)

MODES = ("auto", "required", "off")

# The extension's API_VERSION this code is written against (native/src/python.rs).
API_VERSION = 1

# The rules both engines load. backend/native/rules/, found from here.
RULES_PATH = Path(__file__).resolve().parents[2] / "native" / "rules" / "contact_leaks.json"


def load(mode: str) -> tuple[ModuleType | None, str]:
    """The extension if it can be used under `mode`, and a sentence saying
    what was loaded or why nothing was."""
    if mode == "off":
        return None, "switched off (BROKA_NATIVE=off)"
    try:
        import broka_native
    except ImportError as exc:
        return None, f"broka_native is not installed ({exc})"

    found = getattr(broka_native, "API_VERSION", None)
    if found != API_VERSION:
        return None, f"broka_native has API_VERSION {found!r}, this code needs {API_VERSION} - rebuild it"
    try:
        # Bytes, not text mode: a CRLF checkout must compare equal to the
        # copy include_str! embedded from the same file.
        on_disk = RULES_PATH.read_bytes().decode("utf-8")
    except OSError as exc:
        return None, f"cannot read {RULES_PATH} ({exc})"
    if broka_native.CONTACT_RULES_JSON != on_disk:
        return None, f"broka_native was built from different contact-leak rules than {RULES_PATH.name} - rebuild it"
    try:
        broka_native.scan_contact_leaks("self-check: call me on 0712 345 678")
    except (KeyboardInterrupt, SystemExit):
        raise
    except BaseException as exc:  # a Rust panic surfaces as a BaseException
        return None, f"broka_native failed its self-check ({exc!r})"
    return broka_native, f"broka_native {broka_native.__version__}"


module, REASON = load(settings.native_mode)
AVAILABLE = module is not None
BACKEND = "rust" if AVAILABLE else "python"
