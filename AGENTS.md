# Working on BROKA

Guidance for anyone changing this repository - people and coding agents alike.
For **where things are**, read [`graphify.md`](graphify.md) first: a map
generated from the source (every API endpoint with its auth and handler,
every table, module summaries, app and web routes). CI keeps it current.

BROKA is a marketplace where buyers and sellers deal through Zeno, an AI
broker; money moves through escrow. Three deployables:

| Part | Stack | Deploys to |
|---|---|---|
| `backend/` | FastAPI, async SQLAlchemy, Python 3.11; a Rust extension in `backend/native/` (PyO3) | Render: PostgreSQL + Redis |
| `flutter_app/` | Flutter 3.24.5 (pinned in CI) | APK from GitHub releases |
| `web/` | Next.js 16, TypeScript: the store pages at `broka.co.ke/store/<name>` | Vercel |

`README.md` describes the product; `ARCHITECTURE.md` and the topic documents
(`ESCROW_AUDIT.md`, `AUCTIONS.md`, `CALLING.md`, `STORES_PLAN.md`...) explain
the designs; `REPO_REVIEW.md` is the latest review and what is still open.

## Checks to run

Run the checks for every part you touched. CI runs all of them, and a
push to `main` releases the APK.

**Backend** (from `backend/`):

```
pip install -r requirements.txt
ENV=test SECRET_KEY=<32+ characters> DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  python -m pytest tests/ -q -o addopts=""
```

With `REDIS_URL=redis://localhost:6379/0` the Redis-only tests run too.
Without the Rust extension installed the suite runs on its Python fallback
and the Rust-vs-Python parity tests skip; CI runs it both ways.
**Anything touching the schema, datetimes or transactions must also pass on
PostgreSQL**, which production runs and SQLite does not imitate (foreign
keys, timezone-aware values):

```
POSTGRES_TEST_URL=postgresql+asyncpg://user:pass@localhost:5432/db \
  python -m pytest tests/ -q -o addopts="" -p tests.postgres_plugin
```

**Rust extension** (from `backend/native/`, when you touched it or its
`rules/`): `cargo fmt --check`,
`cargo clippy --locked --all-targets --features python -- -D warnings`,
`cargo test --locked`; then, from `backend/`, `pip install ./native` and run
the backend suite with `BROKA_NATIVE=required`.

**Web** (from `web/`): `npm ci`, then `npm run typecheck`, `npm run lint`,
`npm test`, `npm run build`.

**App** (from `flutter_app/`): `flutter pub get`,
`flutter analyze --no-fatal-warnings --no-fatal-infos` (errors fail CI), `flutter test`.

**Repository map**: `python scripts/graphify.py` rewrites `graphify.md`.
You don't have to: CI regenerates and commits it on every push to `main`.

## How changes are made here

- **Every bug fix comes with a test that fails on the old code.** Check that
  it does (stash the fix, run the test, restore) before calling it a fix.
- **Comments say why**, and name the failure a guard prevents: "keyed on
  the caller's IP, not the body - a value the caller picks is no limit at
  all". Match the density and tone of the file you're in.
- **Keep changes in scope.** Fix what was asked; report what else you
  noticed instead of widening the change.

## Rules the code depends on

**Database**
- New tables: define the model; `init_db()`'s `create_all` creates them.
- New columns or indexes on an existing table: add the statement to
  `init_db()`'s `migrations` list in `backend/api/database.py`. It runs on
  every start, each statement in its own savepoint, so it must be safe to
  repeat and valid on both SQLite and PostgreSQL (`BOOLEAN ... DEFAULT FALSE`,
  not `0`). **Alembic does not run on deploy.**
- DateTime columns hold **naive UTC**. Convert with
  `api.core.timeutil.to_naive_utc`; never write a timezone-aware value
  (PostgreSQL refuses it - that took down signup and login).
- A column that can hold something other than a row id (`"system"` as an
  audit actor, a claimed id before its row exists) is not a foreign key.
- Reading a row again after another transaction may have changed it: use
  `.execution_options(populate_existing=True)`, since sessions use
  `expire_on_commit=False`. After a rollback, don't touch ORM objects loaded
  before it (they expire; async code can't lazy-load) - select plain columns.

**Money** (`backend/api/domains/escrow/`, `backend/api/routers/mpesa.py`,
`backend/api/core/workers.py`, `backend/api/domains/payments/`)
- Deal money (buyer to seller) is E-Confirm's; money users pay BROKA (fees,
  plans, boosts, badges) is ZetuPay's when `ZETUPAY_ENABLED`, else Daraja's.
  Never route one through the other (`ZETUPAY.md`).
- Change a deal's status only under its row lock (`lock_deal_if_status`),
  re-checking the state after taking it.
- E-Confirm deals: E-Confirm holds the money, not BROKA. Never settle them
  as if BROKA did; when automation can't act, raise a reconciliation alert
  (`api/core/reconciliation.py`) and write an audit row.
