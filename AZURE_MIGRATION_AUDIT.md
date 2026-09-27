# Azure Container Apps migration audit

2026-09-27. Scope: what the backend needs from its environment, what ties it
to Render, and what has to be true before the app's API URL moves from Render
(`broka-dbjd.onrender.com`) to Azure Container Apps (`broka-api`, resource
group `broka-production`, South Africa North, image from
`brokaproductionacr.azurecr.io`).

**This is an audit, nothing more.** No code, Dockerfile, `render.yaml`,
workflow or app URL was changed. Render stays exactly as it is, as the
rollback. No secret values appear here; every value below is a name, a
default that is already in the source, or a placeholder.

## Summary

1. **No code change is required for the container to run on Azure.** The
   image starts with `uvicorn main:app --host 0.0.0.0 --port 8000`, nothing
   reads `$PORT`, and every Render hostname in the code is a fallback that an
   environment variable overrides.
2. **`GET /` returning 200 does not show that Azure is configured.** With
   `ENV` unset the app boots with nothing configured at all: SQLite inside the
   container, placeholder signing keys, no fatal checks (verified in section 1).
   Look at `GET /ready` and the startup log line instead.
3. **Four values must be copied from Render byte for byte, not regenerated:**
   `SECRET_KEY`, `ZAC_SECRET`, `MPESA_CALLBACK_SECRET`, `STOREFRONT_API_KEY`.
   Render generated the first and third (`generateValue: true`), so copy them
   from the Render dashboard.
4. **Don't copy `CLIENT_IP_HEADER=CF-Connecting-IP` to Azure.** Azure is not
   behind Cloudflare, so any caller could set that header and dodge every
   per-IP limit. Use `TRUSTED_PROXY_HOPS=1` and check it (section 4).
5. **`DATABASE_URL` must not end in `?sslmode=require`.** asyncpg raises
   `TypeError` on the first connection (verified). Use `?ssl=require` or no
   parameter.
6. **Render and Azure will run at the same time for as long as old APKs
   exist.** The API URL is compiled into the APK and there is no forced
   update. So both must share one PostgreSQL and one Redis, and the in-process
   parts (WebSocket hubs, sweeps) need a decision first (section F).

---

## 1. Container and startup compatibility

| Check | Result |
|---|---|
| Dockerfile | `backend/Dockerfile`: `python:3.11-slim`, `EXPOSE 8000`, exec-form `CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]`. Matches the Azure target port 8000. `tests/test_deployment_config.py` pins the command. |
| `$PORT` | Nothing in the backend reads `PORT`. Render finds the open port on its own, so the same fixed port works on both platforms. No change needed. |
| Root `Dockerfile` | A mirror for root-context builds. Neither Render nor the Azure workflow uses it (the workflow builds `appSourcePath: backend`). |
| Build context | The Azure workflow builds from `backend/`, the same context Render uses (`dockerContext: ./backend`). |
| Startup sequence | The lifespan runs `validate_secret_key()`, `validate_startup()`, then `init_db()` (`create_all` plus about 94 idempotent `ALTER`/`CREATE INDEX` statements, each in its own savepoint), then the in-process workers and the 60 s and 300 s sweeps. uvicorn only binds port 8000 **after** all of that finishes, so a slow or distant database makes startup slow. |
| Health endpoints | `/live` and `/health` (process up), `/ready` (runs `SELECT 1` and pings Redis; returns 503 if the database is down), `/` (version banner). |
| Proxy headers | uvicorn's default `forwarded_allow_ips` is `127.0.0.1`, so `request.client` is Azure's ingress. That's correct: callers are resolved by `api/core/client_ip.py`. **Don't** add `--forwarded-allow-ips '*'` or `FORWARDED_ALLOW_IPS`, because then any caller could set their own address. Nothing builds absolute URLs from the request's scheme or host (no `request.base_url` or `url_for`), so plain HTTP behind TLS-terminating ingress does no harm. |
| WebSockets | `/deal-ws`, `/auction-ws`, `/calls/ws`, `/media`. Azure ingress supports WebSocket upgrades. uvicorn[standard] pings every 20 s and the calls socket has its own heartbeat, so idle timeouts aren't a concern. |
| `.env` files | `python-dotenv` is installed but `load_dotenv()` is never called. All configuration must come from the platform's environment (Container App env vars or `secretref:` secrets). |
| Shutdown | uvicorn handles SIGTERM and the lifespan stops the sweeps and workers. Jobs in the in-process queues are lost on exit, the same as on Render. |

### What production refuses to start without (verified)

`validate_secret_key()` and `validate_startup()` were run with `ENV=production`
and placeholder values, removing one variable at a time:

| Missing or bad | Result |
|---|---|
| All of the following set | starts |
| `SECRET_KEY` (unset, default, or under 32 characters) | **FATAL** |
| `ZAC_SECRET` (unset or default) | **FATAL** |
| `MPESA_CALLBACK_SECRET` (unset) | **FATAL** |
| `ECONFIRM_API_KEY` (unset) | **FATAL** |
| `DATABASE_URL` (unset, which means SQLite) | **FATAL** |
| `STOREFRONT_API_KEY` set but under 32 characters | **FATAL** |
| **`ENV` unset and nothing else set** | **starts**: development mode, SQLite in the container, placeholder keys |

Everything else only logs a warning at boot: Redis, Sentry, SMS provider,
R2, TURN, Resend, `STOREFRONT_API_KEY` unset, client-IP resolution, and a
wildcard `ALLOWED_ORIGINS`.

