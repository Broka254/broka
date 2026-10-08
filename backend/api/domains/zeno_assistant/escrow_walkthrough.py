"""Zeno walking a buyer or a seller through paying with an escrow service,
one step at a time, as a conversation (2026-10-08).

BROKA holds no deal money for launch (pricing/safe_payment.py), so the safe
way to pay someone you can't meet is an independent escrow service - and
the people most likely to need one are the ones who have never used one.
A list of steps on a card is read once and forgotten halfway through a
deal; a conversation keeps their place: "Step 3 of 7", "tell me when that's
done", and the next step when they say so. Questions in between go to the
model, which is given the step they are on (service.py).

No model call, like the guides: every step is written here from what each
provider publishes about itself (safe_payment.PROVIDERS), so the answer is
the same every time and true - a model asked to explain an escrow service
it has never used invents a paybill number.

STATELESS, LIKE EVERY ZENO TURN. The app sends the transcript; where the
user is comes from Zeno's own last walkthrough message in it, whose first
line is a marker this module wrote - "Step 3 of 7 · Buying with E-Confirm".
The user can see it (it is their progress), and could type one, but all
it can do is show them a different step of the same public guide.

English only for now, like the guides; Zeno's own replies follow the
user's language.
"""
from __future__ import annotations

import re
from typing import Optional

from api.domains.pricing.safe_payment import PROVIDERS, PROVIDERS_BY_ID

BUYING, SELLING = "buying", "selling"

# Matches the first line of a step reply. "·" is what this module writes;
# a plain "-" is accepted too in case a client normalises it.
_STEP = re.compile(r"^Step (\d+) of (\d+) [·\-] (Buying|Selling) with (.+?)\s*$", re.M)
# The two questions asked before the steps start - each names what it is
# waiting for, so the answer can be read against it.
_ASK_ROLE = "are you buying or selling?"
_ASK_PROVIDER = re.compile(r"Which escrow service will you and the (seller|buyer) use\?")

# What people call each provider. Longest first: "escrow kenya" must not
# be read as "kenya escrow" - they are different companies.
_ALIASES: list[tuple[str, str]] = sorted([
    ("e-confirm", "econfirm"), ("econfirm", "econfirm"), ("e confirm", "econfirm"),
    ("escrow kenya", "escrowkenya"), ("escrowkenya", "escrowkenya"),
    ("kenya escrow", "kenyaescrow"), ("kenyaescrow", "kenyaescrow"),
    ("lipasafe", "lipasafe"), ("lipa safe", "lipasafe"),
    ("shikilia", "shikilia"),
], key=lambda a: -len(a[0]))

# "Done - what's next?" is the chip under every step; the rest is how
# people say it, typed or spoken.
_NEXT = re.compile(
    r"^(?:(?:ok(?:ay)?|sawa|yes|yep|right)[, ]+)?(?:next(?: step)?(?: please)?|done|i'?m done|all done|"
    r"i(?: have|'ve)? done (?:it|that)|did it|i did (?:it|that)|finished|ready|go on|continue|carry on|"
    r"what'?s next|what next|then what|and then|got it|ok(?:ay)?|sawa|nimemaliza|tayari|endelea|"
    r"done(?:\s*[-–—,]\s*|\s+)what'?s next)$")
_BACK = re.compile(r"^(?:back|go back|previous(?: step)?|last step|the step before|rudi)$")
_REPEAT = re.compile(r"^(?:repeat(?: (?:that|this|the step|this step|that step))?|again|say (?:that|it) again|"
                     r"once more|rudia)$")
_RESTART = re.compile(r"^(?:start over|restart|start again|from the (?:start|beginning)|anza upya)$")
_STOP = re.compile(r"^(?:stop|cancel|quit|exit|that'?s all|no thanks|nevermind|never mind|acha)$")
_CHOOSE = re.compile(r"^(?:help me (?:choose|pick|decide)|which (?:one )?(?:should i (?:use|pick|choose)|is best)|"
                     r"not sure|i don'?t know|recommend one)$")
_I_BUY = re.compile(r"^(?:i'?m |i am )?(?:buying|the buyer|a buyer|paying|nanunua|ninanunua)$")
_I_SELL = re.compile(r"^(?:i'?m |i am )?(?:selling|the seller|a seller|getting paid|nauza|ninauza)$")

