# BROKA — AI-Mediated P2P Marketplace for East Africa

BROKA is a mobile marketplace where buyers and sellers deal through **Zeno**,
an AI broker that negotiates, translates, privately coaches each side, and
mediates disputes.

**For launch (2026-10-08) BROKA holds no deal money.** Buyers pay sellers
through one of Kenya's independent escrow services (E-Confirm, Escrow Kenya,
Kenya Escrow, Lipasafe, Shikilia), listed in the app and on the web store,
and Zeno walks them through it one step at a time. No commission is charged.
BROKA's own escrow is built and switched off (`IN_APP_PAYMENTS_ENABLED`), and
so are auctions (`AUCTIONS_ENABLED`), whose winning bids need it. See
`CHANGES.md`, "Paying with escrow services, and no auctions for launch".

| Part | Stack |
|---|---|
| `backend/` | FastAPI (Python 3.11) + async SQLAlchemy. PostgreSQL in production, SQLite in dev and tests. A Rust extension (`backend/native/`, PyO3) scans chat for off-platform contact details and does distance math, with a Python fallback |
| `flutter_app/` | Flutter 3.24.5 (the version CI pins), `provider` for state |
| `web/` | The web storefront at `broka.co.ke/store/<name>`: Next.js 16 (App Router) + TypeScript on Vercel |

Design notes live next to this file: `ARCHITECTURE.md`, `AUCTIONS.md`,
`CALLING.md`, `EVENT_ARCHITECTURE.md`, `PRIVACY.md`, `ZENO_ACTIONS.md` and
`SELLER_METRICS.md`, plus the audit write-ups (`ESCROW_AUDIT.md`,
`DISPUTE_AUDIT.md`, `AI_AUDIT.md`, `COMMUNICATIONS_AUDIT.md`,
`REPO_REVIEW.md`).

Working on the code: start with `AGENTS.md` (how to build, test and change
things safely) and `graphify.md`, a map of the repository generated from
the source - every endpoint with its auth and handler, every table, module
summaries, app and web routes. CI regenerates it on every push to `main`.

---

## Recent changes (2026-09-25)

A hardening pass after the repository review (`REPO_REVIEW.md` has the
details and the tests behind each item):

- **Signup and login work on PostgreSQL.** The refresh-token row was
  written with a timezone-aware expiry, which Postgres refuses: every
  signup and login returned 500 there. Two foreign keys that couldn't hold
  what their columns store are gone too: `"system"` audit rows (which took
  E-Confirm payment updates down with them) and the auction deal claim.
  CI now runs the whole backend suite on PostgreSQL as well as SQLite.
- **Real client addresses behind Render.** Per-IP limits (login, signup,
  OTP) keyed on Render's proxy, one bucket for every user. They now read
  `CF-Connecting-IP` (`CLIENT_IP_HEADER`); the web storefront passes on its
  visitors' addresses with `STOREFRONT_API_KEY`. Check it with
  `GET /admin/diagnostics/client-ip`.
- **The app no longer stores the account password**, and app data is
  excluded from Android backups. Sessions renew with the refresh token only,
  which now slides (renewed after a week of use); a refused one returns
  the user to sign-in. Signup keeps its refresh token (it was dropped).
- **Images:** an oversized image header is a 422, not a 500, and can no
  longer stop the media backfill; legacy image fields accept only inline
  images, never links elsewhere; uploads nothing used are removed after a
  week; uploads are capped per day.
- **Store counts** are limited by who is really calling, not a visitor id
  the caller chooses; a paused store's product links go to the store page;
  an unverified business email is shown only to the owner.
- **Idempotency keys** are scoped to user and route; **request bodies**
  are capped (32 MB).