### Recommended Container App settings (portal or `az`, not code)

- **Scale:** `minReplicas: 1`, `maxReplicas: 1` for now. At zero replicas
  nothing runs the sweeps (deal timers, auction closes, E-Confirm
  reconciliation, availability SMS). With more than one replica, the
  process-local problems in F.5 apply. Check what is set now with
  `az containerapp show -n broka-api -g broka-production --query properties.template.scale`.
- **Probes:** startup `GET /live`, with enough failures allowed to cover
  `init_db()` against the real database. Liveness `GET /live`. Readiness
  `GET /ready`. Don't point liveness at `/ready`: a database hiccup would
  then restart the container.

---

## 2. Environment-variable inventory

"Where" is the file that reads the variable. Most go through
`backend/api/core/config.py` (`settings`), but several modules still call
`os.getenv` directly. Those are listed too, because they read the environment
at import time, independently of `settings`.

Required means one of three things:
- **fatal**: production refuses to boot without it.
- **functional**: it boots, but a core feature is broken without it.
- **optional**: a default or a graceful fallback exists.

Secret means the value must go in a Container App secret, not a plain
env var.

### Runtime

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `ENV` | app | `config.py:37`, `security.py:47` | **fatal in effect**: must be `production` | no | Unset means `development`: SQLite, no fatal checks. `ENVIRONMENT` is read as a fallback alias. |
| `ENVIRONMENT` | app | `config.py:37`, `security.py:47` | optional | no | Only read when `ENV` is unset. |
| `DEBUG` | app | `config.py:38` | optional | no | Read but used nowhere. |
| `MAX_REQUEST_BODY_MB` | app | `config.py:305`, applied in `main.py` | optional (32) | no | |
| `JSON_LOGS` | logging | `core/observability.py:56` | optional | no | Production already logs JSON (`configure_logging(json_logs=is_production)`). |
| `RENDER` | Render | `config.py:28` | **don't set on Azure** | no | Render sets it automatically. It only chooses the `CLIENT_IP_HEADER` default. |

### PostgreSQL

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `DATABASE_URL` | PostgreSQL | `database.py:19`, `config.py:41`, `migrations/env.py:24`; passed raw to `task_recompute_trust_score` (`core/zeno_subscribers.py`) | **fatal** | **yes** (holds the password) | Use the form `postgresql+asyncpg://USER:PASSWORD@HOST:5432/DB?ssl=require`. **Not** `?sslmode=require`: asyncpg raises `TypeError: connect() got an unexpected keyword argument 'sslmode'` (verified with SQLAlchemy 2.1.1 and asyncpg 0.31.0). With no parameter, asyncpg tries TLS first (`prefer`). The `+asyncpg` form also matters because the trust-score job builds its own engine from the raw value, and a plain `postgresql://` selects psycopg2, which isn't installed. Render's value is the **internal** connection string, which Azure can't reach; Azure needs the **external** one. |
| `DB_POOL_SIZE` | PostgreSQL | `database.py:49` | optional (10) | no | Up to pool + overflow connections per replica, **per platform**. With Render and Azure both live, keep the total under the server's connection limit. |
| `DB_MAX_OVERFLOW` | PostgreSQL | `database.py:50` | optional (20) | no | As above. |

### Redis, ARQ and background work

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `REDIS_URL` | Redis | `config.py:308`. Used by `core/rate_limit.py`, `core/idempotency.py`, `core/call_state.py`, `core/event_catalog.py`, `core/events.py`, `core/stats_cache.py`, `core/workers.py` (ARQ enqueue), `domains/ai_broker/service.py`, `domains/stores/stats.py`, `main.py` (`/ready`) | **functional** (warns only) | **yes** (password) | Without it: rate limits, idempotency keys, call state and the event bus fall back to in-process, per replica. **Must be the same Redis Render uses** while both are live, or rate limits, idempotency and call state split in two. `rediss://` (TLS) works for redis-py. The ARQ enqueue parser only understands `redis://` (see "Noticed along the way"). |

There is no separate ARQ worker variable. `arq api.core.workers.WorkerSettings`
isn't deployed on Render or Azure; the sweeps run inside the web process.

### Authentication, tokens and OTP

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `SECRET_KEY` | auth | `security.py:24`, `config.py:46`; also derives the Fernet key in `core/secrets_crypto.py` | **fatal** (32+ chars) | **yes** | **Must equal Render's.** It signs access, refresh, phone-verify and call tokens, and encrypts stored E-Confirm confirmation codes. A different value logs out every user on the new backend and makes stored confirmation codes unreadable. |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | auth | `security.py:27`, `config.py:50` | optional (15) | no | Keep equal to Render's. |
| `REFRESH_TOKEN_EXPIRE_DAYS` | auth | `security.py:28`, `config.py:53` | optional (30) | no | Keep equal to Render's. |
| `PHONE_VERIFY_TOKEN_EXPIRE_MINUTES` | auth | `config.py:187` | optional (15) | no | |
| `CALL_TOKEN_EXPIRE_MINUTES` | calls | `config.py:225` | optional (5) | no | |
| `OTP_LENGTH` | OTP | `config.py:182` | optional (6) | no | |
| `OTP_EXPIRY_SECONDS` | OTP | `config.py:183` | optional (300) | no | |
| `OTP_MAX_ATTEMPTS` | OTP | `config.py:184` | optional (5) | no | |
| `ZAC_SECRET` | disputes | `config.py:230`, `routers/disputes.py:64`, `domains/disputes/service.py:53` | **fatal** | **yes** | **Must equal Render's**: it HMAC-signs dispute codes. It isn't in `render.yaml`, so it was set by hand in the Render dashboard. |
| `ADMIN_BOOTSTRAP_EMAIL` | admin | `config.py:238`, `routers/admin.py:62` | optional | no (an email address) | Keep equal to Render's. |

