"""What Zeno, the assistant, may do - and the commands it understands
without asking a model.

THE VOCABULARY IS CLOSED
========================
The same rule as the Buying Agent's actions (buy_agent/actions.py) and the
negotiation room's (ZENO_ACTIONS.md): the model proposes, this module
decides. An action the model invents, a screen that is not in
DESTINATIONS, a query that is empty - each becomes NONE, and Zeno just
talks. Nothing here moves money or changes anything on the server: every
action is navigation, or a CALL that the app puts in front of the user
for a tap before anything rings, through the one endpoint that can ring a
phone (POST /calls/initiate).

THE FAST PATH
=============
"Open my inbox" does not need a language model. A Siri-like assistant that
takes two seconds and a billed model call to open a screen is not one, so
plain imperative commands are recognised here, in English and Kiswahili,
and answered at once. The rules are deliberately narrow - a command has to
START with the verb - so "I want to sell my car, what's it worth?" still
goes to the model rather than being yanked off to the Sell screen.
"""
from __future__ import annotations

import re
from typing import Optional

# Screen ids the app knows how to open (flutter_app/lib/features/
# zeno_assistant/zeno_assistant_actions.dart maps each to its route). Only
# screens that need nothing but the signed-in user - no listing, no deal.
DESTINATIONS: dict[str, str] = {
    "home": "Home - the marketplace feed",
    "inbox": "Inbox - the user's conversations with buyers and sellers",
    "sell": "Sell - post something for sale",
    "menu": "Menu - account, store, settings and help",
    "profile": "The user's own profile",
    "settings": "Settings - language, notifications, privacy",
    "search": "Search listings (with no query yet)",
    "buying_agent": "The Buying Agent - Zeno finds, watches for and negotiates an item",
    "seller_dashboard": "The seller dashboard - the user's listings and sales",
    "deal_history": "The user's deals and receipts",
    "verify": "Get verified - ID and selfie",
    "market_insights": "Zeno's market insights - prices and trends",
    "how_broka_works": "How BROKA works - escrow, fees, safety",
}

ACTION_TYPES = ("NONE", "NAVIGATE", "SEARCH", "FIND_FOR_ME", "CALL", "OPEN_CHAT")

MAX_QUERY_CHARS = 100
MAX_CONTACT_CHARS = 60

# What people call each screen, for the fast path. The model gets
# DESTINATIONS' descriptions instead and needs none of this.
_SYNONYMS: dict[str, tuple[str, ...]] = {
    "inbox": ("inbox", "messages", "my messages", "chats", "my chats", "conversations",
              "my conversations", "ujumbe", "jumbe"),
    "home": ("home", "home screen", "homepage", "the feed", "feed", "marketplace", "nyumbani"),
    "sell": ("sell", "selling", "sell screen", "post an ad", "new listing", "kuuza"),
    "menu": ("menu", "the menu", "main menu"),
    "profile": ("profile", "my profile", "my account", "account", "wasifu"),
    "settings": ("settings", "my settings", "preferences", "mipangilio"),
    "search": ("search", "search screen"),
    "buying_agent": ("buying agent", "the buying agent", "buy agent"),
    "seller_dashboard": ("seller dashboard", "dashboard", "my dashboard", "my listings",
                         "my shop", "my sales"),
    "deal_history": ("deals", "my deals", "deal history", "receipts", "my receipts",
                     "orders", "my orders", "purchases", "my purchases"),
    "verify": ("verification", "verify", "get verified", "verify me", "verify my account"),
    "market_insights": ("insights", "market insights", "market prices", "price trends"),
    "how_broka_works": ("how broka works", "how it works", "escrow explained"),
}

_OPEN = (r"(?:please\s+)?(?:open|go(?:\s+to)?|goto|take\s+me(?:\s+to)?|show(?:\s+me)?|bring\s+up|"
         r"navigate\s+to|switch\s+to|launch|fungua|nipeleke(?:\s+kwa)?|nionyeshe)")
_POLITE_TAIL = r"(?:\s+(?:please|for\s+me|now|pls|tafadhali))*"

_SEARCH = re.compile(
    r"^(?:please\s+)?(?:search(?:\s+broka)?(?:\s+for)?|look\s+up|tafuta)\s+(?P<q>.+?)" + _POLITE_TAIL + r"$")