# Starting it. Narrow, like the rest of the fast path: a question that
# also asks for judgement goes to the model (intents.detect_fast).
_START = re.compile(
    r"^(?:(?:please |can you |could you )?(?:walk|take|talk|guide|help) me (?:through|with|to use|use|on|to)\s+|"
    r"how (?:do|can|should) i (?:use|pay (?:with|through|via|using)|get paid (?:with|through|via)|pay into)\s+|"
    r"how does\s+|how to (?:use|pay (?:with|through|via))\s+|show me how to (?:use|pay with)\s+|"
    r"i want to (?:use|pay with|pay through)\s+|"
    r"guide me through (?:buying|selling|paying|getting paid) with\s+|"
    r"(?:help me |i want to |i'?d like to )?(?:pay|buy) (?:safely )?(?:with|through|using|via)\s+)"
    r"(?:paying (?:with|through|via)\s+|buying (?:with|through|via)\s+|selling (?:with|through|via)\s+|"
    r"getting paid (?:with|through|via)\s+)?"
    r"(?:an? |the )?(?P<what>.+?)(?: work)?$")
_ESCROW_WORDS = re.compile(r"\bescrow\b|e-?confirm|escrow ?kenya|kenya ?escrow|lipa ?safe|shikilia")
# Asked as a plain question about paying safely - the opener chips and
# the escrow screen's buttons send these.
_PLAIN_START = re.compile(
    r"^(?:escrow|escrow payments?|pay with escrow|paying with escrow|help me pay with escrow|"
    r"what is escrow|what'?s escrow|how does escrow work|explain escrow|how do i pay (?:a |the )?(?:seller|store) safely|"
    r"how (?:do|can|should) i pay safely|paying safely|how do i get paid safely|how (?:do i|to) use escrow|"
    r"walk me through (?:paying with |using )?escrow(?: step by step)?|walk me through it step by step)$")
_SELLER_HINT = re.compile(r"\bsell(?:ing|er)?\b|get(?:ting)? paid|receive (?:the )?(?:money|payment)")


# Whole words only: as a bare substring "e confirm" is in "please confirm",
# and a user saying it mid-walkthrough was switched to E-Confirm.
_ALIAS_RES = [(re.compile(rf"(?<![a-z]){re.escape(alias)}(?![a-z])"), pid) for alias, pid in _ALIASES]


def _provider_in(text: str) -> Optional[dict]:
    for pattern, pid in _ALIAS_RES:
        if pattern.search(text):
            return PROVIDERS_BY_ID[pid]
    return None


def _steps(p: dict, role: str) -> list[tuple[str, str]]:
    """The steps for [p], buyer or seller, as (title, text)."""
    name, url = p["name"], p["url"]
    site = url.removeprefix("https://").removeprefix("www.")
    other = "seller" if role == BUYING else "buyer"
    agree = ("Agree the deal first",
             f"Before any money moves, agree with the {other} in the BROKA chat: the price, exactly what's "
             f"included, how it gets to you, and that you'll use {name}. Agree who pays its fee too. "
             f"Its fee: {p['fees'][0].lower() + p['fees'][1:]}")
    if role == SELLING:
        agree = (agree[0], agree[1].replace("how it gets to you", "how it gets to them"))
    open_it = (f"Open {name} yourself",
               f"Go to {site} yourself - tap Open {name} below, or type it in your browser. Never use an "
               f"escrow link, paybill or phone number the {other} sends you: fake escrow sites are a common "
               "scam, and they look real.")
    if role == BUYING:
        return [
            agree,
            open_it,
            ("Set up the deal", p["start"]),
            (f"Pay {name}, not the seller",
             f"Pay in with {p['pay']}. Before you enter your PIN, check it names {name} and shows the "
             f"agreed amount - if it shows a person's name, stop and tell me. {p['limits']}"),
            ("The seller delivers - you check",
             f"Tell the seller it's paid; they can see on {name} that the money is held. When the item "
             "reaches you, or you collect it, check it properly: it works, it's what you agreed, "
             "nothing is missing."),
            ("Release the money",
             f"Happy with it? Then {p['release']} That's the deal done - leave the seller a review on BROKA."),
            ("If something is wrong",
             f"Don't release the money. {p['dispute']} Show {name} the BROKA chat and photos "
             "of the problem. BROKA doesn't hold the money, so it's their call - you can still report "
             "the seller on BROKA."),
        ]
    return [
        agree,
        open_it,
        ("Set up the deal",
         f"Whoever starts it on {name}: {p['start']} Check the amount, and that the number you'll be "
         "paid on is yours."),
        ("Wait until the money is held",
         f"Don't hand anything over yet. Wait until {name} itself shows the buyer's money is held - "
         "check on its site or in its own message. A screenshot or an M-Pesa SMS from the buyer proves "
         "nothing: fake ones are easy to make."),
        ("Deliver it",
         "Deliver it or hand it over exactly as agreed, and keep proof - a delivery note, photos, the "
         "courier's receipt."),
        ("Get paid",
         f"The buyer confirms on {name}. Then {p['payout']}"),
        ("If the buyer doesn't confirm",
         f"Contact {name}. {p['dispute']} Show them the BROKA chat and your proof of delivery. Tell me "
         "if you get stuck."),
    ]


