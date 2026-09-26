"""The conversational Buying Agent - Zeno actually talking to a buyer.

WHAT CHANGED AND WHY
====================
The Buying Agent used to be a three-screen form wearing a chatbot's
clothes: type one sentence -> a single parse -> a confirmation card ->
fire. Typing "iPhone" ran a search for the word "iPhone". No model, no
storage, no budget, no chance to supply any of them - and when it came
back empty, "0 results found" with no explanation of which part of the ask
was the problem. Every advantage of having an agent (that it can ask, that
it can compromise, that it can tell you WHY) was engineered out.

This module is the agent. One endpoint, many turns:

    buyer: "I'm looking for an iPhone"
    Zeno:  "Nice - which one are you after, and roughly what's your budget?"
    buyer: "iPhone 14, at least 12GB RAM and 128GB storage"
    Zeno:  "Got it. Any ceiling on price, or shall I just go and look?"
    buyer: "don't worry about price, get on with it"
    Zeno:  [searches] "Closest I could get is two iPhone 14s, but both are
            8GB, not the 12GB you wanted. Worth a look?"

THE THREE PIECES
----------------
1. ASK-OR-SEARCH, one LLM call per turn (ai_broker.buy_agent_turn). The
   model reads the transcript, updates the gathered criteria, and either
   asks one more question or commits to searching. The model proposes; this
   module decides - see the turn policy below, which is what stops an agent
   interrogating someone forever.

2. FLEXIBLE SEARCH (matching.py). Only the constraints that would make a
   result WRONG are SQL filters. Everything else is scored, and every
   shortfall is recorded. That is what turns "0 results found" into "two,
   but they're 8GB not 12GB".

3. NARRATION (ai_broker.narrate_matches), which only ever sees rows that
   really came back. The verdict it is told to use - found it / closest I
   could get - is computed here, in Python, from the results themselves,
   because that is the sentence a buyer will act on and it is not
   something to leave to a model's mood.

STATE
-----
Deliberately stateless: the client holds the transcript and the gathered
criteria and sends both each turn, exactly as the existing Zeno chat
already does (api_service.dart's zenoChat). The slots it hands back are
re-validated first thing every turn (clean_buy_agent_slots, the same rules
the model's own output goes through) - they only ever scope that same
buyer's own search.
"""
from __future__ import annotations

import logging
from typing import Any, Dict, List, Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import Category, User
from api.domains.ai_broker.service import AIBrokerService, clean_buy_agent_slots
from api.domains.categories.seed import CATEGORY_FILTERS, SUBCATEGORY_FILTERS
from api.domains.listings.service import ListingService
from . import matching

logger = logging.getLogger(__name__)

# How many questions Zeno may ask before it has to go and look. Two is the
# difference between an agent that clarifies and one that interrogates -
# and a search on partial criteria is always recoverable (the buyer can
# refine from the results), where a fourth question is just annoying.
MAX_QUESTIONS = 2

# Candidate pool the scorer ranks over. Larger than a page on purpose:
# scoring can only find the closest thing among what it is shown, and the
# whole point of this search is that it does not hard-filter the near
# misses out before scoring ever runs.
CANDIDATE_POOL = 200

# What Zeno hands back per turn.
RESULT_LIMIT = 10


def _attribute_hints(category: Optional[str], subcategory: Optional[str]) -> List[str]:
    """The spec names actually configured for this category - so Zeno asks
    about RAM and storage for a phone, and mileage and year for a car,
    instead of a generic "any other specifications?".

    Read from the same seeded taxonomy the sell wizard renders its dynamic
    fields from (categories/seed.py), so what Zeno asks a buyer and what a
    seller was asked to fill in are the same vocabulary. Asking about a
    field no seller was ever prompted for would just manufacture misses.
    """
    hints: List[str] = []
    if category:
        for name, _kind, _opts in CATEGORY_FILTERS.get(category, []):
            hints.append(name)
        if subcategory:
            for name, _kind, _opts in SUBCATEGORY_FILTERS.get((category, subcategory), []):
                if name not in hints:
                    hints.append(name)
    return hints


async def _first_name(db: AsyncSession, user_id: str) -> str:
    name = (await db.execute(select(User.name).where(User.id == user_id))).scalar_one_or_none()
    return (name or "").strip().split(" ")[0] if name else ""


async def _taxonomy(db: AsyncSession):
    all_cats = (await db.execute(select(Category))).scalars().all()
    top = [c for c in all_cats if c.parent_id is None]
    names = [c.name for c in top]
    subs = {c.name: [s.name for s in all_cats if s.parent_id == c.id] for c in top}
    by_name = {c.name: c for c in top}
    children = {c.name: {s.name: s for s in all_cats if s.parent_id == c.id} for c in top}
    return names, subs, by_name, children