- **For coding agents:** `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and the
  generated `graphify.md`.

## Recent changes (2026-09-24)

- **Store links open a real storefront, on the web and in the app**
  (Online Stores phase 3, see `STORES_PLAN.md`). `broka.co.ke/store/<name>`
  is a web store (`web/`) that works without the app: the store's cover,
  logo, seller record, search, category pills with product counts, sort,
  and product pages with photos and "Make an offer in the BROKA app", on
  the same glowing connected-dots background. Shared links show a real
  preview in WhatsApp and elsewhere: the store's or product's photo as a
  JPEG, since WhatsApp doesn't show WebP. Android visitors get an "Open in
  the app" banner, and with the app installed the links open the new store
  home screen in the app, which replaces the old store page there too.
  Web visits count toward the owner's stats with their source. The API's
  old HTML store page now redirects to the web store.
- **Setting up an online store, and "My Store"** (Online Stores phase 2,
  see `STORES_PLAN.md`). Store setup is a step-by-step wizard on the
  signup screens' look: name, a link the owner picks
  (`broka.co.ke/store/<name>`, checked live as they type and fixed once
  the store opens), one of BROKA's 16 categories, county and area from a
  list of all 47 counties, logo, cover and shop photos, and an optional
  business email proven with an emailed code. The draft is kept on the
  phone after every change. Only long-term sellers can open a store; a
  short-term seller (or buyer) adds business details as the wizard's
  first step. When the store opens, the owner gets its link, a QR code
  and one-tap sharing to WhatsApp, TikTok, Instagram, Facebook and X.
  My Store shows real visit counts for the last 7 days and where visitors
  came from (each shared link carries a `?via=` tag; link-preview crawlers
  aren't counted), lets the owner pause the store, add products straight
  into it or move existing listings in, and edit every part of it. Stores
  no longer have phone or WhatsApp contact fields.
- **Images are stored files, not text in the database** (Online Stores
  phase 1, see `STORES_PLAN.md`). Every photo is checked, turned upright,
  stripped of its metadata (phone photos carry GPS coordinates) and saved
  as WebP in three sizes on Cloudflare R2. Product lists now carry small
  image links instead of every photo, video and seller selfie as base64,
  which made a 20-product page tens of megabytes. The app uploads each
  photo as soon as it's taken, with progress and retry, so publishing no
  longer sends all the photos in one request. Images already in the
  database are converted in the background.
- **Zeno chat requires sign-in.** `POST /negotiate/chat`, the handler that
  serves every Zeno conversation, took no token, no rate limit and no size
  limit, so anyone who found the URL could send unlimited prompts and images
  billed to BROKA's AI keys. It now requires an access token, allows 20
  requests a minute per user, and caps the message (8,000 characters), each
  history entry (2,000 characters; the newest 20 are kept) and the image
  (10 MB). In the app, a guest who opens Zeno's verdict on a product page is
  asked to sign in first.
- **An E-Confirm payout can't be requested twice.** When two "confirm
  delivery" requests overlapped, the second one's safety re-check read its
  own earlier copy of the escrow row, so it could ask E-Confirm to release
  the same payment again. Escrow lookups now always read the current row.
- **The app stays signed in past 15 minutes.** Access tokens last 15
  minutes. The app's newer HTTP client, used for escrow, disputes, auctions,
  stores and the buying agent, never picked up a refreshed token and never
  retried on a 401, so those screens failed until the app was restarted. It
  now renews the session on a 401 (one renewal shared by requests that fail
  together) and retries once. The Zeno chat calls do the same.

Regression tests: `backend/tests/test_cost_bounds.py`,
`backend/tests/test_route_ordering.py`, `backend/tests/test_payment_races.py`,
`backend/tests/test_media_assets.py`, `backend/tests/test_store_setup.py`,
`flutter_app/test/session_renewal_test.dart`,
`flutter_app/test/image_upload_test.dart`,
`flutter_app/test/store_setup_test.dart`,
`flutter_app/test/storefront_test.dart` and `web/src/**/*.test.ts(x)`.

---

## How it works

### Money

**For launch, with `IN_APP_PAYMENTS_ENABLED` off:** no route that starts a
buyer's payment answers (409 `IN_APP_PAYMENTS_OFF`), and
`GET /pricing/safe-payment` serves the independent escrow services - how
each takes a payment, its fees and limits as it publishes them, how a deal
starts, releases and is disputed - with the rules that stop fake-escrow
scams (`api/domains/pricing/safe_payment.py`). Zeno's step-by-step
walkthrough of them is `api/domains/zeno_assistant/escrow_walkthrough.py`.

With in-app payments on, two escrow paths run side by side:

- **E-Confirm** holds the **full agreed price**. E-Confirm doesn't call
  BROKA back, so BROKA polls it: on every payment-status request, and every
  5 minutes in the background. The release code is stored encrypted and
  never leaves the server.
- **Legacy M-Pesa (Safaricom Daraja):** the STK push charges only the
  commission, and the goods money changes hands off-platform. Daraja also
  handles listing boosts and seller verification payments.

A deal moves `agreed → paid → released` (or `refunded`), with dispute
sub-states in between. Every money movement is written to a double-entry
ledger (`api/core/ledger.py`). `POST /deal/{deal_id}/fund` accepts an
`X-Idempotency-Key` header and also claims each attempt under the deal's
row lock, so a double tap can't send two payment prompts. Anything
that needs a person, such as money arriving for a cancelled deal, raises a
reconciliation alert to Sentry tagged `alert:reconciliation`.

### AI

Model calls go through a fallback chain: Gemini → DeepSeek → OpenRouter →
Groq → a cached reply → an error. A provider is skipped when its key is
unset, and each has a circuit breaker that stops calling it for 30 seconds
after a run of consecutive failures. Groq currently does nothing, because its
configured model was decommissioned. See `api/routers/negotiate.py`'s
`_call_ai` for the live chain.

Zeno writes a separate, private reply to each side of a conversation.
`backend/tests/test_message_visibility_guard.py` scans every chat-message query so
that neither side can read the other's copy (see `PRIVACY.md`).

### Auctions

**Off for launch** (`AUCTIONS_ENABLED`; `api/domains/auctions/paused.py`): none
can be created, changed or bid on, no feed lists one, and the app shows no
way to them (`kAuctionsEnabled`). The code below is unchanged and comes back
with the setting.

The server clock decides whether an auction is upcoming, live or ended. Bids
and closes are single atomic updates that only succeed if the row hasn't
changed since it was read. The reserve price is judged once, at close, and
is never exposed publicly. A win becomes a normal deal. See `AUCTIONS.md`.

### Events and background work

- **Events are handled in-process.** `event_catalog.emit()` awaits every
  subscriber inside the request that raised the event. With `REDIS_URL`
  set, events are also appended to Redis Streams, but nothing reads those
  streams yet, so treat them as a log rather than a delivery mechanism. See
  `EVENT_ARCHITECTURE.md`.
- **Scheduled work runs inside the web process**, in two loops started at
  boot:
  - every 60 seconds: auction closes, ending-soon reminders, unpaid-win
    lapses and seller availability reminders;
  - every 5 minutes: deal and dispute timers, E-Confirm reconciliation,
    seller metrics and call expiry.
- **Queued jobs** (today, trust-score recalculation after a review or a
  fraud flag) go to ARQ when `REDIS_URL` is set, and need a worker process:
  `arq api.core.workers.WorkerSettings`. Without Redis they run in-process.

### Images

`POST /media/images` takes one image with a purpose (listing photo,
showcase, store logo/cover/photo). The server reads it with Pillow (so a
renamed non-image is refused), applies the phone's rotation, drops all
metadata, and writes WebP at 480, 960 and 1600 pixels on the longest side
(`thumb`, `medium`, `large`). It returns an id, which listings and stores
are created with; the server checks the id belongs to the caller and was
uploaded for that purpose.

Files go to Cloudflare R2 when the five `R2_*`/`MEDIA_PUBLIC_BASE_URL`
variables are set, and to the database otherwise (served by
`GET /media/i/...`). Either way the URLs never change, so they're cached
forever. Rows written before this, or by older app builds, still hold
base64; a background pass every 5 minutes converts a batch at a time
(`POST /admin/media/backfill` runs one on demand). List responses send the
first legacy photo only until a row is converted, and single-listing reads
keep the base64 for older app builds.

### Online stores

A store is a long-term seller's business page: `Listing.store_id` puts a
listing in it, and every store product still appears on Home and in
search. The owner picks the store's link name once, at setup
(`GET /stores/name-available` checks it; rules in
`api/domains/stores/naming.py`: 3-30 lowercase letters, digits and single
hyphens, no reserved words), and renaming the store never changes it. The
full link is `{STORE_LINK_BASE}/<name>`.

The storefront is `StoreHomeScreen` in the app and the `web/` project on
the web, both fed by `GET /stores/slug/{name}`, `GET /stores/{id}/listings`
and `/categories` (search, category and sort). The web project calls the
API from its own server, caches reads for 60 seconds, and serves link
previews as `/og/<image id>.jpg` (1200x630 JPEGs made by
`GET /media/og/{id}.jpg`). Store links (`https://broka.co.ke/store/<name>`
and `/store/<name>/p/<id>`) open in the app through an Android intent
filter and `lib/services/deep_link_service.dart`. The API's own
`GET /store/<name>` page redirects to the link base when that's another
host. Store visits (`POST /stores/{id}/visit`, from the app, or from the
web page with a browser visitor id) and share taps are counted per day in
`store_daily_counts`, once per visitor per half hour, never for the owner
or for crawlers; the owner reads them with `GET /stores/{id}/stats`. A business email is only saved once proven with
an emailed code (`POST /stores/email/request-code`, `/stores/email/verify`),
unless it's the owner's own verified account email. The phased plan,
including checkout and the web storefront, is in `STORES_PLAN.md`.

