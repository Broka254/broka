"""Contact-leak scanning: does a chat message try to take a deal off BROKA?

BROKA's money moves through escrow. The way a deal escapes it is always the
same: one side slips the other a phone number, a WhatsApp handle or an M-Pesa
till, and the payment happens where nobody can protect the buyer. People who
do it on purpose hide it - "zero seven one two...", "0712 345 678", a Cyrillic
"о" for a zero, a zero-width space inside "whatsapp" - so the text is
normalized before anything is matched. The rules themselves are data, in
native/rules/contact_leaks.json.

TWO ENGINES, ONE BEHAVIOUR
==========================
`scan()` runs the Rust engine (native/src/text_guard.rs) when the extension
is loaded (api/core/native.py), and `PythonEngine` below otherwise. They
implement the same steps in the same order, and tests/test_native_parity.py
feeds both thousands of adversarial messages and requires identical output.
Change one, change the other.

Rust is preferred because every message a user sends is scanned and its text
is whatever the sender chose. Python's `re` backtracks: one careless pattern
added to the rules can take seconds on a crafted message, holding the event
loop for everyone. The Rust `regex` crate is linear-time for every pattern.
The Python engine is written to stay linear too (emails are found by walking
out from each "@", the digit-run pattern can't overlap itself), but only the
Rust one guarantees it for rules added later.

WHAT A FINDING IS FOR
=====================
Findings are recorded as `off_platform_solicitation_detected` audit rows
(routers/negotiate.py), which domains/trust/completion_rate.py reads as a
sign the deal leaked - lowering the seller's rank. So a rule must be
precise, not merely suggestive, and nothing here blocks or edits a message.
"""
from __future__ import annotations

import json
import re
import unicodedata
from functools import lru_cache
from typing import Iterable, NamedTuple

from api.core import native

# Mirrors text_guard.rs. A hundred findings already says everything a caller
# can act on; the cap keeps a pasted megabyte of numbers from becoming a
# megabyte of objects.
MAX_FINDINGS = 100

KIND_PHONE = "phone"
KIND_EMAIL = "email"


class ContactFinding(NamedTuple):
    """One thing in a message that looks like an off-platform contact.

    `start`/`end` index the NORMALIZED text (see `normalize`), and `text` is
    that slice - not the original message, whose offsets normalization does
    not preserve. It can hold a phone number: don't log it.
    """
    kind: str
    start: int
    end: int
    text: str


def scan(text: str) -> list[ContactFinding]:
    """Everything in `text` that looks like an off-platform contact, sorted
    by position, at most MAX_FINDINGS."""
    if not text:
        return []
    if native.module is not None:
        return [ContactFinding(*f) for f in native.module.scan_contact_leaks(text)]
    return python_engine().scan(text)


def normalize(text: str) -> str:
    """The form of `text` the rules are matched against."""
    if native.module is not None:
        return native.module.normalize_text(text)
    return python_engine().normalize(text)


def kinds_of(findings: Iterable[ContactFinding]) -> list[str]:
    """The distinct kinds among `findings`, sorted - what an audit row may
    record without recording the number itself."""
    return sorted({f.kind for f in findings})


@lru_cache(maxsize=1)
def python_engine() -> "PythonEngine":
    """The Python engine for the rules on disk, built on first use."""
    return PythonEngine(native.RULES_PATH.read_bytes().decode("utf-8"))


# ── The Python reference engine ───────────────────────────────────────────────
# Step for step the Rust engine; the comments there explain each step.

_DIGITS = "0123456789"
_LOWER = "abcdefghijklmnopqrstuvwxyz"
_LOCAL_PART = frozenset(_LOWER + _DIGITS + "._%+-")
_DOMAIN_PART = frozenset(_LOWER + _DIGITS + ".-")
_LETTERS_AS_DIGITS = str.maketrans("oli", "011")
_TOKEN_RE = re.compile(r"[a-z0-9]+", re.ASCII)
_DIGIT_GROUP_RE = re.compile(r"[0-9]+", re.ASCII)
# See find_phones in text_guard.rs. Separators and digits never overlap, so
# the repetition can't backtrack into itself.
_DIGIT_RUN_RE = re.compile(r"[0-9](?:[ .()\-]{0,3}[0-9])*", re.ASCII)
_SNAKE_CASE_RE = re.compile(r"[a-z_]+", re.ASCII)

# Characters seen, mapped - chat text reuses a small alphabet, and the
# Unicode lookups are the slow part of this engine. Bounded so text in every
# script at once can't grow it without limit.
_CHAR_CACHE_MAX = 8192


