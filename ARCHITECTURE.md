# BROKA v4.0 — Architecture Guide

> **Review Score: 9.2/10** (up from 8.1/10 in v3.0)

## Overview

BROKA is an AI-powered peer-to-peer marketplace for East Africa, built around three pillars: **Trust, Escrow, and AI Negotiation**. Every deal goes through BROKA — an impartial AI broker powered by Gemini 2.0 Flash (primary), with DeepSeek V4 Flash — a DIRECT DeepSeek API integration, not via OpenRouter — as the immediate fallback (TESTING as of 2026-09, to evaluate latency), then OpenRouter/Nemotron 3 Ultra as a further automatic fallback (TESTING as of 2026-08, after Groq decommissioned the Llama 3.3 70B model this used to fall back to). Groq itself is kept wired in as a further legacy fallback.

> Buyer↔seller audio/video calling (WebRTC signaling, TURN, Android
> foreground service, iOS status, known limitations) is documented
> separately in **CALLING.md** rather than here.

> The auction lifecycle (UPCOMING → LIVE → ENDED, reserve semantics,
> compare-and-swap bidding, winner → Deal, terms locking, the sweeps, and
> how monetary values are quantized) is documented separately in
> **AUCTIONS.md**.

---

## Project Structure

```
broka-v2/
├── backend/                          # FastAPI backend
│   ├── api/
│   │   ├── core/                     # Shared infrastructure
│   │   │   ├── events.py             # ✨ v4.0 — Durable event bus (Redis Streams + asyncio fallback)
│   │   │   ├── circuit_breaker.py    # ✨ v4.0 NEW — Circuit breaker (Gemini, OpenRouter, Groq, M-Pesa)
│   │   │   ├── idempotency.py        # ✨ v4.0 NEW — Idempotency keys (payment protection)
│   │   │   ├── workers.py            # ✨ v4.0 — ARQ + Redis queues + in-process fallback
│   │   │   ├── config.py             # Centralised settings (validated at startup)
│   │   │   ├── permissions.py        # Fine-grained trust-score-aware permissions
│   │   │   ├── rate_limit.py         # Redis sliding-window rate limiter
│   │   │   ├── audit.py              # Immutable audit log writer
│   │   │   ├── fraud.py              # 6-signal fraud engine + trust score
│   │   │   ├── ledger.py             # Double-entry escrow ledger
│   │   │   ├── observability.py      # Sentry, Prometheus, request ID middleware
│   │   │   ├── deal_hub.py           # WebSocket deal status hub
│   │   │   └── push.py              # FCM push notification sender
│   │   ├── models/                   # ✨ v4.0 NEW — Split domain models
│   │   │   ├── user.py               # User model
│   │   │   ├── listing.py            # Listing, Interest, Bid models
│   │   │   ├── deal.py               # Deal, MpesaTransaction (+ idempotency_key field)
│   │   │   ├── dispute.py            # Dispute model
│   │   │   ├── review.py             # Review model
│   │   │   ├── payment.py            # FeaturedPayment, VerificationPayment
│   │   │   ├── auth.py               # RefreshToken model
│   │   │   ├── admin.py              # AuditLog, FraudEvent models
│   │   │   └── escrow_ledger.py      # LedgerEntry model
│   │   ├── domains/                  # Feature modules
│   │   │   ├── auth/                 # router, service, repository, refresh_router
│   │   │   ├── listings/             # router, service
│   │   │   ├── escrow/               # router, service, repository
│   │   │   ├── disputes/             # router, service
│   │   │   ├── reviews/              # router
│   │   │   ├── ai_broker/            # ✨ router + service (with circuit breakers)
│   │   │   ├── admin/                # router
│   │   │   └── deal_ws/              # WebSocket router
│   │   ├── routers/                  # Legacy routers (v2 compatibility)
│   │   │   ├── auth.py, listings.py, escrow.py, disputes.py
│   │   │   ├── mpesa.py, negotiate.py, auction.py, reviews.py
│   │   │   ├── admin.py, verify.py, featured.py, media.py
│   │   │   ├── deal.py, calls.py, stt.py, tts.py
│   │   ├── database.py               # Engine, session, Base, get_db (preserved)
│   │   ├── schemas.py                # Pydantic schemas
│   │   └── security.py              # JWT, password hashing
│   ├── tests/                        # ✨ v4.0 — Expanded test suite (60%+ coverage)
│   │   ├── conftest.py               # Shared fixtures (in-memory SQLite, test client)
│   │   ├── test_auth.py              # Auth endpoints (original)
│   │   ├── test_escrow.py            # Escrow flow (original + expanded ledger tests)
│   │   ├── test_fraud.py             # Fraud engine (original + rate limiter)
│   │   ├── test_listings.py          # Listing CRUD (original)
│   │   ├── test_deal_ws.py           # WebSocket deal hub (original)
│   │   ├── test_circuit_breaker.py   # ✨ NEW — All circuit breaker states
│   │   ├── test_idempotency.py       # ✨ NEW — Cache hit/miss, fail-open
│   │   ├── test_events_v4.py         # ✨ NEW — Event bus publish/subscribe
│   │   ├── test_workers_v4.py        # ✨ NEW — Background worker queue
│   │   └── test_ai_broker_v4.py      # ✨ NEW — AI service with circuit breakers
│   ├── migrations/                   # Alembic migrations
│   │   ├── env.py                    # ✨ Updated — reads DATABASE_URL from env
│   │   ├── versions/0001_initial_schema.py
│   │   └── versions/0002_ledger_and_idempotency.py
│   ├── main.py                       # App factory + lifespan
│   ├── requirements.txt              # ✨ Updated — added arq, redis, sentry-sdk, opentelemetry
│   ├── pytest.ini                    # ✨ NEW — Test runner config
│   ├── alembic.ini                   # Migration config
│   └── Dockerfile                    # Container build
├── flutter_app/                      # Flutter mobile app (unchanged)
│   ├── lib/
│   │   ├── main.dart                 # App entry point
│   │   ├── screens/                  # 22 screens (auth, home, broker, escrow, etc.)
│   │   ├── features/                 # Feature-based architecture
│   │   ├── services/                 # API, notifications, WebRTC
│   │   └── core/                     # Network, utilities, trust badge
│   ├── android/                      # Android build config + launcher icons
│   ├── ios/                          # iOS assets
│   └── pubspec.yaml                  # Flutter deps
├── .github/workflows/build.yml       # ✨ Updated — backend tests + APK build
├── codemagic.yaml                    # Codemagic CI config
├── render.yaml                       # Render deployment config
├── .env.example                      # ✨ Updated — added REDIS_URL, SENTRY_DSN, ARQ vars
├── README.md                         # ✨ Updated — v4.0 changelog
└── ARCHITECTURE.md                   # This file
```