### Calling

WebRTC audio and video between the two phones. The backend relays call
setup over a WebSocket and keeps call state in Redis, and Cloudflare TURN
relays media when a direct connection fails. See `CALLING.md`.

---

## Getting started

### Backend

```bash
cd backend
pip install -r requirements.txt
cp ../.env.example .env       # fill in SECRET_KEY, an AI provider key, MPESA_*, etc.
uvicorn main:app --reload --port 8000 --env-file .env
```

Nothing in the code loads `.env` by itself, so pass `--env-file` (or export
the variables in your shell).

With Redis (Redis-backed rate limits, idempotency keys, call state and the
ARQ queue):

```bash
docker run -d -p 6379:6379 redis:7-alpine
export REDIS_URL=redis://localhost:6379/0
uvicorn main:app --reload --env-file .env
arq api.core.workers.WorkerSettings        # in a second terminal
```

### Flutter app

```bash
cd flutter_app
flutter pub get
flutter run --dart-define=API_URL=https://your-backend.onrender.com
```

### Web storefront

Node 22.

```bash
cd web
npm ci
BROKA_API_URL=http://127.0.0.1:8000 npm run dev    # http://localhost:3000/store/<name>
```

`web/.env.example` lists its settings. `BROKA_API_URL` defaults to the
production API.

