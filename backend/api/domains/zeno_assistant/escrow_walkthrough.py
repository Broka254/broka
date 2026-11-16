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
provider publishes about itself (the escrow_directory catalogue), so the
answer is the same every time and true - a model asked to explain an escrow
service it has never used invents a paybill number. Where the catalogue has
no fact (how a deal starts, how a dispute is opened) the step says to follow
the provider's own instructions; it never fills the gap.

Only providers BROKA lists are walked through. A provider it has suspended,
or one the user names that is not on the list, gets a plain "not on Broka's
list" answer instead of being silently swapped for a similarly named one
(Kenya Escrow and Escrow Kenya are different websites).

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

from api.domains.escrow_directory import aliases, catalogue, projection

BUYING, SELLING = "buying", "selling"

# Matches the first line of a step reply. "·" is what this module writes;
# a plain "-" is accepted too in case a client normalises it.
_STEP = re.compile(r"^Step (\d+) of (\d+) [·\-] (Buying|Selling) with (.+?)\s*$", re.M)
# The two questions asked before the steps start - each names what it is
# waiting for, so the answer can be read against it.
_ASK_ROLE = "are you buying or selling?"
_ASK_PROVIDER = re.compile(r"Which escrow service will you and the (seller|buyer) use\?")

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


def _names_a_provider(text: str) -> bool:
    return bool(aliases.mentions(text, _records()))


class _EscrowWords:
    """`_ESCROW_WORDS.search(text)`: the word "escrow", or any provider the
    catalogue knows by name - computed from the catalogue, not typed here."""
    _WORD = re.compile(r"\bescrow\b")

    def search(self, text: str):
        return self._WORD.search(text or "") or (_names_a_provider(text or "") or None)


_ESCROW_WORDS = _EscrowWords()

# Asked as a plain question about paying safely - the opener chips and
# the escrow screen's buttons send these.
_PLAIN_START = re.compile(
    r"^(?:escrow|escrow payments?|pay with escrow|paying with escrow|help me pay with escrow|"
    r"what is escrow|what'?s escrow|how does escrow work|explain escrow|how do i pay (?:a |the )?(?:seller|store) safely|"
    r"how (?:do|can|should) i pay safely|paying safely|how do i get paid safely|how (?:do i|to) use escrow|"
    r"walk me through (?:paying with |using )?escrow(?: step by step)?|walk me through it step by step)$")
_SELLER_HINT = re.compile(r"\bsell(?:ing|er)?\b|get(?:ting)? paid|receive (?:the )?(?:money|payment)")


def _records() -> list[dict]:
    """Every provider the catalogue knows, listed or not, as of now."""
    return catalogue.current_records()


def _listed() -> list[dict]:
    """The providers BROKA lists, each as the flat dict the steps read."""
    return [projection.legacy_view(r) for r in catalogue.listed(_records())]


def _provider_in(text: str) -> Optional[dict]:
    """The LISTED provider [text] names, or None. Whole words, longest name
    first (aliases.py); a provider that is not listed is not returned."""
    listed_ids = {r["id"] for r in catalogue.listed(_records())}
    hit = aliases.first_mention(text, [r for r in _records() if r["id"] in listed_ids])
    return projection.legacy_view(hit) if hit else None


def _unlisted_in(text: str) -> Optional[dict]:
    """A provider [text] names that BROKA does not list (suspended, rejected)."""
    listed_ids = {r["id"] for r in catalogue.listed(_records())}
    hit = aliases.first_mention(text, [r for r in _records() if r["id"] not in listed_ids and r["status"] != "draft"])
    return hit


