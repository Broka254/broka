"""The Rust extension and the Python reference agree, and the loader only
hands out an extension it can trust.

api/core/text_guard.py and api/core/geo.py each run on the Rust extension
when it's loaded and on Python otherwise. Production runs Rust (the Docker
image requires it); the PostgreSQL CI job, local checkouts nobody compiled,
and BROKA_NATIVE=off run Python. Both must give the same answer, or a leak
counted in one environment is missed in another. So the two engines are fed
the same generated text - disguised numbers, look-alike letters, invisible
characters, every script - and must produce identical output.

The generator is seeded: a failure names its input and reproduces.

The engines' Unicode tables differ in age: Python 3.11 ships Unicode 14, the
Rust crates something newer. Characters assigned since behave differently
(Python sees an unknown code point), so generated text only uses characters
Python knows. That gap is the one documented divergence.
"""
import dataclasses
import json
import math
import random
import sys
import time
import types
import unicodedata

import pytest

from api.core import geo, native, text_guard
from api.core.config import settings

needs_rust = pytest.mark.skipif(native.module is None, reason=f"Rust extension not in use: {native.REASON}")

SEED = 20260928
CASES = 4000


def test_extension_is_in_use_when_required():
    """CI's SQLite job and the Docker image set BROKA_NATIVE=required: there,
    a missing or stale extension is a failure, not a quiet fallback."""
    if settings.native_mode == "required":
        assert native.AVAILABLE, native.REASON
        assert native.BACKEND == "rust"


# ── Generated text ────────────────────────────────────────────────────────────

_FRAGMENTS = [
    # digits, spaced and spelled
    "0", "7", "1", "2", "0712", "345", "678", "254", "+254", "(0)", "07", "10", "2025",
    "0712345678", "0733 123 456", "zero", "seven", "one", "oh", "double", "triple",
    "sifuri", "saba", "moja", "mbili", "tisa", "nane", "O7l2", "l0l",
    # separators and punctuation
    " ", "  ", "-", ".", "(", ")", ",", ":", "/", "+", "@", "#", "'", "_", "%",
    "\t", "\n", "\r\n", "\x00", "\x1c", "\x7f",
    # words and rule material
    "whatsapp", "whats app", "what's", "app", "wh@ts@pp", "wa.me/", "t.me/", "telegram",
    "call me", "text", "me", "on", "my", "number", "yangu", "namba", "nipigie", "nitumie sms",
    "pay", "directly", "outside", "send", "money", "cash", "pesa", "tuma", "kwa",
    "till", "paybill", "no.", "lipa na mpesa", "escrow", "skip", "gmail", "dot", "com",
    "jo.doe", "example.co.ke", "iPhone", "KES", "45,000", "bei gani", "is it available",
    # look-alikes, styled, invisible, marks, other scripts
    "а", "о", "е", "р", "с", "х", "і", "ӏ",   # Cyrillic
    "α", "ο", "ρ", "Α", "Ο", "Σ", "σ",             # Greek
    "０", "７", "Ｗ", "ａ", "\U0001d7ce", "\U0001d7d5", "①",
    "²", "Ⅷ", "ﬀ", "Ω", "Å", "İ", "ẞ", "ß",
    "​", "‌", "‍", "⁠", "﻿", "­", "᠎", "ㅤ", "ﾠ",
    "́", "̈", "⃝", "ि", "️",
    "é", "ø", "ł", "đ", "Å", "ǅ",
    "٠", "٧", "۷", "१", "๗",
    " ", " ", "　", " ", " ",
    "\U0001f600", "\U0001f4de", "中文", "مرحبا", "가",
    "\ud800", "\udfff",                                                                 # lone surrogates
]


def _python_knows(c: str) -> bool:
    return unicodedata.category(c) != "Cn"


def _random_char(rng: random.Random) -> str:
    while True:
        cp = rng.choice((rng.randrange(0x80, 0x3000), rng.randrange(0x3000, 0x30000)))
        c = chr(cp)
        if _python_knows(c) or 0xD800 <= cp <= 0xDFFF:
            return c