def _step_reply(p: dict, role: str, index: int) -> dict:
    steps = _steps(p, role)
    index = max(0, min(index, len(steps) - 1))
    title, text = steps[index]
    last = index == len(steps) - 1
    head = f"Step {index + 1} of {len(steps)} · {role.capitalize()} with {p['name']}"
    tail = ("That's every step. Ask me anything about it - or start over with another service."
            if last else "Tell me when that's done, or ask me anything about it.")
    reply = f"{head}\n\n{title}: {text}\n\n{tail}"
    suggestions = (["Start over", "See escrow services"] if last else
                   ["Done - what's next?", "Repeat this step"] + (["Back"] if index else []))
    out = {"reply": reply, "suggestions": suggestions}
    if index == 1 or index == 2:
        # Opening the provider is the step people get wrong - the link is
        # BROKA's, never one from the chat.
        out["link"] = {"label": f"Open {p['name']}", "url": p["url"]}
    return out


def _ask_role() -> dict:
    return {
        "reply": ("I'll walk you through it, one step at a time. 🛡️ With escrow, the money goes to an "
                  "independent service, not to the seller - and the seller is paid only once the buyer "
                  "confirms they got what they paid for.\n\nFirst - " + _ASK_ROLE),
        "suggestions": ["I'm buying", "I'm selling"],
    }


def _ask_provider(role: str) -> dict:
    other = "seller" if role == BUYING else "buyer"
    lines = "\n".join(f"• {p['name']}: {p['best_for'][0].lower() + p['best_for'][1:]}" for p in PROVIDERS)
    return {
        "reply": (f"Which escrow service will you and the {other} use? What each is best at:\n{lines}\n\n"
                  f"If the {other} already uses one of these, that's often easiest. None of them is run "
                  "by BROKA."),
        "suggestions": [p["name"] for p in PROVIDERS] + ["Help me choose"],
    }


def _help_choose(role: str) -> dict:
    other = "seller" if role == BUYING else "buyer"
    return {
        "reply": ("A quick way to pick:\n"
                  "• Paying by M-Pesa: E-Confirm (KES 100 to 500,000 a deal - though one M-Pesa "
                  "payment carries at most KES 250,000).\n"
                  "• Over KES 250,000, a car, or a broker in the middle: Escrow Kenya - it takes bank "
                  "transfers.\n"
                  "• No time to sign up: Kenya Escrow.\n"
                  "• You want everyone ID-checked: Lipasafe.\n"
                  "• You arranged it all on WhatsApp: Shikilia.\n"
                  "• Land: no escrow app - do an official search on Ardhisasa and pay through an advocate.\n\n"
                  f"Which escrow service will you and the {other} use?"),
        "suggestions": [p["name"] for p in PROVIDERS],
    }


def _where(history: list[dict]) -> Optional[dict]:
    """Where the walkthrough is, from Zeno's newest messages: a step, a
    question it asked, or nothing. Only the last few - a walkthrough from
    an hour of conversation ago is not the one "next" is about."""
    zeno = [h.get("content") or "" for h in history[-8:] if h.get("role") != "user"]
    for text in reversed(zeno):
        m = _STEP.search(text)
        if m:
            p = next((x for x in PROVIDERS if x["name"] == m.group(4)), None)
            if p is not None:
                return {"kind": "step", "provider": p, "role": m.group(3).lower(),
                        "index": int(m.group(1)) - 1}
        m = _ASK_PROVIDER.search(text)
        if m:
            return {"kind": "provider", "role": BUYING if m.group(1) == "seller" else SELLING}
        if _ASK_ROLE in text.lower():
            return {"kind": "role"}
    return None