### Email (Resend)

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `RESEND_API_KEY` | Resend | `config.py:246` → `core/email.py` | functional (email verification returns 503 without it) | **yes** | |
| `RESEND_FROM` | Resend | `config.py:247` | functional | no | Must be on a domain verified in Resend. |
| `RESEND_REPLY_TO` | Resend | `config.py:250` | optional | no | |

### SMS (phone OTP and nudges)

At least one provider pair is **functional**-required: without one, phone OTP
and therefore signup fail in production.

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `MOBITECH_API_KEY` | Mobitech | `config.py:157` → `core/sms.py` | functional (with the sender name) | **yes** | Tried first. |
| `MOBITECH_SENDER_NAME` | Mobitech | `config.py:158` | functional | no | |
| `MOBITECH_BASE_URL` | Mobitech | `config.py:159` | optional | no | Domain only, no path (a startup warning checks this). |
| `MOBITECH_SEND_ENDPOINT` | Mobitech | `config.py:176` | optional (`/sms/sendsms`) | no | |
| `AT_USERNAME` | Africa's Talking | `config.py:179` → `core/sms.py` | fallback provider | no | |
| `AT_API_KEY` | Africa's Talking | `config.py:180` | fallback provider | **yes** | |
| `AT_SENDER_ID` | Africa's Talking | `config.py:181` | optional | no | |

### Payments: M-Pesa (Daraja)

Several routers read these directly with `os.getenv` at import: `routers/mpesa.py`,
`routers/verify.py`, `routers/featured.py`, `routers/disputes.py` and
`domains/disputes/service.py`. `core/mpesa_stk.py` and the pricing and premium
payments read `settings`.

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `MPESA_ENV` | M-Pesa | `config.py:112`, `routers/mpesa.py:32`, `verify.py:38`, `featured.py:42`, `routers/disputes.py:78`, `domains/disputes/service.py:70` | functional: `production` for real money | no | Defaults to `sandbox`. |
| `MPESA_CONSUMER_KEY` | M-Pesa | same files | functional | **yes** | |
| `MPESA_CONSUMER_SECRET` | M-Pesa | same files | functional | **yes** | |
| `MPESA_SHORTCODE` | M-Pesa | same files | functional | no | Defaults to the sandbox shortcode `174379`. |
| `MPESA_PASSKEY` | M-Pesa | `config.py:116`, `mpesa.py:36`, `verify.py:42`, `featured.py:46` | functional | **yes** | |
| `MPESA_CALLBACK_SECRET` | M-Pesa | `config.py:237`, `mpesa.py:53`, `verify.py:46`, `featured.py:50`; the pricing and premium callbacks | **fatal** | **yes** | **Must equal Render's.** It's the secret path segment in every callback URL already handed to Safaricom. |
| `MPESA_CALLBACK_URL` | M-Pesa (deals, legacy) | `mpesa.py:55`, `config.py:117` | **set explicitly on Azure** | **yes** (contains the secret) | Unset, it becomes `https://broka-dbjd.onrender.com/mpesa/callback/<secret>`. |
| `MPESA_VERIFY_CALLBACK_URL` | M-Pesa (verification) | `verify.py:47`, `config.py:120` | **set explicitly** | **yes** | Unset, it defaults to the Render URL **without** the secret, and that route is refused once the secret is set. So verification payments never complete unless this is set with `/<secret>`. |
| `MPESA_FEATURED_CALLBACK_URL` | M-Pesa (boosts) | `featured.py:51`, `config.py:123` | **set explicitly** | **yes** | Same as the row above. |
| `MPESA_LISTING_FEE_CALLBACK_URL` | M-Pesa (listing fees) | `config.py:343` → `domains/pricing/payments.py:62` | optional | **yes** if set | Unset, it is `(PUBLIC_API_BASE_URL or the Render host)/pricing/listing-fee/callback/<secret>`. |
| `MPESA_PREMIUM_CALLBACK_URL` | M-Pesa (plans) | `config.py:359` → `domains/premium/payments.py:55` | optional | **yes** if set | Unset, it is `(PUBLIC_API_BASE_URL or the Render host)/premium/callback/<secret>`. |
| `MPESA_B2C_INITIATOR` | M-Pesa B2C (legacy refunds) | `config.py:126`, `routers/disputes.py:82`, `domains/disputes/service.py:74` | functional for legacy refunds | no | |
| `MPESA_B2C_CREDENTIAL` | M-Pesa B2C | same files | functional for legacy refunds | **yes** | |
| `MPESA_B2C_TIMEOUT_URL` | M-Pesa B2C | `config.py:128`, `routers/disputes.py:84`, `domains/disputes/service.py:76` | **set explicitly** | no | Defaults to the Render host. |
| `MPESA_B2C_RESULT_URL` | M-Pesa B2C | `config.py:131`, `routers/disputes.py:85`, `domains/disputes/service.py:77` | **set explicitly** | no | Defaults to the Render host. |