def not_listed_reply(record: dict) -> dict:
    """What Zeno says when the user asks about a provider BROKA does not list."""
    name, domain = record["display_name"], record["identity"]["canonical_domain"]
    notice = record.get("public_notice") or (
        f"{name} ({domain}) is not on Broka's list, so I can't walk you through using it.")
    return {
        "reply": (f"{notice}\n\nIf you were sent a link to a provider that isn't on Broka's list, don't "
                  "pay on it. Pick one of the listed providers instead, and open its official website "
                  "yourself."),
        "suggestions": [p["name"] for p in _listed()] + ["Help me choose"],
    }


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
             f"Pay through {name}'s own checkout, by {p['pay']}. Before you approve the M-Pesa prompt, "
             f"check it names {name}, shows the agreed amount and says what it is for - if it shows a "
             "person's name, stop and tell me. Never share your PIN, an OTP or a password with "
             f"anyone, and never pay a personal number someone gives you in chat. Limits: {p['limits']}."),
            ("The seller delivers - you check",
             f"Tell the seller it's paid; they can see on {name} that the money is held. When the item "
             "reaches you, or you collect it, check it properly: it works, it's what you agreed, "
             "nothing is missing."),
            ("Release the money",
             f"Only once it is what you agreed. {p['release']} Release it through {name}'s own website "
             "or app, never to someone who asks you to release it for them, and never share a "
             "release code or PIN. Then leave the seller a review on BROKA."),
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
         f"The buyer confirms on {name}, and you are paid {p['payout']} Don't hand over anything more "
         "because someone says an agent will pay you later."),
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
    lines = "\n".join(f"• {p['name']}: {p['best_for'][0].lower() + p['best_for'][1:]}" for p in _listed())
    return {
        "reply": (f"Which escrow service will you and the {other} use? What each is best at:\n{lines}\n\n"
                  f"If the {other} already uses one of these, that's often easiest. None of them is run "
                  "by BROKA."),
        "suggestions": [p["name"] for p in _listed()] + ["Help me choose"],
    }


def _help_choose(role: str) -> dict:
    """How the listed providers differ, from what the catalogue records -
    limits, whether an account is needed, what each publishes about its fee.
    It does not say which is "best": that depends on the deal, and BROKA has
    not reviewed them far enough to rank them (the comparison screen only
    ranks verified, complete pricing). A fact the catalogue lacks is not
    mentioned."""
    other = "seller" if role == BUYING else "buyer"
    lines = []
    for r in catalogue.listed(_records()):
        c = r["conditions"]
        bits = [projection.limits_summary(c)]
        if c.get("registration_required") is False:
            bits.append("no account needed")
        elif c.get("registration_required") is True:
            bits.append("account needed")
        if c.get("kyc_required") is True:
            bits.append("ID checks")
        bits.append(projection.fee_summary(r).rstrip("."))
        review = "" if r["status"] == "approved" else " (not yet verified by Broka)"
        lines.append(f"• {r['display_name']}{review}: " + "; ".join(bits))
    comparison = "\n".join(lines) if lines else "• No providers are available right now."
    return {
        "reply": ("Here is how the providers on Broka's list differ, from what each publishes:\n"
                  f"{comparison}\n\n"
                  "I can't say which is cheapest unless every figure is published and verified - "
                  "the escrow comparison screen shows that where it can. Your amount and the kind "
                  "of deal matter more than a general ranking. Land and cars: no M-Pesa escrow "
                  "carries those, so do the official search first (Ardhisasa for land, NTSA for a "
                  "logbook) and pay through a bank or an advocate.\n\n"
                  f"Which escrow service will you and the {other} use?"),
        "suggestions": [p["name"] for p in _listed()],
    }


def _where(history: list[dict]) -> Optional[dict]:
    """Where the walkthrough is, from Zeno's newest messages: a step, a
    question it asked, or nothing. Only the last few - a walkthrough from
    an hour of conversation ago is not the one "next" is about."""
    zeno = [h.get("content") or "" for h in history[-8:] if h.get("role") != "user"]
    for text in reversed(zeno):
        m = _STEP.search(text)
        if m:
            p = next((x for x in _listed() if x["name"] == m.group(4)), None)
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
        if kind in ("role", "provider", "step") and len(text.split()) <= 6:
            gone = _unlisted_in(text)
            if gone is not None and _provider_in(text) is None:
                return not_listed_reply(gone)
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
        chosen = _provider_in(m.group("what"))
        if chosen is None:
            gone = _unlisted_in(m.group("what"))
            if gone is not None:
                return not_listed_reply(gone)
        return start(_role_of(text), chosen)
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