def _verdict(matches: List[dict]) -> str:
    if not matches:
        return "EMPTY"
    exact = sum(1 for m in matches if m.get("match_is_exact"))
    if exact == len(matches):
        return "EXACT"
    if exact == 0:
        return "PARTIAL"
    return "MIXED"


def _fallback_narration(matches: List[dict], unmet: List[str], verdict: str) -> str:
    """What Zeno says when the narration model is unavailable.

    Built from the same rows, so it is never wrong - just plainer. The
    Buying Agent staying usable when an AI provider is down matters more
    than it sounding warm, and every other AI path in this codebase has the
    same shape of fallback (see ai_broker/service.py).
    """
    if verdict == "EMPTY":
        return ("I couldn't find anything matching that yet. Want me to widen it — "
                "a higher budget, a wider area — or shall I keep watching and tell you "
                "the moment something turns up?")

    n = len(matches)
    plural = "" if n == 1 else "s"
    prices = [m["price"] for m in matches if m.get("price") is not None]
    price_bit = ""
    if prices:
        price_bit = (f" at KES {prices[0]:,.0f}" if len(prices) == 1
                     else f" from KES {min(prices):,.0f} to KES {max(prices):,.0f}")

    if verdict == "EXACT":
        return f"Found {n} option{plural}{price_bit} matching what you asked for. Which one shall we look at?"

    shortfall = ""
    if unmet:
        shortfall = f" None of them met your {', '.join(unmet)} though."
    return (f"Closest I could get is {n} option{plural}{price_bit}.{shortfall} "
            f"Have a look and tell me if any of these work.")


async def converse(
    db: AsyncSession,
    buyer_id: str,
    message: str,
    history: List[dict],
    slots: Optional[dict],
    questions_asked: int,
    viewer_lat: Optional[float] = None,
    viewer_lng: Optional[float] = None,
) -> dict:
    """One turn. Returns either a question or a finished search."""
    cat_names, subs_by_cat, top_by_name, children_by_cat = await _taxonomy(db)
    # The client's copy of the criteria is cleaned exactly like the model's
    # before anything reads it - the prompt, the fallbacks below and the
    # search all trusted it before (see clean_buy_agent_slots).
    slots = clean_buy_agent_slots(slots, cat_names, subs_by_cat)
    # get_current_user() carries only an id (api/security.py), so the name
    # is looked up here - an agent that can say "Found it, Xavier" instead
    # of "Found it" is most of what makes this read as a person doing you a
    # favour rather than a form submitting.
    user_name = await _first_name(db, buyer_id)

    try:
        turn = await AIBrokerService().buy_agent_turn(
            message=message,
            history=history,
            slots=slots,
            valid_categories=cat_names,
            subcategories_by_category=subs_by_cat,
            attribute_hints=_attribute_hints(slots.get("category"), slots.get("subcategory")),
            user_name=user_name,
            questions_asked=questions_asked,
            max_questions=MAX_QUESTIONS,
        )
    except Exception as exc:
        # Every AI provider being down must not take the Buying Agent screen
        # with it. _call_ai already walks four providers and a cache before
        # it gives up, so reaching here means the buyer would otherwise get
        # a 500 on the one screen whose entire job is to talk to them. Fall
        # through with what we already had: the turn policy below turns this
        # into a plain question, or - if we already know enough - a real
        # search, which needs no model at all.
        logger.warning("[buy_agent] turn model unavailable, degrading gracefully: %s", exc)
        turn = {"action": "SEARCH" if (slots.get("query") or slots.get("category")) else "ASK",
                "reply": "", "slots": slots}

    new_slots = turn.get("slots") or slots
    action = turn.get("action")

    # ── Turn policy. The model proposes; these three rules decide. ──────────
    # 1. Out of questions -> search with whatever we have. An agent that
    #    keeps asking is worse than one that shows you its best guess.
    if action == "ASK" and questions_asked >= MAX_QUESTIONS:
        action = "SEARCH"
    # 2. Nothing to search FOR -> ask, whatever the model said. Searching on
    #    an empty criteria set returns the whole marketplace, which is not
    #    an answer to anything.
    if action == "SEARCH" and not (new_slots.get("query") or new_slots.get("category")):
        action = "ASK"
        turn["reply"] = ""
    # 3. The model said ASK but gave us no question -> don't send an empty
    #    bubble. This also covers the unusable-JSON path.
    if action == "ASK" and not turn.get("reply"):
        turn["reply"] = (
            "Sorry — what is it you're looking for? Tell me the item and anything "
            "that matters to you about it."
            if not (new_slots.get("query") or new_slots.get("category"))
            else "Got it. Anything else that matters — budget, condition, how far you'll travel?"
        )

    if action == "ASK":
        return {
            "phase": "ASKING",
            "reply": turn["reply"],
            "slots": new_slots,
            "questions_asked": questions_asked + 1,
            "matches": [],
        }

    results, unmet = await search_for(
        db, new_slots, buyer_id,
        top_by_name=top_by_name, children_by_cat=children_by_cat,
        viewer_lat=viewer_lat, viewer_lng=viewer_lng,
    )
    verdict = _verdict(results)

    reply = ""
    try:
        reply = await AIBrokerService().narrate_matches(
            slots=new_slots, matches=results, unmet=unmet, verdict=verdict, user_name=user_name,
        )
    except Exception as exc:
        logger.warning("[buy_agent] narration failed, using deterministic reply: %s", exc)
    if not reply:
        reply = _fallback_narration(results, unmet, verdict)

    return {
        "phase": "RESULTS",
        "reply": reply,
        "slots": new_slots,
        # Budget reset. MAX_QUESTIONS is "questions before a search", not a
        # lifetime allowance: once the buyer is looking at real results, the
        # next thing they say is usually about those results ("what's the
        # difference?", "the 76k one") and Zeno should be free to answer or
        # ask rather than being forced into another blind search by an
        # exhausted counter. The cap still applies to the run-up to each
        # subsequent search.
        "questions_asked": 0,
        "matches": results,
        "verdict": verdict,
        "unmet": unmet,
    }