def _message(rng: random.Random) -> str:
    parts = []
    for _ in range(rng.randrange(0, 40)):
        roll = rng.random()
        if roll < 0.8:
            frag = rng.choice(_FRAGMENTS)
            parts.append(frag.upper() if rng.random() < 0.1 else frag)
        elif roll < 0.9:
            parts.append(_random_char(rng))
        else:
            parts.append(str(rng.randrange(0, 10 ** rng.randrange(1, 14))))
    return "".join(parts)


def _messages():
    rng = random.Random(SEED)
    return [_message(rng) for _ in range(CASES)]


# ── Text: Rust and Python give the same answer ───────────────────────────────

@needs_rust
def test_normalize_agrees_on_generated_text():
    python = text_guard.python_engine()
    for text in _messages():
        assert native.module.normalize_text(text) == python.normalize(text), repr(text)


@needs_rust
def test_scan_agrees_on_generated_text():
    python = text_guard.python_engine()
    with_findings, kinds = 0, set()
    for text in _messages():
        rust = [tuple(f) for f in native.module.scan_contact_leaks(text)]
        assert rust == [tuple(f) for f in python.scan(text)], repr(text)
        with_findings += bool(rust)
        kinds.update(f[0] for f in rust)
    # The generator must exercise every detector, not only clean text.
    assert with_findings > CASES // 5
    assert kinds == {"phone", "email", "messaging_app", "contact_request", "payment_redirect"}


@needs_rust
def test_scan_agrees_on_every_known_bmp_character():
    python = text_guard.python_engine()
    chars = [chr(cp) for cp in range(0x80, 0x10000)
             if not 0xD800 <= cp <= 0xDFFF and _python_knows(chr(cp))]
    for i in range(0, len(chars), 64):
        block = "0712" + " ".join(chars[i:i + 64]) + " whatsapp 345678"
        assert native.module.normalize_text(block) == python.normalize(block), repr(block)


# ── Geo: Rust and Python give the same number ────────────────────────────────

def _coords(rng: random.Random):
    edge = [0.0, 90.0, -90.0, 180.0, -180.0, 1e-12, -1.2864, 36.8172, math.nan, math.inf, -math.inf]
    for _ in range(3000):
        yield tuple(rng.choice(edge) if rng.random() < 0.15 else rng.uniform(-200, 200) for _ in range(4))


def _same(a: float, b: float) -> bool:
    return (math.isnan(a) and math.isnan(b)) or math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-9)


@needs_rust
def test_haversine_agrees():
    for lat1, lng1, lat2, lng2 in _coords(random.Random(SEED)):
        rust = native.module.haversine_km(lat1, lng1, lat2, lng2)
        python = geo._haversine_km(lat1, lng1, lat2, lng2)
        assert _same(rust, python), (lat1, lng1, lat2, lng2, rust, python)


@needs_rust
def test_distances_agree_including_missing_points(monkeypatch):
    rng = random.Random(SEED)
    points = [(None if rng.random() < 0.1 else rng.uniform(-5, 5),
               None if rng.random() < 0.1 else rng.uniform(33, 42)) for _ in range(500)]
    rust = geo.distances_km(-1.2864, 36.8172, points)
    monkeypatch.setattr(native, "module", None)
    python = geo.distances_km(-1.2864, 36.8172, points)
    assert len(rust) == len(python) == len(points)
    for r, p in zip(rust, python):
        assert (r is None and p is None) or _same(r, p)


def test_geo_known_values_on_the_loaded_engine():
    d = geo.haversine_km(-1.2864, 36.8172, -4.0435, 39.6682)       # Nairobi-Mombasa
    assert 435 < d < 445
    assert geo.haversine_km(1.0, 2.0, 1.0, 2.0) == 0.0
    assert math.isclose(geo.haversine_km(0.0, 0.0, 0.0, 180.0), math.pi * geo.EARTH_RADIUS_KM)
    assert math.isnan(geo.haversine_km(math.nan, 0.0, 0.0, 0.0))
    assert math.isnan(geo.haversine_km(0.0, math.inf, 0.0, 0.0))    # used to raise
    assert geo.distances_km(0.0, 0.0, [(None, 1.0), (1.0, None)]) == [None, None]


