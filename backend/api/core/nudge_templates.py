"""
BROKA — availability-nudge SMS composition.

System-generated, not AI-generated. This replaces the
`AIBrokerService.draft_availability_nudge_sms()` call in
`api/core/workers.py::_fire_availability_nudge`.

Why move this off the LLM:

  • It is a transactional notification, not a conversation. It goes to a
    phone number over a paid SMS channel, it cannot be corrected once
    sent, and the seller cannot reply to it to clear up a mistake.
  • An LLM call here costs latency and money on every nudge, can fail (the
    old code had a try/except falling back to one hard-coded string, so in
    practice every failure produced the *same* message anyway), and can
    hallucinate a price, a product detail, or a promise BROKA has not made.
  • Variation is the only thing the LLM was really buying, and a template
    set gives that deterministically.

Three things this module gets right that a naive f-string does not:

  1. **Greeting matches the seller's actual local time** (Africa/Nairobi),
     not the server's UTC clock. See `greeting_for()`.
  2. **No message can mis-gender anyone**, whatever the data says. See
     `Pronouns` and the note on templates below.
  3. **Nothing is sent in the middle of the night.** See `is_quiet_hours()`.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Optional

# Kenya is UTC+3 year-round and has never observed daylight saving, so a
# fixed offset is correct here and avoids a tzdata dependency. If BROKA ever
# serves a DST-observing market, this must become a real timezone lookup
# against the user's location rather than a constant.
EAT = timezone(timedelta(hours=3))

# Quiet hours in EAT. A nudge that comes due inside this window is deferred
# to the start of the next allowed window rather than sent.
QUIET_START_HOUR = 21   # 21:00
QUIET_END_HOUR = 7      # 07:00


# ── Gender / pronouns ─────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Pronouns:
    """Subject/object/possessive plus the verb forms that must agree.

    The verb forms are the part that is easy to forget and impossible to
    bolt on afterwards: "he is interested" and "they are interested" differ
    in more than the pronoun, so a template holding only `{subject}` will
    produce "they is interested" the first time it meets an undisclosed
    gender. Agreement travels with the pronoun set.
    """
    subject: str        # he / she / they
    object: str         # him / her / them
    possessive: str     # his / her / their
    is_are: str         # is / are
    has_have: str       # has / have
    was_were: str       # was / were


_MASCULINE = Pronouns("he", "him", "his", "is", "has", "was")
_FEMININE = Pronouns("she", "her", "her", "is", "has", "was")
# Singular "they" is the correct and standard English fallback. It is used
# for BOTH "prefer not to say" and "we were never told" — deliberately the
# same path, because those two cases must be indistinguishable in output.
# If undisclosed gender produced visibly different wording from a declined
# one, the message itself would leak which users had declined to answer.
_NEUTRAL = Pronouns("they", "them", "their", "are", "have", "were")

VALID_GENDERS = ("male", "female", "prefer_not_to_say")


def pronouns_for(gender: Optional[str]) -> Pronouns:
    """Resolve a gender value to a grammatically complete pronoun set.

    Never raises and never returns None. An unrecognised value, an empty
    string, `None` (every account created before the gender field existed)
    and an explicit "prefer_not_to_say" all resolve to singular they —
    which is always grammatical, so no caller needs a special case.
    """
    if gender == "male":
        return _MASCULINE
    if gender == "female":
        return _FEMININE
    return _NEUTRAL


# ── Time-appropriate greeting ─────────────────────────────────────────────────

def now_eat() -> datetime:
    """Current time in the seller's local zone."""
    return datetime.now(timezone.utc).astimezone(EAT)


def greeting_for(when: Optional[datetime] = None) -> str:
    """Greeting that matches the wall clock the seller is actually looking at.

    The bug this exists to prevent: the server stores and reasons in UTC,
    Kenya is UTC+3, so any greeting derived from `datetime.utcnow()` is
    three hours behind the seller's day. A nudge sent at 09:00 EAT reads
    the server clock as 06:00 and says "Good morning" — correct by luck.
    One sent at 14:00 EAT reads 11:00 and *also* says "Good morning", which
    is wrong. The error is invisible in testing anywhere near UTC and
    obvious to every user in Nairobi.

    Note there is deliberately no "Good night": in English that is a
    farewell, not a greeting, so it reads as though the message is ending
    before it has begun. Late hours fall back to a neutral "Hi" — though in
    practice `is_quiet_hours()` means those messages are deferred rather
    than sent.
    """
    t = when or now_eat()
    h = t.hour
    if 5 <= h < 12:
        return "Good morning"
    if 12 <= h < 17:
        return "Good afternoon"
    if 17 <= h < 21:
        return "Good evening"
    return "Hi"


