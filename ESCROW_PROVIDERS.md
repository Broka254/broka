# Escrow providers: the directory, the comparison, and Zeno's fraud guidance

BROKA does **not** run an escrow service and does **not** hold, receive,
control or release anyone's money. This document is about the information
BROKA gives people who choose an *independent* provider, and about helping
them avoid being defrauded while they do. `IN_APP_PAYMENTS_ENABLED` stays
`false`; nothing described here moves money.

(The repository also contains an E-Confirm **API integration** for deals paid
through BROKA - `backend/api/domains/escrow/`, described in `ESCROW_AUDIT.md`.
It is switched off by `IN_APP_PAYMENTS_ENABLED=false`, is untouched by this
work, and is a different thing from the directory of independent providers
described here. See "Open decisions" below.)

## Where things are

| What | Where |
|---|---|
| The one list of providers (records, fee maths, freshness, filters, wording) | `backend/api/domains/escrow_directory/` |
| The starting records (research inputs, not approvals) | `.../escrow_directory/seed.py` |
| Admin edits, reviews, suspension; public reads | `.../escrow_directory/router.py`, `repository.py` |
| Storage (provider rows, change history) | `backend/api/models/escrow_provider.py` |
| Zeno's scam rules and the guard on what a model says | `backend/api/domains/zeno_assistant/fraud_guidance.py` |
| Scam reports, private evidence, restrictions, appeals | `backend/api/domains/scam_reports/`, `backend/api/models/scam_report.py` |
| The app: compare, detail, report | `flutter_app/lib/features/safe_payment/provider_*.dart`, `report_scam_screen.dart` |
| The website's escrow box | `web/src/components/EscrowBox.tsx`, `web/src/lib/escrow-providers.ts` |

The app and the website have **no list of providers of their own**. They ask
`GET /escrow-providers` (and `/compare`). The older `GET /pricing/safe-payment`
still answers, built from the same catalogue, in the shape older app builds read.

## Public API

```
GET /escrow-providers                  listed providers, how current each is, notices, disclosures
GET /escrow-providers/compare          the same, filtered, with a fee estimate per provider
    ?amount=5000                       whole KSh the SELLER should receive
    &payout=phone|till|paybill|bank    where the seller is paid (some providers charge differently)
    &sort=name|lowest_fee|highest_limit
    &no_account=true  &kyc=required|not_required  &payment_method=mpesa|...
    &category=goods|services|vehicles|property|digital|freelance
    &documented_disputes=true  &documented_refunds=true
GET /escrow-providers/{id}             one provider in full (or its notice, if it is not listed)
```

Only `approved` and `under_review` providers are listed. `draft`, `rejected`
and `suspended` providers are not; a suspended one may have a short neutral
public notice (so that "Escrow Kenya" is never mistaken for "Kenya Escrow").
Internal reviewer notes and the reviewer's identity are never in a public
response (tested).

## The review process

A provider is **`under_review`** until an administrator has done every check
below and recorded it. Nothing is approved because the code shipped.

1. **Edit details** - `PATCH /admin/escrow-providers/{id}`. A change to
   anything that affects a fee needs `source_url` (a page on the provider's
   own domain) and `source_note` (what the page says). The edit **clears** the
   checks it makes untrue: changed fees clear the pricing review and its date;
   changed identity clears the identity check; changed terms, limits or
   protection clear the terms check; any of them takes an `approved` provider
   back to `under_review`. An edit **cannot** set its own `status`, review
   statuses, verification dates or reviewer: those are refused.
2. **Record each review** - `POST /admin/escrow-providers/{id}/review`
   for `identity`, `terms`, `pricing` (needs the page you checked against and
   what it showed) and `operational` (a real test transaction). A "verified"
   needs a real date, not in the future.
3. **Approve** - `POST /admin/escrow-providers/{id}/status {"status":"approved"}`.
   Refused unless: identity verified; the legal entity is named **and**
   confirmed; terms and pricing reviewed; pricing has a verification date; an
   operational test passed; the record has a verification date and a next review
   date; sources are recorded; the terms and privacy-policy URLs are present.
4. **Suspend** - `POST .../status {"status":"suspended","reason":"..."}`. Needs only
   a reason, and takes effect at once in the process that handled it and within
   30 seconds elsewhere. A suspended provider disappears from the list, the
   comparison, the ranking, Zeno's walkthrough and Zeno's prompt. It cannot go
   straight back to `approved`; it returns through `under_review`.

Every change writes an append-only revision (who, when, what, why, source) and
an audit-log row. Nothing in the code fetches a provider's website: **a fee
changes only when a named administrator records it with its source.**
There is no four-eyes rule (the repository has a single admin permission set);
see "Open decisions".

### Freshness

`ESCROW_PRICING_MAX_AGE_DAYS` (default 30) and `ESCROW_RECORD_MAX_AGE_DAYS`
(default 90). Pricing is **current** only if it was verified, the pricing review
says so, the date is not in the future and has not passed its limit or the
record's `next_review`. Otherwise it is **expired** (checked once, too long ago)
or **unverified** (never checked, or its fees were just edited). Only `current`
is good news: expired and unverified pricing is shown with a warning and is
**never ranked**.