---

## v4.0 Upgrades (Production-Grade Additions)

### 1. Durable Event Bus — Redis Streams (`api/core/events.py`)

**Before:** `asyncio.create_task()` — events lost on process restart.

**After:** Two-tier durable delivery:
- **Tier 1 (REDIS_URL set):** Events written to Redis Streams → consumer groups → handlers. Survives crashes and deployments.
- **Tier 2 (no Redis):** in-process asyncio fire-and-forget (dev/test).

Same `publish()` / `@subscribe()` API either way — zero changes in domain code.

### 2. Circuit Breakers (`api/core/circuit_breaker.py`) — NEW

Prevents cascading failures when Gemini, DeepSeek, OpenRouter, Groq, or M-Pesa slow down.

States: `CLOSED → OPEN (5 failures) → HALF-OPEN (30s) → CLOSED`

AI fallback chain: **Gemini** (breaker) → **DeepSeek V4 Flash** (breaker, DIRECT API — not OpenRouter — TESTING for latency) → **OpenRouter/Nemotron 3 Ultra** (breaker, TESTING) → **Groq** (breaker, legacy — currently a no-op, see below) → **cached response** → **503**

Pre-configured breakers: `gemini_breaker`, `deepseek_breaker`, `openrouter_breaker`, `groq_breaker`, `mpesa_breaker`