def is_quiet_hours(when: Optional[datetime] = None) -> bool:
    """True if a nudge coming due now should be held rather than sent.

    A 3am SMS about a second-hand fridge is not urgency, it is a nuisance —
    it wakes the seller, makes BROKA feel spammy, and is the kind of traffic
    that gets a shortcode flagged by the aggregator. The deal is not lost by
    waiting until morning; the buyer is asleep too.
    """
    t = when or now_eat()
    return t.hour >= QUIET_START_HOUR or t.hour < QUIET_END_HOUR


def next_send_time(when: Optional[datetime] = None) -> datetime:
    """When a nudge deferred by quiet hours should next be attempted."""
    t = when or now_eat()
    if not is_quiet_hours(t):
        return t
    target = t.replace(hour=QUIET_END_HOUR, minute=0, second=0, microsecond=0)
    if t.hour >= QUIET_START_HOUR:
        target += timedelta(days=1)
    return target


# ── Templates ─────────────────────────────────────────────────────────────────
#
# Ten variants so a seller who gets several nudges in a week does not see
# the same sentence every time — repetition is what makes an automated
# message start reading as spam.
#
# GENDER SAFETY BY CONSTRUCTION: the seller is addressed in the second
# person ("you"), which never needs a gender. The buyer is referred to by
# NAME, or by a pronoun-free noun ("this buyer", "the sale"). Only
# templates 7 and 10 use a pronoun slot, and those draw on `pronouns_for()`
# which is grammatical for every input including no input at all.
#
# That mix is deliberate rather than absolute. Making every template
# pronoun-free would mean the gender field bought nothing here; making them
# all pronoun-dependent would put a mis-gendering risk on a channel that
# cannot be corrected. Most messages therefore cannot mis-gender anyone
# even if the gender data is wrong, and the two that use it degrade to
# correct singular "they" when it is absent.
#
# Placeholders: {greeting} {seller} {buyer} {listing} {price}
#               {subject} {object} {possessive} {is_are} {has_have}

TEMPLATES: tuple[str, ...] = (
    # 1 — closest to the original brief
    "{greeting} {seller}, it's Zeno, your AI assistant from BROKA. I've found "
    "a potential buyer, {buyer}, for your {listing}. Is it still available at "
    "the same price? Please reply as soon as you can so we don't lose the sale.",

    # 2 — leads with the question
    "{greeting} {seller}, Zeno here from BROKA. {buyer} is asking whether your "
    "{listing} is still available at {price}. A quick reply in the app keeps "
    "this one warm.",

    # 3 — short and direct
    "{greeting} {seller}. Zeno from BROKA: {buyer} wants your {listing}. Still "
    "available at the same price? Reply in the BROKA app to continue.",

    # 4 — emphasises that the buyer is waiting right now
    "{greeting} {seller}, this is Zeno from BROKA. A buyer named {buyer} asked "
    "about your {listing} a few minutes ago and is waiting on an answer. Is it "
    "still available?",

    # 5 — frames the cost of silence without pressure
    "{greeting} {seller}, Zeno from BROKA. I have a real buyer, {buyer}, "
    "interested in your {listing} at {price}. Serious buyers move fast — open "
    "the app and let me know if it's still available.",

    # 6 — polite, slightly more formal
    "{greeting} {seller}. Zeno from BROKA here. {buyer} has enquired about your "
    "{listing}. Could you confirm whether it's still available at the same "
    "price? A reply in the app is all I need.",

    # 7 — uses a pronoun in OBJECT position only.
    #
    # It originally read "{buyer} {is_are} asking ... and {has_have} not
    # heard back", which renders as "Clinton are asking ... and have not
    # heard back" for an undisclosed gender. The mistake is subtle and
    # worth recording: singular "they" takes PLURAL verb agreement only
    # when "they" is itself the subject. A proper noun is always singular,
    # so pairing a name with pronoun-derived agreement is wrong for exactly
    # one of the three gender cases — the fallback case, i.e. the most
    # common one. A name therefore always takes singular verbs, and
    # {is_are}/{has_have} are only safe where {subject} is the subject (see
    # template 10).
    "{greeting} {seller}, it's Zeno from BROKA. {buyer} is asking about your "
    "{listing} and hasn't heard back yet. Is it still available? Reply in the "
    "app and I'll pass it straight to {object}.",

    # 8 — reassurance rather than urgency
    "{greeting} {seller}, Zeno from BROKA. Good news — {buyer} is interested in "
    "your {listing}. Just confirm it's still available at {price} and I'll take "
    "the conversation from there.",

    # 9 — names the specific ask
    "{greeting} {seller}. Zeno from BROKA: {buyer} asked me one thing about "
    "your {listing} — is it still available at the same price? Reply in the app "
    "whenever you're free.",

    # 10 — uses pronouns (resolver-backed)
    "{greeting} {seller}, Zeno from BROKA. {buyer} is looking at your {listing} "
    "right now. Let me know if it's still available and I'll tell {object} "
    "straight away, before {subject} {has_have} a chance to look elsewhere.",
)