async def search_for(
    db: AsyncSession,
    slots: dict,
    buyer_id: str,
    top_by_name: Dict[str, Any],
    children_by_cat: Dict[str, Dict[str, Any]],
    viewer_lat: Optional[float] = None,
    viewer_lng: Optional[float] = None,
) -> tuple[List[dict], List[str]]:
    """Hard-filter to what would otherwise be plain wrong, then score.

    Note what is NOT passed to list_listings: price, condition, attributes
    and distance. Those are the buyer's preferences, and handing them to
    SQL is what produced "0 results found" - the near miss is filtered out
    before anything can notice it was a near miss. They are scored in
    matching.py instead, which is the entire difference between this and
    the old SEARCH_PRODUCTS path.
    """
    category_name = None
    subcategory_id = None
    cat = top_by_name.get(slots.get("category")) if slots.get("category") else None
    if cat is not None:
        category_name = cat.name
        sub = children_by_cat.get(cat.name, {}).get(slots.get("subcategory")) if slots.get("subcategory") else None
        subcategory_id = sub.id if sub is not None else None

    # The top-level category is the only taxonomy filter applied in SQL.
    # subcategory_id goes to the scorer instead: it is nullable on Listing
    # and routinely null, so filtering on it would drop exactly the
    # obviously-right listing this search exists to find. See matching.py.
    svc = ListingService(db)
    scope = dict(category=category_name, viewer_lat=viewer_lat, viewer_lng=viewer_lng,
                 sort=None, offset=0, limit=CANDIDATE_POOL)
    # FIX (buying-agent review, 2026-09-26): the pool used to be only the
    # category's top CANDIDATE_POOL by BROKA ranking, with the buyer's words
    # playing no part in which rows got in - so in a category busier than
    # the pool (or with no category at all: the whole marketplace), the
    # listing a buyer named exactly could rank outside it, and Zeno said
    # "closest I could get" over unrelated items. Listings carrying every
    # word of the query are fetched first; the ranked pool is still added
    # after them, because it is where the near misses come from.
    pool: List[dict] = []
    if slots.get("query"):
        pool = await svc.list_listings(search=slots["query"], **scope)
    seen = {p["id"] for p in pool}
    pool += [p for p in await svc.list_listings(**scope) if p["id"] not in seen]

    # A buyer's own listings are never an answer to their own search - same
    # rule the standing-request matcher applies (core/buy_agent_subscribers.py).
    candidates = [p for p in pool if p.get("seller_id") != buyer_id]

    criteria = {
        "query": slots.get("query"),
        "max_price": slots.get("max_price"),
        "min_price": slots.get("min_price"),
        "condition": slots.get("condition"),
        "max_distance_km": slots.get("max_distance_km") if viewer_lat is not None else None,
        "attributes": slots.get("attributes") or {},
        "subcategory_id": subcategory_id,
    }
    return matching.rank(candidates, criteria, limit=RESULT_LIMIT)