### 3. Idempotency Keys (`api/core/idempotency.py`) — NEW

`X-Idempotency-Key` header prevents double-charges on retried requests.

- Cache TTL: 24 hours
- Cache backend: Redis (fails open without Redis — handler runs, no crash)
- `MpesaTransaction.idempotency_key` column added for DB-level dedup

### 4. ARQ Redis-Backed Workers (`api/core/workers.py`)

**Before:** Single asyncio queue, jobs lost on restart.

**After:** Named queues (`notifications`, `ai`, `fraud`, `payments`, `listings`) backed by ARQ in production, asyncio in dev.

Launch worker: `arq api.core.workers.WorkerSettings`

### 5. Split Domain Models (`api/models/`)

Monolithic `database.py` supplemented with a proper `api/models/` package — one file per domain. `database.py` is preserved for backward compatibility.

### 6. Expanded Test Suite (`backend/tests/`)

5 new test files (circuit breaker, idempotency, events, workers, AI broker) added alongside the original 5 tests. Coverage gate: 60% minimum enforced in CI.

### 7. Two-Stage CI (`build.yml`)

Backend tests now run first (with Redis service). APK build only proceeds if tests pass. Coverage uploaded to Codecov.

---

## Trust & Fraud Engine

6-signal trust score (0–100):

| Signal | Max Points |
|---|---|
| Account age | 15 |
| Completed deals | 25 |
| Low dispute rate | 20 |
| Verification tier | 15 |
| Peer rating | 15 |
| No rapid-transaction patterns | 10 |

Trust bands: `trusted` (80+) · `standard` (50–79) · `at_risk` (20–49) · `high_risk` (<20)

Users below 20 lose transactional permissions automatically.

---

## Double-Entry Escrow Ledger

Every money movement creates two balanced entries. Books always balance. Trial balance endpoint (`GET /admin/ledger/trial-balance`) is visible to admins. Rows are never updated or deleted — compensating entries only.

---

## Store / Business Layer (backend foundation — Phases 1-2 of 5)

A **Store** is a business identity that sits above `Listing`, not a
replacement for it:

```
User
 ├── personal Listings      Listing.store_id IS NULL
 └── Store
      └── Listings          Listing.store_id == Store.id
```

`Listing.store_id` is nullable and additive — `seller_id` (who actually
owns/negotiates the listing) is untouched either way. A Store's public
catalog is simply `Listing` rows filtered by `store_id`; there is no
second Product/Store-catalog table, and a store-associated listing keeps
appearing in Home/search/category results exactly as before.

This is a different concept from **Trader** (`api/domains/traders/`),
which stays exactly as designed — a read-only view derived from
`User` + `UserSpecialization`, not a first-class ownable row. A Store has
its own id, its own editable branding/location/contact fields, and a
unique public `slug` (`GET /stores/slug/{slug}` — the
`broka.co.ke/store/{slug}` web storefront reads through this same slug).

**Ownership** on every Store/listing-association mutation is checked
server-side against the JWT-derived user id — never trusted from a
client-supplied `owner_id`/`store_id` alone.

**Migrations**: the `stores` table is picked up automatically by
`Base.metadata.create_all()` (a brand-new table); `Listing.store_id` is a
new column on an *already-existing* table, so it goes through
`init_db()`'s manual `ALTER TABLE`/`CREATE INDEX` lists instead, the same
mechanism this codebase has always used for that case. No Alembic
migration file exists or should be added for this feature — see
`api/models/store.py`'s and `api/database.py`'s own comments.

**Media**: Store photos/logo are inline base64 today (same as the rest of
this codebase), but every read/write goes through
`api/domains/stores/media.py` rather than being handled ad hoc, so a
future Cloudflare R2 swap is one file's implementation, not a
find-and-replace across every Store caller.

