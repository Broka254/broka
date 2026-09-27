"""One turn of Zeno as the user's assistant - text or voice, it is the same
turn.

    message -> FAST PATH (plain commands, no model)
            -> or MODEL (talk, and propose at most one action)
            -> CLEAN (closed vocabulary)  -> RESOLVE (whose conversation?)
            -> {reply, action}

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
from typing import Optional

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.database import User
from api.domains.ai_broker.service import AIBrokerService
from . import contacts, intents

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
}


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


def _offline(language: str) -> str:
    if _sw(language):
        return ("Siwezi kufikiri vizuri sasa hivi - lakini bado naweza kufungua skrini, "
                "kutafuta, au kumpigia mtu unayeongea naye. Jaribu \"fungua ujumbe\".")
    return ("I can't think straight right now - but I can still open screens, search, or call "
            "someone you're talking to. Try \"open my inbox\" or \"search for a laptop\".")


async def _first_name(db: AsyncSession, user_id: str) -> str:
    name = (await db.execute(select(User.name).where(User.id == user_id))).scalar_one_or_none()
    return (name or "").strip()


async def _resolve(db: AsyncSession, user_id: str, action: dict) -> tuple[dict, Optional[str]]:
    """Fill in who a CALL / OPEN_CHAT is for. Returns the action and, when
    it cannot be done as asked, what Zeno should say instead."""
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
) -> dict:
    # 1. A plain command needs no model. A call or chat request only
    #    short-cuts when it names someone the user actually talks to -
    #    "call it a day" is not a request to ring someone called "it".
    fast = intents.detect_fast(message)
    if fast:
        action = intents.clean_action(fast)
        if action["type"] != "NONE":
            resolved, problem = await _resolve(db, user_id, action)
            if problem is None:
                return {"reply": _confirmation(resolved, language), "action": resolved, "source": "rules"}
            if problem == "choose":
                return {"reply": _choose(resolved["choices"], language), "action": resolved,
                        "source": "rules"}

    # 2. The model: conversation, and at most one proposed action.
    from api.routers.negotiate import _language_instruction  # router module; imported late
    try:
        turn = await AIBrokerService().assistant_turn(
            message=message,
            history=history,
            destinations=intents.DESTINATIONS,
            language_instruction=_language_instruction(language),
            user_name=await _first_name(db, user_id),
            voice=voice,
        )
    except Exception as exc:
        # Every provider down must not take the assistant with it: say so,
        # and say what still works (the fast path above).
        logger.warning("[zeno_assistant] model unavailable: %s", exc)
        return {"reply": _offline(language), "action": None, "source": "fallback"}

    action = intents.clean_action(turn.get("action"))
    reply = (turn.get("reply") or "").strip()
    if action["type"] == "NONE":
        return {"reply": reply or _offline(language), "action": None, "source": "model"}

    resolved, problem = await _resolve(db, user_id, action)
    if problem == "no_match":
        return {"reply": _no_match(action, language), "action": None, "source": "model"}
    if problem == "choose":
        return {"reply": _choose(resolved["choices"], language), "action": resolved, "source": "model"}
    return {"reply": reply or _confirmation(resolved, language), "action": resolved, "source": "model"}
