"""One turn of Zeno as the user's assistant - text or voice, it is the same
turn.

    message -> ESCROW WALKTHROUGH (one step at a time, no model) when the
               message starts one or answers one (escrow_walkthrough.py)
            -> FAST PATH (plain commands and how-to guides, no model)
            -> or MODEL (talk, and propose at most one action), given the
               user's own data for the topics the question is about
               -> if it asks for data it wasn't given (NEED_INFO): fetch it
                  and ask once more - never more than two model calls
            -> CLEAN (closed vocabulary)  -> RESOLVE (whose conversation?)
            -> {reply, action}

What costs money here is model calls and prompt size, so: commands and
guides take none; data goes in only for the topics a question is about
(knowledge.topics_for); and the second call happens only when the model
asks for data the rules did not foresee.

The app does what the action says: opens a screen, runs a search, hands a
shopping request to the Buying Agent, opens a chat - and, for a CALL, puts
a confirmation in front of the user and only then goes through
POST /calls/initiate, the one path in BROKA that can ring a phone. This
module never rings, sends or changes anything; like every other Zeno
action (ZENO_ACTIONS.md), a misheard or talked-into proposal costs at most
a button the user doesn't press.

Stateless, like the Buying Agent: the app sends the transcript each turn.
"""
from __future__ import annotations

import logging
import re
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import User
from api.domains.ai_broker.service import AIBrokerService
from . import contacts, escrow_walkthrough, guides, intents, knowledge, listing_context

logger = logging.getLogger(__name__)

# How many people Zeno offers when "call Jane" fits more than one.
MAX_CHOICES = 4

_SCREEN_NAMES = {
    "home": ("Home", "Nyumbani"),
    "inbox": ("your inbox", "ujumbe wako"),
    "sell": ("Sell", "Uza"),
    "menu": ("the menu", "menyu"),
    "profile": ("your profile", "wasifu wako"),
    "settings": ("Settings", "mipangilio"),
    "search": ("Search", "utafutaji"),
    "buying_agent": ("the Buying Agent", "wakala wa ununuzi"),
    "seller_dashboard": ("your seller dashboard", "dashibodi yako ya muuzaji"),
    "deal_history": ("your deals", "mikataba yako"),
    "verify": ("verification", "uthibitisho"),
    "market_insights": ("market insights", "maarifa ya soko"),
    "how_broka_works": ("how BROKA works", "jinsi BROKA inavyofanya kazi"),
    "store_setup": ("store setup", "kufungua duka"),
    "my_store": ("your store", "duka lako"),
    "start_selling": ("Start selling", "anza kuuza"),
    "escrow_services": ("the escrow services", "huduma za escrow"),
}

# Under a model's reply while an escrow walkthrough is under way: the way
# back to the steps after a question. And under any reply about escrow
# that didn't start one.
_RESUME = ["Done - what's next?", "Repeat this step"]
_OFFER_WALKTHROUGH = ["Walk me through it step by step"]


def _sw(language: str) -> bool:
    return (language or "").lower() in ("swahili", "sheng")


def _confirmation(action: dict, language: str) -> str:
    """Zeno's line for a command it recognised without the model."""
    sw = _sw(language)
    kind = action["type"]
    if kind == "NAVIGATE":
        name = _SCREEN_NAMES.get(action["destination"], (action["destination"],) * 2)[1 if sw else 0]
        return f"Nafungua {name}." if sw else f"Opening {name}."
    if kind == "SEARCH":
        q = action["query"]
        return f"Natafuta \"{q}\"." if sw else f"Searching for \"{q}\"."
    if kind == "GUIDE":
        title = (action.get("guide_content") or {}).get("title", "")
        return f"{title} - hatua hizi hapa." if sw else f"{title} - here's how."
    if kind == "FIND_FOR_ME":
        return ("Nimempa Wakala wa Ununuzi - atakuuliza machache kisha atafute."
                if sw else "Handing that to the Buying Agent - it'll ask a question or two, then go looking.")
    target = action.get("target") or {}
    who = (target.get("peer_name") or "").split(" ")[0] or action.get("contact", "")
    if kind == "CALL":
        video = action.get("call_type") == "video"
        if sw:
            return f"Nampigia {who} simu ya {'video' if video else 'sauti'} - thibitisha tu."
        return f"{'Video calling' if video else 'Calling'} {who} - just confirm."
    return f"Nafungua mazungumzo yako na {who}." if sw else f"Opening your chat with {who}."


