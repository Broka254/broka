# Auctions — how the system works, and why (2026-09-18)

The authority for every auction rule is
`backend/api/domains/auctions/lifecycle.py`. Nothing else decides anything:
the router validates shapes and delegates, the sweep finds work and
delegates, and the Flutter countdown is decoration. This document explains
the design decisions that are easy to get wrong when changing that file.

---

## 1. The lifecycle

```
UPCOMING ──(starts_at passes)──▶ LIVE ──(ends_at passes)──▶ ENDED
```

`effective_status(meta, now)` derives the state **from the clock**, and the
`auction_meta.status` column is a cache that is written on the way past, never
trusted on the way in. A status column that has drifted — a worker that died
mid-tick, a row edited by hand — cannot make a closed auction accept a bid or
a live one reject a valid one.

Two shapes are legal and deliberately so:

* **no `starts_at`** — live from creation.
* **no `ends_at`** — the row may exist (a lazily seeded `ensure_meta` on a
  listing with no `auction_date`), but `place_bid` refuses it with
  `409 AUCTION_NOT_SCHEDULED`. An auction that can never close cannot take
  bids, because there is no point at which a winner would be decided.
  The normal creation path never produces one: `_create_auction_meta`
  defaults to `settings.auction_default_duration_hours` (72h) when neither
  `auction_ends_at` nor `auction_date` is given, so a listing created
  through the sell wizard is biddable rather than silently inert.

### Outcomes

`close_auction()` writes exactly one of:

| outcome | meaning | what follows |
|---|---|---|
| `won` | highest bid ≥ reserve (or no reserve) | Deal created, payment deadline set, winner + seller notified |
| `no_bids` | nobody bid | listing returns to `active` |
| `reserve_not_met` | bids existed, highest was under the reserve | no sale; seller told the top bid so they can relist or negotiate |
| `unpaid` | won, but the winner missed the payment deadline | deal cancelled, listing relisted |

---

## 2. The reserve is not a floor

This is the rule most often implemented backwards, and the old
`routers/auction.py` had it backwards: it **rejected** bids below the reserve.

A reserve is the seller's secret walk-away price and it is evaluated **once,
at close**. Bids below it are perfectly valid bids:

```
starting price 20,000, reserve 50,000
  bid 20,500 → accepted
  bid 45,000 → accepted
  close at 45,000 → reserve_not_met, no sale
  close at 55,000 → won
```

Rejecting sub-reserve bids turns the reserve into a published minimum, which
is the one thing a reserve exists not to be — and it also tells the bidder
what the reserve is, by binary search.

`public_state()` returns `has_reserve` and `reserve_met` and **never
`reserve_price`**. Buyers need to know whether the reserve has been met in
order to bid sensibly; they must not learn what it is.

---

## 3. Concurrency: compare-and-swap, not row locks

Bidding is a race by definition, so "two simultaneous bids can never corrupt
the final state" is a correctness property of the feature, not a deployment
detail.

`escrow/service.py`'s `lock_deal_if_status` uses `SELECT ... FOR UPDATE`, and
its own docstring records the caveat: **SQLAlchemy silently drops FOR UPDATE
on SQLite**, which has no row-level locking. Production is Postgres, so that
is accepted there — but CI runs SQLite, so a guarantee resting on FOR UPDATE
is a guarantee nothing tests.

So every state change here is a **single UPDATE whose WHERE clause pins the
state that was just validated**:

```python
# bid
UPDATE auction_meta
   SET current_bid = :amount, current_bidder_id = :bidder, bid_count = bid_count + 1
 WHERE listing_id = :id AND closed_at IS NULL AND current_bid = :what_i_validated_against

# close
UPDATE auction_meta
   SET closed_at = ..., outcome = ..., winner_id = ..., winning_amount = ...
 WHERE listing_id = :id AND closed_at IS NULL
```