### Link safety

A provider's addresses must be `https`, with no user-info, on the default port,
ASCII (no `xn--`), and on **exactly** the provider's canonical domain or
`www.` + it (never "ends with"). The canonical domain must be in
`ESCROW_PROVIDER_DOMAINS`, a deployment setting: an administrator can change what
a provider's page says but cannot make the app link to a domain nobody put in
the deployment's configuration. Adding a provider on a new domain is therefore a
reviewed deploy. The app and website re-check every link before opening it, and
open it in the external browser.

## Fee formulas

The calculator answers: *the seller should receive X - what does the buyer pay?*
It assumes the buyer pays every charge on top; each charge is rounded **up** to
a whole shilling (none of these providers publishes its own rounding), and the
total is the sum of the rounded lines. Arithmetic is `Decimal`: in a float,
1,500 x 5.4% is `81.00000000000001`, which rounds up to 82. The checkout
quotation is always authoritative.

**Kenya Escrow** (published, `https://kenyaescrow.com/pricing`): fee = seller
amount x band % + fixed charge, for a seller amount of KSh 50 to 240,000.
It says it pays the M-Pesa charges, so those are KSh 0.

| Seller receives (KSh) | % | + fixed (KSh) |
|---|---|---|
| 50 - 100 | 10 | 10 |
| 101 - 500 | 10 | 19 |
| 501 - 1,000 | 6 | 40 |
| 1,001 - 5,000 | 5.4 | 46 |
| 5,001 - 10,000 | 4.7 | 81 |
| 10,001 - 25,000 | 4 | 151 |
| 25,001 - 50,000 | 3.7 | 226 |
| 50,001 - 100,000 | 3.3 | 440 |
| 100,001 - 150,000 | 2.8 | 955 |
| 150,001 - 200,000 | 2.65 | 1,190 |
| 200,001 - 240,000 | 0.3 | 5,905 |

Example: KSh 5,000 -> 270 + 46 = 316; buyer pays 5,316 (6.32%).
KSh 1,234 -> 66.636 rounds to 67, + 46 = 113.
At 240,000 the total is 246,625: under the KSh 250,000 M-Pesa limit its page quotes.

**eConfirm**: platform commission 1% (published). It also publishes an estimated
M-Pesa payout reserve with separate phone and till bands. **Those bands are not
loaded** (see below), so the calculator shows the 1% commission and **withholds
the total**. The 1% is never presented as the whole fee.

**Lipasafe**: "Check live quotation in Lipasafe before paying". No rate is invented.
**Shikilia**: "Fee not publicly specified – confirm before paying". No rate is invented.

### When the calculator will say one provider is cheapest

Only when at least two providers each have an estimate that is **comparable**:
every charge calculated (including payout charges), the provider's own statement
that no other fees apply, pricing verified and not out of date, and the provider
`approved`. Otherwise it says there is not enough comparable, verified pricing and
gives each provider's reason. An unknown fee is not "cheaper" or "dearer": it is
not in the ranking. As shipped, nobody is verified, so **no ranking is ever made
until an administrator has verified at least two providers.**

## Zeno's fraud guidance

Two parts that do not depend on a model behaving:

* **Rules** - a message that describes a known scam pattern (a deposit to reserve
  an item; a request for a PIN, OTP or password; a request to skip escrow;
  unexpected "customer care"; a fake or forwarded M-Pesa message; a screenshot
  offered as proof; a changed payee or a personal number replacing the official
  checkout; a link the other party sent; pressure to pay now; a price far below
  market) gets a **written answer**: what the pattern is, what to do, and the
  payment rules, repeated. So do plain questions - what to agree before paying,
  buyer guidance, seller guidance, what to do after a scam. No model is called,
  and these turns are never counted against the day's rationed Zeno sessions.
* **Guard** - a model's reply that contains a phone, till, paybill or account
  number, a web address that is not an approved provider's, a fee figure the
  catalogue does not publish for that provider (including in the next sentence
  after naming it, and a made-up "most charge about 3%"), or a promise BROKA has
  not earned ("guaranteed", "licensed by the CBK", "fully safe") is **replaced**,
  and the action it proposed does not run. The model is also told, in its prompt
  each turn, the live catalogue and what is unknown.

Zeno never says a payment message, screenshot or link is genuine, never calls
anyone a scammer, and never promises BROKA can recover money. English only for
now, like the escrow walkthrough.

## Reporting and Trust & Safety

A scam report is a complaint (`user_feedback`, category `safety`), so the existing
triage queue, alerts and `repeat_reported_users` see it, plus structured details,
up to three private screenshots, and repeat detection.

