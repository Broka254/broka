# BROKA v6.0 — AI-Powered P2P Marketplace for East Africa

> **Score: 9.2/10** — Production-grade marketplace with trust, escrow, and AI negotiation.

**v4.0 changes:** Durable Redis Streams event bus · Circuit breakers · Idempotency keys · ARQ Redis workers · Split domain models · CI-enforced test coverage floor · Two-stage CI (tests + APK)

---

## What is BROKA?

BROKA is a mobile marketplace where every transaction is mediated by an AI broker with automatic multi-provider fallback (Gemini, DeepSeek, and Groq/Llama are all present in the current code's fallback chain — the effective primary depends on which API keys are configured in the deployment environment, so treat any single model name here as illustrative, not a guaranteed-current default; see `api/domains/ai_broker/service.py` for the live chain). Buyers and sellers negotiate through BROKA — an impartial AI that protects both parties and drives fair deals.

**3% transaction fee** covers escrow protection, fraud prevention, and verified payments.

---

## Stack

| Layer | Technology |
|---|---|
| Mobile app | Flutter (Dart) |
| Backend API | FastAPI (Python 3.11) + async SQLAlchemy |
| AI broker | Multi-provider fallback chain (Gemini, DeepSeek, Groq Llama) — active provider depends on configured API keys |
| Event bus | ✨ Redis Streams (production) · asyncio (dev fallback) |
| Background jobs | ✨ ARQ + Redis (production) · asyncio queue (dev fallback) |
| Rate limiting | Redis sliding-window (multi-instance safe) |
| Observability | Sentry · Prometheus · OpenTelemetry · JSON logs |
| DB | PostgreSQL (production) · SQLite (dev/test) |
| CI/CD | GitHub Actions (backend tests + APK build) |

---

## v4.0 What's New

### Circuit Breakers
Gemini/Groq/M-Pesa wrapped in circuit breakers. If Gemini slows down — breaker opens after 5 failures, auto-falls back to Groq, then cached response, then clean 503. No request hangs forever.

### Durable Event Bus
Events written to Redis Streams in production. Survive process restarts and deployments. Same `publish()` / `@subscribe()` API — no changes needed in domain code. Falls back to asyncio in dev.

### Idempotency Keys
Double-tap the Pay button? No problem. `X-Idempotency-Key` header on payment endpoints: the key is reserved atomically (`SET NX`) before the handler runs, so a concurrent duplicate gets `409` instead of a second execution, and the first response is cached in Redis for 24 hours so retries replay it. Independently of Redis, the escrow fund path claims each attempt in the database under the deal row lock, so a second STK push can't be sent even with a fresh key or with Redis down.

### ARQ Background Workers
Named queues (`notifications`, `ai`, `fraud`, `payments`, `listings`) backed by Redis in production. Jobs survive crashes. Horizontal scaling by adding more worker processes. Degrades to asyncio in dev.

### Expanded Test Suite
Backend tests cover circuit breakers, idempotency, rate limiting, the event bus, workers, the AI broker, auth, escrow and payment races, auctions, fraud, listings, Stores and WebSockets; the Flutter app has its own widget/unit suite under `flutter_app/test/`. The backend build fails if coverage drops below 50% — the same floor in `.github/workflows/build.yml` and `backend/pytest.ini`, so the command below behaves locally exactly as it does in CI. Raise it only alongside genuinely higher measured coverage, not as a number to chase.

---

## Getting Started

### Backend (Python)

```bash
cd backend
pip install -r requirements.txt
cp ../.env.example .env       # fill in SECRET_KEY, GEMINI_API_KEY, MPESA_*, etc.
uvicorn main:app --reload --port 8000
```

**With Redis (recommended — enables all v4.0 features):**
```bash
docker run -d -p 6379:6379 redis:7-alpine
export REDIS_URL=redis://localhost:6379/0
uvicorn main:app --reload
```

**Background workers (production):**
```bash
arq api.core.workers.WorkerSettings
```

**Run tests:**
```bash
cd backend
pytest tests/ -v --cov=api --cov-report=term-missing
```

### Flutter App

```bash
cd flutter_app
flutter pub get
flutter run --dart-define=API_URL=https://your-backend.onrender.com
```

---

## Environment Variables

See `.env.example` for the full reference. Key variables:

| Variable | Required | Purpose |
|---|---|---|
| `SECRET_KEY` | ✅ | JWT signing (min 32 chars — startup validates) |
| `DATABASE_URL` | ✅ | PostgreSQL in production, SQLite in dev |
| `REDIS_URL` | ⭐ Strongly recommended | Enables all v4.0 features |
| `GEMINI_API_KEY` | ✅ | Primary AI broker |
| `GROQ_API_KEY` | ✅ | Fallback AI |
| `SENTRY_DSN` | ⭐ Production | Error tracking |
| `MPESA_*` | ✅ | M-Pesa Daraja API |

---

## API Reference

### Auth (`/auth/`)
`POST /register` · `POST /login` · `GET /me` · `PATCH /profile` · `GET /search`

### Listings (`/listings/`)
`GET /` · `POST /` · `GET /{id}` · `POST /{id}/interest` · `PATCH /{id}/status`

### Escrow (`/escrow/`)
`POST /finalize` · `POST /fund/{deal_id}` · `POST /confirm-delivery/{deal_id}` · `GET /state/{deal_id}`

### AI Broker (`/negotiate/`)
`POST /chat` · `POST /scam-check` · `POST /price-recommend` · `POST /dispute-analysis`

### Disputes (`/disputes/`)
`POST /open/{deal_id}` · `GET /{id}` · `POST /resolve/{id}`

### Admin (`/admin/`)
`GET /summary` · `GET /audit-logs` · `GET /circuit-breakers`

---

## Database Schema Changes

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

**Backend:** Render (`render.yaml` included) · Railway · Fly.io · AWS ECS

**Minimum production config:**
1. PostgreSQL database
2. Redis instance (Upstash free tier is sufficient to start)
3. At least one ARQ worker process
4. `ENV=production` set

**Never in production:**
- `DATABASE_URL=sqlite://...` (startup rejects this)
- Default `SECRET_KEY` placeholder (startup rejects this)

---

## Roadmap

- [x] Multi-step registration (selfie, biometrics)
- [x] 6-signal trust score + fraud engine
- [x] Double-entry escrow ledger
- [x] M-Pesa STK Push + B2C payout
- [x] WebSocket real-time deal status
- [x] AI broker with multi-provider fallback (Gemini, DeepSeek, Groq)
- [x] Store/business layer (User → Store → Listings, public storefront page at `/store/{slug}`) — see `ARCHITECTURE.md`'s Store section; AI store intelligence, analytics, and bundle negotiation are NOT part of this
- [x] Redis Streams durable event bus
- [x] Circuit breakers (AI + M-Pesa)
- [x] Idempotency keys (payment safety)
- [x] ARQ Redis-backed worker queues
- [x] CI-enforced test coverage floor (50%, `--cov-fail-under` in `.github/workflows/build.yml` and `backend/pytest.ini`)
- [x] VoIP calling (WebRTC)
- [x] STT / TTS voice support
- [ ] Event sourcing for payments (Phase 3)
- [ ] ML-based fraud models (Phase 4)
- [ ] Seller reputation graph (Phase 4)
