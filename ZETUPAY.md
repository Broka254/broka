# ZetuPay

How BROKA collects money that is its own: listing fees, premium plans,
featured boosts and verification badges. Code: `backend/api/core/zetupay.py`
(the API client), `backend/api/domains/payments/` (the payment and its
webhook), `backend/api/models/zetupay.py` (the tables). Tests:
`backend/tests/test_zetupay.py`.

```
BUYER  → E-CONFIRM → SELLER     deals, escrow, auctions      domains/escrow, ESCROW_AUDIT.md
USER   → ZETUPAY   → BROKA      fees, plans, boosts, badges  domains/payments (this document)
```

The two never meet. No deal, escrow or dispute code imports ZetuPay (a test
reads their source to keep it so), ZetuPay's tables never refer to a deal,
and `Purpose` has no value for deal money - `start()` refuses anything else.

## Switching it on

**Not yet.** The request format in `core/zetupay.py` has not been checked
against ZetuPay's API reference, so `CONTRACT_VERIFIED` there is `False`, and
while it is, `ZETUPAY_ENABLED` is ignored: the four charges stay on Daraja,
startup logs an error, and nothing else changes (startup does not fail over
it - that would take deals down too).

`ZETUPAY_ENABLED` (default `false`). Off, the four charges go through Daraja
(`core/mpesa_stk.py` and the two legacy routers) exactly as before. On, every
new charge goes through ZetuPay; payments already started on Daraja still
settle through Safaricom's callbacks.

1. Check every row of the table below against ZetuPay's current API
   reference; correct `core/zetupay.py` and `tests/test_zetupay.py` to the
   exact contract, including how webhooks are authenticated (below); then
   set `CONTRACT_VERIFIED = True` in the same change.
2. Set `ZETUPAY_SECRET_KEY` (`sk_live_...`), and whatever webhook credential
   ZetuPay's reference specifies, where the API's environment is configured
   (Azure, and `render.yaml` while Render still runs). Server-only: never in
   the app, the web storefront, logs or Git. `Settings` keeps them out of its
   `repr`.
3. In ZetuPay's dashboard, set the transaction webhook to
   `https://api.broka.co.ke/payments/zetupay/webhook`.
4. Set `ZETUPAY_ENABLED=true`. Production then refuses to start with a
   secret missing, and warns on a key that is not `sk_live_`.
5. Pay one KES 10 charge and follow it to the end (see "First live payment").

The app needs no change: it calls the same endpoints and polls the same
status routes.

## Check before switching on

ZetuPay's documentation could not be reached when this was built (its hosts
are outside the build environment's network policy, and no public index
carries its API reference). What BROKA was told is built in as stated: the
base URL, the secret key, the 202 "processing" answer to an STK push,
`x-zetupay-secret` on webhooks, and `waveTransactionId`. Everything else is
an assumption, all of it in `core/zetupay.py`:

| What | Assumed | Where |
|---|---|---|
| STK push | `POST /mpesa/stk-push`, body `{phone, amount, reference, description}`; 200/201/202 = accepted | `STK_PUSH_PATH`, `stk_push()` |
| Status | `GET /transactions/{reference}`; 404 = unknown | `STATUS_PATH`, `transaction_status()` |
| Auth | `Authorization: Bearer <secret key>` | `_headers()` |
| `paymentKey` | **not handled** - nothing here knows what it is | - |
| Amounts | whole KES | `stk_push()` |
| Webhook auth | `x-zetupay-secret` compared with `ZETUPAY_WEBHOOK_SECRET`, a separate setting. **Unconfirmed**: ZetuPay may send the secret key itself, or something else | `webhook_secret_ok()` |
| Webhook fields | `reference`, `status`, `amount`, `currency`, `waveTransactionId`, `mpesaReceiptNumber`, flat or under `data` | `_REFERENCE` ... `_RECEIPT` |
| Statuses | success / completed / paid; failed / cancelled / expired / timeout; anything else is still pending | `_SUCCESS`, `_FAILED` |
| Subscriptions | ZetuPay's subscription API is not used | - |

The webhook reader accepts the usual alternative spellings of each field, so
a webhook still parses if a name differs; the STK push body must match
exactly. Once the reference is in hand, narrow the readers to its exact
names.

## First live payment