### Escrow: E-Confirm

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `ECONFIRM_API_KEY` | E-Confirm | `config.py:138` → `core/econfirm_client.py` | **fatal** | **yes** | E-Confirm holds the escrow money. No callbacks: the sweep polls. |
| `ECONFIRM_BASE_URL` | E-Confirm | `config.py:139` | optional | no | |
| `ECONFIRM_TIMEOUT_SECONDS` | E-Confirm | `config.py:142` | optional (20) | no | |
| `ECONFIRM_POLL_INTERVAL_SECONDS` | E-Confirm | `config.py:145` | optional (4) | no | |
| `ECONFIRM_MAX_POLL_SECONDS` | E-Confirm | `config.py:148` | optional (180) | no | |

### Pricing switches

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `LISTING_FEES_ENABLED` | pricing | `config.py:337` → `domains/listings/service.py`, `domains/pricing/*` | optional (false) | no | **Must equal Render's**, or the rules depend on which backend a build talks to. |
| `PREMIUM_ENABLED` | premium | `config.py:354` → `domains/premium/*` | optional (false) | no | **Must equal Render's.** |

### AI providers

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `GEMINI_API_KEY` | Gemini | `config.py:58` → `domains/ai_broker/service.py`, `routers/negotiate.py:61`, `routers/disputes.py:65`, `domains/disputes/service.py:56` | functional (primary broker) | **yes** | |
| `DEEPSEEK_API_KEY` | DeepSeek | `config.py:77`, `negotiate.py:78` | optional | **yes** | Skipped when unset. |
| `DEEPSEEK_MODEL` | DeepSeek | `config.py:78`, `negotiate.py:88` | optional | no | The code default is `deepseek-flash`; `render.yaml` sets `deepseek-v4-flash`. Copy Render's value. |
| `DEEPSEEK_BASE_URL` | DeepSeek | `config.py:81`, `negotiate.py:89` | optional | no | |
| `DEEPSEEK_TIMEOUT_SECONDS` | DeepSeek | `config.py:88`, `negotiate.py:90` | optional (15) | no | |
| `OPENROUTER_API_KEY` | OpenRouter | `config.py:66`, `negotiate.py:70`, `routers/disputes.py:74`, `domains/disputes/service.py:65` | functional (fallback) | **yes** | |
| `OPENROUTER_MODEL` | OpenRouter | same files | optional | no | |
| `GROQ_API_KEY` | Groq | `config.py:59`, `negotiate.py:65`, `routers/disputes.py:66`, `domains/disputes/service.py:57` | optional (currently does nothing) | **yes** | |
| `FAL_KEY` | fal.ai (AI covers) | `config.py:98` → `core/fal_client.py` | optional (warns) | **yes** | Not in `render.yaml`. |
| `FAL_SHOWCASE_MODEL` | fal.ai | `config.py:104` | optional | no | |
| `OPENAI_API_KEY` | OpenAI Whisper (`/stt`) | `routers/stt.py:25` | optional | **yes** | Not in `render.yaml` or `.env.example`. |
| `DEEPGRAM_API_KEY` | Deepgram (voice) | `routers/stt.py:123` | optional (503 when unset) | **yes** | |
| `ASSEMBLYAI_API_KEY` | AssemblyAI (voice fallback) | `routers/stt.py:206` | optional | **yes** | |

TTS (`routers/tts.py`) uses Edge TTS and a public Hugging Face Space and needs
no keys.

### Firebase (push notifications)

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `FIREBASE_SERVICE_ACCOUNT_JSON` | FCM | `core/push.py:52`, `routers/calls.py:132` | functional (push and incoming-call rings) | **yes** | The whole service-account JSON in one value. Container App secrets hold multi-line values. |
| `GOOGLE_APPLICATION_CREDENTIALS` | FCM | `core/push.py:64` | optional | no (a path) | A file-path alternative, read only by `PushService`, not by `calls.py`. On Azure it would need a mounted secret volume, so prefer the JSON variable. |

### WebRTC and TURN

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `CLOUDFLARE_TURN_KEY_ID` | Cloudflare TURN | `config.py:212` → `core/cloudflare_turn_client.py` | functional (relayed calls) | no | |
| `CLOUDFLARE_TURN_API_TOKEN` | Cloudflare TURN | `config.py:213` | functional | **yes** | |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare | `config.py:216` | optional (unused) | no | |
| `APNS_AUTH_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID`, `APNS_USE_PRODUCTION` | APNs (iOS VoIP) | **not read**: `config.py:202-206` hard-codes them | n/a | the key would be | Documented in `CALLING.md`, but setting them has no effect today. |

### Images: Cloudflare R2, and public URLs

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `R2_ACCOUNT_ID` | R2 | `config.py:263` → `core/media_storage.py` | functional (all five together, or images go to the database) | no | |
| `R2_ACCESS_KEY_ID` | R2 | `config.py:264` | as above | **yes** | |
| `R2_SECRET_ACCESS_KEY` | R2 | `config.py:265` | as above | **yes** | |
| `R2_BUCKET` | R2 | `config.py:266` | as above | no | |
| `MEDIA_PUBLIC_BASE_URL` | R2 | `config.py:267` → `core/media_storage.py`, `domains/media/service.py:253` | as above | no | Platform-neutral: images served from R2 don't depend on the API host. |
| `PUBLIC_API_BASE_URL` | this API | `config.py:273` → `core/media_storage.py:87`, `domains/media/service.py:251`, `domains/pricing/payments.py:66`, `domains/premium/payments.py:58` | **set explicitly on Azure** | no | Three jobs: absolute URLs for database-stored images, recognising BROKA's own image URLs sent back by old builds, and the base of the listing-fee and plan callbacks. |
| `STORE_LINK_BASE` | store links | `config.py:279` | optional (`https://broka.co.ke/store`) | no | Already platform-neutral. |

