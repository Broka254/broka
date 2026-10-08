"""Zeno listing an item from its photo (2026-10-08).

Sellers asked for this: "I only upload the photo to Zeno and Zeno handles
the rest". The seller takes the camera-verified photos as always; then,
instead of ten steps of forms, Zeno and the seller talk:

  1. LOOK (POST /zeno/listing-draft/autolist): Zeno looks at the first photo
     and fills the listing in - title, category and subcategory, condition,
     the category's details, the description - and asks for what the photo
     can't show (battery health, mileage, a title deed). Spends one of the
     plan's AI descriptions: the same costly look at a photo as the
     Description step's card, under the same allowance (PRICING.md
     section 4), given back if nothing came of it.
  2. TALK (POST /zeno/listing-draft/autolist/turn): the seller answers, or
     corrects ("it's the 256 GB one"), and Zeno folds it into the whole
     listing - a corrected model is a new title, not only a new line. Free
     once the plan has descriptions, as describe_turn is.
  3. PRICE (POST /zeno/listing-draft/autolist/price): a fair range and the
     one number to ask. On a plan with price checks it is grounded on
     similar live BROKA listings (selling.comparables) and spends one; on
     any other it is Zeno's general estimate, and says so.

The cover is the existing POST /showcase/preview. Nothing here creates a
listing: the app puts the result into the sell wizard, and the seller
finishes what Zeno can't know (how many, where) and reviews all of it
before anything is published.

Everything a model says is checked before the app sees it. The category
must be one of BROKA's (a made-up one would be a 400 at publish, or a
listing filed where no buyer looks); the details are kept only under the
names the category's own fields use, with a select field's value one of
its options; and a price must be one the wizard could list.
"""
from __future__ import annotations

import logging
import math
import re
from typing import Optional

from fastapi import HTTPException
from sqlalchemy.ext.asyncio import AsyncSession

from api.domains.listings.validation import (
    CONDITIONS,
    LAND_CATEGORY,
    LAND_SIZE_UNITS,
    MAX_DESCRIPTION_LEN,
    MAX_NAME_LEN,
    MIN_NAME_LEN,
)
from api.domains.premium import entitlements
from . import selling

logger = logging.getLogger(__name__)

# Kinds of item whose condition isn't a question - the sell wizard's
# Details step asks none for them either.
NO_CONDITION = {"land", "property", "services", "food & beverages"}

_ATTR_VALUE_MAX = 60
_MAX_ATTRIBUTES = 12
# A number in a model's value: "85,000 km" -> 85000, "6.5 inches" -> 6.5.
_NUMBER = re.compile(r"\d[\d,]*(?:\.\d+)?")


class Taxonomy:
    """BROKA's categories as a model is shown them and as its picks are
    checked: names matched without regard to case, an old name read as
    the new one ("Vehicles" is Automobiles)."""

    def __init__(self, names: list[str], subs: dict[str, list[str]], top_by_name: dict,
                 children_by_cat: dict[str, dict]):
        self.names = names
        self.subs = subs
        self.top_by_name = top_by_name
        self.children_by_cat = children_by_cat
        self._top_lower = {n.lower(): n for n in names}

    @classmethod
    async def load(cls, db: AsyncSession) -> "Taxonomy":
        from api.domains.buy_agent.conversation import _taxonomy
        return cls(*await _taxonomy(db))

    def prompt(self) -> str:
        return "\n".join(
            f"- {name}: {', '.join(self.subs.get(name) or [])}" if self.subs.get(name) else f"- {name}"
            for name in self.names
        )

    def category(self, value) -> Optional[str]:
        if not isinstance(value, str) or not value.strip():
            return None
        from api.domains.categories.seed import canonical_category_name
        name = canonical_category_name(" ".join(value.split()))
        return self._top_lower.get(str(name).lower())

    def subcategory(self, category: Optional[str], value) -> Optional[str]:
        if not category or not isinstance(value, str) or not value.strip():
            return None
        wanted = " ".join(value.split()).lower()
        return next((s for s in self.subs.get(category) or [] if s.lower() == wanted), None)

    def parent_of(self, subcategory) -> Optional[str]:
        """The one category a subcategory name belongs to - for a model
        that named the right type of item under the wrong category."""
        if not isinstance(subcategory, str) or not subcategory.strip():
            return None
        wanted = " ".join(subcategory.split()).lower()
        owners = {c for c in self.names if any(s.lower() == wanted for s in self.subs.get(c) or [])}
        return owners.pop() if len(owners) == 1 else None

    def ids(self, category: Optional[str], subcategory: Optional[str]) -> tuple[Optional[str], Optional[str]]:
        top = self.top_by_name.get(category) if category else None
        sub = (self.children_by_cat.get(category) or {}).get(subcategory) if subcategory else None
        return (top.id if top is not None else None, sub.id if sub is not None else None)