Only after all of the above. One KES 10 charge: the smallest listing fee is
KES 9 and the cheapest plan KES 199, so the simplest is a temporary price,
or a listing whose quote is about KES 10. Check, in order: the prompt
reaches the phone; `zetupay_payments` goes `processing`, then `success` with
a `wave_transaction_id` and receipt; one `zetupay_transactions` row with
outcome `applied`; the domain row is `success` and the listing is live;
resending the same webhook from ZetuPay's dashboard answers `duplicate` and
changes nothing; nothing in `deals` or `external_escrows` changed.

## A payment

`domains/payments/service.py` has the detail. In short:

1. **Start.** The domain writes its own pending row as it always has
   (`listing_payments`, `subscription_payments`, `featured_payments`,
   `verification_payments`, now with `provider = 'zetupay'`). The service
   writes a `zetupay_payments` row under a new **reference** and commits both
   before calling ZetuPay - so a webhook that beats ZetuPay's reply still
   finds it.
2. **The reference** is twelve characters - the purpose (`LF` listing fee,
   `PL` plan, `BS` boost, `VB` badge) and 50 random bits, e.g.
   `LF7K3M9Q2XAB` - and its row says who pays (`user_id`), for what
   (`purpose`), how much (`amount`, the only amount that buys anything) and
   which BROKA record (`target_id`, the domain row; `related_id`, the listing,
   plan or badge tier).
3. **ZetuPay's 202 buys nothing.** The payment becomes `processing`; the
   domain row stays pending; the listing stays hidden.
4. **The result** arrives as a webhook, or as ZetuPay's own status answer
   when the app polls and the webhook is late (after 20 seconds), or from
   the 5-minute sweep (payments 2 minutes to 24 hours old). All three go
   through `apply_event()`.
5. **Applied** only for a success with the amount asked for, in KES. The
   domain then does what it always did: extends `Listing.paid_until` and
   announces a first payment, extends the plan from where it ends, features
   the listing, grants the badge.

## Webhook and idempotency

`POST /payments/zetupay/webhook`:

- **401** without the right `x-zetupay-secret` (compared in constant time;
  with no secret configured, everything is refused). Checked before the body
  is read.
- **400** for a body that isn't a JSON object.
- **200** `{"received": true, "outcome": ...}` otherwise - including for
  outcomes that buy nothing, so ZetuPay stops redelivering.
- **500** if processing failed, so ZetuPay redelivers; nothing of that event
  was committed, or the ledger turns the redelivery away.

Idempotency is held by the database, not by a check that two requests could
both pass:

- Each terminal state of a transaction is a row in `zetupay_transactions`,
  unique on **(`waveTransactionId`, status)**, written first. A redelivered
  webhook, or a webhook racing the status poll, fails that insert and stops:
  outcome `duplicate`. (Keyed with the status, not the id alone, so a
  "processing" or "failed" report never blocks the same transaction's
  later success.)
- The payment is then row-locked and re-read, and its state decides:

| Event | Payment | Outcome |
|---|---|---|
| success, right amount | not yet paid (including failed: a prompt that timed out here, then was paid) | `applied` |
| success, right amount | paid by another `waveTransactionId` | `duplicate_payment`: not applied; audit + reconciliation alert to refund |
| success, wrong amount or currency | any | `amount_mismatch`: not applied, unpaid payment failed; audit + alert |
| success | no such reference | `unknown_reference`: recorded; audit + alert |
| failed / cancelled | initiated or processing | `failed`: the domain row fails, a new prompt is allowed |
| pending, or anything already settled | | `ignored` |

## ZetuPay down or slow

- Refused or unreachable: the payment fails (`prompt_not_sent`), the app
  gets a 502 "Couldn't reach M-Pesa", and a retry is allowed at once.
- Timed out: the prompt may have gone out. The payment fails
  (`provider_timeout`) and the app is told it can still pay a prompt that
  arrives; if it is paid, the webhook or the sweep applies it.
- A payment is never failed for being slow.

## Plans

BROKA's plans are prepaid: 1, 3, 6 or 12 months for the catalogue price
(PRICING.md §4), and BROKA's `subscriptions` row is the authority. A renewal
is another payment for the same plan, through ZetuPay like any other, and
extends the plan from where it ends. ZetuPay's own subscriptions -
charging automatically each month - are not wired in: their API could not be
read. When they are, each charge they make arrives as a transaction webhook
with its own `waveTransactionId`, and the ledger above already applies each
one once.

## Not done

- `GET` routes for ZetuPay payments in the admin screens; revenue is in
  `zetupay_payments` (and the domain tables) but nothing sums it yet.
- Reconciliation alerts without a deal share one Sentry issue per kind an
  hour (`core/reconciliation.py` keys repeats on the deal); the audit row
  and the log line are written every time.