### Observability

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `SENTRY_DSN` | Sentry | `config.py:311` → `core/observability.py`, `core/workers.py` | functional: it also carries **reconciliation alerts** (money that needs a person) | treat as **yes** | Both platforms report `environment=production`, so Sentry can't tell them apart. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OpenTelemetry | `core/tracing.py:81` | optional | no | gRPC with `insecure=True`. It doesn't go straight to Azure Monitor; that needs a collector. Leave it unset unless you run one. |
| `OTEL_CONSOLE_EXPORT` | OpenTelemetry | `core/tracing.py:76` | optional (dev only) | no | |

### Requests, CORS, client address, storefront

| Variable | Service | Where | Required | Secret | Notes |
|---|---|---|---|---|---|
| `ALLOWED_ORIGINS` | CORS | `config.py:314` → `main.py` | optional (`*`) | no | Render sets `*`. The app isn't subject to CORS and the storefront calls the API server-side, so match Render. |
| `CLIENT_IP_HEADER` | rate limits and audit IPs | `config.py:299` → `core/client_ip.py` | see section 4 | no | **Leave unset on Azure.** |
| `TRUSTED_PROXY_HOPS` | rate limits and audit IPs | `config.py:300` → `core/client_ip.py` | **set on Azure** (1, then verify) | no | |
| `STOREFRONT_API_KEY` | web storefront | `config.py:301` → `core/client_ip.py` | fatal if set and under 32 chars; warns if unset | **yes** | **Must equal Render's and Vercel's.** |

### Marketplace tuning (all optional; keep equal to Render's)

`BUY_AGENT_MAX_ACTIVE` (`config.py:373`), `BUY_AGENT_WATCH_DAYS` (`:379`),
`AUCTION_PAYMENT_DEADLINE_HOURS` (`:385`), `AUCTION_FUNDING_SETTLE_MINUTES`
(`:395`), `AUCTION_DEFAULT_MIN_INCREMENT` (`:400`), `AUCTION_ENDING_SOON_MINUTES`
(`:405`), `AUCTION_DEFAULT_DURATION_HOURS` (`:415`). None are secret.

### Outside the backend (for reference)

| Variable | Part | Where | Secret | Notes |
|---|---|---|---|---|
| `BROKA_API_URL` | web storefront (Vercel) | `web/src/lib/server-config.ts:5` | no | Defaults to the Render host. Switched in Vercel's settings, not in code. |
| `STOREFRONT_API_KEY` | web storefront | `web/src/lib/server-config.ts:14` | **yes** | The same value as the API's. |
| `NEXT_PUBLIC_SITE_URL`, `NEXT_PUBLIC_APP_DOWNLOAD_URL`, `ANDROID_CERT_SHA256`, `APPLE_APP_IDS` | web storefront | `web/src/lib/config.ts`, `web/src/app/.well-known/*` | no | Not affected by the move. |
| `API_URL`, `API_WS_URL` (`--dart-define`) | Flutter app | `api_service.dart:18`, `api_client.dart:30`, `deal_ws_client.dart:85`, `auction_ws_client.dart:23` | no | Compiled in. CI passes no `--dart-define`, so the Render defaults ship. Change **both** together, later. |
| `BROKAAPI_AZURE_CLIENT_ID`, `BROKAAPI_AZURE_TENANT_ID`, `BROKAAPI_AZURE_SUBSCRIPTION_ID` | GitHub Actions (Azure OIDC login) | `.github/workflows/broka-api-AutoDeployTrigger-*.yml` | GitHub secrets | Deploy identity only, never app configuration. |

### Documentation gaps found

- **`render.yaml` doesn't list many variables production needs**:
  `ZAC_SECRET`, `ECONFIRM_API_KEY`, every `MPESA_*` except the secret and the
  two optional callback URLs, `MOBITECH_*`, `FAL_KEY` and `OPENAI_API_KEY`.
  They must be set by hand in the Render dashboard. **Copy from the Render
  dashboard, not from `render.yaml`.**
- **`.env.example` omits** `OPENAI_API_KEY`, `DEEPGRAM_API_KEY`,
  `ASSEMBLYAI_API_KEY`, `FAL_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`, `OTEL_*`,
  the `OTP_*` and token-lifetime settings, and the `AUCTION_*` settings.

---

## A. Required variables (Azure won't work correctly without them)

**Fatal at boot:** `ENV=production`, `SECRET_KEY`, `ZAC_SECRET`,
`MPESA_CALLBACK_SECRET`, `ECONFIRM_API_KEY`, `DATABASE_URL`.

**Functional**: the app boots, but core features break without them:
- `REDIS_URL`: shared state and rate limits.
- M-Pesa: `MPESA_ENV`, `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`,
  `MPESA_SHORTCODE`, `MPESA_PASSKEY`.
- One SMS pair: `MOBITECH_API_KEY` with `MOBITECH_SENDER_NAME`, or
  `AT_USERNAME` with `AT_API_KEY`. Without one, signup fails.
- `GEMINI_API_KEY` and/or `OPENROUTER_API_KEY`: Zeno.
- `FIREBASE_SERVICE_ACCOUNT_JSON`: push and call rings.
- All five R2 variables: images.
- `SENTRY_DSN`: reconciliation alerts.
- `CLOUDFLARE_TURN_KEY_ID` and `CLOUDFLARE_TURN_API_TOKEN`: relayed calls.
- `RESEND_API_KEY` and `RESEND_FROM`: email verification.
- `STOREFRONT_API_KEY`.