def _one_line(value, limit: int) -> str:
    return " ".join(str(value or "").split())[:limit]


def _fields_for(category: Optional[str], subcategory: Optional[str]) -> dict[str, tuple[str, Optional[list]]]:
    """The details this kind of item is described by, as the sell wizard
    asks for them (categories/seed.py): name -> (kind, options)."""
    from api.domains.categories.seed import CATEGORY_FILTERS, SUBCATEGORY_FILTERS

    fields: dict[str, tuple[str, Optional[list]]] = {}
    for name, kind, options in SUBCATEGORY_FILTERS.get((category, subcategory), []) if subcategory else []:
        fields[name] = (kind, options)
    for name, kind, options in CATEGORY_FILTERS.get(category or "", []):
        fields.setdefault(name, (kind, options))
    # Derived on the server from the size and its unit, never typed.
    fields.pop("land_size_acres", None)
    return fields


def _key(value) -> str:
    return re.sub(r"[^a-z0-9]+", "_", str(value or "").strip().lower()).strip("_")


def _number(value) -> Optional[str]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    else:
        found = _NUMBER.search(str(value or ""))
        if not found:
            return None
        try:
            number = float(found.group(0).replace(",", ""))
        except ValueError:
            return None
    if not math.isfinite(number) or number < 0:
        return None
    # Four places, as the server keeps a land size: an eighth of an acre
    # is 0.125, not 0.12.
    return str(int(number)) if number.is_integer() else f"{number:.4f}".rstrip("0").rstrip(".")


def _option(value, options: list) -> Optional[str]:
    """A select field's value as one of its options: "8 GB" is "8GB",
    and "256GB" is the "256GB+" option."""
    wanted = re.sub(r"\s+", "", str(value or "")).lower()
    if not wanted:
        return None
    for option in options:
        plain = re.sub(r"\s+", "", str(option)).lower()
        if wanted == plain or wanted == plain.rstrip("+"):
            return option
    return None


def _land_size(attributes: dict) -> dict:
    """A Land listing's size, kept only when it is a number in a unit the
    server takes (validation.clean_land_details) - half a size is a
    question for the seller, not a value."""
    from api.domains.listings.validation import _LAND_UNIT_ALIASES

    size = _number(attributes.get("land_size"))
    unit_raw = " ".join(str(attributes.get("land_size_unit") or "").split()).lower()
    unit = _LAND_UNIT_ALIASES.get(unit_raw, unit_raw)
    if size is None or float(size) <= 0 or unit not in LAND_SIZE_UNITS:
        return {}
    return {"land_size": size, "land_size_unit": unit}


def clean_attributes(raw, category: Optional[str], subcategory: Optional[str]) -> dict[str, str]:
    """The model's details, kept only under the names this category's own
    fields use and in their shape: a number for a number, one of the
    options for a choice. Anything else is in the description lines
    already, where a buyer reads it; as an attribute it would be a filter
    no buyer can use."""
    if not isinstance(raw, dict):
        return {}
    given = {_key(k): v for k, v in raw.items() if v not in (None, "", [], {})}
    fields = _fields_for(category, subcategory)
    out: dict[str, str] = {}
    for name, (kind, options) in fields.items():
        value = given.get(name)
        if value is None or isinstance(value, (dict, list)):
            continue
        if kind == "select":
            cleaned = _option(value, options or [])
        elif kind == "number_range":
            cleaned = _number(value)
        else:
            cleaned = _one_line(value, _ATTR_VALUE_MAX) or None
        if cleaned is not None:
            out[name] = cleaned
        if len(out) >= _MAX_ATTRIBUTES:
            break
    if category == LAND_CATEGORY:
        out.update(_land_size(given))
    return out


