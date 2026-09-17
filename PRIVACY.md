# Message visibility — how the audience line is enforced

`NegotiationMessage.recipient_role` decides who may see a row:

| value | audience |
|---|---|
| `NULL` | both parties |
| `"buyer"` | the buyer only |
| `"seller"` | the seller only |

Zeno writes a **different message to each side** of the same relay. One
party's copy routinely contains coaching — what to counter-offer, how much
room the other side probably has. Showing it to the wrong party is not a
cosmetic bug.

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

Current state: 18 queries scanned, 4 filtered in SQL, 14 marked with a
stated reason, 0 unaccounted for.

### Filtering in SQL

```python
or_(
    NegotiationMessage.recipient_role.is_(None),
    NegotiationMessage.recipient_role == viewer_role,
)
```

### Filtering in Python

Several paths load rows and filter in the loop (`get_history`, the grounding
builder, the media socket). That is fine, but the marker must say so, and
the loop must be in the same function — a filter applied by a distant caller
is a filter someone will drop.

## What this does not cover

The guard checks that a constraint exists, not that it is correct. It cannot
tell `== viewer_role` from `!= viewer_role`. Pinned tests in the same file
cover the two surfaces that actually leaked; behavioural coverage for the
rest is still worth adding.

Direct-chat WebSocket pushes are not `select()` calls and are outside the
scanner. They are audience-correct today by construction — the socket
carries only `role in (buyer, seller)` — but nothing enforces that.
