# BROKA — Repository Review

**Date:** 2026-09-17
**Commit reviewed:** `1d80ddd` ("BROKA update")
**Branch:** `claude/respiratory-review-hwj7tj`

Everything below was verified by running it, not by reading comments. Where a
finding could not be verified in this sandbox, that is stated explicitly.

---

## 1. Baseline: what actually works

| Check | Result |
|---|---|
| Backend test suite (522 tests) | All pass, ~60s |
| Measured backend coverage | 45% |
| Committed secrets | None found |
| Bare `except:` clauses | 0 |
| Backend Python | 43,196 lines |
| Flutter Dart | 43,785 lines |

The test suite is genuinely green. Run with:

```
cd backend && ENV=test SECRET_KEY=<32+ chars> \
  DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  pytest tests/ -q --no-cov
```

The codebase is unusually well commented. Most non-obvious decisions carry a
comment explaining the failure mode they exist to prevent, and several of those
comments correctly document prior incidents. That is a real asset and it made
this review much faster.

---

## 2. Critical — production container cannot start

All three Dockerfiles (`Dockerfile`, `Docker`, `backend/Dockerfile`) use this
entrypoint:

```
CMD ["sh", "-c", "alembic upgrade head && uvicorn main:app --host 0.0.0.0 --port 8000"]
```

`render.yaml` deploys `./backend/Dockerfile`, so this is the live production
path. The Alembic step fails two independent ways, and because the shell uses
`&&`, uvicorn is never reached. The container exits non-zero and crash-loops.

**Failure one — no synchronous Postgres driver.** `migrations/env.py` rewrites
the async URL to a sync one and builds a normal engine, which resolves to
psycopg2. That package is not in `requirements.txt` and is not installed in the
image. Reproduced with the production URL shape:

```
DATABASE_URL="postgresql://u:p@db.example.com:5432/broka" alembic upgrade head
→ ModuleNotFoundError: No module named 'psycopg2'
→ exit 1
```

**Failure two — the migration chain is internally inconsistent.** Independent of
the driver, the chain cannot run from scratch on any database. Revision `0001`
creates `mpesa_transactions.callback_processed`, and revision `0002` adds the
same column again. Reproduced on SQLite:

```
INFO  Running upgrade      -> 0001, Initial schema — all v3.0 tables
INFO  Running upgrade 0001 -> 0002, Add callback_processed idempotency ...
sqlalchemy.exc.OperationalError: duplicate column name: callback_processed
```

**Why this has not been noticed.** The README states plainly that Alembic is not
used and that nothing in the repository calls `alembic upgrade`. Schema changes
really do go through `create_all()` plus hand-written `ALTER TABLE` lists in
`api/database.py`'s `init_db()`. The README is right about the mechanism and
wrong about the call site: the Dockerfiles call it. The Alembic scaffolding is
unexercised, untested, and wired into the one place it must not fail.

**Fix.** Drop `alembic upgrade head &&` from all three Dockerfiles, matching the
documented reality. If Alembic is meant to become the real mechanism later, that
is a separate piece of work: it needs psycopg2 added, the `0001`/`0002` conflict
resolved, and a CI job that actually runs the chain against an empty database.

I did not verify the live deployment. It is possible production is served some
other way, in which case this is latent rather than active. As committed, the
deploy configuration is broken.

---

## 3. High — call tokens work as full account tokens

`api/security.py` issues a deliberately narrow, room-scoped token for WebRTC
signalling. Its own comment states the intent:

> scoping it to one room_id means a leaked call token only exposes that one
> call, not the holder's whole account

That is not what happens. `decode_token_strict()` rejects only `type ==
"refresh"`. Nothing anywhere requires `type == "access"` — a repo-wide search
for such a check returns nothing. A call token carries `sub`, so it satisfies
`get_current_user()` and authenticates every HTTP route in the app.

Verified directly:

```
call token payload: {'sub': 'user-123', 'room_id': 'room-abc', 'type': 'call', ...}
get_current_user(call_token) -> {'id': 'user-123'}
```

The phone-verify token is safe by accident, not design: it has no `sub`, so it
fails a later check with "Bad token payload" rather than a type check.

Impact is bounded by the 5-minute expiry, but the token is designed to travel
through a WebSocket URL, which is exactly the place that ends up in proxy and
server access logs. The whole reason for scoping it is defeated.