def clean_listing(raw, taxonomy: Taxonomy, previous: Optional[dict] = None) -> dict:
    """The listing a model filled in, checked: {"name", "category",
    "category_id", "subcategory", "subcategory_id", "condition",
    "attributes", "description"} plus the description's blank labels
    ("blanks"), which are questions it should have asked.

    [previous] is the listing as it stood before this turn: what a model
    leaves out or gets wrong falls back to it rather than to nothing - a
    seller answering "128 GB" must not lose the category."""
    raw = raw if isinstance(raw, dict) else {}
    previous = previous or {}

    name = _one_line(raw.get("name"), MAX_NAME_LEN)
    if len(name) < MIN_NAME_LEN:
        name = _one_line(previous.get("name"), MAX_NAME_LEN)

    category = taxonomy.category(raw.get("category")) or taxonomy.parent_of(raw.get("subcategory"))
    if category is None:
        category = taxonomy.category(previous.get("category"))
    subcategory = taxonomy.subcategory(category, raw.get("subcategory"))
    if subcategory is None and category == taxonomy.category(previous.get("category")):
        subcategory = taxonomy.subcategory(category, previous.get("subcategory"))
    category_id, subcategory_id = taxonomy.ids(category, subcategory)

    condition = raw.get("condition") if raw.get("condition") in CONDITIONS else previous.get("condition")
    if condition not in CONDITIONS or (category or "").lower() in NO_CONDITION:
        condition = None

    attributes = clean_attributes(raw.get("attributes"), category, subcategory)
    if not attributes and previous.get("category") == category:
        attributes = clean_attributes(previous.get("attributes"), category, subcategory)

    description, blanks = selling.clean_description(
        "\n".join(str(line) for line in raw["description"])
        if isinstance(raw.get("description"), list) else raw.get("description"))
    if not description:
        description, _ = selling.clean_description(previous.get("description"))

    return {
        "name": name,
        "category": category,
        "category_id": category_id,
        "subcategory": subcategory,
        "subcategory_id": subcategory_id,
        "condition": condition,
        "attributes": attributes,
        "description": description[:MAX_DESCRIPTION_LEN],
        "blanks": blanks,
    }


def listing_lines(listing: dict) -> list[str]:
    """The listing as "Field: value" lines, for the next turn's prompt."""
    lines = []
    if listing.get("name"):
        lines.append(f"Name: {_one_line(listing['name'], MAX_NAME_LEN)}")
    if listing.get("category"):
        sub = f" > {_one_line(listing['subcategory'], 60)}" if listing.get("subcategory") else ""
        lines.append(f"Category: {_one_line(listing['category'], 60)}{sub}")
    if listing.get("condition") in CONDITIONS:
        lines.append(f"Condition: {listing['condition']}")
    attributes = listing.get("attributes") if isinstance(listing.get("attributes"), dict) else {}
    for key, value in list(attributes.items())[:_MAX_ATTRIBUTES]:
        lines.append(f"Attribute {_one_line(key, 30)}: {_one_line(value, _ATTR_VALUE_MAX)}")
    if listing.get("description"):
        lines.append("Description:\n" + str(listing["description"])[:MAX_DESCRIPTION_LEN])
    return lines


def _answer(listing: dict, questions: list[dict], reply: str) -> dict:
    public = {k: v for k, v in listing.items() if k != "blanks"}
    return {"reply": reply, "listing": public, "questions": questions}


def _default_reply(listing: dict, questions: list[dict], first_look: bool) -> str:
    where = listing.get("category")
    if listing.get("subcategory"):
        where = f"{where} › {listing['subcategory']}"
    if first_look:
        start = (f"This looks like {listing['name']} - I've filed it under {where}."
                 if listing.get("name") and where else "Here's your listing from the photo.")
        return f"{start} A few things buyers will ask:" if questions else f"{start} Check it over."
    return ("Got it. A few things are still open:" if questions
            else "Got it - your listing is ready for a price.")


