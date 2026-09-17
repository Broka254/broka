# Communications audit — 1:1 chat, receipts, notifications, leak filter (2026-09-14)

## 1. Cross-party leak (critical)

`_build_messages_for_party` in `negotiate.py` builds the model context for
each party's reply — **including the reply drafted for the other party**
(`msgs_other = _build_messages_for_party(history, data, other_role)`).

It filtered only *broker* messages by `recipient_role` and appended every
human message verbatim, then appended the sender's current message
unconditionally. So a buyer's private "is this seller legit? I heard he
scams people" — correctly ruled non-relayable by `_classify_relay` — sat
verbatim in the context Zeno used to write to the seller.

`_grounding_transcript`, ten lines away, was carefully hardened against
exactly this and documents why. Two functions, the same job, one safe.
The one feeding cross-party drafts was the unsafe one.

Nothing but the system prompt stood between that text and the seller's
screen. **A prompt asking a model not to repeat what it can see is
mitigation, not access control.** Now the private words never enter the
context, and the sender's raw message is excluded from the other party's
draft entirely — the relay summary is the only sanctioned representation
of it. 8 regression tests in `tests/test_thread_privacy.py`.

## 2. Unread counts leaked activity (privacy + phantom badges)

`_thread_unread_and_seen` counted every message from the counterpart,
including `via_ai=True` messages the viewer can never see.

- **Phantom badges.** A buyer in a long private Zeno chat gave the seller
  "7 unread"; the seller opened it, found nothing, repeatedly, and stopped
  trusting the badge.
- **A side channel.** The count told the seller the buyer was talking to
  Zeno right now and roughly how much. You can't read the words, but you
  can watch the meter. That's precisely what the visibility rules exist to
  withhold.

## 3. Thread bleed on the seller's screen

In `/history`, the "my own messages" branch had no `buyer_id` scoping,
unlike every other branch. A seller negotiating with five buyers on one
listing saw their own replies from all five threads merged into whichever
thread they were viewing. Not a cross-party leak (the buyer view was
scoped) but a serious usability failure.

## 4. Chat WebSocket registered before `accept()`

`_thread_connections[key][ws] = uid` ran **before** `await
websocket.accept()`. A broadcast landing in that window called `send_json`
on an un-accepted socket, which raises — and the raise is swallowed by
`_broadcast`'s per-socket `try`, which then bins the socket as dead. The
peer's first message could silently vanish for someone who had just opened
the thread. Reads to the user as "it didn't send".

## 5. Receipts — what shipped

The existing `ThreadReadState` watermark was sound (one row per side per
thread, not a flag per message) but only expressed *read*. The UI drew a
grey **double** tick for anything unread — claiming delivery with no
delivery signal at all, and collapsing the two states users most need to
distinguish into one glyph.

Added `last_delivered_at` as a second watermark. Now:

| State | Meaning | Set by |
|---|---|---|
| `sending` | queued locally | no server id yet |
| `sent` ✓ | server has it | message persisted |
| `delivered` ✓✓ | their device has it | chat socket connect, inbox sweep |
| `read` ✓✓ (violet) | thread was open | `mark-read` |
| `relayed` ✨ | Zeno passed on the substance | `via_ai=true` |

**`relayed` is BROKA's own state and has no WhatsApp equivalent.** When you
write to Zeno rather than directly, Zeno relays the concrete fact, not your
words. Without a marker people assume the seller read what they typed, then
find the reply doesn't match. Delivery/read ticks would be a lie about such
a message; `relayed` is the honest report. That distinction is load-bearing
for the whole mediated-chat model, so it gets its own glyph.

Watermarks only ever move forward — an out-of-order retry must not rewind a
receipt the other party has already been shown. A tick that un-ticks is
worse than a late tick.

## Still open (not addressed in this pass)

- **`_classify_relay` is an LLM call with no deterministic backstop.** It
  fails closed on error, which is right, but a confidently-wrong
  classification still relays. Worth a regex pre-filter for obvious
  private markers (phone numbers, "don't tell", budget ceilings) that
  forces `needs_relay=false` regardless of what the model says.
- **Legacy `buyer_id IS NULL` rows are visible to everyone** on every
  branch of `/history`. Deliberate backward compatibility, but it is an
  open hole that should be closed with a backfill.
- The relay-draft prompt is still the only thing keeping the *summary*
  faithful; the summary itself is model-generated from private text.