# ── The Python fallback stays linear ─────────────────────────────────────────

def test_python_engine_is_linear_on_hostile_text():
    """Long runs that make backtracking engines quadratic or worse. Rust is
    linear by construction; the fallback must be too, since BROKA_NATIVE=off
    puts it on every message."""
    hostile = (
        "1 " * 20_000 + "a" * 20_000 + "@" * 5_000 + "what " * 5_000
        + "0" * 20_000 + ". " * 10_000 + "till " * 5_000 + "gmail " * 5_000
    )
    started = time.perf_counter()
    text_guard.python_engine().scan(hostile)
    assert time.perf_counter() - started < 10


# ── The loader ────────────────────────────────────────────────────────────────

def _fake_extension(**overrides) -> types.ModuleType:
    fake = types.ModuleType("broka_native")
    fake.__version__ = "0.0.0-test"
    fake.API_VERSION = native.API_VERSION
    fake.CONTACT_RULES_JSON = native.RULES_PATH.read_bytes().decode("utf-8")
    fake.scan_contact_leaks = lambda text: []
    for name, value in overrides.items():
        setattr(fake, name, value)
    return fake


def test_off_never_imports_the_extension(monkeypatch):
    monkeypatch.setitem(sys.modules, "broka_native", None)   # an import would raise
    module, reason = native.load("off")
    assert module is None and "off" in reason


def test_a_missing_extension_falls_back(monkeypatch):
    monkeypatch.setitem(sys.modules, "broka_native", None)
    module, reason = native.load("auto")
    assert module is None and "not installed" in reason


def test_a_matching_extension_is_used(monkeypatch):
    fake = _fake_extension()
    monkeypatch.setitem(sys.modules, "broka_native", fake)
    assert native.load("auto") == (fake, "broka_native 0.0.0-test")


def test_an_extension_built_for_another_api_is_refused(monkeypatch):
    monkeypatch.setitem(sys.modules, "broka_native", _fake_extension(API_VERSION=native.API_VERSION + 1))
    module, reason = native.load("auto")
    assert module is None and "API_VERSION" in reason


def test_an_extension_built_from_other_rules_is_refused(monkeypatch):
    rules = json.loads(native.RULES_PATH.read_text())
    rules["rules"] = rules["rules"][1:]
    monkeypatch.setitem(sys.modules, "broka_native", _fake_extension(CONTACT_RULES_JSON=json.dumps(rules)))
    module, reason = native.load("auto")
    assert module is None and "different contact-leak rules" in reason


def test_an_extension_that_panics_is_refused(monkeypatch):
    class PanicException(BaseException):     # what a Rust panic surfaces as
        pass

    def panics(text):
        raise PanicException("rules did not compile")

    monkeypatch.setitem(sys.modules, "broka_native", _fake_extension(scan_contact_leaks=panics))
    module, reason = native.load("auto")
    assert module is None and "self-check" in reason


def test_startup_refuses_required_without_the_extension(monkeypatch):
    from api.core import config
    monkeypatch.setattr(config, "settings", dataclasses.replace(settings, native_mode="required"))
    monkeypatch.setattr(native, "AVAILABLE", False)
    monkeypatch.setattr(native, "REASON", "broka_native is not installed (test)")
    with pytest.raises(RuntimeError, match="BROKA_NATIVE=required"):
        config.validate_startup()


def test_startup_refuses_an_unknown_mode(monkeypatch):
    from api.core import config
    monkeypatch.setattr(config, "settings", dataclasses.replace(settings, native_mode="requried"))
    with pytest.raises(RuntimeError, match="BROKA_NATIVE="):
        config.validate_startup()
