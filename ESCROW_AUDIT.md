# Escrow audit — findings and fixes (2026-09-14)

## 1. The ledger's release entry used the wrong amount (critical)

`record_escrow_released()` built its `escrow_holding` debit from the
caller's `amount` — `deal.agreed_price` — regardless of what had actually
been escrowed.

That's correct for the **E-Confirm flow**, which escrows the full goods
price. It's wrong for the **legacy M-Pesa flow**, where the STK push
charges the *commission only* (`api/routers/mpesa.py`:
`amount = max(1, int(round(deal.commission)))`) because the goods settle
off-platform.

So on a 50,000 KES legacy deal the ledger credited `escrow_holding` 1,500
and then debited it 50,000 — leaving that account short **48,500 on every
completed legacy deal**, and inventing a 48,500 `seller_wallet` credit for
money BROKA never held.

**Fix:** release and refund now derive the amount from
`escrow_balance(deal_id)` — what the deal's escrow account actually holds
per the ledger — instead of a caller-supplied figure. The operation is
self-balancing: it cannot leave a residue however wrong the caller's idea
of the amount is. Commission is clamped to what's held, which is what makes
the legacy path fall out correctly with no seller-payout leg at all.

## 2. The safety net couldn't see it (critical)

`trial_balance()` compared total debits to total credits across the whole
table. **Every ledger helper writes matched debit/credit pairs**, so that
equality holds *by construction* however wrong the individual amounts are.
The books could be arbitrarily broken and the only check that existed would
still report `balanced: true`.

Worse: `trial_balance()` was never called from anywhere. The double-entry
ledger's only integrity check was unreachable dead code.

**Fix:** added `negative_escrow_deals` / `escrow_integrity_ok`. A deal's
escrow balance may be positive (held) or zero (settled) — never negative,
which means more money left the deal than entered it. That is exactly the
condition bug #1 produced. Exposed at `GET /admin/ledger-integrity`.

## 3. Ledger writes were not idempotent (high)

`core/deal_hub_subscribers.py` drives these writes off an at-least-once
event bus. A redelivered `EscrowFunded`/`EscrowReleased` appended a second
full set of entries, doubling a deal's recorded money while keeping the
global trial balance perfectly "balanced". Each operation now checks for
its own signature entry first.

## 4. `agreed_price` was completely unvalidated (critical)

`POST /deal/finalize` took a bare `float` on the endpoint that creates a
money obligation. Three classes got through:

- **Negative.** `-50000` → commission `-1500`, `amount_to_pay` `-51500`, a
  Deal row of negative money poisoning every aggregate over it.
- **Zero/dust.** `0.001` rounds commission to `0.00` — and completing deals
  is what raises `completed_deals` and trust score. Free reputation.
- **Infinity/NaN.** Python's `json` module parses the bare literals
  `Infinity` and `NaN` by default, so `{"agreed_price": Infinity}` reaches
  the handler as `float('inf')` — **verified, not theoretical**. `round(inf
  * 0.03, 2)` is `inf`, and it propagates silently. A bound alone doesn't
  catch NaN, which fails every comparison including against itself.

Fixed at the router (`gt=0`, `le`, `allow_inf_nan=False`) *and* in the
service, since `finalize_deal()` is also reachable from `negotiate.py`'s
deal-acceptance intents, which build a price from parsed conversation text.

## 5. M-Pesa callback trusted the reported amount (critical)

`txn.amount = float(item["Value"])` — the amount *we requested* was
overwritten with whatever the callback claimed, then the deal was marked
paid and `EscrowFunded(amount=txn.amount)` published, so the ledger
recorded that figure. The endpoint is unauthenticated by design, and its
own docstring already flags that a guessed `CheckoutRequestID` reaches it.
A forged callback could settle a 50,000 deal claiming `Amount: 1`; a
genuine partial payment was accepted as full settlement.

Now the requested amount is the authority and the callback's figure is
checked against it; a mismatch marks the transaction failed and settles
nothing.

## 6. Deal status had no transition guard on the callback (high)

`deal.status = DealStatus.paid` unconditionally. A late or replayed
callback could drag an already released/refunded/cancelled deal back to
`paid`, re-opening a settled deal for a second release. `callback_processed`
doesn't cover it — that's per-transaction, and a deal can have several.

## 7. Seller ratings inflated themselves (high)

The callback ran `seller.rating = min(5.0, seller.rating + 0.05)` on
payment. A rating is supposed to mean a buyer assessed them; this handed
out +0.05 for the act of being paid, before delivery had happened. On a
marketplace whose whole proposition is trust, a self-inflating rating is
worse than no rating. Removed.

`seller.completed_deals` was also incremented here *and* again on delivery
confirmation, so every legacy deal counted twice. Now credited once, at
release, where it's earned.

## Listing stock at finalize (2026-09-30)

`finalize_deal` didn't check the listing wasn't already committed: two
buyers could both finalize on the same listing, and `listing.status =
"pending"` was set without checking. It also set "pending" on the first
agreement whatever the listing's quantity, so a seller of 100 bags vanished
from every feed when one bag was agreed, and nothing set it back when that
deal was refunded or cancelled.

