# Proposed Terms wording: store orders and escrow

**Status: a proposal for legal review. Not in effect.** The Terms that users
accept are unchanged: `flutter_app/assets/legal/terms.md`, revision
`2026-10-12`. No version, digest or acceptance rule changed with this
document. Nothing below should be applied until it is approved, and then only
through the versioning steps in the last section.

## Why the current text can mislead a store-order buyer

BROKA has two ways of buying, with different payment models. Both are
described here as the code implements them, not as a new policy.

| | Deals agreed in the app | Store orders |
|---|---|---|
| What it is | Buyer and seller agree a deal through Zeno; `EscrowService.finalize_deal` opens a deal | A buyer sends a store an order request from the web storefront |
| Who holds the money | Where BROKA offers escrow, E-Confirm (BROKA never settles it, `ESCROW_AUDIT.md`); otherwise the buyer pays the seller directly | **BROKA never receives, holds, verifies or releases money** (`STORE_ORDERS.md`). The buyer pays the store directly, or opens an escrow on an independent provider's own website |
| What BROKA records | The deal's escrow status from E-Confirm | Reports from the buyer and the store, each marked `verified: false` |
| When something goes wrong | A dispute in the app (Terms §12) | "Report a problem" on the order: it notifies the store and doesn't change the order. There is no dispute flow |

Current Terms §7, first bullet:

> **Where BROKA offers escrow**, the buyer's payment is held by our licensed
> escrow partner (E-Confirm), not by BROKA, and is released to the seller
> under the escrow partner's rules once the buyer confirms delivery or the
> deal is otherwise settled. The escrow partner's own terms also apply.

Three things make this unclear for store orders:

1. **The same provider appears in both models.** BROKA's escrow directory,
   which store-order buyers choose from, lists eConfirm (`id: econfirm`,
   status `under_review`, which counts as listed).
   A buyer who chooses it for a store order opens that escrow themselves, on
   eConfirm's site. BROKA does not open, monitor or settle it. Read together
   with "Where BROKA offers escrow ... our licensed escrow partner
   (E-Confirm)", the buyer can believe BROKA arranged or stands behind that
   escrow.
2. **§12 says "If a deal goes wrong, open a dispute in the app."** Store
   orders have no dispute process.
3. **The Terms never name store orders.** §1 says "The deal you agree is
   between you and the other user"; an order request to a store isn't
   obviously a "deal".

The storefront itself already says the right things at checkout and on every
order. The payment block on every order reads: "BROKA does not receive, hold,
verify or release payments for store orders. These are reports made by the
buyer or the store, not confirmations from BROKA or from any payment
provider." A chosen provider carries: "This escrow provider is independent of
BROKA. Check its own fees, terms, protections and process on its official
website before you pay." (both in `store_orders/lifecycle.py`). The checkout's
escrow box says the services "are not run by BROKA"
(`web/src/components/EscrowBox.tsx`). The Terms are the only place that
says otherwise.

## Proposed wording

Each change shows the current text, the proposed text in the Terms' own
formatting, and what changed. Bold in the quotes is the Terms' formatting,
not a change marker.

### Change 1: §7 (heading and bullets)

Current:

> ## 7. Payments for deals
>
> - **Where BROKA offers escrow**, the buyer's payment is held by our licensed
>   escrow partner (E-Confirm), not by BROKA, and is released to the seller
>   under the escrow partner's rules once the buyer confirms delivery or the
>   deal is otherwise settled. The escrow partner's own terms also apply.
> - **Where the app says BROKA does not handle the payment**, you pay the
>   seller directly. BROKA does not hold, receive or guarantee that money and
>   cannot recover it. Pay only once you have seen the item, and never to a
>   number or account that someone sends you claiming to be "BROKA escrow".
> - Money you pay BROKA for its own services (section 8) is collected through
>   M-Pesa or our payment partner (ZetuPay) and is never mixed with deal money.

Proposed:

> ## 7. Payments for deals and store orders
>
> - **Deals agreed in the BROKA app.** Where BROKA offers escrow for a deal,
>   the buyer's payment is held by our licensed escrow partner (E-Confirm),
>   not by BROKA, and is released to the seller under the escrow partner's
>   rules once the buyer confirms delivery or the deal is otherwise settled.
>   The escrow partner's own terms also apply.
> - **Where the app says BROKA does not handle the payment**, you pay the
>   seller directly. BROKA does not hold, receive or guarantee that money and
>   cannot recover it. Pay only once you have seen the item, and never to a
>   number or account that someone sends you claiming to be "BROKA escrow".
> - **Store orders.** When you send a store an order request on BROKA, BROKA
>   does not receive, hold, verify or release any payment for it, and the
>   escrow in the first point does not apply. You pay the store directly, or
>   through an independent escrow provider you choose from the providers
>   BROKA lists. You open that escrow on the provider's own website, under its
>   own terms, fees and protections, and BROKA does not open, monitor or
>   settle it, including when the provider is one BROKA also works with for
>   deals agreed in the app. The payment updates on a store order are reports
>   made by you or the store, not confirmations from BROKA or from any payment
>   provider.
> - Money you pay BROKA for its own services (section 8) is collected through
>   M-Pesa or our payment partner (ZetuPay) and is never mixed with deal money.

