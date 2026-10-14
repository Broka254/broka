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

`ZETUPAY_ENABLED` (default `false`). Off, the four charges go through Daraja
(`core/mpesa_stk.py` and the two legacy routers) exactly as before. On, every
new charge goes through ZetuPay; payments already started on Daraja still
settle through Safaricom's callbacks. The app needs no change: it calls the
same endpoints and polls the same status routes.

1. `ZETUPAY_SECRET_KEY`: the wallet's **live** Secret Key (`sk_live_...`)
   from ZetuPay's Developers page, set where the API runs (Railway). It
   authenticates BROKA's requests *and* verifies ZetuPay's webhooks, which
   are always signed with the live key - there is no second webhook secret.
   Server-only: never in the app, the storefront, logs or Git; `Settings`
   keeps it out of its `repr`. Startup refuses production with ZetuPay on and
   no key, and logs an error for a key that is not `sk_live_`.
2. On the same page, add `https://api.broka.co.ke/payments/zetupay/webhook`
   under **Transaction Callback Endpoints**.
3. `ZETUPAY_ENABLED=true`.
4. Run the KES 10 test (below).

`CONTRACT_VERIFIED` in `core/zetupay.py` is the switch above the switch:
`True` since the client was checked against ZetuPay's documentation. Set it
back to `False` if the API ever changes under us - `ZETUPAY_ENABLED` is then
ignored and the charges stay on Daraja, without startup failing over it.

## The contract

Read from ZetuPay's documentation (pay.zetupay.co.ke/docs: authentication,
stk-push, payment-status, callbacks, errors, testing) on 2026-10-01, and
held to it by `tests/test_zetupay.py`, which uses the documented sample
responses verbatim.

| What | ZetuPay's contract | BROKA |
|---|---|---|
| Base URL | `https://pay.zetupay.co.ke/api/v1` | `ZETUPAY_BASE_URL` |
| Auth | `Authorization: Bearer sk_live_...`, from a server only | `_headers()` |
| STK push | `POST /payment/stk-push`; body `{amount, phoneNumber, reference}`: whole KES 1-250,000, a Safaricom number, a reference up to 100 characters; optional `Idempotency-Key` header (24 hours) | body exactly that; the reference is also the `Idempotency-Key`, so a repeated request never prompts twice |
| Its answer | `202 {success: true, data: {paymentKey, waveTransactionId, status: "processing", ...}}` - not a payment | both ids kept on `zetupay_payments` (`provider_payment_id`, `wave_transaction_id`); the payment becomes `processing` |
| Errors | `{success: false, error, message}`: 400 401 402 403 409 422 429 500 502 | all mean "no prompt": the payment fails, the app gets a 502 |
| Status | `GET /payment/stk-push/{paymentKey}` with the key; `status` pending / processing / success / failed / cancelled / expired; 404 unknown, 410 just expired; kept 24 hours | asked by `paymentKey`; `success` applies, failed/cancelled/expired fail it, anything else waits; an answer naming another reference is refused |
| Webhook | Successful payments only, POSTed to the Transaction Callback Endpoint as the bare transaction: `status: "success"`, `amount`, `reference`, `waveTransactionId`, `receiptNumber`, ...; retried up to 6 times until a 2xx | `POST /payments/zetupay/webhook` |
| Webhook auth | `x-zetupay-signature: t=<unix>,v1=<hex HMAC-SHA256 of "<t>.<raw body>">` keyed with the **live** Secret Key; reject timestamps over 5 minutes old. The older `x-zetupay-secret` header carries the key itself - ZetuPay advises against relying on it | signature checked on the raw body before parsing, constant-time, 5-minute window; `x-zetupay-secret` is ignored |
| Subscriptions | Plans & subscriptions events share the URL as `{event, data}` | acknowledged and ignored - BROKA creates no ZetuPay subscriptions |
| Testing | No sandbox: even `sk_test_` keys move real money | the KES 10 test charge below |

## The KES 10 test

ZetuPay's own going-live check is a small real payment to your own phone.
`POST /payments/zetupay/test-charge` (admins only, `{"phone_number": ...}`)
prompts that phone for KES 10 through the whole path - reference, ledger,
signature, amount check, settled once - and buys nothing
(`domains/payments/test_charge.py`). `GET
/payments/zetupay/payments/{reference}` (admins only) shows where it stands,
asking ZetuPay first if it is unfinished.

