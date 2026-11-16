"""What people call each provider - built from the catalogue, not typed in.

Zeno's walkthrough used to carry its own alias list, so a provider added,
renamed or suspended in the catalogue still answered to its old name there.
The names come from the records now.

TWO RULES THAT MATTER
  * Whole words only. "e confirm" is inside "please confirm"; a user saying
    "please confirm" mid-walkthrough was switched to eConfirm once already.
  * Longest alias first, and a span is claimed once. "kenya escrow" and
    "escrow kenya" are different companies; neither may be read as the
    other, and "escrow" alone (a common word) is not an alias at all.
"""
from __future__ import annotations

import re
from typing import Iterable, Optional


def aliases_for(record: dict) -> list[str]:
    """Lower-case names a person might use for [record], longest first."""
    name = record["display_name"].lower()
    domain = record["identity"]["canonical_domain"]
    stem = domain.split(".")[0]
    names = {name, record["id"], domain, f"www.{domain}", stem, name.replace(" ", ""),
             name.replace("-", " "), name.replace("-", "")}
    # "econfirm" -> "e-confirm" / "e confirm": a one-letter prefix is how
    # people write it.
    if len(stem) > 2 and stem[0] == "e" and stem[1:] == name.replace(" ", "")[1:]:
        names.update({f"e-{stem[1:]}", f"e {stem[1:]}"})
    if " " in name:
        names.add(name.replace(" ", "-"))
    names = {n.strip() for n in names if len(n.strip()) >= 4}
    return sorted(names, key=lambda n: (-len(n), n))


def _pattern(alias: str) -> "re.Pattern[str]":
    return re.compile(rf"(?<![a-z0-9]){re.escape(alias)}(?![a-z0-9])")


def mentions(text: str, records: Iterable[dict]) -> list[dict]:
    """The records [text] names, in the order they appear, each once.

    Overlapping matches are resolved to the longest alias, so one span of
    text names one provider."""
    t = (text or "").lower()
    found: list[tuple[int, int, dict]] = []
    for record in records:
        for alias in aliases_for(record):
            for m in _pattern(alias).finditer(t):
                found.append((m.start(), m.end(), record))
    found.sort(key=lambda f: (f[0], -(f[1] - f[0])))
    taken_to = -1
    out: list[dict] = []
    seen: set[str] = set()
    for start, end, record in found:
        if start < taken_to:
            continue
        taken_to = end
        if record["id"] not in seen:
            seen.add(record["id"])
            out.append(record)
    return out


def first_mention(text: str, records: Iterable[dict]) -> Optional[dict]:
    hits = mentions(text, records)
    return hits[0] if hits else None