What changed:

- Heading: "and store orders" added.
- First bullet: the lead "Deals agreed in the BROKA app." added, and "for a
  deal" added after "Where BROKA offers escrow". The rest of the sentence is
  word for word the current text. Its old bold lead moves to the new lead.
- New third bullet, "Store orders". Every statement in it describes what the
  code does (`STORE_ORDERS.md` §4) and repeats the notices buyers already
  see.
- Second and last bullets: unchanged.

### Change 2: §12, third paragraph (variant A)

Current:

> If a deal goes wrong, open a dispute in the app. Zeno will help both sides
> set out what happened, and BROKA may review the evidence. For an escrowed
> deal, the outcome follows the escrow partner's rules. BROKA's dispute
> process is not a court: it does not take away your right to go to the
> authorities or the courts.

Proposed:

> If a deal goes wrong, open a dispute in the app. Zeno will help both sides
> set out what happened, and BROKA may review the evidence. For an escrowed
> deal, the outcome follows the escrow partner's rules. For a store order,
> report the problem on the order: it goes to the store. BROKA's dispute
> process is for deals agreed in the app, and if you paid for a store order
> through an independent escrow provider, that provider's own process
> applies. BROKA's dispute process is not a court: it does not take away your
> right to go to the authorities or the courts.

What changed: two sentences added after "...follows the escrow partner's
rules." The rest is unchanged.

Variant A describes what is built. If BROKA intends to review store-order
problems itself, that is a business decision, and the support process has to
exist before the Terms promise it. No wording is proposed for that case.

### Change 3 (optional): §1

Current:

> The deal you agree is between you and the other user.

Proposed:

> The deal you agree is between you and the other user. An order you place
> with a store on BROKA is between you and the store.

## Questions for counsel (no wording proposed)

- **§16 (liability)** names "payments made directly to another user". Should
  it also name store orders and independent escrow providers? That would be a
  new limitation of liability, so it is left to counsel.
- **"Our licensed escrow partner (E-Confirm)".** The directory's own record
  for eConfirm says BROKA has not yet confirmed the company's exact registered
  name, and that its terms describe the platform as a beta
  (`escrow_directory/seed.py`). Counsel should confirm the "licensed" claim
  while the sentence is under review. The Terms spell the name "E-Confirm" and
  the directory spells it "eConfirm". Pick one.
- **§9** forbids asking "for payment outside the agreed channel". For a store
  order, paying the store directly is an agreed channel. Counsel may want
  that stated.

## Making the change, once approved (`LEGAL_ACCEPTANCE.md`)

The version is the document's own date, and any change to the text is a new
revision, even a typo fix.

1. Edit `flutter_app/assets/legal/terms.md`, including its
   `_Last updated: DD Month YYYY_` line.
2. In `backend/api/core/legal_documents.py`, set `TERMS.version` to that date
   (`YYYY-MM-DD`) and `TERMS.digest` to the file's SHA-256
   (`sha256sum flutter_app/assets/legal/terms.md`).
3. In `flutter_app/lib/core/legal/legal_documents.dart`, set the same version.
4. In `web/src/lib/legal.ts`, set `TERMS_VERSION`. Copy the new text into
   `TERMS_MARKDOWN` in `web/src/lib/legal-text.ts`, character for character.
5. Run `backend/tests/test_legal_documents.py` and the web suite
   (`src/lib/legal.test.ts`). Both fail until every copy, version and digest
   agree.

What the buyer sees, and when:

- **New accounts** (app and web storefront) see the text they accept. The web
  sign-up shows the app's own text at `/store/legal/terms` and sends
  `TERMS_VERSION`, and the backend refuses any other revision.
- **Rollout.** The backend accepts exactly one Terms version at a time
  (`check_signup_acceptance`). Whichever side moves first, sign-ups from the
  other are refused until they match: an app build still sending
  `2026-10-12` once the backend has moved, or a new build that arrives
  before it. Plan the release to keep that window short (`LEGAL_ACCEPTANCE.md`,
  "Rollout and compatibility"). Deploy the web storefront together with the
  backend, since the storefront sends its version on every sign-up.
- **Existing accounts** accepted `2026-10-12`, and nothing asks them to accept
  again: the re-acceptance flow is not built. Under §18 a material change must
  be announced before it takes effect. A buyer who signed up earlier would
  otherwise place store orders under the old text. Before store orders are
  switched on in production (`STORE_ORDERS_ENABLED`), decide between
  building re-acceptance and announcing the change under §18.
- **Order of release:** approve the wording, ship the new revision, then
  switch store orders on.
