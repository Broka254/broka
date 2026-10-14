"""How a buyer gets what a listing sells: delivered, or not movable at all.

Most listings are goods that travel - the seller delivers, or the buyer
collects. Land and buildings don't move. Asking their seller "can you
arrange delivery?" is nonsense, and telling a buyer "the seller delivers"
about a plot is worse: Zeno would promise it. For these the buyer views the
property where it is, and ownership passes by a title transfer (the escrow
release already asks about the documents - escrow/policy.py's
OWNERSHIP_TRANSFER_CATEGORIES, which adds vehicles: a car moves, so it can
still be delivered, but its logbook must transfer too).

Top-level category names (api/domains/categories/seed.py), lower-cased.
"""
from __future__ import annotations

from typing import Optional

NOT_DELIVERABLE_CATEGORIES = frozenset({"land", "property"})

# What buyers and Zeno are told instead of a delivery answer.
IN_PLACE_NOTE = (
    "Not delivered - it stays where it is. The buyer views it on site, and "
    "ownership passes by a title transfer."
)


def is_deliverable(category: Optional[str]) -> bool:
    return not (bool(category) and category.strip().lower() in NOT_DELIVERABLE_CATEGORIES)


def handover(category: Optional[str]) -> str:
    """"delivery" (delivered or collected) or "in_place" (viewed on site, title transfer)."""
    return "delivery" if is_deliverable(category) else "in_place"