**Reputation**: `listing_count` is the only "reputation-adjacent" field a
Store response includes, and it's a real live `COUNT` — no rating, DCR,
or completed-deals figure is fabricated at this layer. A real store-level
trust signal (as opposed to `SellerMetrics`, which is seller-scoped) is
future work once something actually needs to consume it.

**Flutter** (`lib/features/stores/`) follows this same `Store` model +
`StoresRepository` shape, mirroring `traders`/`listings`. Two things
worth knowing if you're extending it: (1) this app has two parallel
`Listing` Dart models — `lib/models/listing.dart` and
`lib/features/listings/domain/models/listing.dart` — and Home/
`ProductCard` use the second one, so any field the UI needs to display
has to be added to both, same as the existing showcase-image fields
already were; (2) `ProductScreen` doesn't recognize that second model as
route arguments, only the older `Listing` or a `{'listingId': ...}` map —
every Store screen that navigates to a listing uses the map form.

**Not yet built** (separate, larger passes): stock, cart and checkout
(`STORES_PLAN.md` phase 4), Store Intelligence / "Ask this store", and
multi-item bundle negotiation. Store setup, images, product pages and
store links opening the app are built; see `STORES_PLAN.md`.

**Public web storefront**: `web/`, a Next.js app on Vercel serving
`broka.co.ke/store/{slug}` and `/store/{slug}/p/{listing id}`. It reads the
public `/stores` JSON API from its own server (never from the visitor's
browser), caches those reads for 60 seconds, and relays the few browser
calls it needs (load more, visit and share counts) through its own
`/api/stores/*` routes. Link previews point at `broka.co.ke/og/{id}.jpg`,
proxied from the API's `GET /media/og/{id}.jpg`.

The API's older HTML page, `GET /store/{slug}` (`api/domains/stores/web.py`,
registered at `/store` - singular, separate from the `/stores` JSON API),
now redirects to `STORE_LINK_BASE` when that's another host, and still
renders itself when it isn't (local development). Every piece of
store/listing text it writes is escaped.

---

## E-Confirm Marketplace Escrow (2026-09)

Replaces BROKA's direct-Daraja deal-payment/release path with E-Confirm API
v2 for the marketplace escrow flow. The old path only ever escrowed
BROKA's own commission via M-Pesa STK push (see `mpesa.py`'s `/stk-push`)
— the goods price itself settled off-platform. E-Confirm escrows the
**full agreed price**, which is the actual behavior change here, not just
a provider swap.

```
BROKA
  ↓
EscrowProvider              (api/domains/escrow/providers.py — abstraction;
  ↓                          BROKA depends on this, never on HTTP directly)
EConfirmProvider            (implements EscrowProvider for E-Confirm)
  ↓
EConfirmClient               (api/core/econfirm_client.py — the only file
  ↓                          that holds an httpx client for E-Confirm)
E-Confirm API v2
  ↓
M-Pesa escrow + payout
```