- Read `ESCROW_AUDIT.md` before changing any of it.

**Requests**
- The caller's address is `api.core.client_ip.client_ip(request)`, never
  `request.client.host` (behind Render's proxy that is the proxy, shared by
  every user).
- Rate limits are keyed on the signed-in user or that address - never on
  anything the request body says.
- Money endpoints take `X-Idempotency-Key` through
  `api.core.idempotency.idempotency_guard`, which scopes keys to user, method
  and path.
- Request bodies are capped (`MAX_REQUEST_BODY_MB`, default 32).

**Images**
- Uploads go through `POST /media/images` and `api/domains/media/service.py`
  (decoded and re-encoded, metadata stripped). Listings and stores reference
  them by asset id.
- Legacy base64 fields from old app builds are checked with
  `check_legacy_images`: inline images or the user's own BROKA image URLs,
  never links elsewhere.

**Rust extension** (`backend/native/`, read its README first)
- Every function in it has a Python reference implementation with identical
  output, used when the extension isn't loaded; `tests/test_native_parity.py`
  holds the two together. Change one, change the other.
- Only `api/core/native.py` imports `broka_native`. Bump `API_VERSION` there
  and in `native/src/python.rs` together when a signature changes.
- Contact-leak rules live in `native/rules/contact_leaks.json`, read by both
  engines. A finding lowers the seller's rank (it marks the deal as leaked),
  so a rule must be precise; add its near misses to `tests/test_text_guard.py`.

**Settings**: add them to `backend/api/core/config.py`, `.env.example` and
`render.yaml` (or `web/.env.example`). Secrets used by the web storefront's
server go in `web/src/lib/server-config.ts`, never behind `NEXT_PUBLIC_`.

**App**
- New API calls go through `ApiClient` (`flutter_app/lib/core/network/api_client.dart`),
  which renews an expired session and retries once.
- The only credentials kept on the phone are the access and refresh tokens.
  Never store a password; app data is excluded from Android backups.

## Where to look first

| To change... | Start at |
|---|---|
| An endpoint | its row in `graphify.md` (file and line), then the domain's `service.py` |
| Signup, login, sessions | `backend/api/domains/auth/`, `flutter_app/lib/services/api_service.dart` |
| Deals, escrow, payments | `backend/api/domains/escrow/`, `backend/api/routers/mpesa.py`, `ESCROW_AUDIT.md` |
| Disputes | `backend/api/domains/disputes/`, `DISPUTE_AUDIT.md` |
| Fees, commission, premium and store plans | `backend/api/domains/pricing/`, `PRICING.md` |
| Collecting BROKA's own charges (ZetuPay: fees, plans, boosts, badges) | `backend/api/domains/payments/`, `backend/api/core/zetupay.py`, `ZETUPAY.md` |
| Auctions | `backend/api/domains/auctions/`, `AUCTIONS.md` |
| Stores and the web storefront | `backend/api/domains/stores/`, `web/`, `STORES_PLAN.md` |
| Browsing by category, type of item and brand (Home's category cards, Zones, type screens, card artwork) | `flutter_app/lib/features/categories/` (`category_visual.dart`, `subcategory_visual.dart`, `presentation/subcategory_screen.dart`), `backend/api/domains/categories/seed.py` (`BRAND_SUGGESTIONS`) |
| Images | `backend/api/domains/media/`, `backend/api/core/image_processing.py` |
| Zeno (the AI broker) | `backend/api/routers/negotiate.py`, `backend/api/domains/ai_broker/`, `ZENO_ACTIONS.md` |
| Zeno as the assistant (the Zeno tab, voice mode, the pill across screens, the orb on every screen, check-ins, the new-user introduction and tour, guides) | `backend/api/domains/zeno_assistant/`, `flutter_app/lib/features/zeno_assistant/` (`zeno_session.dart`, `zeno_intro.dart`, `zeno_tour.dart`, `presentation/zeno_live_overlay.dart`, `presentation/zeno_launcher.dart`), `ZENO_ACTIONS.md` |
| The Buying Agent's screen (its motion, radar and results) | `flutter_app/lib/screens/zeno_screen.dart` (buying mode), `flutter_app/lib/features/buy_agent/presentation/widgets/` (`agent_motion.dart`, `agent_hud.dart`) |
| Calls | `backend/api/routers/calls.py`, `CALLING.md` |
| Push notifications (calls, messages, alerts to a closed app) | `backend/api/core/push_devices.py`, `message_push.py`, `flutter_app/lib/services/notification_service.dart`, `NOTIFICATIONS.md` |
| Scheduled work | `backend/api/core/workers.py` (the 5-minute sweep) |
| The Rust extension, chat contact-leak scanning, distances | `backend/native/README.md`, `backend/api/core/native.py`, `text_guard.py`, `geo.py` |