### Tests

Backend, the way CI runs it (`pytest.ini` also enforces the 50% coverage
floor):

```bash
cd backend
ENV=test SECRET_KEY=ci-test-secret-key-long-enough-for-testing-purposes \
  DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  REDIS_URL=redis://localhost:6379/0 \
  python -m pytest tests/
```

Leave out `REDIS_URL` to skip the handful of tests that need a real Redis.

The Rust extension (`backend/native/README.md`) is optional locally: without
it the backend and its tests run on the Python fallback. To build it (needs
the Rust toolchain in `backend/native/rust-toolchain.toml`) and run the
suite on it, as CI and production do:

```bash
cd backend
pip install ./native
BROKA_NATIVE=required ENV=test \
  SECRET_KEY=ci-test-secret-key-long-enough-for-testing-purposes \
  DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  python -m pytest tests/
```

The same suite on PostgreSQL, as CI also runs it (production is Postgres,
and SQLite neither enforces foreign keys nor refuses timezone-aware
datetimes; each test module gets a fresh schema):

```bash
cd backend
ENV=test SECRET_KEY=ci-test-secret-key-long-enough-for-testing-purposes \
  POSTGRES_TEST_URL=postgresql+asyncpg://user:pass@localhost:5432/broka_test \
  python -m pytest tests/ -o addopts="" -p tests.postgres_plugin
```

Flutter:

```bash
cd flutter_app
flutter analyze --no-fatal-warnings --no-fatal-infos
flutter test
```

Web:

```bash
cd web
npm run typecheck && npm run lint && npm test && npm run build
```

---

## Environment variables

`.env.example` has the full list. The ones that matter most:

| Variable | Needed | Purpose |
|---|---|---|
| `SECRET_KEY` | Required | JWT signing. Production refuses to start with a default or a key under 32 characters |
| `DATABASE_URL` | Required | PostgreSQL in production (production refuses SQLite) |
| `MPESA_CALLBACK_SECRET` | Required in production | Authenticates Safaricom callbacks. Production refuses to start without it |
| `ECONFIRM_API_KEY` | Required in production | E-Confirm escrow. Production refuses to start without it |
| `ZAC_SECRET` | Required in production | Signs dispute resolution codes. Production refuses the default |
| `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY` | At least one | AI providers, tried in that order |
| `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_BUCKET`, `MEDIA_PUBLIC_BASE_URL` | Production | Image storage on Cloudflare R2. Any unset: images are stored in the database |
| `PUBLIC_API_BASE_URL` | Optional | This API's own URL, for absolute links to database-stored images |
| `STORE_LINK_BASE` | Default `https://broka.co.ke/store` | Base of every store's shareable link, served by the web storefront. The API's own store page redirects there |
| `REDIS_URL` | Strongly recommended | Rate limits and idempotency across instances, call state, the ARQ queue |
| `CLIENT_IP_HEADER` | Default `CF-Connecting-IP` on Render | Where the caller's real address is, for per-IP rate limits. `TRUSTED_PROXY_HOPS` for hosts without such a header |
| `STOREFRONT_API_KEY` | Production | 32+ random characters, the same value in the API and the web project: lets the storefront pass on its visitors' addresses |
| `SENTRY_DSN` | Production | Error tracking and reconciliation alerts |
| `MPESA_*` | For M-Pesa | Safaricom Daraja |
| `AT_*` or `MOBITECH_*` | For SMS | Phone OTP codes and SMS reminders |
| `RESEND_API_KEY`, `RESEND_FROM` | Optional | Email verification codes (requests return 503 without them) |
| `DEEPGRAM_API_KEY`, `ASSEMBLYAI_API_KEY` | Optional | Zeno voice input. The app only ever receives short-lived tokens |
| `CLOUDFLARE_TURN_KEY_ID`, `CLOUDFLARE_TURN_API_TOKEN` | Optional | Call relay for networks where a direct connection fails |
| `FAL_KEY` | Optional | AI showcase images for listings |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Default 15 | Access token lifetime. The refresh token (30 days) renews it |