**Required on Azure specifically**, because the fallbacks point at Render or
suit Render only:
- `PUBLIC_API_BASE_URL`, `MPESA_CALLBACK_URL`, `MPESA_VERIFY_CALLBACK_URL`,
  `MPESA_FEATURED_CALLBACK_URL`, `MPESA_B2C_RESULT_URL`,
  `MPESA_B2C_TIMEOUT_URL`.
- `TRUSTED_PROXY_HOPS`.

## B. Optional variables

`ENVIRONMENT`, `DEBUG`, `JSON_LOGS`, `MAX_REQUEST_BODY_MB`, `DB_POOL_SIZE`,
`DB_MAX_OVERFLOW`, `ACCESS_TOKEN_EXPIRE_MINUTES`, `REFRESH_TOKEN_EXPIRE_DAYS`,
`PHONE_VERIFY_TOKEN_EXPIRE_MINUTES`, `CALL_TOKEN_EXPIRE_MINUTES`,
`OTP_LENGTH`, `OTP_EXPIRY_SECONDS`, `OTP_MAX_ATTEMPTS`,
`ADMIN_BOOTSTRAP_EMAIL`, `RESEND_REPLY_TO`, `MOBITECH_BASE_URL`,
`MOBITECH_SEND_ENDPOINT`, `AT_SENDER_ID`, `MPESA_LISTING_FEE_CALLBACK_URL`,
`MPESA_PREMIUM_CALLBACK_URL`, `MPESA_B2C_INITIATOR`, `MPESA_B2C_CREDENTIAL`
(needed only for legacy refunds), `ECONFIRM_BASE_URL`, `ECONFIRM_*_SECONDS`,
`LISTING_FEES_ENABLED`, `PREMIUM_ENABLED`, `DEEPSEEK_*`, `OPENROUTER_MODEL`,
`GROQ_API_KEY`, `FAL_KEY`, `FAL_SHOWCASE_MODEL`, `OPENAI_API_KEY`,
`DEEPGRAM_API_KEY`, `ASSEMBLYAI_API_KEY`, `GOOGLE_APPLICATION_CREDENTIALS`,
`CLOUDFLARE_ACCOUNT_ID`, `STORE_LINK_BASE`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
`OTEL_CONSOLE_EXPORT`, `ALLOWED_ORIGINS`, `CLIENT_IP_HEADER` (unset on Azure),
`BUY_AGENT_*`, `AUCTION_*`.

Optional means the app runs without them. "Keep equal to Render's" still
applies to the switches and tuning values.

## C. Secrets (Container App secrets, referenced with `secretref:`)

- **Must be identical to Render's:** `SECRET_KEY`, `ZAC_SECRET`,
  `MPESA_CALLBACK_SECRET`, `STOREFRONT_API_KEY`.
- **Connection strings:** `DATABASE_URL`, `REDIS_URL`.
- **Payments:** `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`, `MPESA_PASSKEY`,
  `MPESA_B2C_CREDENTIAL`, `ECONFIRM_API_KEY`, and every callback URL that
  embeds the secret (`MPESA_CALLBACK_URL`, `MPESA_VERIFY_CALLBACK_URL`,
  `MPESA_FEATURED_CALLBACK_URL`, and `MPESA_LISTING_FEE_CALLBACK_URL` and
  `MPESA_PREMIUM_CALLBACK_URL` if set).
- **Providers:** `MOBITECH_API_KEY`, `AT_API_KEY`, `RESEND_API_KEY`,
  `GEMINI_API_KEY`, `DEEPSEEK_API_KEY`, `OPENROUTER_API_KEY`, `GROQ_API_KEY`,
  `FAL_KEY`, `OPENAI_API_KEY`, `DEEPGRAM_API_KEY`, `ASSEMBLYAI_API_KEY`,
  `FIREBASE_SERVICE_ACCOUNT_JSON`, `CLOUDFLARE_TURN_API_TOKEN`,
  `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`.
- **Treat as secret:** `SENTRY_DSN`.

Keep them out of the workflow file and the repository. Set them on the
Container App (portal, or `az`, or Key Vault references):

```sh
# Placeholders only. Run from a trusted shell; values never go in git.
az containerapp secret set -n broka-api -g broka-production \
  --secrets secret-key=<value> database-url=<value>
az containerapp update -n broka-api -g broka-production \
  --set-env-vars ENV=production SECRET_KEY=secretref:secret-key \
                 DATABASE_URL=secretref:database-url TRUSTED_PROXY_HOPS=1
```

Container App secret names must be lowercase, so map `SECRET_KEY` to
`secret-key` and so on. Changing env vars creates a new revision. Changing a
secret alone doesn't: restart the revision for it to take effect.

---

## D. Render-specific configuration

