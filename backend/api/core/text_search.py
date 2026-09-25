"""What a typed search box means to a query.

Listing search (GET /listings/?search=) and trader search (GET
/traders?search=) both take whatever a user typed into a phone. Two things
went wrong when that text went straight into `column.ilike(f"%{text}%")`:

  * The whole phrase had to appear, in order. "samsung a54" never found
    "Galaxy A54 (Samsung)", and "13 pro iphone" never found "iPhone 13 Pro".
    Every word is now its own condition, and a listing has to match all of
    them - in any order, in any of the searched columns.
  * `%` and `_` in the text are LIKE wildcards. The bound parameter stops
    injection, not pattern semantics, so a search for "_" matched every
    listing and "100%" matched "100 kg". They are escaped now and mean
    themselves.

Plain LIKE rather than a full-text index, on purpose: it is identical on
SQLite (tests, local dev) and PostgreSQL (production), which a tsvector or
FTS5 index is not.
"""
from __future__ import annotations

import re

from sqlalchemy import and_, or_

# Bounds the work one request can ask for: a pasted paragraph becomes eight
# conditions, not two hundred.
MAX_TERMS = 8

_ESCAPE = "\\"


def search_terms(text: str | None) -> list[str]:
    """The distinct words of [text], lower-cased, in order, at most MAX_TERMS."""
    if not text:
        return []
    seen: list[str] = []
    for word in re.split(r"\s+", text.strip().lower()):
        if word and word not in seen:
            seen.append(word)
        if len(seen) == MAX_TERMS:
            break
    return seen


def contains_pattern(term: str) -> str:
    """A LIKE pattern matching [term] anywhere, with its own wildcards escaped.

    Use with `ESCAPE '\\'` - see [matches_all_terms].
    """
    escaped = (
        term.replace(_ESCAPE, _ESCAPE * 2)
        .replace("%", _ESCAPE + "%")
        .replace("_", _ESCAPE + "_")
    )
    return f"%{escaped}%"


def term_matches(term: str, columns):
    """True where any of [columns] contains [term], case-insensitively."""
    pattern = contains_pattern(term)
    return or_(*(col.ilike(pattern, escape=_ESCAPE) for col in columns))


def matches_all_terms(terms: list[str], columns):
    """True where every term appears in at least one of [columns]."""
    return and_(*(term_matches(t, columns) for t in terms))
