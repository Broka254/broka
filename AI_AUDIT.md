# AI integration audit + cost controls (2026-09-14)

## Where the money goes

`negotiate_chat` makes **2–3 model calls per user message**:

| # | Call | When | Output |
|---|---|---|---|
| 1 | `_classify_relay` | always | JSON, read by code |
| 2 | `_call_ai(sys_sender, …)` | always | prose the sender reads |
| 3 | `_call_ai(sys_other, …)` | only when (1) says relay | prose the other party reads |

Call 1 carries ~700 tokens of fixed policy text and ran on **every**
message, including "ok", "asante sana" and "👍". It is also the only one
whose inputs are small and closed — it sees `content`, `sender_role`,
`other_role` and nothing else. That makes it simultaneously the most
wasteful call and the only safely cacheable one.

**Calls 2 and 3 are untouched.** They produce what users read; trimming
them is the kind of "saving" that shows up as worse replies.

## Bugs found

**Gemini had no circuit breaker.** It is the primary, tried first on every
call, and was the only tier without one (DeepSeek and OpenRouter both have
one). A degraded Gemini meant every request paid its full timeout before
falling through to a provider that was working — an upstream outage became
latency on every message, plus spend on calls that were never going to
return. Added at `failure_threshold=8` (higher than the fallbacks': tripping
the primary is more disruptive, so it should take more evidence).

**`max_tokens: 400` was global.** A classifier emitting ~30 tokens of JSON
was allowed the same ceiling as a full conversational reply. Now threaded
per call; classification is capped at 150.

**The architecture doc claims a Redis-cached tier in the fallback chain.**
`AIBrokerService` does have one, but `negotiate.py::_call_ai` — the hot path
carrying 2–3 calls per message — had no cache at all. The doc describes a
different code path than the one that runs.

## Cost controls added

### 1. Deterministic pre-filter — ~60% of classifier calls
Acknowledgements and greetings ("ok", "thanks", "asante sana", "sawa", "👍")
are listed in the classifier's *own* prompt as never relay-worthy, yet each
cost a full call. They are now recognised locally.

**Why this is safe:** it can only ever return "don't relay" — the same
direction `_classify_relay` already fails in on error or ambiguity. It cannot
cause a leak or a spurious relay. It makes the privacy guarantee slightly
*stronger*.

Escape hatches, so it never swallows real content: any digit (a price),
any `?`, any availability/delivery/condition stem, anything over 24 chars.
`"ok 1500"` and `"good condition?"` both reach the model.

### 2. Classification cache, 7-day TTL
Safe because the prompt's only inputs are content and the two roles — no
listing, no thread, no user, no timestamp. The same triple always has the
same correct answer. Short messages only (≤120 chars); long ones are
near-unique so caching them buys nothing.

Two guards: the key includes a `_CLASSIFIER_PROMPT_VERSION` so editing the
prompt retires every entry at once, and **only successful classifications
are cached** — caching a failure would pin a fail-closed default for a week
and quietly stop relaying messages that should have been relayed.

### 3. Cheap-first routing for machine-read output
Internal JSON classifiers now try the cheap tier first. The chain is
**reordered, not shortened** — it still falls through to Gemini, so a
classification never fails because of this. Prose calls still get Gemini
first.

### 4. `GET /admin/ai-savings`
Per-worker counters of calls avoided. An aid for tuning the word list, not
billing.

## Measured effect

On a representative 18-message thread: **18 classifier calls → 7**, a 61%
reduction, before any cache hits. Cache hits then remove repeated phrasings
across threads ("is it still available?" is asked verbatim constantly).

Not claimed: a total-spend figure. Calls 2 and 3 dominate token volume and
are deliberately unchanged, so the overall saving is a fraction of the
classifier line, not of the whole bill.

## Not done — deliberately

- **Shortening history (`MAX_HISTORY = 20`) for calls 2/3.** Would cut input
  tokens materially and is the single biggest remaining lever, but it
  directly degrades reply quality. Needs an A/B, not a guess.
- **Provider-native prompt caching** (Gemini context caching). Real savings
  on the large fixed system prompts, but provider-specific and would need
  the fallback chain reworked.
- **Skipping call 3 by templating simple relays.** Many relay drafts are
  formulaic; some could be templates like the SMS nudge. Needs a study of
  real outputs first.