Check, in order: the prompt reaches the phone; the charge goes `processing`,
then `success` with a `wave_transaction_id` and receipt; one
`zetupay_transactions` row with outcome `applied`; ZetuPay's dashboard shows
the webhook delivered with a 2xx. Then cancel a second test prompt on the
phone: no webhook comes, and the lookup reports `failed`. Nothing in `deals`
or `external_escrows` changes.

## A payment

`domains/payments/service.py` has the detail. In short:

1. **Start.** The domain writes its own pending row as it always has
   (`listing_payments`, `subscription_payments`, `featured_payments`,
   `verification_payments`, now with `provider = 'zetupay'`). The service
   writes a `zetupay_payments` row under a new **reference** and commits both
   before calling ZetuPay - so a webhook that beats ZetuPay's reply still
   finds it.
2. **The reference** is twelve characters - the purpose (`LF` listing fee,
   `PL` plan, `BS` boost, `VB` badge, `TS` test charge) and 50 random bits, e.g.
   `LF7K3M9Q2XAB` - and its row says who pays (`user_id`), for what
   (`purpose`), how much (`amount`, the only amount that buys anything) and
   which BROKA record (`target_id`, the domain row; `related_id`, the listing,
   plan or badge tier).
3. **ZetuPay's 202 buys nothing.** The payment becomes `processing`; the
   domain row stays pending; the listing stays hidden.
4. **The result** arrives as a signed webhook (successes only), or as
   ZetuPay's own status answer by `paymentKey` - when the app polls (after
   5 seconds, ZetuPay's suggested interval) or from the 5-minute sweep
   (payments 2 minutes to 24 hours old). Failures send no webhook, so asking
   is how they are learnt of. All of it goes through `apply_event()`.
5. **Applied** only for a success with the amount asked for, in KES. The
   domain then does what it always did: extends `Listing.paid_until` and
   announces a first payment, extends the plan from where it ends, features
   the listing, grants the badge.

## Webhook and idempotency

`POST /payments/zetupay/webhook`:

- **401** without a valid, fresh `x-zetupay-signature` (with no key
  configured, everything is refused). Checked on the raw body before it is
  parsed.
- **400** for a body that isn't a JSON object.
- **200** `ignored_event` for a subscription event (`{event, data}`).
- **200** `{"received": true, "outcome": ...}` otherwise - including for
  outcomes that buy nothing, so ZetuPay stops redelivering.
- **500** if processing failed, so ZetuPay redelivers; nothing of that event
  was committed, or the ledger turns the redelivery away.

Idempotency is held by the database, not by a check that two requests could
both pass:

- Each terminal state of a transaction is a row in `zetupay_transactions`,
  unique on **(`waveTransactionId`, status)**, written first. A redelivered
  webhook, or a webhook racing the status poll, fails that insert and stops:
  outcome `duplicate`. (Keyed with the status, not the id alone: ZetuPay
  assigns the `waveTransactionId` when the prompt is sent, so a "failed"
  answer must never block the same transaction's later success.)
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
  arrives; if it is paid, its success webhook applies it. (With no 202 there
  is no `paymentKey`, so nothing can ask about it.)
- A payment is never failed for being slow.

## Plans

BROKA's plans are prepaid: 1, 3, 6 or 12 months for the catalogue price
(PRICING.md §4), and BROKA's `subscriptions` row is the authority. A renewal
is another payment for the same plan, through ZetuPay like any other, and
extends the plan from where it ends. ZetuPay's own plans & subscriptions
(`POST /plans`, `POST /subscriptions`) are not used: they bill a fixed
amount on a fixed interval, require each subscriber's email, and settle
upgrades, downgrades and prepaid months nowhere - BROKA's plans do all
three. Moving to them is a product decision (auto-renewal, past-due
handling, cancellation), not a wiring change. Their events reach the
webhook as `{event, data}` and are ignored.

## Not done

- `GET` routes for ZetuPay payments in the admin screens; revenue is in
  `zetupay_payments` (and the domain tables) but nothing sums it yet.
- Reconciliation alerts without a deal share one Sentry issue per kind an
  hour (`core/reconciliation.py` keys repeats on the deal); the audit row
  and the log line are written every time.