_FIND = re.compile(
    r"^(?:please\s+)?(?:find\s+me|get\s+me|i(?:'m|\s+am)\s+looking\s+for|i\s+need\s+to\s+buy|"
    r"i\s+want\s+to\s+buy|help\s+me\s+(?:find|buy)|nitafutie|natafuta|nataka\s+kununua)\s+"
    r"(?P<q>.+?)" + _POLITE_TAIL + r"$")
_CALL = re.compile(
    r"^(?:please\s+)?(?:(?P<video>video\s*call|facetime)|call|ring|phone|voice\s*call|"
    r"piga\s+simu(?:\s+kwa)?|mpigie(?:\s+simu)?|nipigie)\s+(?P<who>.+?)" + _POLITE_TAIL + r"$")
_CHAT = re.compile(
    r"^(?:please\s+)?(?:message|text|dm|write\s+to|chat\s+with|open\s+(?:my\s+)?(?:chat|conversation|"
    r"thread)\s+with|mtumie\s+ujumbe|ongea\s+na)\s+(?P<who>.+?)" + _POLITE_TAIL + r"$")


def normalise(text: str) -> str:
    t = (text or "").strip().lower()
    t = re.sub(r"^(?:hey|hi|ok|okay|yo|hello)?\s*,?\s*zeno\s*[,:!.]?\s*", "", t)
    t = t.rstrip(" .!?")
    return re.sub(r"\s+", " ", t)


def _destination_for(phrase: str) -> Optional[str]:
    phrase = phrase.strip()
    said = {phrase, re.sub(r"^(?:the|my)\s+", "", phrase)}
    for dest, names in _SYNONYMS.items():
        if said.intersection(names):
            return dest
    return None


def _flat_synonyms() -> set[str]:
    return {n for names in _SYNONYMS.values() for n in names}


def detect_fast(message: str) -> Optional[dict]:
    """The command in [message] when it is one of the plain ones, else None.

    Returns the raw action - {"type", ...} - for resolve_action to check
    like any other. None sends the message to the model.
    """
    t = normalise(message)
    if not t or len(t) > 160:
        return None

    m = re.match(_OPEN + r"\s+(?P<dest>.+?)" + _POLITE_TAIL + r"$", t)
    if m:
        dest = _destination_for(m.group("dest"))
        if dest:
            return {"type": "NAVIGATE", "destination": dest}
    # A bare screen name - "inbox", "settings" - is a command too.
    if t in _flat_synonyms() and len(t.split()) <= 3:
        return {"type": "NAVIGATE", "destination": _destination_for(t)}

    for pattern, kind in ((_FIND, "FIND_FOR_ME"), (_SEARCH, "SEARCH")):
        m = pattern.match(t)
        if m:
            return {"type": kind, "query": m.group("q")}

    m = _CALL.match(t)
    if m:
        who = m.group("who")
        video = bool(m.group("video"))
        # "call jane on video"
        tail = re.search(r"\s+(?:on|via|by|with|kwa)\s+video$", who)
        if tail:
            who, video = who[: tail.start()], True
        return {"type": "CALL", "contact": who, "call_type": "video" if video else "audio"}

    m = _CHAT.match(t)
    if m:
        return {"type": "OPEN_CHAT", "contact": m.group("who")}
    return None


def clean_action(raw) -> dict:
    """The model's (or the fast path's) action reduced to the vocabulary.

    Anything that does not fit becomes NONE - Zeno still answers, it just
    doesn't do anything. Contacts are left as text: who they are is
    decided by contacts.resolve against the user's own conversations,
    never by an id the model wrote.
    """
    if not isinstance(raw, dict):
        return {"type": "NONE"}
    kind = raw.get("type")
    if kind not in ACTION_TYPES or kind == "NONE":
        return {"type": "NONE"}

    if kind == "NAVIGATE":
        dest = raw.get("destination")
        return {"type": kind, "destination": dest} if dest in DESTINATIONS else {"type": "NONE"}

    if kind in ("SEARCH", "FIND_FOR_ME"):
        query = raw.get("query")
        query = query.strip()[:MAX_QUERY_CHARS] if isinstance(query, str) else ""
        return {"type": kind, "query": query} if query else {"type": "NONE"}

    contact = raw.get("contact")
    contact = contact.strip()[:MAX_CONTACT_CHARS] if isinstance(contact, str) else ""
    if not contact:
        return {"type": "NONE"}
    action = {"type": kind, "contact": contact}
    if kind == "CALL":
        action["call_type"] = "video" if raw.get("call_type") == "video" else "audio"
    return action