async def look(
    db: AsyncSession,
    user_id: str,
    known: dict,
    language: str,
    photo_id: Optional[str] = None,
    image_base64: Optional[str] = None,
) -> dict:
    """{"reply", "listing", "questions"} from Zeno's look at the photo,
    spending one of the plan's AI descriptions - given back if nothing came
    of it. [known] is whatever the seller had already entered (a draft
    they started by hand), in the shape ListingDraftIn takes."""
    from api.core.vision import ImageRejected, prepare_for_model
    from api.domains.ai_broker.service import AIBrokerService
    from api.routers.negotiate import _language_instruction  # router module; imported late

    # The photo first: one that can't be used must not cost a description.
    if photo_id:
        image = await selling._photo_from_asset(db, user_id, photo_id)
    elif image_base64:
        try:
            image = await prepare_for_model(image_base64)
        except ImageRejected as exc:
            raise HTTPException(status_code=422, detail=str(exc))
    else:
        raise HTTPException(status_code=400, detail="Take a photo of the item first - Zeno lists it from the photo.")

    taxonomy = await Taxonomy.load(db)
    await entitlements.consume(db, user_id, entitlements.Feature.AI_DESCRIPTION)
    try:
        turn = await AIBrokerService().autolist_look(
            image_base64=image,
            taxonomy=taxonomy.prompt(),
            known=selling.draft_lines({**known, "asking_price": None}),
            language_instruction=_language_instruction(language),
        )
    except Exception:
        await entitlements.release(db, user_id, entitlements.Feature.AI_DESCRIPTION)
        raise
    seed = {k: known.get(k) for k in ("name", "category", "subcategory", "condition", "attributes",
                                       "description")}
    listing = clean_listing(turn.get("listing"), taxonomy, previous=seed)
    questions = selling.clean_questions(turn.get("questions"), listing["description"], listing["blanks"])
    if turn.get("listing") is None or not (listing["name"] and listing["description"]):
        # Nothing a seller could build on: the look didn't happen.
        await entitlements.release(db, user_id, entitlements.Feature.AI_DESCRIPTION)
        raise HTTPException(status_code=502, detail="Zeno couldn't make out the item. Please try again, "
                                                    "or take a clearer photo in good light.")
    return _answer(listing, questions, turn.get("reply") or _default_reply(listing, questions, first_look=True))


async def turn(
    db: AsyncSession,
    user_id: str,
    listing: dict,
    questions: list[dict],
    message: str,
    history: list[dict],
    language: str,
) -> dict:
    """One turn of the seller answering or correcting Zeno: the whole
    listing back with their words folded in, and what is still open.

    Free once the plan has descriptions (require, not consume): the photo
    was counted on the first look, and this is a typed Zeno turn about it."""
    from api.domains.ai_broker.service import AIBrokerService
    from api.routers.negotiate import _language_instruction  # router module; imported late

    await entitlements.require(db, user_id, entitlements.Feature.AI_DESCRIPTION)
    taxonomy = await Taxonomy.load(db)
    before = clean_listing(listing, taxonomy)
    answered = await AIBrokerService().autolist_turn(
        listing=listing_lines(before),
        questions=questions,
        message=message,
        history=history,
        taxonomy=taxonomy.prompt(),
        language_instruction=_language_instruction(language),
    )
    # A model that lost the thread (prose, no listing) must not take the
    # seller's listing with it: what they had stands.
    after = clean_listing(answered.get("listing"), taxonomy, previous=before) \
        if answered.get("listing") is not None else before
    still_open = answered.get("questions")
    still_open = selling.clean_questions(questions if still_open is None else still_open,
                                         after["description"], after["blanks"])
    return _answer(after, still_open,
                   answered.get("reply") or _default_reply(after, still_open, first_look=False))