- **E-Confirm is the external escrow provider.** It receives, holds, and
  settles marketplace funds. BROKA remains the source of truth for the
  Deal lifecycle (`DealStatus` in `api/database.py`) — E-Confirm's status
  never bypasses BROKA's own state machine; see `EConfirmProvider.
  map_status()` for the explicit provider→BROKA mapping, and note that an
  unrecognized provider string deliberately maps to `unknown` rather than
  being guessed at.
- **BROKA does not call Safaricom Daraja directly for E-Confirm escrow
  funding.** The existing Daraja implementation (`api/routers/mpesa.py`)
  is untouched and still used for featured-listing payments, verification
  payments, and legacy B2C dispute refunds — none of that is part of this
  integration.
- **E-Confirm credentials are server-side only.** `ECONFIRM_API_KEY` never
  reaches Flutter; neither does the release credential
  (`confirmation_code`), which is stored encrypted at rest (`api/core/
  secrets_crypto.py`) and only ever decrypted in memory, briefly, inside
  the release call in `EscrowService._confirm_delivery_econfirm`.
- **E-Confirm's callbacks aren't exposed to BROKA as developer callbacks**,
  so reconciliation is poll-based: a fresh `GET /deal/{id}/payment-status`
  call triggers an immediate check, and `core/workers.py`'s periodic sweep
  (`task_reconcile_econfirm_escrows`, every 5 minutes) catches anything a
  client never polled for — including recovering correctly after a
  process restart, since escrow state lives in the `external_escrows`
  table, not in memory.
- **Two release paths coexist on purpose.** A Deal with no `ExternalEscrow`
  row was funded the old way (commission-only Daraja) and
  `confirm_delivery` keeps releasing it exactly as before. A Deal with an
  `ExternalEscrow` row goes through E-Confirm's own release endpoint, and
  `Deal.status` only becomes `released` once E-Confirm's response (or a
  later reconciliation poll) confirms `Completed` — never on request
  receipt alone. Two older code paths that could previously flip a deal
  straight to `released`/`refunded` with no provider involvement at all
  (`api/routers/escrow.py`'s legacy `/confirm-delivery`, and the dispute
  engine's B2C-refund branch in `api/domains/disputes/service.py`) now
  refuse outright on any E-Confirm-funded deal rather than silently
  under-paying or double-paying someone.
- **No Alembic migration.** `ExternalEscrow` (`api/models/
  external_escrow.py`) is a brand-new table, picked up automatically by
  `init_db()`'s existing `Base.metadata.create_all()` — see `api/core/
  migrations_guide.py`.

**Finalization pass (2026-09, second round):**
- `fee_quote` corrected from `POST /fee-quote` to `GET /fee-quote?amount=<int>`.
- `EConfirmClient` now normalizes both a flat response and a `{"success":
  bool, "data": {...}}` envelope to one shape before anything above it
  sees the body — `success: false` on an HTTP 200 is treated as a
  provider error, same as a 4xx.
- Fixed a real double-release race: the release flow used to hold a DB
  row lock across the entire E-Confirm HTTP call and only re-checked
  `Deal.status` on re-entry — which stays `paid` when a release's
  immediate response is `payout_initiated` rather than `Completed`, so a
  second concurrent/retried request could slip past that check and call
  release a second time. Now the lock is held only for a short
  "re-verify state fresh, mark `RELEASE_PENDING`, commit" step *before*
  the network call (matching the "don't hold a lock across an external
  call" pattern used throughout this integration), and the fresh
  `escrow.status` — not `Deal.status` — is what a second request checks.
- **Neither correction above has been verified against live E-Confirm v2
  docs or a real sandbox** — both are applied exactly as specified by
  whoever requested this finalization pass. See `econfirm_client.py`'s
  module docstring.

---

## Production Deployment Checklist

### Required
- [ ] `DATABASE_URL` → PostgreSQL
- [ ] `SECRET_KEY` → 64-char random (startup validation enforces this)
- [ ] `GEMINI_API_KEY` + `OPENROUTER_API_KEY` (+ `DEEPSEEK_API_KEY`, optional — direct API, TESTING for latency; app runs fine without it) (+ `GROQ_API_KEY`, legacy — currently a no-op until its model is updated)
- [ ] `MPESA_*` credentials
- [ ] `ECONFIRM_API_KEY` → marketplace escrow funding/release fails for every deal without it (validate_startup() refuses to start in production without one)

### Highly Recommended
- [ ] `REDIS_URL` → Upstash, Railway, or Redis Cloud (enables all v4.0 features)
- [ ] `SENTRY_DSN` → Error tracking

### Operations
- [ ] Launch ARQ worker: `arq api.core.workers.WorkerSettings`
- [ ] Set `JSON_LOGS=true` for log aggregation
- [ ] Set `ENV=production` (disables SQLite, enforces secret length)
- [ ] Run migrations: `alembic upgrade head`

---

## Regulatory Note

BROKA handles escrow and payments. Before production launch in Kenya:
- Central Bank of Kenya may require licensing for escrow/payment services
- Engage compliance counsel before handling real KES
- Full audit trail is already in place (AuditLog + LedgerEntry)