| # | Where | What | Effect on Azure | Recommendation |
|---|---|---|---|---|
| 1 | `config.py:118-132`, `routers/mpesa.py:54`, `routers/verify.py:49`, `routers/featured.py:53`, `routers/disputes.py:84-85`, `domains/disputes/service.py:76-77`, `domains/pricing/payments.py:59`, `domains/premium/payments.py:52` | `https://broka-dbjd.onrender.com` as the fallback M-Pesa callback and result host | Unless overridden, payments started on Azure tell Safaricom to call back **Render**. That works only while Render is up and shares the database, and silently breaks the day Render is retired. | **Now:** set the callback variables explicitly on Azure (A). **Later, optional:** derive the fallbacks from `PUBLIC_API_BASE_URL`, keeping the Render host as the last resort so Render behaves the same (E.2). |
| 2 | `routers/negotiate.py:701`, `routers/disputes.py:213`, `domains/disputes/service.py:165`, `domains/ai_broker/service.py:1079` | OpenRouter `HTTP-Referer: https://broka-dbjd.onrender.com` | None: it's an attribution header. | Cosmetic. Optionally make it `https://broka.co.ke` (E.3). |
| 3 | `config.py:23-30` (`_client_ip_header_default`) | `RENDER=true` makes `CF-Connecting-IP` the client-IP header | Correct on both platforms: Azure doesn't set `RENDER`. | Keep, because Render needs it. The hazard is **copying** `CLIENT_IP_HEADER=CF-Connecting-IP` into Azure (section 4). |
| 4 | `render.yaml` | `CLIENT_IP_HEADER: CF-Connecting-IP`, `DATABASE_URL fromDatabase` (the internal URL), `generateValue` for `SECRET_KEY` and `MPESA_CALLBACK_SECRET`, `region: oregon`, `plan: free` | Render only. | Leave untouched (the rollback). Copy the generated values; don't regenerate them. |
| 5 | `flutter_app/lib/services/api_service.dart:20`, `lib/core/network/api_client.dart:32`, `deal_ws_client.dart:87`, `auction_ws_client.dart:25` | Render as the compiled-in default for `API_URL` and `API_WS_URL` | The app talks to Render. | Not changed, as instructed. See F.9 and F.10 before changing. |
| 6 | `web/src/lib/server-config.ts:5`, `web/.env.example:2` | Render as the storefront's default API | The storefront talks to Render. | Switch with `BROKA_API_URL` in Vercel when ready; no code change. |
| 7 | `$PORT` / start command | None found | n/a | Nothing to do. |
| 8 | Deploy triggers | Render deploys from its blueprint on `main`. `.github/workflows/broka-api-AutoDeployTrigger-*.yml` deploys to Azure on any push to `main` touching `backend/**` or `.github/workflows/**`, **without waiting for the test jobs** in `build.yml`. | A commit whose tests fail still reaches Azure (and Render). | Later: gate the Azure job on CI success (for example, `workflow_run` on the CI workflow). Not changed here. |
| 9 | Comments and docs | `database.py:3` ("PostgreSQL for production (Render)"), `main.py` `/ready` docstring, `render.yaml` `JSON_LOGS` comment, `.env.example:21,133,168`, `mpesa.py:3-10` docstring, `README.md:269`, `CALLING.md` ("single-instance Render deployment"), `web/src/lib/server-config.ts:4` | None | Cosmetic. Update when the switch is final. |

## E. Code changes actually required for Azure

**None are required.** Everything Azure needs is configuration. These are
optional, platform-neutral improvements, **not implemented** and proposed for
review:

1. **Accept `sslmode=` in `DATABASE_URL`** (`api/database.py`, `_build_db_url`):
   rewrite `sslmode=<mode>` to asyncpg's `ssl=<mode>`, so a libpq-style
   connection string can't crash startup. Small, with a regression test.
   The workaround until then is to write `?ssl=require`.
2. **Derive the M-Pesa fallback URLs from `PUBLIC_API_BASE_URL`**, keeping
   `https://broka-dbjd.onrender.com` as the last fallback, so Render's
   behaviour is unchanged. Touches `config.py`, `routers/mpesa.py`, `verify.py`,
   `featured.py`, and both `disputes` modules.
3. **Take OpenRouter's `HTTP-Referer` from one setting** instead of four
   hard-coded Render URLs.
4. **Warn at startup when `CLIENT_IP_HEADER=cf-connecting-ip` is set but
   `RENDER` isn't.** That is the exact mistake that would make per-IP limits
   forgeable on Azure.

---

## 4. Client addresses on Azure

Per-IP limits on login, signup, OTP and store visits, and the IPs in audit
rows, come from `api/core/client_ip.py`. It resolves in this order: the
storefront's key, then `CLIENT_IP_HEADER`, then the `TRUSTED_PROXY_HOPS`-th
entry from the right of `X-Forwarded-For`, then the TCP peer.

- **With no setting on Azure**, the peer is Azure's ingress proxy, shared by
  every user. Every per-IP limit becomes one bucket for the whole platform
  (for example, three signups per five minutes for everyone). Startup warns
  about this in production.
- **With `CLIENT_IP_HEADER=CF-Connecting-IP`** (copied from Render), the
  header is taken from the caller as-is, because nothing in front of Azure
  sets it. A client can then pick its own address and skip every limit.
- **Use `TRUSTED_PROXY_HOPS=1`**, since Azure's ingress appends the caller to
  `X-Forwarded-For`. Then confirm it: call `GET /admin/diagnostics/client-ip`
  as an admin from a known address. It should report your address with
  source `forwarded-for`.
- If Azure is later put behind Cloudflare (for example `api.broka.co.ke`,
  proxied), switch to `CLIENT_IP_HEADER=CF-Connecting-IP` **only once direct
  access to the `*.azurecontainerapps.io` host is blocked**. Otherwise the
  header can still be forged there.

---

## F. Blockers before switching the mobile app to Azure

1. **Show that Azure is really configured.** `GET /` returns 200 even with
   no configuration. Check two things instead:
   - The startup log line
     `[startup] ✓ Config validated  env=production  db=postgres  redis=yes  sentry=yes`
     (`az containerapp logs show -n broka-api -g broka-production`).
   - `GET /ready`, which should show `"db": "ok"` and `"redis": "ok"`.

   This couldn't be checked from here: the audit environment's network
   policy blocks the Azure host.
