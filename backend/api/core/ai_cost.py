"""
BROKA — AI cost controls.

Every mechanism here is chosen so that it CANNOT change what the user
sees. That constraint rules out the obvious levers (smaller models for
everything, shorter history, terser prompts) and leaves the ones that are
free: not making calls whose answer is already known, and not making calls
whose answer is structurally predetermined.

Where the money actually goes on the main chat path
───────────────────────────────────────────────────
`api/routers/negotiate.py::negotiate_chat` makes **2–3 model calls per
user message**:

  1. `_classify_relay(...)`            — always
  2. `_call_ai(sys_sender, ...)`       — always
  3. `_call_ai(sys_other, ...)`        — only when (1) says relay

Call 1 is the cheapest per call but runs on *every* message including
"ok", "thanks" and "👍". Its system prompt is ~700 tokens of fixed policy
text, so an "ok" costs roughly 700 input tokens to be told what a two-line
regex already knew. It is also the only one of the three whose inputs are
small and closed: it sees `content`, `sender_role`, `other_role` and
nothing else — no listing, no history, no user. That makes it both the
most wasteful call and the only one that is safely cacheable.

This module therefore attacks call 1 only, in two stages, and leaves
calls 2 and 3 completely untouched — those produce the prose the user
reads, and trimming them is exactly the kind of "saving" that shows up as
worse replies.
"""
from __future__ import annotations

import hashlib
import re
from typing import Optional

# ── Stage 1: deterministic pre-filter ────────────────────────────────────────
#
# A message matching one of these patterns is never relay-worthy under the
# classifier's own stated rules ("'thanks', 'ok', greetings, small talk" are
# listed there as NEVER relay-worthy). Recognising them locally skips the
# call entirely.
#
# SAFETY: this function can only ever return "don't relay". That is the same
# direction `_classify_relay` already fails in — its docstring says it fails
# closed on error, malformed output, or ambiguity, because "understating what
# needs relaying is a much smaller problem than leaking a private question".
# So the worst case here is identical to an error case that is already
# handled, and it can never cause a message to be relayed that otherwise
# wouldn't be. It makes the privacy guarantee stronger, not weaker: these
# messages now cannot be relayed even if the model would have said yes.

_ACK_WORDS = {
    "ok", "okay", "okey", "oki", "k", "kk", "sawa", "sawasawa", "poa", "fine",
    "yes", "yeah", "yep", "ya", "ndio", "ndiyo", "no", "nope", "hapana",
    "thanks", "thank", "thankyou", "asante", "asantesana", "cheers",
    "hi", "hey", "hello", "hallo", "habari", "mambo", "niaje", "sasa",
    "morning", "afternoon", "evening", "goodmorning", "goodevening",
    "sure", "alright", "noted", "got", "gotit", "cool", "nice", "great",
    "please", "pls", "welcome", "karibu", "bye", "later",
    "waiting", "hmm", "hmmm", "lol", "haha",
    # Modifiers and address terms that only ever appear alongside the words
    # above, given the other constraints this filter applies (<=24 chars,
    # no digits, no question hint). Without them "Asante sana" and "Good
    # morning" fell through to the model — harmless, since that is the safe
    # direction, but a wasted call on two of the most common messages on
    # the platform.
    "good", "sana", "very", "much", "lot", "so", "my",
    "bro", "boss", "friend", "sir", "madam", "dear",
}

# Emoji / punctuation / whitespace only.
_NON_TEXT_RE = re.compile(
    r"^[\s\W_]*$|^[\s]*[\U0001F000-\U0001FAFF\u2600-\u27BF\uFE0F\u200D]+[\s]*$"
)

# A number in the message almost always means a price offer, which IS
# relay-worthy. This is the escape hatch that stops the pre-filter from
# swallowing "ok 1500" or "sawa, 2000".
_HAS_DIGIT_RE = re.compile(r"\d")

# Question marks and these stems signal a factual question only the other
# party can answer — never pre-filtered, always sent to the classifier.
_QUESTION_HINT_RE = re.compile(
    r"\?|\b(available|availab|still|deliver|delivery|colour|color|size|"
    r"condition|warrant|receipt|location|where|when|how much|price|"
    r"negotiab|discount|iko|bado|bei)\b",
    re.IGNORECASE,
)

