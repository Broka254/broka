# BROKA — AI-Mediated P2P Marketplace for East Africa

BROKA is a mobile marketplace where buyers and sellers deal through **Zeno**,
an AI broker that negotiates, translates, privately coaches each side, and
mediates disputes. Money moves through escrow, and BROKA takes a **3%
commission** on each deal.

| Part | Stack |
|---|---|
| `backend/` | FastAPI (Python 3.11) + async SQLAlchemy. PostgreSQL in production, SQLite in dev and tests |
| `flutter_app/` | Flutter 3.24.5 (the version CI pins), `provider` for state |

Design notes live next to this file: `ARCHITECTURE.md`, `AUCTIONS.md`,
`CALLING.md`, `EVENT_ARCHITECTURE.md`, `PRIVACY.md`, `ZENO_ACTIONS.md` and
`SELLER_METRICS.md`, plus the audit write-ups (`ESCROW_AUDIT.md`,
`DISPUTE_AUDIT.md`, `AI_AUDIT.md`, `COMMUNICATIONS_AUDIT.md`,
`REPO_REVIEW.md`).

---

## Recent changes (2026-09-23)

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
`backend/tests/test_route_ordering.py`, `backend/tests/test_payment_races.py`
and `flutter_app/test/session_renewal_test.dart`.

---

## How it works

### Money

Two escrow paths run side by side:

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

Flutter:

```bash
cd flutter_app
flutter analyze --no-fatal-warnings --no-fatal-infos   # CI runs this
flutter test                                           # CI does not run this yet
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
| `REDIS_URL` | Strongly recommended | Rate limits and idempotency across instances, call state, the ARQ queue |
| `SENTRY_DSN` | Production | Error tracking and reconciliation alerts |
| `MPESA_*` | For M-Pesa | Safaricom Daraja |
| `AT_*` or `MOBITECH_*` | For SMS | Phone OTP codes and SMS reminders |
| `RESEND_API_KEY`, `RESEND_FROM` | Optional | Email verification codes (requests return 503 without them) |
| `DEEPGRAM_API_KEY`, `ASSEMBLYAI_API_KEY` | Optional | Zeno voice input. The app only ever receives short-lived tokens |
| `CLOUDFLARE_TURN_KEY_ID`, `CLOUDFLARE_TURN_API_TOKEN` | Optional | Call relay for networks where a direct connection fails |
| `FAL_KEY` | Optional | AI showcase images for listings |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | Default 15 | Access token lifetime. The refresh token (30 days) renews it |

---

## API overview

A running server serves the full interactive reference at `/docs`. Most
routes need `Authorization: Bearer <access token>`.

| Prefix | Covers |
|---|---|
| `/auth` | Phone and email OTP, register, login, profile, token refresh and revoke |
| `/listings` | Browse, create and edit listings; listing and seller metrics; AI showcase images |
| `/categories`, `/trending`, `/traders` | Discovery |
| `/stores`, `/store/{slug}` | Store API, and the public HTML storefront page |
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
| `/media` | Voice note and image upload |
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
PostgreSQL database, both on Render's free plan.

**Minimum production config:**
1. PostgreSQL.
2. `ENV=production` and the required secrets in the table above. Startup
   checks them and refuses to run without them.
3. Redis (Upstash's free tier is enough to start).
4. An ARQ worker whenever `REDIS_URL` is set:
   `arq api.core.workers.WorkerSettings`. `render.yaml` doesn't define one
   yet, and without it queued trust-score jobs wait in Redis unprocessed.

**Worth knowing:**
- Scheduled work lives in the web process. Render's free plan puts an idle
  service to sleep, and while it sleeps, auction closes, deal timers and
  E-Confirm reconciliation don't run. They catch up once it wakes.
- CI (`.github/workflows/build.yml`) runs on every push to `main`: backend
  tests against Redis with the 50% coverage gate, then `flutter analyze`
  (errors only), then an APK build that replaces the `latest-release`
  GitHub release. Without a keystore configured, that APK is signed with the
  debug key.

---

## Roadmap

- [x] Multi-step registration (selfie, biometrics)
- [x] 6-signal trust score + fraud engine
- [x] Double-entry escrow ledger
- [x] M-Pesa STK Push + B2C payout
- [x] E-Confirm escrow for the full agreed price
- [x] WebSocket real-time deal status
- [x] AI broker with multi-provider fallback (Gemini, DeepSeek, OpenRouter)
- [x] Store/business layer (User → Store → Listings, public storefront page at `/store/{slug}`) — see `ARCHITECTURE.md`'s Store section; AI store intelligence, analytics, and bundle negotiation are NOT part of this
- [x] Auction lifecycle (window, atomic bids, close, winner → deal)
- [x] Circuit breakers (AI + M-Pesa)
- [x] Idempotency keys (payment safety)
- [x] ARQ Redis-backed worker queues
- [x] CI-enforced test coverage floor (50%, `--cov-fail-under` in `.github/workflows/build.yml` and `backend/pytest.ini`)
- [x] VoIP calling (WebRTC)
- [x] STT / TTS voice support
- [ ] Consume the Redis event streams (events are written there but only handled in-process today)
- [ ] Run `flutter test` in CI
- [ ] Event sourcing for payments (Phase 3)
- [ ] ML-based fraud models (Phase 4)
- [ ] Seller reputation graph (Phase 4)