Now a deal takes `Deal.quantity` units (NULL = one), counted under the
listing's row lock against `Listing.quantity` less the units already in
deals that aren't refunded or cancelled; more than are left is a 409. The
listing is hidden when the last unit goes, and the five-minute sweep puts it
back on sale when a deal gives units back, or marks it completed once every
unit is paid out (`api/domains/listings/stock.py`). No payout, refund or
dispute path was touched. Auctions keep their own lifecycle (one item),
but take the same lock: the close and a retry of the winner's deal could
both be inside `finalize_deal` at once, neither saw the other's uncommitted
deal, and the winner got two (`test_concurrent_sweeps_close_each_auction_
exactly_once`, intermittently on PostgreSQL). The second now waits and
returns the first's deal.

## Partial payments (2026-10-02)

A buyer pays before anyone confirms the price, and need not pay it all at
once: whatever they pay (never more than the balance, at least KES 100 unless
it clears the balance) goes into escrow, and they add to it until the
balance is cleared. Waiting for the seller to confirm a price before paying
was ruled out: a buyer turned away at the pay button may not come back.

- **One E-Confirm transaction per payment.** `external_escrows` holds one row
  per payment (`payment_no` 0, 1, 2...); `deal_id` is no longer unique, and
  `(deal_id, payment_no)` is, which also stops a double tap opening the same
  payment twice. Existing rows are each their deal's payment 0.
- **One open payment at a time.** While the latest payment is being set up
  or its prompt is on the buyer's phone, a pay request continues it; the next
  payment opens only once it has settled, and only on a `paid` deal with a
  balance and no open refund request. Auctions are paid in one payment.
- **Commission** is split across the payments in proportion, and the payment
  that clears the balance carries the rest, so paying in parts costs the same
  as paying at once (minimum included).
- **The price.** The seller states the price they agreed
  (`POST /deal/{id}/price`), never below what is paid or being paid; the
  buyer sees the balance and pays it or asks for a refund. The seller can
  accept what was paid by stating that as the price.
- **Release** releases every funded payment; the deal is `released` only once
  E-Confirm has paid out all of them.
- **Ledger.** Funding is now idempotent per payment reference rather than per
  deal (a deal paid twice is credited twice, a redelivered event once).

## Release, reminders and refund requests (2026-10-02)

The rules live in `api/domains/escrow/protection.py`; the numbers in
`policy.py`, which the app is shown as deadlines.

- **Buyer release** (`POST /deal/{id}/confirm-delivery`) takes the buyer's
  answers to "has it been delivered?" and, for land, property and vehicles,
  "have the ownership documents been transferred?". A "no" makes the app
  recommend waiting; it never blocks, and it is written to the audit row.
- **Delivery claim → 72 hours.** The seller marks the deal delivered
  (`POST /deal/{id}/mark-delivered`, or the chat button). The clock starts at
  the claim, never at payment: started at payment, a seller who never
  delivered would be paid when it ran out. Zeno reminds the buyer every 12
  hours, an SMS goes on days 2 and 3 (texts wait out quiet hours), and at 72
  hours the money is released - for an E-Confirm deal through E-Confirm with
  the stored release codes, after the sweep has committed (a provider call
  must not run under its row locks). A failed automatic release is audited and
  raised as a reconciliation alert. This replaces the 4 check-ins over 7 days.
- **Refund request** (`POST /deal/{id}/refund-request`). Before a delivery
  claim, the seller is told at once (chat, push, SMS) and has 48 hours to
  accept or contest (`POST /deal/{id}/refund-response`), with a reminder and
  a second SMS at 24 hours. Silence refunds the buyer: nothing has left the
  seller's hands, so waiting costs them nothing, and a seller who disappears
  cannot hold the money. Contesting opens a dispute. After a delivery claim the
  buyer's word alone cannot undo the deal, so the request is a dispute. A
  seller who claims delivery while a refund request is open is contesting it
  (a dispute), never starting the countdown to their own payout. The buyer
  can withdraw the request (`DELETE`), and releasing the money withdraws it.
- **E-Confirm refunds are manual.** BROKA has no refund call on E-Confirm's
  API. An approved refund on an E-Confirm deal freezes it (`disputed`), writes
  an `econfirm_refund_required` audit row and reconciliation alert, and the
  team returns the money through E-Confirm, then closes the deal with
  `POST /admin/deals/{id}/econfirm-refunded` (refunded, and in the ledger).

**Found while doing it:** the ledger's release subscriber
(`deal_hub_subscribers.on_escrow_released`) read the deal before opening its
transaction, so `db.begin()` raised "A transaction is already begun" and no
release had ever been written to the ledger - every released deal's escrow
account stayed full. Fixed, with a test.

## Still open

- **Fees on a refund.** Who bears BROKA's commission and E-Confirm's fee when
  a deal is refunded is not decided; the E-Confirm refund alert asks the team
  to return what the buyer paid into escrow.
- **A declined STK prompt** still leaves that payment open (pending) for good,
  which blocks the next payment as it always blocked the first; it needs
  E-Confirm to say whether an unpaid transaction can be cancelled or retried.
- **Released deals missing their ledger release entry** (the subscriber bug
  above). Their escrow accounts still show the money held; they need
  compensating release entries. `/admin/ledger-integrity` does not list them,
  since a positive balance is not an integrity failure.
- **A seller can name any `buyer_id`**, creating a deal obligation against a
  user who never agreed. Pre-existing and acknowledged in the code's own
  comment, but it's spam surface.
- **No backfill for already-corrupted rows.** `/admin/ledger-integrity` will
  list every legacy deal released before this fix; those need compensating
  entries (the ledger is append-only by design — never edit them).