def _no_match(action: dict, language: str) -> str:
    who = action.get("contact", "")
    if _sw(language):
        return (f"Sijampata \"{who}\" kwenye mazungumzo yako. Naweza kupiga au kufungua "
                "mazungumzo na watu unaoongea nao kwenye BROKA tu.")
    return (f"I couldn't find \"{who}\" in your conversations. I can only call or open chats "
            "with people you're already talking to on BROKA.")


def _choose(choices: list[dict], language: str) -> str:
    names = [f"{c['peer_name']} ({c['listing_name']})" if c.get("listing_name") else c["peer_name"]
             for c in choices]
    word = "au" if _sw(language) else "or"
    listed = names[0] if len(names) == 1 else ", ".join(names[:-1]) + f" {word} {names[-1]}"
    return f"Yupi - {listed}?" if _sw(language) else f"Which one - {listed}?"


def _offer(action: dict, language: str) -> str:
    """Zeno's line for a search it offers, about a listing, and waits on."""
    q = action["query"]
    if _sw(language):
        return f"Nikutafutie \"{q}\" badala yake?"
    return f"Want me to look for \"{q}\" instead?"


def _gone(language: str) -> str:
    """Asked from a listing buyers can no longer see. The model used to be
    asked anyway, with no listing to read - "is this a fair price?" about
    nothing."""
    if _sw(language):
        return ("Siwezi kufungua tangazo hilo tena - huenda limeondolewa au halipo BROKA kwa sasa. "
                "Niambie unachotafuta nikusaidie kupata kingine.")
    return ("I can't open that listing any more - it may have been removed, or it's off BROKA "
            "for now. Tell me what you're after and I'll help you find another.")


def _finding_similar(action: dict, language: str) -> str:
    """Zeno's line for "find me something similar", handed to the Buying Agent."""
    title = ((action.get("slots") or {}).get("query") or "").strip()
    if _sw(language):
        return f"Natafuta bidhaa kama \"{title}\" - Wakala wa Ununuzi anaanza sasa."
    return f"Looking for listings like \"{title}\" - the Buying Agent is on it."


# The user talking about themselves - "my rating", "show me my sales".
# Asked from someone else's listing, anything else about trust, reviews
# or sales is about the seller.
_ABOUT_THEMSELF = re.compile(r"\b(?:my|mine|myself|yangu|wangu|changu|zangu|langu)\b", re.IGNORECASE)


def is_free_turn(message: str, history: list[dict], image_base64: Optional[str] = None) -> bool:
    """A turn that is never one of the day's Zeno sessions: a step of the
    escrow walkthrough, which no model answers (escrow_walkthrough.py).
    Paying safely is not something to ration."""
    if image_base64:
        return False
    return escrow_walkthrough.turn(intents.normalise(message), history) is not None


async def listing_access(db: AsyncSession, user_id: str, listing_id: str) -> str:
    """listing_context.OWN, VISIBLE or GONE - for the router, which counts
    a session only for questions about someone else's listing."""
    return await listing_context.access(db, user_id, listing_id)


async def _aim_at_listing(db: AsyncSession, user_id: str, listing_id: str, action: dict) -> dict:
    """A search asked for from a listing, aimed at it.

    "Find me something similar" reached the Buying Agent as the query
    "something similar": no category, no item, and it asked "what is it
    you're looking for?" - and the listing itself could come back as a
    result. A query that only means "like this one" becomes the listing's
    title, with its category and subcategory; any FIND_FOR_ME from here
    also carries the listing's id, so the Buying Agent leaves it out of its
    results and the hunt is part of this listing's session
    (premium/zeno_sessions.py). A query with words of its own keeps them,
    and no category: "a laptop" asked from a phone's listing is not a
    phone.
    """
    if action.get("type") not in ("SEARCH", "FIND_FOR_ME"):
        return action
    similar = await listing_context.similar_to(db, user_id, listing_id)
    if similar is None:
        return action
    out = dict(action)
    reference = intents.refers_to_listing(action.get("query") or "")
    if action["type"] == "SEARCH":
        if reference and similar["slots"].get("query"):
            out["query"] = similar["slots"]["query"][:intents.MAX_QUERY_CHARS]
        return out
    if reference:
        out["query"] = f"Something like {similar['title']}"[:intents.MAX_QUERY_CHARS]
        out["slots"] = dict(similar["slots"])
    out["from_listing_id"] = similar["listing_id"]
    return out