def _code_point(hex_text: str) -> int:
    try:
        return int(hex_text.strip(), 16)
    except ValueError:
        raise ValueError(f"bad code point {hex_text!r}") from None


def _scalar(hex_text: str) -> str:
    cp = _code_point(hex_text)
    if cp > 0x10FFFF or 0xD800 <= cp <= 0xDFFF:
        raise ValueError(f"{hex_text!r} is not a Unicode scalar value")
    return chr(cp)


def _ascii_replacement(field: str, key: str, value: object) -> str:
    if not (isinstance(value, str) and len(value) == 1 and "!" <= value <= "~"):
        raise ValueError(f"{field}[{key!r}] must be one printable ASCII character, got {value!r}")
    return value


def _word_alternation(words: Iterable[str]) -> str:
    words = list(words)
    for w in words:
        if not w or any(c not in _LOWER for c in w):
            raise ValueError(f"{w!r} must be lowercase ASCII letters")
    return "|".join(sorted(words, key=lambda w: (-len(w), w)))


def _is_kenyan_mobile(d: str) -> bool:
    n = len(d)
    if n == 10:
        return d[0] == "0" and d[1] in "17"
    if n == 12:
        return d.startswith("254") and d[3] in "17"
    if n == 13:
        return d.startswith("2540") and d[4] in "17"
    return False


def _letters_as_digits(match: re.Match) -> str:
    token = match.group(0)
    has_digit = any(c in _DIGITS for c in token)
    only_lookalikes = all(c in _DIGITS or c in "oli" for c in token)
    return token.translate(_LETTERS_AS_DIGITS) if has_digit and only_lookalikes else token


def _finding(norm: str, kind: str, start: int, end: int) -> tuple[int, int, str, str]:
    return (start, end, kind, norm[start:end])


def _find_emails(norm: str, found: list) -> None:
    at = norm.find("@")
    while at != -1:
        start = at
        while start > 0 and norm[start - 1] in _LOCAL_PART:
            start -= 1
        end = at + 1
        while end < len(norm) and norm[end] in _DOMAIN_PART:
            end += 1
        while end > at + 1 and norm[end - 1] in ".-":
            end -= 1
        local, domain = norm[start:at], norm[at + 1:end]
        tld = domain.rsplit(".", 1)[1] if "." in domain else ""
        if (
            any(c in _LOWER or c in _DIGITS for c in local)
            and not domain.startswith(".")
            and ".." not in domain
            and len(tld) >= 2
            and all(c in _LOWER for c in tld)
        ):
            found.append(_finding(norm, KIND_EMAIL, start, end))
        at = norm.find("@", at + 1)