def in_progress(history: list[dict]) -> Optional[dict]:
    """The step the user is on, for the model's prompt - or None."""
    where = _where(history)
    return where if where and where["kind"] == "step" else None


def _role_of(text: str) -> Optional[str]:
    if _I_SELL.match(text) or _SELLER_HINT.search(text):
        return SELLING
    if _I_BUY.match(text) or re.search(r"\bbuy(?:ing|er)?\b|\bpay(?:ing)?\b", text):
        return BUYING
    return None


def start(role: Optional[str] = None, provider: Optional[dict] = None) -> dict:
    """The walkthrough's first turn - as far in as the user's words take it."""
    if provider is not None:
        return _step_reply(provider, role or BUYING, 0)
    if role is not None:
        return _ask_provider(role)
    return _ask_role()


def turn(text: str, history: list[dict]) -> Optional[dict]:
    """Zeno's next walkthrough turn for [text] (already normalised by
    intents.normalise), or None when this isn't one - the message then
    goes on to the rest of the fast path and the model."""
    where = _where(history)

    if where is not None:
        if _STOP.match(text):
            return {"reply": "No problem. Ask me any time - \"walk me through escrow\" picks it up again.",
                    "suggestions": []}
        if _RESTART.match(text):
            return start()
        kind = where["kind"]
        if kind == "role":
            role = SELLING if _I_SELL.match(text) else BUYING if _I_BUY.match(text) else None
            if role:
                return _ask_provider(role)
            chosen = _provider_in(text)
            if chosen is not None and len(text.split()) <= 6:
                return _step_reply(chosen, BUYING, 0)
        if kind in ("provider", "step"):
            role = where["role"]
            chosen = _provider_in(text)
            if chosen is not None and len(text.split()) <= 6:
                # Switching service mid-way keeps their place.
                return _step_reply(chosen, role, where.get("index", 0) if kind == "step" else 0)
            if _CHOOSE.match(text):
                return _help_choose(role)
        if kind == "step":
            p, role, i = where["provider"], where["role"], where["index"]
            if _NEXT.match(text):
                if i + 1 >= len(_steps(p, role)):
                    return {"reply": ("That was the last step - you know the whole thing now. Want to "
                                      "go through it with another service, or see them all?"),
                            "suggestions": ["Start over", "See escrow services"]}
                return _step_reply(p, role, i + 1)
            if _BACK.match(text):
                return _step_reply(p, role, i - 1)
            if _REPEAT.match(text):
                return _step_reply(p, role, i)

    # Not mid-walkthrough (or the answer didn't fit it): is this a request
    # to start one?
    if _PLAIN_START.match(text):
        return start(SELLING if _SELLER_HINT.search(text) else None)
    m = _START.match(text)
    if m and _ESCROW_WORDS.search(m.group("what")):
        return start(_role_of(text), _provider_in(m.group("what")))
    return None


def mentions_escrow(message: str) -> bool:
    """Whether [message] is about escrow, or paying a seller safely - for
    offering the walkthrough under a reply that didn't start it."""
    t = (message or "").lower()
    return bool(_ESCROW_WORDS.search(t) or re.search(r"pay(?:ing)? (?:a |the )?(?:seller|store )?safely", t))


def knowledge(where: dict) -> str:
    """For the model, when a question comes in the middle of a step: which
    step, and the facts it may use about that service."""
    p, role, i = where["provider"], where["role"], where["index"]
    steps = _steps(p, role)
    title, text = steps[max(0, min(i, len(steps) - 1))]
    return (
        f"ESCROW WALKTHROUGH IN PROGRESS: you are walking the user through {role} with {p['name']} "
        f"({p['url']}), step {i + 1} of {len(steps)} - \"{title}: {text}\"\n"
        f"What {p['name']} publishes: pay in: {p['pay']}. Fees: {p['fees']} Limits: {p['limits']} "
        f"Release: {p['release']} Payout: {p['payout']} Disputes: {p['dispute']}\n"
        "Answer their question about this step in two or three sentences, using only these facts and "
        "the payment policy above; if the answer isn't here, say so and tell them to check on "
        f"{p['name']}'s own site or contact it. Then tell them to say \"next\" when they're ready. "
        "Never invent a paybill, till, phone number, fee or limit."
    )
