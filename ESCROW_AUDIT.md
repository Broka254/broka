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

## Still open

- **`finalize_deal` doesn't check the listing isn't already committed.** Two
  buyers can both finalize on the same listing; `listing.status = "pending"`
  is set without checking it wasn't already pending for someone else.
- **A seller can name any `buyer_id`**, creating a deal obligation against a
  user who never agreed. Pre-existing and acknowledged in the code's own
  comment, but it's spam surface.
- **No backfill for already-corrupted rows.** `/admin/ledger-integrity` will
  list every legacy deal released before this fix; those need compensating
  entries (the ledger is append-only by design — never edit them).