def _clean_range(low, high, suggested) -> Optional[tuple[int, int, int]]:
    """(low, high, suggested) as whole KES the wizard could list, in
    order - or None. A suggestion outside its own range is moved into it;
    a range with no suggestion is suggested at its middle."""
    low, high, suggested = (selling._clean_price(v) for v in (low, high, suggested))
    if low is None and high is None and suggested is None:
        return None
    if low is None or high is None:
        if suggested is None:
            return None
        low = low or suggested
        high = high or suggested
    if low > high:
        low, high = high, low
    if suggested is None:
        suggested = round((low + high) / 2)
    return low, high, min(max(suggested, low), high)


def _range_from(found: dict) -> Optional[tuple[int, int, int]]:
    """The range BROKA's own listings give: their middle half once there
    are enough for one, else lowest to highest, around the median."""
    if not found or not found.get("count"):
        return None
    low = found.get("typical_low") if found.get("typical_low") is not None else found["low"]
    high = found.get("typical_high") if found.get("typical_high") is not None else found["high"]
    return _clean_range(low, high, found.get("median"))


async def price(
    db: AsyncSession,
    user_id: str,
    draft: dict,
    language: str,
) -> dict:
    """The range and the one number to ask: {"reply", "low", "high",
    "suggested_price", "basis", "comparables", "can_check_broka"}.

    basis is "broka" when the range stands on similar live BROKA listings -
    on a plan with price checks, which spends one - and "estimate" when it
    is Zeno's general knowledge. can_check_broka says whether the plan has
    checks at all: without them the app offers Pro rather than a button
    the server would refuse."""
    from api.domains.ai_broker.service import AIBrokerService
    from api.routers.negotiate import _language_instruction  # router module; imported late

    await entitlements.require(db, user_id, entitlements.Feature.AI_DESCRIPTION)
    found = None
    can_check = await _has(db, user_id, entitlements.Feature.PRICE_CHECK)
    if can_check:
        try:
            await entitlements.consume(db, user_id, entitlements.Feature.PRICE_CHECK)
        except HTTPException as exc:
            # This month's checks are spent: an estimate still prices it.
            if exc.status_code != 402:
                raise
        else:
            try:
                found = await selling.comparables(db, user_id, draft)
            except Exception:
                await entitlements.release(db, user_id, entitlements.Feature.PRICE_CHECK)
                raise
    grounded = _range_from(found)

    try:
        answer = await AIBrokerService().autolist_price(
            draft="\n".join(selling.draft_lines({**draft, "asking_price": None})) or "(nothing yet)",
            comparables=selling._comparables_block(found) if found is not None else None,
            language_instruction=_language_instruction(language),
        )
    except Exception as exc:
        logger.warning("[zeno_autolist] pricing model unavailable: %s", exc)
        answer = {"reply": "", "low": None, "high": None, "suggested_price": None}

    priced = _clean_range(answer.get("low"), answer.get("high"), answer.get("suggested_price"))
    if grounded is not None and priced is not None:
        # The model weighs condition and details against the listings, but
        # a range it made up beside BROKA's own numbers is no range: its
        # number is kept only where the listings put it.
        priced = (grounded[0], grounded[1], min(max(priced[2], grounded[0]), grounded[1]))
    priced = priced or grounded
    if priced is None:
        raise HTTPException(status_code=502, detail="Zeno couldn't price it right now. "
                                                    "Please try again, or set your own price.")
    reply = answer.get("reply") or (
        f"Similar listings on BROKA ask KES {priced[0]:,}-{priced[1]:,}. I'd ask KES {priced[2]:,}."
        if grounded is not None else
        f"My estimate is KES {priced[0]:,}-{priced[1]:,}. I'd ask KES {priced[2]:,}.")
    return {
        "reply": reply,
        "low": priced[0],
        "high": priced[1],
        "suggested_price": priced[2],
        "basis": "broka" if grounded is not None else "estimate",
        "comparables": found,
        "can_check_broka": can_check,
    }


async def _has(db: AsyncSession, user_id: str, feature: str) -> bool:
    """Whether the user's plan includes [feature] at all (or premium is
    off, when everything does)."""
    try:
        await entitlements.require(db, user_id, feature)
        return True
    except HTTPException as exc:
        if exc.status_code != 402:
            raise
        return False