The web storefront's settings, set in Vercel:

| Variable | Needed | Purpose |
|---|---|---|
| `BROKA_API_URL` | Required | The API (the Render URL). Read on the server only |
| `NEXT_PUBLIC_SITE_URL` | Default `https://broka.co.ke` | The address visitors see, for canonical links and link previews: broka.co.ke, not the project's own `*.vercel.app` |
| `STOREFRONT_API_KEY` | Required | The same value as on the API: lets it trust the visitor address sent with visit and share counts |
| `STOREFRONT_PROXY_KEY` | For visit stats | The same value as in the BROKA website's project: lets this site trust the visitor address the website sends with the requests it passes on |
| `NEXT_PUBLIC_APP_DOWNLOAD_URL` | Optional | Where "Get the app" goes. Defaults to the latest APK on GitHub releases |
| `ANDROID_CERT_SHA256` | For App Links | The release key's SHA-256 fingerprint(s), comma-separated, served in `/.well-known/assetlinks.json` so store links open the app directly |
| `APPLE_APP_IDS` | For an iOS build | `<TeamID>.com.broka.app`, for Universal Links |

---

## API overview

A running server serves the full interactive reference at `/docs`. Most
routes need `Authorization: Bearer <access token>`.

| Prefix | Covers |
|---|---|
| `/auth` | Phone and email OTP, register, login, profile, token refresh and revoke |
| `/listings` | Browse, create and edit listings; listing and seller metrics; AI showcase images |
| `/categories`, `/trending`, `/traders` | Discovery |
| `/stores`, `/store/{slug}` | Store setup (link check, business-email codes), catalogue and categories, visit/share counting, owner stats. `/store/{slug}` redirects to the web storefront |
| `/auctions` (legacy `/auction`) | Auction grid, detail and terms |
| `/negotiate` | Zeno chat (`/chat`), mediated messages, direct chat, inbox, read receipts, deal timers, scam check, price advice |
| `/buy-agent-requests` | Standing "find and negotiate for me" requests |
| `/deal` | Finalize a deal; E-Confirm fee quote, funding, payment status and delivery confirmation |
| `/escrow` | Legacy escrow (the M-Pesa commission flow) |
| `/mpesa`, `/featured`, `/verify` | Daraja STK push and callbacks, listing boosts, seller verification |
| `/disputes/v2` | Dispute cases, evidence, AI analysis and resolution |
| `/reviews` | Seller reviews |
| `/calls` | Call setup, TURN credentials, call logging |
| `/stt`, `/tts` | Speech-to-text tokens and transcription, text-to-speech |
| `/media` | Image upload (`/media/images`) and serving, link-preview JPEGs (`/media/og/{id}.jpg`), chat voice notes and images |
| `/admin` | Summary, users, audit logs, fraud events, ledger integrity, AI savings |
| `/health`, `/ready`, `/live` | Liveness and readiness probes |

WebSockets: `/deal-ws/ws/{deal_id}` (deal status), `/auction-ws/ws/{listing_id}`
(live bids), `/media/ws/{listing_id}` (chat) and `/calls/ws/{room_id}` (call
signalling).

---

## Database schema changes