def _offline(language: str) -> str:
    """The whole of what Zeno says when no model answers: that it failed.

    It used to advertise what still worked ("open my inbox"), which read
    like an answer and left the failure unsaid - the user had asked a
    question and got suggestions for other ones. Say it plainly, and ask
    them to try again.
    """
    if _sw(language):
        return "Samahani, hilo halikufanikiwa. Tafadhali jaribu tena."
    return "Sorry, that wasn't successful. Please try again."


async def _first_name(db: AsyncSession, user_id: str) -> str:
    name = (await db.execute(select(User.name).where(User.id == user_id))).scalar_one_or_none()
    return (name or "").strip()


def _walkthrough_turn(walk: dict) -> dict:
    out = {"reply": walk["reply"], "action": None, "source": "rules",
           "suggestions": walk.get("suggestions", [])}
    if walk.get("link"):
        out["link"] = walk["link"]
    return out


async def _resolve(db: AsyncSession, user_id: str, action: dict) -> tuple[dict, Optional[str]]:
    """Fill in who a CALL / OPEN_CHAT is for, or build a GUIDE for this
    user. Returns the action and, when it cannot be done as asked, what
    Zeno should say instead."""
    if action["type"] == "GUIDE":
        built = await guides.build(db, user_id, action["guide"])
        if built is None:
            return {"type": "NONE"}, "no_guide"
        return {"type": "GUIDE", "guide": action["guide"], "guide_content": built}, None
    if action["type"] not in ("CALL", "OPEN_CHAT"):
        return action, None
    partners = await contacts.conversation_partners(db, user_id)
    found = contacts.resolve(partners, action["contact"])
    if not found:
        return {"type": "NONE"}, "no_match"
    if len(found) == 1:
        return {**action, "target": found[0].to_target(),
                "requires_confirmation": action["type"] == "CALL"}, None
    return {**action, "choices": [p.to_target() for p in found[:MAX_CHOICES]],
            "requires_confirmation": True}, "choose"