**Fix.** Have `decode_token_strict()` accept only `type == "access"`, and give
the call and phone-verify paths their own decoders, which they already have in
`decode_call_token()` and `decode_phone_verify_token()`.

---

## 4. High — unauthenticated endpoint runs an unbounded query per request

`GET /disputes/v2/stats/summary` has no auth dependency. That is deliberate and
documented: the payload is aggregate-only and is shown to buyers before they
commit to escrow. The data exposure is fine. The cost model is not.

The handler reads a Redis cache and, on a miss, computes the aggregate inline.
`api/core/stats_cache.py` returns `None` whenever Redis is not configured, so
every request misses. The aggregation loads all closed dispute cases from a
rolling 90-day window into Python as fully hydrated ORM objects, with no limit.
The four-hour self-gating in `task_refresh_dispute_summary_cache` reads its own
timestamp out of that same cache, so with Redis absent the gate never engages
either.

Result: with Redis unset or briefly down, an unauthenticated and unrate-limited
endpoint performs an unbounded table scan on every request. README lists Redis
as "strongly recommended", not required, so this configuration is one the
project explicitly supports.

**Fix.** Add a process-local memo with its own timestamp so the gate holds
without Redis, bound the query, and return the null-valued fallback rather than
computing inline on a cold cache. The frontend already handles null fields.

---

## 5. Medium — idempotency is narrower than advertised

The README says:

> Double-tap the Pay button? No problem.

`idempotency_guard` in `api/core/idempotency.py` is check-then-act with no
reservation. It issues a `GET`; on a miss it returns and lets the handler run,
and the response is stored only after the handler returns. There is no atomic
`SET NX` at check time.

Two concurrent requests carrying the same key both see a miss and both execute.
A double-tap produces exactly that: two near-simultaneous requests. The guard
protects sequential retries after one has already completed, which is the case
it does handle well, but not the one the README advertises.

The money path is not actually exposed here, because `EscrowService.
fund_deal_escrow` has a separate and well-designed defence: `funding_initiated_at`
ensures `provider.fund_escrow()` is called at most once per escrow, and the
docstring reasons carefully about ambiguous failures versus confirmed
rejections. That guard is what is really preventing a double STK push. It is
itself a read-then-write without a row lock on the escrow row, so a true
simultaneous double-tap is not fully closed either, though the window is small.

Worth noting the guard also fails open on Redis errors and no-ops entirely when
Redis is unconfigured.

**Fix.** Use `SET key <placeholder> NX EX <ttl>` at check time and treat a failed
set as in-flight, returning 409. Separately, consider taking the escrow row lock
in the funding path, as the release paths already do via `lock_deal_if_status`.

---

## 6. Medium — the documented local test command always fails

`backend/pytest.ini` sets `--cov-fail-under=60` in `addopts`. Measured coverage
is 45%. The README tells contributors to run:

```
pytest tests/ -v --cov=api --cov-report=term-missing
```

That picks up `addopts` and exits 1 with `FAIL Required test coverage of 60% not
reached` even though every test passed. On a single file it is worse — 32%.

CI passes only because `.github/workflows/build.yml` overrides with
`--cov-fail-under=35` on the command line. So the gate a contributor hits
locally is stricter than the one that actually guards the branch, and the local
one is unreachable.

Three different numbers are in play: 60 in `pytest.ini`, 35 in CI, 35 in the
README prose.

**Fix.** Set `pytest.ini` to the number CI enforces, or better, to the measured
45% so the floor is honest and ratchets upward.

Note that roughly 832 statements of the uncovered total are the deliberately
quarantined dead routers in section 7, which are counted in the `--cov=api`
denominator at 0%. Excluding them, real coverage of live code is about 49%.

---

## 7. Low — dead code, duplicate files, stale counts

**Quarantined routers.** Five modules under `api/routers/` (`admin.py`,
`auth.py`, `disputes.py`, `reviews.py`, `listings.py`) are dead. I confirmed
they are neither imported nor mounted. Each carries a clear header saying so and
naming its replacement, and the decision to quarantine rather than delete is
explicitly recorded. This is handled well. The only cost is the coverage
distortion above, fixable with a `.coveragerc` omit.

**Duplicate Dockerfile.** The file named `Docker` is byte-identical to
`Dockerfile`. Neither is referenced by `render.yaml`, which points at
`backend/Dockerfile`. Delete both root copies or point something at them.

