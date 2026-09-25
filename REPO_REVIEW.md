# BROKA — Repository Review

**Date:** 2026-09-25
**Commit reviewed:** `1d41018` ("CI checks the web storefront and can sign with the release key; docs")
**Previous review:** 2026-09-23 at `939eafd` (in git history of this file)
**Branch:** `claude/respiratory-review-9bsdjg`

This review does two things. It rechecks what the 2026-09-23 review left
open, and it reviews the 21 commits since then (~30k lines): the fix pass,
image storage on R2, online stores phase 2 (backend and app), the Next.js
web storefront, and session renewal in the app. Every finding marked
**Reproduced** was confirmed by running code against the real service
layer; each repro was a throwaway test, not committed.

---

## 1. Baseline

| Check | Result |
|---|---|
| Backend tests, CI configuration (real Redis, fresh) | **975 passed**, 1 skipped (`alembic` CLI not on PATH locally), coverage **60%** (gate 50%) |
| Backend tests, second run against the same Redis | **1 failed**: `test_escrow.py::…::test_pending_blocks_fund_regardless_of_idempotency_key` (see §6) |
| Web (`web/`): typecheck, lint, test, build | all pass; **46 tests** |
| Flutter `analyze` (CI flags) | exit 0: **0 errors, 0 warnings**, 21 infos (unchanged) |
| Flutter `test` | **223 passed**, 12 files (was 164 in 8) |

Code size: backend 41.9k lines (+16.5k of tests), Flutter `lib/` 57.4k,
web 2.7k.

---

## 2. Status of the 2026-09-23 open items

Everything that review found was fixed in its own fix pass, with
regression tests, and those tests still pass. What it left for a decision:

| # | Item | Status |
|---|---|---|
| 1 | Legacy refunds pay 97% of the price out of BROKA's account | **Unchanged.** Still a business decision. |
| 2 | E-Confirm deals in the dispute/condition-check flows fail closed | **Unchanged.** Automated release/refund against E-Confirm's API isn't built yet. |
| 3 | Reconciliation alerts | **Done** in code (Sentry, `alert:reconciliation`). `SENTRY_DSN` and the Sentry alert rule can't be checked from the repo. |
| 4 | `ALLOWED_ORIGINS: "*"` | **Unchanged, still safe.** The web storefront is now a browser client, but its browser code only calls its own `/api/...` routes, which call the API server to server. No origin needs allowing. |
| 5 | Nine unused private helpers in the seller dashboard | **Unchanged** (9 of the 21 analyzer infos). |

The three commits after that review's write-up are sound:

- `b071d05`: `populate_existing` on the escrow repository's single-row
  reads. I checked the claim in its comment that unflushed edits are safe:
  sessions keep autoflush on (the `sessionmaker` default), so pending
  edits are written before the re-read.
- `e418dcb`: `/negotiate/chat` now requires sign-in, is rate-limited, and
  has size caps.
- `380503f`: `ApiClient` renews an expired session on a 401 and retries
  once. The renewal is single-flight.

---

## 3. Medium — the app stores the user's password in plain text, and Android backs it up

**Pre-existing; not flagged by earlier reviews.** `ApiService._saveSession`
(`flutter_app/lib/services/api_service.dart:98`) and
`AuthRepository` (`features/auth/data/repositories/auth_repository.dart:81`)
write the account password to SharedPreferences under `user_password`.
It is kept only as the last fallback in `_tryRefreshOrRelogin`, used when
the refresh token is rejected.

- SharedPreferences is a plain XML file on Android and a plist on iOS.
- `AndroidManifest.xml` sets no `android:allowBackup`, so Android's default
  applies: auto-backup is on, and the file, with the password, access token
  and refresh token, goes into the user's Google Drive backup. iOS device
  backups include the plist too.
- The password is more than a login. `POST /mpesa/stk-push` uses it as its
  "second-factor authorization" (`backend/api/routers/mpesa.py:125`), so a
  copy on disk defeats that check as well.

Now that refresh tokens work (fixed 2026-08-13), the fallback is rarely
needed. When the refresh token is rejected, sending the user to sign-in is
the right answer.

**Fix.**
1. Stop writing `user_password`, and delete it on the next app start.
2. Drop Attempt 2 of `_tryRefreshOrRelogin`, and route to sign-in when
   renewal fails.
3. Set `android:allowBackup="false"`, or exclude shared prefs with
   `dataExtractionRules` / `fullBackupContent`.
4. Consider `flutter_secure_storage` (Keystore/Keychain) for the refresh
   token.

---