async def assistant_turn(
    db: AsyncSession,
    user_id: str,
    message: str,
    history: list[dict],
    language: str,
    voice: bool = False,
    listing_id: Optional[str] = None,
    image_base64: Optional[str] = None,
) -> dict:
    # 0. Paying with escrow, step by step (escrow_walkthrough.py): before
    #    the commands, because "next", "done" and "back" only mean anything
    #    against the step the user is on - and before the judgement check,
    #    which would send "which one should I use?" to the model.
    if not image_base64:
        walk = escrow_walkthrough.turn(intents.normalise(message), history)
        if walk is not None:
            return _walkthrough_turn(walk)

    # Asked from a listing buyers can no longer see (removed, unpaid or
    # lapsed): say so, without a model reading nothing.
    if listing_id and await listing_context.access(db, user_id, listing_id) == listing_context.GONE:
        return {"reply": _gone(language), "action": None, "source": "rules"}

    # 1. A plain command needs no model. A call or chat request only
    #    short-cuts when it names someone the user actually talks to -
    #    "call it a day" is not a request to ring someone called "it".
    #    Not with a photo attached: "help" or "sell" typed under a picture
    #    is a question about the picture, and the fast path can't see it.
    fast = None if image_base64 else intents.detect_fast(message)
    if fast:
        action = intents.clean_action(fast)
        if action["type"] != "NONE":
            if listing_id:
                # "Find me something similar": similar to this listing.
                action = await _aim_at_listing(db, user_id, listing_id, action)
            resolved, problem = await _resolve(db, user_id, action)
            if problem is None:
                reply = (_finding_similar(resolved, language)
                         if resolved.get("from_listing_id") and (resolved.get("slots") or {}).get("query")
                         else _confirmation(resolved, language))
                return {"reply": reply, "action": resolved, "source": "rules"}
            if problem == "choose":
                return {"reply": _choose(resolved["choices"], language), "action": resolved,
                        "source": "rules"}

    # 2. The model: conversation, and at most one proposed action - with the
    #    user's own data for the topics the question is about.
    from api.routers.negotiate import _language_instruction  # router module; imported late
    # Opened from a listing: what it says, loaded by id (listing_context.py)
    # - with what similar listings ask when the question is about price.
    about = (await listing_context.load(
        db, user_id, listing_id, market=listing_context.is_price_question(message, history))
        if listing_id else None)
    topics = knowledge.topics_for(message)
    if about is not None and not about["own"] and not _ABOUT_THEMSELF.search(message or ""):
        # "Is the seller trusted? Do they have good reviews?" asked from a
        # listing is about its seller. The asking user's own profile went
        # into the prompt for those words, as "what you know about this
        # user", beside the seller's figures - and could be read as the
        # seller's.
        topics = set()
    facts = await knowledge.gather(db, user_id, topics) if topics else {}
    # A question in the middle of the escrow walkthrough: the model is told
    # which step, and what the service publishes, so it answers about that.
    walking = escrow_walkthrough.in_progress(history)
    service = AIBrokerService()
    name = await _first_name(db, user_id)

    async def ask(known: dict[str, str], may_ask: bool) -> dict:
        return await service.assistant_turn(
            message=message,
            history=history,
            destinations=intents.destinations(),
            language_instruction=_language_instruction(language),
            user_name=name,
            voice=voice,
            facts=known,
            guides=guides.available(),
            topics=(knowledge.TOPIC_HELP if may_ask else None),
            listing=about,
            image_base64=image_base64,
            escrow=escrow_walkthrough.knowledge(walking) if walking else None,
        )

    calls = 1
    try:
        turn = await ask(facts, may_ask=True)
        action = intents.clean_action(turn.get("action"))
        # 3. The model asked for data it wasn't given: fetch it, ask once
        #    more, and stop there - a second NEED_INFO is not honoured.
        if action["type"] == "NEED_INFO":
            wanted = [t for t in action["topics"] if t not in facts]
            if wanted:
                facts = {**facts, **await knowledge.gather(db, user_id, wanted)}
            # Asked again even when what it wanted was already there: its
            # first reply may be empty, and without the option to ask it
            # answers with what it has.
            turn = await ask(facts, may_ask=False)
            calls = 2
            action = intents.clean_action(turn.get("action"))
            if action["type"] == "NEED_INFO":
                action = {"type": "NONE"}
    except Exception as exc:
        # Every provider down must not take the assistant with it: say that
        # this turn failed (the fast path above still runs).
        logger.warning("[zeno_assistant] model unavailable: %s", exc)
        return {"reply": _offline(language), "action": None, "source": "fallback"}

    used = {"facts": sorted(facts), "model_calls": calls}
    reply = (turn.get("reply") or "").strip()
    # The escrow guide is a conversation now, not a card: the model asking
    # for it starts the walkthrough, under whatever it said first.
    if action["type"] == "GUIDE" and action.get("guide") == "escrow":
        walk = escrow_walkthrough.start()
        return {**_walkthrough_turn(walk), "source": "model", **used,
                "reply": (reply + "\n\n" + walk["reply"]) if reply else walk["reply"]}
    if walking:
        used["suggestions"] = _RESUME
    elif escrow_walkthrough.mentions_escrow(message):
        used["suggestions"] = _OFFER_WALKTHROUGH
    if action["type"] == "NONE":
        return {"reply": reply or _offline(language), "action": None, "source": "model", **used}

    resolved, problem = await _resolve(db, user_id, action)
    if problem == "no_match":
        return {"reply": _no_match(action, language), "action": None, "source": "model", **used}
    if problem == "no_guide":
        return {"reply": reply or _offline(language), "action": None, "source": "model", **used}
    if problem == "choose":
        return {"reply": _choose(resolved["choices"], language), "action": resolved, "source": "model", **used}
    if about is not None and resolved["type"] in ("SEARCH", "FIND_FOR_ME"):
        # A search the model came up with while the seller's words were in
        # its prompt is offered, not run: a description must not be able to
        # carry a buyer off to a search they never asked for. A search the
        # user typed as a command took the fast path above and runs.
        resolved = await _aim_at_listing(db, user_id, listing_id, resolved)
        resolved = {**resolved, "requires_confirmation": True}
        return {"reply": reply or _offer(resolved, language), "action": resolved, "source": "model", **used}
    return {"reply": reply or _confirmation(resolved, language), "action": resolved, "source": "model", **used}