**Dead environment variable.** `render.yaml` sets `TOKEN_EXPIRE_MINUTES`.
Nothing reads it. The code reads `ACCESS_TOKEN_EXPIRE_MINUTES`, which
`.env.example` gets right. The defaults happen to match at 15 minutes, so there
is no behavioural difference today, but changing it in the Render dashboard
would silently do nothing.

**Stale README counts.** The README claims 22 Flutter screens and 25 test files.
Actual: 39 files in `lib/screens/` (50 including feature modules) and 40 test
files. Both undersell.

**Wide-open CORS in the production config.** `render.yaml` sets
`ALLOWED_ORIGINS: "*"` with `ENV: production`. The code handles this correctly —
`allow_credentials` is computed to be false whenever origins are `*`, so there
is no credentialed-wildcard vulnerability, and startup logs a warning. Still
worth setting to the real origin list.

---

## 8. Low — rate limiter implementations disagree

The two limiters in `api/core/rate_limit.py` behave differently under load.

The in-memory path appends to the window only after the limit check passes. The
Redis path runs `zadd` unconditionally inside the pipeline, before evaluating
the count. A request that is rejected with 429 therefore still records itself in
Redis, continuously extending its own window. Under sustained abuse the window
never drains, so a throttled identifier stays locked out well past the nominal
window rather than recovering after it.

The Redis path also fails open on any error, which is a reasonable availability
choice but means brute-force protection on login disappears entirely during a
Redis blip. Worth a deliberate decision rather than an inherited default.

**Fix.** Move the `zadd` behind the count check, or subtract the just-added
entry when rejecting.

---

## 9. Flutter app — not verifiable here, and untested

Flutter is not installed in this environment, so `flutter analyze` could not be
run and the Dart findings below are structural rather than behavioural.

**No tests at all.** 43,785 lines of Dart, zero `*_test.dart` files, no `test/`
directory. The backend is well covered by comparison. The app contains the
entire negotiation, calling, and payment UX.

**Lints are declared but not active.** `flutter_lints: ^4.0.0` is a dev
dependency, but there is no `analysis_options.yaml`. Without a file including
`package:flutter_lints/flutter.yaml`, none of those rules apply. The CI
`Analyze` step runs with `--no-fatal-warnings --no-fatal-infos`, so it is
catching only hard analyzer errors. That is a deliberate and well-reasoned
choice, documented at length in the workflow, but it means the declared lint set
is doing nothing.

**Unverified dependency versions.** `pubspec.yaml` says outright that the
Firebase, `record`, `path_provider` and `http_parser` version constraints are
"a best-effort estimate from training knowledge ... NOT verified against a live
pub.dev". Adding `analysis_options.yaml` and a first widget test would be a
cheap, high-value next step.

**Money as `Float`.** `agreed_price`, `commission` and `amount` are SQLAlchemy
`Float` columns in `api/database.py`. The ledger itself correctly uses
`Numeric(18, 2)`, and `api/core/ledger.py` is careful to derive released amounts
from the ledger rather than from caller-supplied figures, so the book of record
is sound. The operational tables around it are not, and they are what the STK
push amount is computed from.

---

## 10. Suggested order of work

1. Remove `alembic upgrade head &&` from the three Dockerfiles. Deployment is
   broken until this is done.
2. Require `type == "access"` in `decode_token_strict()`.
3. Gate the dispute-summary aggregation without depending on Redis.
4. Reconcile the three coverage numbers.
5. Add `SET NX` reservation to the idempotency guard.
6. Add `analysis_options.yaml` and a first Flutter test.
7. Housekeeping: delete `Docker`, fix `TOKEN_EXPIRE_MINUTES`, omit dead routers
   from coverage, refresh the README counts.

---

## Overall

This is a substantial and carefully built codebase. The escrow state machine,
the double-entry ledger, the row-locking discipline on fund-moving transitions,
and the M-Pesa callback authentication are all stronger than typical for a
project this size, and the commentary explaining why each guard exists is
genuinely excellent.

The weaknesses cluster in one place: the gap between what the configuration and
documentation assert and what the code does. Alembic is documented as unused and
is wired into the production entrypoint. A call token is documented as scoped
and is not. Idempotency is documented as solving double-taps and does not. A
coverage floor is documented as 35 and enforced locally as 60. The code is in
better shape than the things that describe it, which is an unusual and
fortunate problem to have.
