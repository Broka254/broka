# Message visibility — how the audience line is enforced

`NegotiationMessage.recipient_role` decides who may see a row:

| role | value | audience |
|---|---|---|
| `broker` | `NULL` | **nobody** — the row names no audience, so no surface shows, previews, counts, pushes or feeds it to a model |
| `broker` | `"buyer"` / `"seller"` | that party only |
| `buyer` / `seller` | `"seller"` / `"buyer"` | the other party, and its sender |
| `buyer` / `seller`, `msg_type = "call"` | `NULL` | both parties — a call card is history for both, not a message |

Zeno writes a **different message to each side** of the same relay. One
party's copy routinely contains coaching — what to counter-offer, how much
room the other side probably has. Showing it to the wrong party is not a
cosmetic bug.

A broker row with no `recipient_role` is therefore **fail-closed**. Rows
written before the audience column existed (or by a path that forgot it)
are silent rather than guessed at: "both" would put a note in front of the
very party it was written about, and no reviewer can tell those apart
after the fact. The rule is applied by one module
(`api/core/message_visibility.py`) so the inbox, push, unread counts,
`/history`, the model context and arbitration cannot disagree — a message
that shows in the inbox and then vanishes when the thread opens is that
disagreement, seen from the user's side.

## Why a structural guard exists

Enforcement used to rest on every read surface remembering the filter.
Two didn't, and neither was caught by review or by the existing tests:

- **`get_inbox`** (both branches) returned whichever copy sorted newest, so
  a seller's inbox preview displayed a message Zeno wrote to the buyer,
  attributed to the buyer by name. It also suppressed the seller's own
  notification, because the row never changed to their copy.
- **`disputes.py`** loaded *every* message on the listing — all buyers, both
  audiences — and fed it to the arbitration model whose written verdict both
  parties read. A listing keeps one thread per interested buyer, so
  unrelated buyers' negotiations became context for someone else's dispute.

`get_history` had the filter from day one and `test_thread_privacy` covered
the AI-context path. Neither helped. A per-surface test only protects the
surfaces someone thought to write a test for, and the failure mode here is
"a new query was added and nobody remembered".

## The rule

Every `select(...)` naming `NegotiationMessage` must either:

1. constrain `recipient_role` in the same statement, or
2. carry an inline `# visibility-ok: <reason>` marker.

`tests/test_message_visibility_guard.py` enforces this by AST-scanning the
whole `api/` tree. It fails with file:line and refuses markers shorter than
a real sentence, because a marker with no reason is a mute button.

A marker is not permission to skip the filter. It is an assertion that the
query **cannot** reach a user — it counts rows, selects only ids, or feeds
analytics nobody reads. Both leaks above looked harmless at a glance; if you
are reaching for a marker to make the test pass, that is the signal to add
the filter instead.

### Filtering in SQL

Use the shared clause, never a hand-written `or_` — the inclusive version
below (`recipient_role IS NULL` = both) is what let an unattributed row
reach both parties:

```python
from api.core.message_visibility import (
    addressed_to_role_clause,          # one viewer's news
    thread_visible_to_role_clause,     # what the thread/preview may show
)
```

### Filtering in Python

Several paths load rows and filter in the loop (`get_history`, the
`_build_messages_for_party`/`_grounding_transcript` pair that builds Zeno's
model context, arbitration). They call `broker_visible_to(recipient_role,
viewer_role)` from the same module. That is fine, but the marker must say
so, and the loop must be in the same function — a filter applied by a
distant caller is a filter someone will drop.

## What this does not cover

The guard checks that a constraint exists, not that it is correct. It cannot
tell `== viewer_role` from `!= viewer_role`. Pinned tests in the same file
cover the two surfaces that actually leaked; behavioural coverage for the
rest is still worth adding.

Direct-chat WebSocket pushes are not `select()` calls and are outside the
scanner. They are audience-correct today by construction — the socket
carries only `role in (buyer, seller)` — but nothing enforces that.