2. **One database and one Redis for both platforms.** Old APKs keep
   calling Render indefinitely: the URL is compiled in, releases are
   side-loaded APKs, and nothing forces an update. The cutover is an
   **overlap of unknown length**, not a switch. If Azure uses its own
   database, users split into two diverging marketplaces, and callbacks for
   payments started on Azure land on Render (D.1). `DATABASE_URL` on Azure
   must be Render's **external** connection string, or both platforms must
   point at a new shared database.
3. **Database distance.** The container runs in South Africa North;
   `render.yaml` puts the database in Oregon. Every query crosses continents,
   and startup runs about 94 schema statements plus `create_all` against it.
   Measure request latency on Azure before switching. Long term, the database
   belongs next to the compute, with Render pointed at it too so the rollback
   still works. That is a data move and a decision for you, not part of this
   audit.
4. **Identical secrets and switches.** `SECRET_KEY`, `ZAC_SECRET`,
   `MPESA_CALLBACK_SECRET`, `STOREFRONT_API_KEY`, `LISTING_FEES_ENABLED`,
   `PREMIUM_ENABLED`, the token lifetimes, and `MPESA_ENV` with its
   credentials. A different `SECRET_KEY` logs out everyone who moves and makes
   stored E-Confirm confirmation codes undecryptable.
5. **Parts that assume one process** (verified in the code). Two platforms at
   once, or more than one Azure replica, break these:
   - **Live connections are process-local.** Deal and auction WebSocket hubs
     (`core/deal_hub.py`, `core/auction_hub.py`) and the call signalling
     relay (`_rooms` in `routers/calls.py`, see `CALLING.md` "Multi-instance
     limitation") only reach clients on the same process. A caller on Render
     and a callee on Azure can't connect a call, and live deal and auction
     updates only reach users on the same backend.
   - **Every process runs the 60 s and 300 s sweeps.** Deal timers and
     E-Confirm reconciliation go through `lock_deal_if_status`, and media and
     watch clean-up use compare-and-swap, so those are safe. But the
     **availability-nudge SMS** (`task_check_interest_nudges`,
     `core/workers.py:987`) claims nothing, so two processes can send the same
     seller the same billable SMS. The other sweep tasks weren't checked for
     concurrent runs.
   - **Decide one of these:** accept the degradation for the overlap; keep
     the overlap short with an update prompt in the app; or add a Redis
     pub/sub relay and a claim on the nudge (code work, not part of this
     audit). In every case, pin Azure to exactly 1 replica with a minimum of 1.
6. **Client addresses:** `TRUSTED_PROXY_HOPS=1`, verified, and **not**
   `CF-Connecting-IP` (section 4).
7. **Callback URLs.** Set `PUBLIC_API_BASE_URL`, `MPESA_CALLBACK_URL`,
   `MPESA_VERIFY_CALLBACK_URL`, `MPESA_FEATURED_CALLBACK_URL`,
   `MPESA_B2C_RESULT_URL` and `MPESA_B2C_TIMEOUT_URL` explicitly on Azure, and
   decide whether they name Azure or Render during the overlap. With a shared
   database either works; Azure is required before Render is retired. STK
   callback URLs travel with each request, so the Daraja portal needs no
   change for STK. Check the portal for any registered C2B URLs.
8. **Provider IP allow-lists.** Nothing in the repository says any provider
   (Safaricom B2C, E-Confirm, Mobitech, Africa's Talking) allow-lists Render's
   outbound address, but check with each. Azure's outbound addresses differ
   from Render's, and they aren't fixed unless the Container Apps environment
   has static egress (a NAT gateway on its VNet).
9. **Put the app on a domain you control before cutting the build.** The
   URL compiled into the APK stays in the wild for good. Pointing it at
   `api.broka.co.ke` (a custom domain on the Container App) rather than
   `*.azurecontainerapps.io` or `*.onrender.com` means the next hosting move
   needs DNS, not an app release.
10. **`API_URL` and `API_WS_URL` change together**, through the four Dart
    defaults or `--dart-define` in CI. Changing only one sends WebSockets and
    HTTP to different backends.
11. **Probes and scale.** Set the startup, liveness and readiness probes and
    the replica pins from section 1.
12. *(Not blocking)* Gate the Azure deploy on CI success (D.8).

---

## Noticed along the way (not Azure-specific, not changed)

- **The `APNS_*` variables have no effect.** They are documented in
  `CALLING.md`, but `config.py:202-206` hard-codes them, so iOS VoIP push
  can't be switched on by configuration.
- **The ARQ path doesn't do what it says.**
  - `_arq_enqueue` (`core/workers.py:305`) parses only `redis://` URLs, and no
    ARQ worker is deployed anywhere.
  - With a `redis://` `REDIS_URL`, trust-score jobs go to a queue nothing
    reads.
  - With `rediss://`, the parser falls back to localhost, retries the
    connection, then runs the job in-process.
  - `WorkerSettings` has no `redis_settings` either.
- **`task_recompute_trust_score` builds an engine from the raw
  `DATABASE_URL`.** A plain `postgresql://` value selects psycopg2, which
  isn't installed.
- **`DEEPSEEK_MODEL`'s code default (`deepseek-flash`) differs from
  `render.yaml`** (`deepseek-v4-flash`).
- **The `routers/mpesa.py` docstring quotes a passkey.** It is Safaricom's
  publicly documented sandbox passkey, not a BROKA secret, but it reads like
  one.