def _variant_index(seed: str, count: int) -> int:
    """Pick a template deterministically from a stable seed.

    Deterministic rather than random so the same nudge re-sent after a
    retry, a redeploy, or a worker restart produces the identical message —
    a seller receiving two *differently worded* copies of one nudge would
    reasonably read it as two separate buyers.
    """
    digest = hashlib.sha256(seed.encode("utf-8")).digest()
    return int.from_bytes(digest[:4], "big") % count


def _first_name(full: Optional[str], fallback: str) -> str:
    if not full or not full.strip():
        return fallback
    return full.strip().split()[0]


def _format_price(price: Optional[float]) -> str:
    if price is None:
        return "the asking price"
    try:
        return f"KES {float(price):,.0f}"
    except (TypeError, ValueError):
        return "the asking price"


def compose_availability_nudge(
    *,
    seller_name: Optional[str],
    buyer_name: Optional[str],
    listing_name: str,
    price: Optional[float] = None,
    buyer_gender: Optional[str] = None,
    seed: Optional[str] = None,
    when: Optional[datetime] = None,
) -> str:
    """Build the nudge SMS.

    `buyer_gender` — not the seller's. The seller is the recipient and is
    addressed as "you", which needs no gender at all. Every pronoun in
    these templates refers to the BUYER ("before they look elsewhere"), so
    the buyer's gender is the one that has to be right. That distinction is
    easy to invert, and inverting it would mean collecting a field that
    could never fix the problem it was collected for.

    `seed` should be stable per nudge (the Interest id is ideal) so retries
    reproduce the same text — see `_variant_index`.
    """
    seller = _first_name(seller_name, "there")
    buyer = _first_name(buyer_name, "A buyer")
    p = pronouns_for(buyer_gender)

    idx = _variant_index(seed or f"{seller}:{buyer}:{listing_name}", len(TEMPLATES))
    template = TEMPLATES[idx]

    text = template.format(
        greeting=greeting_for(when),
        seller=seller,
        buyer=buyer,
        listing=listing_name,
        price=_format_price(price),
        subject=p.subject,
        object=p.object,
        possessive=p.possessive,
        is_are=p.is_are,
        has_have=p.has_have,
    )

    # A single GSM-7 SMS is 160 characters; concatenated parts bill
    # separately, so a long listing name silently multiplies cost per
    # nudge. Trim the listing name rather than the message, since the
    # call to action is the part that has to survive.
    if len(text) > 306:  # two SMS parts, with headroom
        short_listing = (listing_name[:37] + "…") if len(listing_name) > 38 else listing_name
        text = template.format(
            greeting=greeting_for(when),
            seller=seller,
            buyer=buyer,
            listing=short_listing,
            price=_format_price(price),
            subject=p.subject,
            object=p.object,
            possessive=p.possessive,
            is_are=p.is_are,
            has_have=p.has_have,
        )
    return text