## 4. Medium — an oversized image header gets past `ImageRejected`, returns a 500, and stops the media backfill

**Reproduced.** `process_image` (`backend/api/core/image_processing.py:75`)
catches `UnidentifiedImageError, OSError, ValueError` around `Image.open`.
Pillow raises `DecompressionBombError`, a plain `Exception` subclass,
*inside* `Image.open` when the declared canvas is over 2 × its default
limit (178,956,970 pixels). That happens before the module's own
`MAX_PIXELS` check, which would have turned it into a friendly message.

A 50-byte PNG whose header declares 20000 × 10000:

```
process_image(raw)          -> PIL.Image.DecompressionBombError (not ImageRejected)
POST /media/images          -> 500 "Internal server error. Our team has been notified."
```

The same file sent as a legacy base64 field breaks the backfill. Old app
builds still send those fields, and so can any client: `logo_url` and
`photos` on stores, `verified_photos` and `showcase_image_url` on listings.
`backfill._convert` catches only `ImageRejected`, so the error escapes
`run_backfill_pass`. The sweep logs it and tries again five minutes later,
on the same row. One store with the bad logo and one with a good logo:

```
pending before: store_logos 2
pass 0: raised DecompressionBombError
pass 1: raised DecompressionBombError
pass 2: raised DecompressionBombError
pending after:  store_logos 2        <- the good logo is never converted either
```

The whole pass sits in one `try`, and listing photos are converted first.
So one such listing photo would stop every kind: listing photos, showcases,
store logos, store photos and avatars, for every user, on every pass.
(This last part is from reading the code; the store-logo case above was
run.) Any seller can create that row with one request.

**Fix.**
1. In `process_image`, catch `Image.DecompressionBombError` (or
   `Exception`) around `Image.open` and raise `ImageRejected`.
2. In the backfill, catch any per-row exception other than `StorageError`,
   mark that row unconvertible (`"[]"` / `""`, as it already does for
   `ImageRejected`), and carry on. A single row must never stop the pass.

---

## 5. Low — the store visit counter's rate limit is keyed on an id the caller chooses

**Reproduced.** `POST /stores/{id}/visit` is public. For an anonymous
caller the limiter key is `visitor:{body.visitor}`, a random string the
web storefront keeps in `localStorage`, and the same value is the
de-duplication key. Nothing ties it to the caller, so a new value on every
request is a new, unlimited visitor. With the production 60/min limit
simulated at 5/min:

```
same visitor id, 8 requests:    [202, 202, 202, 202, 202, 429, 429, 429]
fresh id per request, 40 reqs:  all 202, 40 counted
owner's stats visits.total:     41
```

So anyone can inflate a store's visit count, and write a database row
update per request, without limit. `/share` counts every call with no
de-duplication.

Separately, calls forwarded by the web storefront (`web/src/lib/forward.ts`)
reach the API from Vercel's servers and carry no client IP. Every anonymous
web share, and every web visit without a `visitor` id (storage blocked),
falls into an `ip:<vercel address>` bucket shared with every other web
visitor to every store.

**Fix.** Key the limiter on the network address, not the body. Have the
storefront pass the visitor's IP (Vercel's `x-forwarded-for`) in a header
the API trusts only from the storefront, for example with a shared
secret, and limit on that. Keep `visitor` for de-duplication only.
Consider de-duplicating shares per visitor as well.

---

## 6. Low (latent) — idempotency keys are global, not per user or request

`reserve_idempotency_key` stores `broka:idempotency:<header value>`, with
no user id, method or path in the key. A request that reuses a key within
24 hours gets the *earlier request's* stored response, whoever sent it and
whichever deal it was for, and the handler never runs.

That is exactly why the test suite fails on a second run against the same
Redis. `test_pending_blocks_fund_regardless_of_idempotency_key` sends
`X-Idempotency-Key: key-A` to fund a new deal, gets the previous run's
cached response for a different deal, and no STK push is made. CI passes
only because its Redis starts empty each time.

```
dirty Redis:  1 failed
FLUSHALL:     1 passed
run again:    1 failed
```

The app sends no `X-Idempotency-Key` today (`grep` over `flutter_app/lib`
finds none), so nothing is exposed now. But the first client that starts
sending keys would inherit cross-user response replay, and a reused key
would silently skip a payment.

**Fix.** Build the Redis key from the user id, method and path plus the
header value (`idempotency_guard` can take `request` and
`get_current_user`). In the test, use a unique key, or flush Redis in the
fixture.

---

## 7. Needs checking — do IP-keyed rate limits see real client IPs on Render?