# Above this length, assume there is real content and let the model decide.
_MAX_PREFILTER_CHARS = 24


def is_trivially_private(content: str) -> bool:
    """True if this message is certainly not relay-worthy, no model needed.

    Deliberately conservative — every ambiguity resolves to False (ask the
    model). A false positive here silently suppresses a relay the user
    wanted; a false negative just costs one cheap call. The asymmetry is
    obvious, so the filter only fires on messages it is sure about.
    """
    if not content:
        return True
    text = content.strip()
    if not text:
        return True

    # Emoji-only / punctuation-only.
    if _NON_TEXT_RE.match(text):
        return True

    # Anything long enough to carry a real request goes to the model.
    if len(text) > _MAX_PREFILTER_CHARS:
        return False

    # A number is very likely a price. Never pre-filter those.
    if _HAS_DIGIT_RE.search(text):
        return False

    # A question, or a word that hints at one the seller must answer.
    if _QUESTION_HINT_RE.search(text):
        return False

    # Every remaining token must be a known acknowledgement/greeting.
    tokens = re.findall(r"[a-z]+", text.lower())
    if not tokens:
        return True
    return all(t in _ACK_WORDS for t in tokens)


# ── Stage 2: classification cache ────────────────────────────────────────────

_CLASSIFY_PREFIX = "broka:relay_cls:"
# 7 days. The classifier's rules are static policy text that only changes
# when someone edits the prompt, and its inputs carry no listing, user or
# time context — so a given (content, roles) triple maps to the same answer
# indefinitely. See _CLASSIFIER_PROMPT_VERSION for the invalidation story.
CLASSIFY_TTL_SECONDS = 7 * 24 * 3600

# Bump this whenever the classifier's system prompt changes in a way that
# could alter its verdict. It is part of the cache key, so bumping it
# retires every cached entry at once without needing a flush — and
# forgetting to bump it is the one way this cache can serve a stale answer.
_CLASSIFIER_PROMPT_VERSION = "v1"


def classification_cache_key(content: str, sender_role: str, other_role: str) -> str:
    """Cache key for one relay classification.

    Hashes exactly the three inputs the classifier prompt actually receives
    and nothing else. If the prompt is ever changed to take more context
    (the listing, the thread, the user), this key MUST grow to match or the
    cache will start returning answers computed for a different situation.
    """
    norm = " ".join(content.strip().lower().split())
    raw = f"{_CLASSIFIER_PROMPT_VERSION}|{sender_role}|{other_role}|{norm}"
    return _CLASSIFY_PREFIX + hashlib.sha256(raw.encode("utf-8")).hexdigest()[:32]


def is_cacheable_for_classification(content: str) -> bool:
    """Only cache short, common messages.

    Long messages are near-unique, so caching them buys nothing and fills
    the store. The hit rate lives entirely in the short repeated ones —
    "is it still available?", "how much?", "can you deliver?" — which are
    asked verbatim across thousands of threads.
    """
    if not content:
        return False
    return len(content.strip()) <= 120


# ── Reporting ────────────────────────────────────────────────────────────────

class AISavings:
    """Process-local counters, for seeing whether any of this is working.

    Deliberately in-memory and unsynchronised: this is an observability aid,
    not billing. Exposed via GET /admin/ai-savings.
    """
    __slots__ = ()
    prefiltered = 0
    cache_hits = 0
    cache_misses = 0

    @classmethod
    def snapshot(cls) -> dict:
        total = cls.prefiltered + cls.cache_hits + cls.cache_misses
        avoided = cls.prefiltered + cls.cache_hits
        return {
            "classification_calls_avoided_by_prefilter": cls.prefiltered,
            "classification_calls_avoided_by_cache": cls.cache_hits,
            "classification_calls_made": cls.cache_misses,
            "classification_requests_total": total,
            "avoided_fraction": round(avoided / total, 4) if total else 0.0,
        }