A conflicting transaction changes the row first, the WHERE stops matching,
the UPDATE reports `rowcount == 0`, and the loser re-reads and reacts instead
of overwriting. One statement, atomic on every dialect. The row lock is still
taken first, but only to make conflicts rarer on Postgres — it is not what
correctness rests on.

`place_bid()` retries a lost CAS up to 3 times, re-validating against the new
`current_bid` each time (so a loser is re-checked against the bid that beat
it, not the one it originally saw) and then gives up with a 409 rather than
spinning.

---

## 4. Closing is idempotent

The close claim carries the **whole outcome** — `closed_at`, winner, winning
amount, payment deadline — in the one UPDATE guarded by `closed_at IS NULL`.
Exactly one caller wins that race; every other caller reads the winner's
result and returns it untouched with `already_closed=True`.

A retried sweep, two workers racing, or a manual call cannot pick a second
winner. **Only the caller that won the claim goes on to create the Deal.**

---

## 5. The Deal, and recovering when it fails

A closed auction with a winner must become a Deal — that is the only bridge
from auction to E-Confirm/escrow. The close is committed *before* the Deal is
created (so a Deal failure can never leave the auction re-openable), which
leaves a deliberate, recoverable gap: **closed, won, no deal**.

`due_for_deal_retry()` finds those with an outer join, and `_needs_deal_retry()`
recognises two shapes:

* `deal_id IS NULL` — creation never succeeded.
* `deal_id` set but **no Deal row has that id** — an orphaned claim, from a
  process that died between claiming the id and writing the row. In effect
  identical to the first case: the winner has nothing to pay.

### Why the claim carries the real id

`_retry_winner_deal()` claims the right to create the deal with a
compare-and-swap against the `deal_id` it just observed, writing **the UUID
the deal will actually have**:

```python
UPDATE auction_meta SET deal_id = :new_uuid
 WHERE listing_id = :id AND deal_id IS :what_i_observed
```

A sentinel value would be indistinguishable from a live in-flight claim, so a
crash mid-claim would strand the auction forever. A real id makes the failure
self-describing: the orphan check above sees a `deal_id` pointing at nothing
and retries. If the deal creation then fails outright, the claim is released
(`deal_id = NULL`) so the next pass retries immediately instead of waiting to
be noticed as an orphan.

`EscrowService.finalize_deal` returns the **existing** deal for a
`(listing, buyer)` pair it has already created rather than making a second
one, which is what makes a retry safe after a partial success — including the
case where the deal was written but `deal_id` was never persisted. When it
adopts a pre-existing deal whose id differs from the claimed one, the claim is
overwritten with the real id, again under CAS.

> **Note for anyone tempted by a unique index on `deals(listing_id, buyer_id)`:**
> don't. The same buyer legitimately deals on the same listing more than once
> (a repeat purchase months later), and
> `tests/test_completion_rate.py::test_earlier_deal_evidence_does_not_contaminate_later_deal`
> depends on exactly that. Uniqueness here is enforced by the CAS above, not
> by the schema.

---

## 6. Terms lock once bidding starts

An auction's terms are the contract bidders are bidding against. Moving the
reserve, the increment or the closing time after someone has committed money
changes the deal underneath them — and moving `ends_at` is how an auction gets
quietly extended until a favoured bid arrives.

`terms_locked_reason()` / `assert_terms_editable()` make the locked terms —
starting price, minimum bid increment, start time, end time, reserve price —
editable **only while the auction is genuinely still UPCOMING and untouched**,
and return `409 AUCTION_TERMS_LOCKED` otherwise. Photos stay editable.

`bid_count` is checked as well as status, because they disagree legitimately:
an auction with no `starts_at` is LIVE from creation, and an auction that took
a bid is settled regardless of what the clock says next.

The lock is enforced on **both** doors:

* `PATCH /auctions/{listing_id}/terms` — the dedicated endpoint.
* `PATCH /listings/{listing_id}` — the generic one, which can set `price`
  (an auction's starting price) and was otherwise a back door around the lock.

`validate_terms()` re-checks every rule server-side, because the client is not
the authority on any of it and a request that skips the app entirely has to
hit the same wall:

| code | rule |
|---|---|
| `INVALID_STARTING_PRICE` | starting price > 0 |
| `INVALID_INCREMENT` | increment > 0 |
| `INVALID_RESERVE` | reserve > 0 (empty = no reserve) |
| `INVALID_WINDOW` | `ends_at` > `starts_at` |
| `RESERVE_BELOW_START` | a reserve under the starting price is met by the first bid, so it protects nothing while the seller believes it does |

---

## 7. The sweeps

Auctions ride the **60-second** `_nudge_loop`, not the 300-second
`_periodic_sweep_loop`. A deadline checked every five minutes is five minutes
late, and "the auction closed four minutes ago but took my bid" is not
something a marketplace can argue about.

| task | what it does |
|---|---|
| `task_close_due_auctions` | closes auctions past `ends_at`; **then, unconditionally**, retries stranded winner deals |
| `task_notify_auctions_ending_soon` | one reminder per auction to everyone who has bid, inside `settings.auction_ending_soon_minutes` |
| `task_lapse_unpaid_auction_wins` | cancels wins past `payment_deadline`, relists the listing |

The word *unconditionally* is load-bearing. The retry pass originally sat
behind an `if not due: return`, so a stranded deal was only ever retried on a
tick that also had an auction closing — on a quiet marketplace, never.
`tests/test_auction_lifecycle.py::TestSweepReliability` covers it.

Each sweep isolates per-auction failures: one bad auction logs and is retried
next pass rather than stopping the rest. Everything they call is idempotent,
so a duplicated tick is harmless.

---

## 8. Notifications

Push is primary; the WebSocket is a live-view nicety that must never be the
only delivery. Events go through the **event catalog**
(`api/core/event_catalog.py`), not the legacy `api.core.events` bus — the
legacy bus stops invoking in-process handlers once `REDIS_URL` is set, which
is precisely the production configuration.

| event | to |
|---|---|
| `AUCTION_OUTBID` | the bidder who was just beaten |
| `AUCTION_ENDING_SOON` | everyone who has bid |
| `AUCTION_WON` | the winner, with the deal id and the payment deadline |
| `AUCTION_LOST` | everyone who bid and did not win — including on a no-sale close, since they are waiting on an answer either way |
| `AUCTION_NO_SALE` | the seller, on `no_bids` and `reserve_not_met`, carrying which one: "nobody bid" and "the bidding never reached your reserve" are different problems with different next moves |
| `AUCTION_PAYMENT_LAPSED` | winner and seller |

Emission is wrapped in `_safe_emit`: a notification failure must not roll back
a close that has already been decided.

---

## 9. Money

### What this system does

Monetary values are produced through `api/core/money.py`:

```python
money(v)            # quantize to 2dp, ROUND_HALF_UP, returns float
add_money(*vs)      # sum in Decimal, quantize once — no accumulated drift
pct_of(v, rate)     # commission and friends
money_decimal(v)    # same quantization, stays a Decimal (for Numeric columns)
```

Floats are converted through `repr()`, never `Decimal(0.1)` — otherwise the
float's own representation error is carried straight into the Decimal
arithmetic meant to avoid it. Rounding is half-up rather than Python's
banker's rounding, matching both the convention everyone expects and the
`round()` calls already in the escrow path.

Used in the auction path for `minimum_next_bid` (`add_money(current_bid,
increment)`), bid quantization, and in escrow for commission (`pct_of`) and
`amount_to_pay` (`add_money(agreed_price, commission)` — previously an
unrounded float sum).

### Why the columns are still Float

`LedgerEntry.amount_kes` — the actual double-entry record — is already
`Numeric(18,2)`. Everything else is `Float`:

`Listing.price`, `Listing.reserve_price`, `Bid.amount`,
`AuctionMeta.starting_price` / `min_bid_increment` / `current_bid` /
`winning_amount`, `Deal.agreed_price` / `Deal.commission`,
`MpesaTransaction.amount`, `FeaturedPayment.amount`,
`VerificationPayment.amount`.

Converting those to `Numeric` is the textbook answer and was deliberately
**not** done here:

* **Python raises `TypeError` on `Decimal + float`.** A partial migration does
  not degrade gracefully — it raises the first time a migrated column meets an
  un-migrated one, somewhere in escrow, M-Pesa reconciliation, disputes or
  commission. The dangerous version of this change is the incremental one.
* The safe version touches every payment path at once, which is exactly the
  code that must not break in a pass whose subject is auctions.

Float is exact for integers up to 2⁵³ and Kenyan marketplace prices are whole
shillings, so storage is not where error creeps in — arithmetic is
(`0.1 + 0.2`, 3% of an odd number, a sum of three rounded values). Quantizing
through Decimal at every point where a value is **produced** means what gets
stored is always a clean 2-decimal number, and the float holding it is the
nearest double to that: the same guarantee `Numeric` would give at these
magnitudes.

`EscrowLedger._entry` quantizes through `money_decimal` rather than trusting
the column, because SQLAlchemy's `Numeric` degrades to float on SQLite — so
without it the ledger would store one number in CI and another in production.

### Still worth doing later

A real `Numeric` migration across every column above, done in one pass with
the arithmetic converted at the same time. The ledger already shows the shape.

---

## 10. Flutter

The seller sets the full auction contract in the sell wizard
(`sell_price_screen.dart`): starting price, **minimum bid increment**, start
time and end time, plus the reserve that was previously the only auction field
in the flow. All of it persists and restores with the rest of the draft
(`sell_wizard_data.dart`) and is submitted in the single `POST /listings`
call (`sell_review_screen.dart`) as `min_bid_increment`, `auction_starts_at`,
`auction_ends_at`.

The client validates for a fast error message. The backend re-validates
because it is the authority — see §6.

---

## 11. Deliberately not built

Out of scope by design, not by omission: proxy/automatic bidding, bid
withdrawal, anti-sniping time extension, bidder deposits, runner-up offers,
watchlists, auction analytics, seller subscriptions, promoted auctions, and
any new payment or escrow provider. Auctions reuse the existing Deal,
E-Confirm and escrow machinery end to end.

---

## 12. Tests

`backend/tests/test_auction_lifecycle.py` — 55 tests:

| class | covers |
|---|---|
| `TestBidWindow` | bids before `starts_at`, after `ends_at`, on a closed auction |
| `TestIncrements` | minimum next bid, sub-increment rejection, first-bid floor |
| `TestConcurrency` | simultaneous bids, CAS loser behaviour, retry exhaustion |
| `TestReserve` | sub-reserve bids accepted; reserve evaluated only at close; never leaked |
| `TestClose` | all four outcomes; idempotency; listing status transitions |
| `TestWinnerBecomesADeal` | Deal creation, commission, E-Confirm handoff |
| `TestPaymentDeadline` | deadline set on win, lapse cancels and relists |
| `TestBidEndpointDelegates` | the router owns no rules |
| `TestSweepDrivesTheWholeThing` | close + notify + lapse through the worker |
| `TestDealCreationFailureAndRetry` | failure leaves auction closed, retry succeeds |
| `TestTermsLocking` | 409 on both PATCH doors, per-term, per-state |
| `TestFullJourney` | create → bid → close → deal → pay, end to end |
| `TestSweepReliability` | the retry pass runs on a tick with no closings |
| `TestOrphanedDealClaim` | a claim that never became a Deal is detected and recovered |

---

## Verification (2026-09-18)

```
backend    673 passed          (CI config: SQLite + Redis, --cov-fail-under=35; coverage 50.46%)
flutter    32 passed
analyze    0 errors            (flutter analyze --no-fatal-warnings --no-fatal-infos)
```