class PythonEngine:
    """The compiled rules, in Python. Validates the rules file exactly as
    the Rust engine does, so a mistake fails loudly in both."""

    def __init__(self, rules_json: str):
        try:
            data = json.loads(rules_json)
            self.version = int(data["version"])
            invisible, digit_blocks = data["invisible"], data["digit_blocks"]
            homoglyphs, number_words = data["homoglyphs"], data["number_words"]
            repeaters, rules = data["repeaters"], data["rules"]
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"contact-leak rules: {exc!r}") from exc

        self._invisible: list[tuple[int, int]] = []
        for spec in invisible:
            lo_hi = spec.split("-", 1)
            lo, hi = _code_point(lo_hi[0]), _code_point(lo_hi[-1])
            if lo > hi:
                raise ValueError(f"invisible range {spec!r} is backwards")
            self._invisible.append((lo, hi))

        self._digit_blocks = [_code_point(s) for s in digit_blocks]

        self._homoglyphs: dict[str, str] = {}
        for key, value in homoglyphs.items():
            src = _scalar(key)
            if src.isascii():
                raise ValueError(f"homoglyphs[{key!r}] is already ASCII")
            self._homoglyphs[src] = _ascii_replacement("homoglyphs", key, value)

        self._number_words: dict[str, str] = {}
        for word, digit in number_words.items():
            if _ascii_replacement("number_words", word, digit) not in _DIGITS:
                raise ValueError(f"number_words[{word!r}] must be a digit, got {digit!r}")
            self._number_words[word] = digit

        self._repeaters: dict[str, int] = {}
        for word, times in repeaters.items():
            if isinstance(times, bool) or not isinstance(times, int) or not 2 <= times <= 9:
                raise ValueError(f"repeaters[{word!r}] must be 2 to 9, got {times!r}")
            self._repeaters[word] = times

        self._rules: list[tuple[str, re.Pattern]] = []
        for spec in rules:
            kind, name, pattern = spec["kind"], spec["name"], spec["pattern"]
            if not _SNAKE_CASE_RE.fullmatch(kind):
                raise ValueError(f"rule {name!r}: kind {kind!r} must be snake_case")
            try:
                rx = re.compile(pattern, re.ASCII)
            except re.error as exc:
                raise ValueError(f"rule {name!r}: {exc}") from exc
            if rx.search("") is not None:
                raise ValueError(f"rule {name!r} matches empty text")
            self._rules.append((kind, rx))

        self._number_word_re = re.compile(
            rf"\b(?:{_word_alternation(self._number_words)})\b", re.ASCII)
        self._repeater_re = re.compile(
            rf"\b({_word_alternation(self._repeaters)}) ?([0-9])", re.ASCII)
        self._char_cache: dict[str, str] = {}

    def _map_char(self, c: str) -> str:
        """One character of lower-cased NFKC text as printable ASCII: "" to
        drop it, a space for anything that can't carry a contact detail."""
        cp = ord(c)
        if cp < 0x80:
            return " " if cp < 0x20 or cp == 0x7F else c
        if any(lo <= cp <= hi for lo, hi in self._invisible):
            return ""
        if unicodedata.category(c).startswith("M"):
            return ""
        base = unicodedata.normalize("NFD", c)[0]
        b = ord(base)
        if b < 0x80:
            return " " if b < 0x20 or b == 0x7F else base
        for start in self._digit_blocks:
            if start <= b < start + 10:
                return _DIGITS[b - start]
        return self._homoglyphs.get(base, " ")

    def normalize(self, text: str) -> str:
        try:
            text.encode("utf-8")
        except UnicodeEncodeError:
            # Lone surrogates (valid in a JSON string, not in UTF-8) become
            # U+FFFD, as the Rust side's to_string_lossy does.
            text = text.encode("utf-8", "surrogatepass").decode("utf-8", "replace")
        lowered = unicodedata.normalize("NFKC", text).lower()

        cache = self._char_cache
        out: list[str] = []
        after_space = True
        for c in lowered:
            m = cache.get(c)
            if m is None:
                m = self._map_char(c)
                if len(cache) < _CHAR_CACHE_MAX:
                    cache[c] = m
            if not m:
                continue
            if m == " ":
                if not after_space:
                    out.append(" ")
                    after_space = True
            else:
                out.append(m)
                after_space = False
        if out and out[-1] == " ":
            out.pop()

        tokens = _TOKEN_RE.sub(_letters_as_digits, "".join(out))
        words = self._number_word_re.sub(lambda m: self._number_words[m.group(0)], tokens)
        return self._repeater_re.sub(
            lambda m: " ".join([m.group(2)] * self._repeaters[m.group(1)]), words)

    def scan(self, text: str) -> list[ContactFinding]:
        norm = self.normalize(text)
        found: list[tuple[int, int, str, str]] = []
        self._find_phones(norm, found)
        _find_emails(norm, found)
        for kind, rx in self._rules:
            for m in rx.finditer(norm):
                found.append(_finding(norm, kind, m.start(), m.end()))
        ordered = sorted(set(found))[:MAX_FINDINGS]
        return [ContactFinding(kind, start, end, t) for start, end, kind, t in ordered]

    def _find_phones(self, norm: str, found: list) -> None:
        for run in _DIGIT_RUN_RE.finditer(norm):
            groups = [(g.start(), g.end()) for g in _DIGIT_GROUP_RE.finditer(norm, run.start(), run.end())]
            singles_from = [0] * (len(groups) + 1)
            for i in range(len(groups) - 1, -1, -1):
                if groups[i][1] - groups[i][0] == 1:
                    singles_from[i] = singles_from[i + 1] + 1
            i = 0
            while i < len(groups):
                first_start, first_end = groups[i]
                first_len = first_end - first_start
                anchor = singles_from[i] if first_len == 1 else first_len
                joined = ""
                all_single = True
                matched = None
                for j in range(i, len(groups)):
                    start, end = groups[j]
                    joined += norm[start:end]
                    all_single = all_single and end - start == 1
                    if len(joined) > 13:
                        break
                    if j > i and not all_single and anchor < 3:
                        break
                    if _is_kenyan_mobile(joined):
                        matched = j
                        break
                if matched is None:
                    i += 1
                else:
                    found.append(_finding(norm, KIND_PHONE, first_start, groups[matched][1]))
                    i = matched + 1