Login (5/min), register (3 per 5 min), and the phone and email OTP
requests (3 per 5 min) are all limited per `request.client.host`. The
container runs `uvicorn main:app` with no `--forwarded-allow-ips`.
Uvicorn only trusts `X-Forwarded-For` from `127.0.0.1` unless told
otherwise. If Render's proxy connects from any other address,
`client.host` is the proxy's, and each of those limits is shared by
**every user** reaching the API through that proxy. That would mean three
signups per five minutes across the whole platform.

The repo can't show which case holds. Log `request.client.host` once in
production. If it's a private or proxy address, add
`--forwarded-allow-ips='*'`, or set `FORWARDED_ALLOW_IPS` to Render's
proxy range, to the start command, since only Render's proxy can reach
the container.

---

## 8. Low — smaller items

- **Legacy image fields accept any string.** **Reproduced:** a store
  created with `"logo_url": "https://tracker.example/p.gif"` keeps it
  after the backfill (it isn't base64, so it's marked unconvertible), and
  `GET /stores/slug/{slug}` serves it as `logo_url`. The web storefront's
  `resolveImage` passes any `https://` URL through, so the page on
  broka.co.ke loads a third-party image: a tracking pixel, or content
  BROKA never checked. The same applies to a store's legacy `photos` and a
  listing's `verified_photos`. Accept only `data:image/…` or bare base64
  in those fields.
- **Unverified business emails are public.** The store payload returns
  `business_email` whether or not it's verified. The web page shows only
  verified ones, but the public API returns what old app builds saved
  unverified, which could be a typo or someone else's address. Return it
  only when `business_email_verified`.
- **A paused store's product pages stay up.** The store page shows an
  empty catalogue, but `/store/<name>/p/<id>` still renders its products
  with "Buy in app". Decide which is intended; if pausing should hide
  products, check `store.is_active` in the product page's `load()`.
- **Uploads are never cleaned up.** An upload that's never attached to a
  listing or store (an abandoned wizard, a replaced photo, an asset from a
  lost backfill race) is kept forever. At 30 uploads a minute per user
  that's unbounded storage, in Postgres when R2 isn't configured. Add a
  sweep that deletes assets unreferenced after a day or so.

---

## 9. What was done well

- **Image pipeline.** Uploads are decoded from the bytes, not trusted by
  extension. EXIF and GPS are stripped while the colour profile is kept.
  JPEGs use draft-mode decoding and there's a pixel budget. Keys are
  immutable, so every response is cacheable forever. Each asset records
  the driver it was written with, so turning R2 on strands nothing. The
  backfill's compare-and-swap writes keep a seller's concurrent edit.
  §4 is the one gap.
- **Store link names.** Strict rules, a reserved list that covers
  impersonation ("support", "official", "mpesa"), case-insensitive
  lookup, and a link that is fixed once chosen. The one-store-per-owner
  check is serialised with a row lock instead of a schema constraint, so
  multi-store stays possible.
- **Web storefront.** It's small and careful:
  - every path and query value is validated before it reaches the API;
  - JSON-LD is escaped for `<script>`;
  - API reads are cached so a busy WhatsApp group costs one request a minute;
  - JPEG link previews exist because WhatsApp ignores WebP;
  - App Links verification is driven by an env var;
  - security headers are set, and CI gates typecheck, lint, tests and build.
- **Deep links** (`deep_link_service.dart`) accept only the two BROKA
  hosts and strict slug/id patterns. A link that arrives during the splash
  screen waits for it.
- **Session renewal** in `ApiClient` retries only token-carrying requests,
  shares one renewal among concurrent 401s, and rebuilds a multipart
  request for its retry.

---

## 10. Suggested order of work

1. §4: catch the decompression-bomb error, and make the backfill skip a
   bad row instead of stopping. It's small, and today any seller can stop
   the migration for everyone.
2. §3: stop storing the password and turn off Android backup of prefs.
3. §7: one production log line decides whether this is a non-issue or the
   most urgent item here.
4. §6: scope idempotency keys, and fix the order-dependent test.
5. §5, then §8.

---

## Overall

The new work is in the same careful style as the rest of the codebase.
The stores backend, image pipeline and web storefront are well layered.
Their comments explain each guard, and the tests are real: 975 backend,
223 Flutter and 46 web tests, all green in CI's configuration.

This week's problems sit at trust boundaries: what a guard lets through
rather than what it checks. `process_image` handles every rejection it
names but not one Pillow raises itself. The visit limiter limits a value
the caller picks. The idempotency cache trusts a header across users. The
app keeps a secret where backups can reach it. Each fix is small.