This project does **not** currently use Alembic migrations, despite the
Alembic scaffolding present under `backend/migrations/` — verified by
checking what actually runs (`main.py`, every startup script, every CI
workflow) rather than assumed; nothing in this repository ever calls
`alembic upgrade`. The real mechanism, in `api/database.py`'s `init_db()`:

- **New tables** are created by `Base.metadata.create_all()`, called
  unconditionally on every startup — in production too, not just tests.
- **New columns on an already-existing table** go through that same
  function's own `migrations` list of `ALTER TABLE ... ADD COLUMN`
  statements (a no-op if the column already exists).
- **New indexes** work the same way via an `index_patches` list.

See `backend/migrations/README.md` and `api/core/migrations_guide.py` for
the fuller explanation, including when this workflow would need to
change (once a populated production database can no longer just be
recreated from the models).

---

## Deployment

`render.yaml` deploys the backend as one Docker web service plus a
PostgreSQL database, both on Render's free plan. The web storefront is a
Vercel project with Root Directory `web` (settings above); Vercel deploys it
on every push. broka.co.ke itself is the BROKA website (the
`broka-website` repository, its own Vercel project), which passes the
storefront's paths on to it: set the website's `STOREFRONT_URL` to the
storefront project's `*.vercel.app` address, and the same
`STOREFRONT_PROXY_KEY` in both.

**Minimum production config:**
1. PostgreSQL.
2. `ENV=production` and the required secrets in the table above. Startup
   checks them and refuses to run without them.
3. Redis (Upstash's free tier is enough to start).
4. `STOREFRONT_API_KEY`: the same random value on Render and in the Vercel
   project. Then call `GET /admin/diagnostics/client-ip` from a phone on
   mobile data: `resolved` should be that phone's address.
5. An ARQ worker whenever `REDIS_URL` is set:
   `arq api.core.workers.WorkerSettings`. `render.yaml` doesn't define one
   yet, and without it queued trust-score jobs wait in Redis unprocessed.

**Worth knowing:**
- Scheduled work lives in the web process. Render's free plan puts an idle
  service to sleep, and while it sleeps, auction closes, deal timers and
  E-Confirm reconciliation don't run. They catch up once it wakes.
- CI (`.github/workflows/build.yml`) runs on every push to `main`: backend
  tests against Redis with the 50% coverage gate, then `flutter analyze`
  (errors only) and `flutter test`, then an APK build that replaces the `latest-release`
  GitHub release. Alongside, separate jobs run the backend suite on
  PostgreSQL, typecheck, lint, test and build `web/`, and regenerate
  `graphify.md` (committed back to `main` when it changed). The APK is signed with the release key when the
  `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`
  and `ANDROID_KEY_PASSWORD` secrets are set, and with the debug key
  otherwise. Store links only open the app directly (App Links) with the
  release key.

---

## Roadmap

- [x] Multi-step registration (selfie, biometrics)
- [x] 6-signal trust score + fraud engine
- [x] Double-entry escrow ledger
- [x] M-Pesa STK Push + B2C payout
- [x] E-Confirm escrow for the full agreed price
- [x] WebSocket real-time deal status
- [x] AI broker with multi-provider fallback (Gemini, DeepSeek, OpenRouter)
- [x] Store/business layer (User → Store → Listings, public storefront at `broka.co.ke/store/{slug}`) — see `ARCHITECTURE.md`'s Store section; AI store intelligence, analytics, and bundle negotiation are NOT part of this
- [x] Auction lifecycle (window, atomic bids, close, winner → deal)
- [x] Circuit breakers (AI + M-Pesa)
- [x] Idempotency keys (payment safety)
- [x] ARQ Redis-backed worker queues
- [x] CI-enforced test coverage floor (50%, `--cov-fail-under` in `.github/workflows/build.yml` and `backend/pytest.ini`)
- [x] VoIP calling (WebRTC)
- [x] STT / TTS voice support
- [x] Image storage on Cloudflare R2 (WebP sizes, metadata stripped)
- [x] `flutter test` in CI
- [x] Online stores: setup wizard with a fixed shareable link, My Store with visit stats (Online Stores phase 2)
- [x] Online stores: storefront in the app and on the web, store links opening the app, link previews (Online Stores phase 3)
- [ ] Online stores: stock, cart and checkout, seller tools (phases 4-5 of `STORES_PLAN.md`)
- [ ] Consume the Redis event streams (events are written there but only handled in-process today)
- [ ] Event sourcing for payments (Phase 3)
- [ ] ML-based fraud models (Phase 4)
- [ ] Seller reputation graph (Phase 4)