**A report is not a verdict.** Reports never restrict, flag or re-score anyone:
three **different** reporters of one account or website raise an Alert Centre alert
asking a person to look (one person reporting five times counts once). A
restriction is applied only by an administrator, with a reason, for 1 to 14 days,
for a scope that is actually enforced (today: posting new listings), it never
touches the trust score, it ends by the clock, and the person is told what it is
and can appeal (one open appeal at a time, two per restriction). Evidence is
private to the reporter and administrators; every administrator view is written to
the audit log before the bytes are returned.

## Feature switches

Nothing was switched on.

| Switch | Value | Governs |
|---|---|---|
| `IN_APP_PAYMENTS_ENABLED` | `false` (unchanged) | BROKA taking payments - stays off |
| `ESCROW_GUIDANCE_ENABLED` | `false` (unchanged) | Zeno proposing escrow / the `escrow_services` destination |
| `PAYMENTS_SHOWN` (app build flag) | `false` (unchanged) | whether the app shows any payment screen, including the comparison |
| `ESCROW_PROVIDER_DOMAINS` | the five domains | which websites a provider record may link to |
| `ESCROW_PRICING_MAX_AGE_DAYS` / `ESCROW_RECORD_MAX_AGE_DAYS` | 30 / 90 | when information is shown as outdated |

The new screens are reachable only from screens `payments_shown.dart` already
hides. The website keeps showing its escrow box (it did before), now from the
API: with no list it says so rather than showing a stale one.

## Open decisions and information still needed

**Not verified. Everything below needs a person with access to the providers' own pages.**

1. **No provider has been verified or approved, and no verification date exists.**
   The research was supplied, not re-checked: the build sandbox could not reach any
   provider page (HTTP 403). Every provider is `under_review` with no verification
   date; none can be approved until the checks above are recorded.
2. **eConfirm's payout-reserve bands** (phone and till) are not in the research and
   its tariffs page could not be read. The mechanism is built and tested on invented
   bands (in tests only); the shipped record has none, so no eConfirm total is shown.
   Load them from `https://econfirm.co.ke/tariffs` via `PATCH` with the source.
3. **Legal entities.** eConfirm: the brief says "Confirm Delegence Solutions";
   this repository's earlier list said "Confirm Diligence Solutions Ltd". Kenya
   Escrow: not identified. Shikilia: the homepage and footer name different companies
   (Jeno-tech Solutions, Jo-Jo Mani Investment Ltd, Travel Pay) and the one
   responsible for the escrow transaction is unresolved. Lipasafe: Holda Fintech
   Technologies Limited, from its terms, unconfirmed.
4. **Kenya Escrow's bands do not all meet.** At the first amount of each band, take that
   band's own formula minus the previous band's formula there (KSh, unrounded). The
   bands from 1,001 to 50,000 meet (differences of -0.01 to 0.00). Six boundaries do not:
   101 (+9.00), 501 (+0.96), 50,001 (+14.00), 100,001 (+15.00), 150,001 (+10.00) and
   200,001 (+14.98). That may be deliberate M-Pesa step costs or a transcription slip.
   The numbers are shipped exactly as supplied; check every one against the live page
   before approving. (The earlier version of this note said the bands met up to 50,000;
   that was wrong for 101 and 501.)
5. **Whether any provider charges more** (dispute or holding fees). Until
   `additional_fees_may_apply` is confirmed `false`, a provider is never ranked.
   Earlier BROKA research mentioned a dispute fee at Kenya Escrow.
6. **Unknown for every provider**: contacts, terms/privacy URLs (Lipasafe's terms
   only), supported transaction categories, refund conditions, cancellation
   policy, seller protection, payout methods (except eConfirm's), confirmation
   windows (except Shikilia's described protection window).
7. **Escrow Kenya (escrowkenya.com)** is seeded as suspended **on the product
   owner's statement**. The repository holds no record of when or why. Attach the
   original decision to the record's internal notes. The public notice is neutral
   by design ("not on Broka's list"); it makes no claim about the company.
8. **The existing E-Confirm API integration** (`domains/escrow/`) contradicts "no
   external escrow API integrations" in spirit. It is off and untouched. Decide
   whether to remove it.
9. **No four-eyes review**: an administrator can edit and then verify the same
   provider. All administrators hold every permission (`core/permissions.py`).
10. **No RLS exists in this repository** (no SQL, no policy files), so none was
    preserved or added; authorization is entirely in the API. Whether the live
    Supabase project has RLS enabled cannot be seen from here.
11. **Provider logos** are not bundled (trademarks; none could be fetched). A coloured
    initial is shown. `identity.logo_url` exists (on the provider's own domain).
12. **Restrictions enforce only "post new listings".** Blocking offers needs a check in
    the negotiation code (4,000+ lines), which was not touched. The scope is not
    offered until it is enforced.
13. **Zeno's in-chat prompts** (`negotiate.py`) get the scam rules but not the live
    provider list: they are built once at import, so a list in them would go stale.
    The assistant's own prompt is rebuilt every turn and carries the live list. The
    output guard runs on the assistant, not on the in-chat replies.
14. **Swahili and other languages**: the written guidance is English only.
