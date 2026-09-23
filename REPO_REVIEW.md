# BROKA — Repository Review

**Date:** 2026-09-23
**Commit reviewed:** `939eafd` ("Zeno voice: bound every startup stage…")
**Previous review:** 2026-09-17 at `1d80ddd` (in git history of this file)
**Branch:** `claude/respiratory-review-clsvba`

This review does two things: it rechecks every finding from the 2026-09-17
review, and it reviews the 18 commits since then (~27k lines: auction
lifecycle, email OTP and seller signup, buying-agent conversation, calling
fixes, Home/Categories redesign, Zeno voice). Every finding marked
**Reproduced** was confirmed by running code against the real service layer,
not by reading comments.

---

## 1. Baseline

| Check | Result |
|---|---|
| Backend test suite | **731 passed**, 0 failed (~2 min) |
| Measured backend coverage | 50% (was 45%) |
| Flutter `analyze` | 0 errors, 24 warnings (see §6) |
| Flutter `test` | **162 passed**, 0 failed |
| Backend Python | ~52,900 lines (was 43,200) |
| Flutter Dart (`lib/`) | ~52,000 lines (was 43,800) |
| Flutter test files | 8 (was 0) |

Run the backend suite with:

```
cd backend && ENV=test SECRET_KEY=<32+ chars> \
  DATABASE_URL="sqlite+aiosqlite:///:memory:" \
  python -m pytest tests/ -q -o addopts="" --cov=api
```

(`-o addopts=""` is needed because of §2 #6. Use `python -m pytest` so the
interpreter with the project's dependencies runs it.)

---

## 2. Status of the 2026-09-17 findings

| # | Finding | Status |
|---|---|---|
| 2 | Production container crash-loops on `alembic upgrade head` | **Fixed** in `8d790b9`. Both Dockerfiles run uvicorn only, the duplicate `Docker` file is gone, and `test_deployment_config.py` guards it. |
| 3 | Call tokens authenticate every HTTP route | **Open.** Reproduced again: `get_current_user(create_call_token(...))` → `{'id': 'user-123'}`. `security.py` gained an email-verify token this week but `decode_token_strict()` still rejects only `type == "refresh"`. |
| 4 | Unauthenticated `/disputes/v2/stats/summary` runs an unbounded query per request when Redis is absent | **Open.** File unchanged. |
| 5 | Idempotency guard is check-then-act (no `SET NX`) | **Open.** File unchanged. |
| 6 | `pytest.ini` requires 60% coverage; CI enforces 35%; measured is 50% | **Open.** The documented local command still exits 1 with every test green. |
| 7 | `TOKEN_EXPIRE_MINUTES` in `render.yaml` is read by nothing | **Open.** |
| 8 | Redis rate limiter records rejected requests (`zadd` before the count check) | **Open.** File unchanged. |
| 9 | No `analysis_options.yaml`; no Flutter tests | **Partly fixed.** 8 widget/unit test files now exist. `analysis_options.yaml` is still missing, so `flutter_lints` is still inert. |

The deploy fix is the one that mattered most, and it was done properly, with
a regression test. Everything else from the last review is still open.

---

## 3. High — an auction payment lapse can cancel a deal the buyer is paying for

**Reproduced.** `lifecycle.lapse_unpaid_win()` cancels the winner's deal
whenever `deal.status` is still `agreed` at the deadline. But `agreed` is
also the deal's status while an M-Pesa STK push is outstanding. Funding moves
the escrow row (`ExternalEscrow.funding_initiated_at` set, status `PENDING`
or `UNKNOWN`), and the deal only becomes `paid` once E-Confirm reports
`FUNDED`. The lapse never looks at the escrow.

Sequence, run against the real service layer:

1. Auction closes, winner gets a deal (`agreed`), 24-hour deadline set.
2. Winner taps Pay at hour 23:59. STK push sent, PIN not yet entered.
3. The sweep runs at 24:00. `lapse_unpaid_win` → `unpaid`. Deal
   `cancelled`, listing back to `active`.
4. Winner enters their PIN. `reconcile_econfirm_escrow` sees `FUNDED`, tries
   `lock_deal_if_status(..., (agreed,))`, gets `None`, and takes the
   `else: commit()  # someone else already moved it — not an error` branch.

Final state:

```
deal.status: cancelled | escrow.status: funded | listing.status: active
```

The buyer's money is held by E-Confirm against a cancelled deal. No event,
audit row or reconciliation alert is raised. The item is back on sale and
can be sold to someone else. The same happens for an escrow in `UNKNOWN`,
the state that exists specifically because the payment may have succeeded.

**Fix.** In `lapse_unpaid_win`, load the deal's `ExternalEscrow`. If
`funding_initiated_at` is set and the status is not a confirmed failure,
don't lapse: reconcile first, or extend the deadline and let a later pass
decide. Separately, in `reconcile_econfirm_escrow`, a `FUNDED` result for a
deal that is not `agreed` should publish `EConfirmReconciliationRequired`
rather than being treated as benign. That branch was written for a
concurrent poller, not a cancelled deal.

---

## 4. High — admin is granted on an unverified email

**Reproduced.** `AuthService.register` sets:

```python
is_admin = bool(settings.admin_bootstrap_email) and email == settings.admin_bootstrap_email
```

`email` here can be a raw, typed, unverified address. Registering with the
bootstrap address and no `email_verify_token` produced:

```
is_admin: True  email_verified: False
```

Anyone who knows or guesses `ADMIN_BOOTSTRAP_EMAIL`, typically the founder's
public address, and registers before its owner does gets full admin,
including `POST /admin/users/{id}/promote-admin`. The window is from the
moment the variable is set until the real admin registers.

This predates this week's work, but the email-OTP flow added this week is
what makes it cheap to fix.

**Fix.** `is_admin = email_verified and email == settings.admin_bootstrap_email`.
The real admin then verifies their address during signup, which needs
`RESEND_API_KEY` set (see §5.3).

---

## 5. Medium / Low — new since the last review

### 5.1 Medium — speech-to-text endpoints have no rate limit

`POST /stt/deepgram-token`, `/stt/assemblyai-token` and `/stt/transcribe`
spend real money per call. The first two mint streaming credentials billed to
BROKA's accounts, and the third makes a paid Whisper call on up to 25 MB of
audio. None of them calls a limiter. Every comparable endpoint does:
`/calls/turn-credential` is limited explicitly because each call costs a
Cloudflare request, and the buy-agent LLM endpoints gained `ai_chat_limiter`
this week for the same reason.

The Deepgram token also keeps working after its 300 s TTL once the socket is
open (per the code's own comment), so one mint can stream for as long as the
client keeps the connection. Combined with §2 #3, a leaked call token is
enough to mint these.

**Fix.** Add a per-user `stt_token_limiter` (e.g. 10/min) to the two token
endpoints and put `ai_chat_limiter` or similar on `/transcribe`.

### 5.2 Medium — `PATCH /auctions/{id}/terms` returns 500 for any timezone-suffixed time

**Reproduced.** The body's `starts_at` / `ends_at` are pydantic `datetime`s,
so `"2026-09-24T10:00:00Z"` parses as timezone-aware. The stored columns and
`datetime.utcnow()` are naive. Both requests below fail with
`TypeError: can't compare offset-naive and offset-aware datetimes`:

```
PATCH terms {"ends_at": "...Z"}                  → 500
PATCH terms {"starts_at": "...Z", "ends_at": "...Z"} → 500
```

The Flutter app sends exactly this format (`toUtc().toIso8601String()`) to
`POST /listings`, whose parser strips the zone. No screen calls the terms
endpoint yet, so users can't hit this today, but the first one that does
will.

Related: `listings/service.py`'s `_coerce_dt` / `_strict_dt` use
`.replace(tzinfo=None)` without converting to UTC first. A `+03:00` time is
silently stored three hours off. The app always sends UTC, so this is latent.

**Fix.** One helper, `aware.astimezone(timezone.utc).replace(tzinfo=None)`,
used by both the terms endpoint and the listings parsers.

### 5.3 Low — production without Resend logs email OTP codes

With `RESEND_API_KEY` unset, `get_email_provider()` returns `ConsoleEmail`
in production too. It writes the full email body, code included, to the log
at WARNING and returns `True`. The API then tells the user the code was sent.
Startup warns about it, but the code still reaches log storage and Sentry
breadcrumbs, and the user never gets it.

Once §4 is fixed, this matters more: whoever can read logs can verify any
address.

**Fix.** In production, return 503 from `/auth/email/otp/request` when no
provider is configured, as the phone path does when an SMS send fails.

### 5.4 Low — buy-agent `history` entries are unbounded

`ConverseTurnIn.history` caps the list at 40 entries but not the size of each
entry. The last 12 are pasted into the LLM prompt verbatim
(`ai_broker/service.py`, `history[-12:]`). `message` is capped at 1000
characters for exactly this reason (its comment says so), and the cap doesn't
extend to the transcript sent alongside it. At 20 calls/min per user this is
cost exposure, not an outage.

**Fix.** Validate `history` as `list[HistoryTurn]` with `content:
str = Field(max_length=1000)`, or truncate each entry where the prompt is
built.

---

## 6. Flutter

Flutter was not available for the previous review. This time Flutter 3.24.5
(the version CI pins) was installed and run:

| Check | Result |
|---|---|
| `flutter analyze` (CI flags) | **0 errors**. 24 warnings, 21 infos |
| `flutter test` | **162 passed**, 0 failed, across 8 files |

The warnings are housekeeping: 10 `unused_field`, 6 `unused_import`, 3
`unused_local_variable`, 5 redundant null checks. None is a type error. The
test suite is new since the last review and covers the right things: signup
wizard, OTP autofill, Home scroll, category zones, and the Deepgram →
AssemblyAI failover state machine.

Structural notes from reading the new code:

- The Zeno voice stack is well separated. `ZenoVoiceController` knows
  nothing about vendors, `RealtimeSttManager` owns failover, and both vendor
  services take injectable connectors, which is what makes
  `zeno_voice_test.dart` and `stt_fallback_test.dart` possible. Permanent STT
  keys stay on the server, and the client only ever holds short-lived tokens.
- After an error, `ZenoVoiceController.open()` returns early because `_open`
  is still true. The only way back is closing the card with X and reopening
  it. If that's intended, the error card should say so. If not, reset `_open`
  in `_failWith`.

---

## 7. What was done well this week

- **Auction lifecycle.** Compare-and-swap bids and closes that hold on
  SQLite as well as Postgres, a reserve that is evaluated only at close and
  never exposed publicly (the old public serializer leaked it; that is fixed
  and documented), idempotent close with a crash-recoverable deal-retry
  claim, and an at-least-once ending-soon reminder with a bounded retry
  budget. 2,300 lines of tests back it.
- **OTP SMS Retriever hash** is validated against its exact format before
  being put into an SMS, which closes an easy phishing relay.
- **Money quantization** (`core/money.py`) is a sound interim answer to Float
  columns, and its docstring is honest about what a real Numeric migration
  still needs.
- **Calling.** The room-ownership check (`_owns_room`) fixes a real
  reconnect race, and call pushes now carry a TTL so a stale ring doesn't
  arrive minutes later.

---

## 8. Suggested order of work

1. §3: don't lapse an auction deal with a funding attempt in flight, and
   alert on `FUNDED` against a non-`agreed` deal. Real money.
2. §4: require `email_verified` for the admin bootstrap. One line.
3. §2 #3: require `type == "access"` in `decode_token_strict()`. One line,
   still open from last week.
4. §5.1: rate-limit the STT endpoints.
5. §5.2: normalize timezone-aware datetimes to naive UTC in one helper.
6. Still open from last week: the Redis-independent dispute-summary gate,
   `SET NX` idempotency, `pytest.ini` coverage floor (set it to 50),
   `TOKEN_EXPIRE_MINUTES`, rate limiter `zadd` order, `analysis_options.yaml`.
7. §5.3, §5.4.

---

## Overall

The codebase kept its character this week. New code is carefully reasoned,
its comments name the failure each guard prevents, and the auction work in
particular is stronger than most production auction code. The pattern from
last week holds, in a narrower form: the most serious problems sit at the
seams between two carefully built systems. The auction sweep reasons only
about auction state and the escrow reconciler only about escrow state, and
the money falls between them. The admin bootstrap was written before email
could be verified and was never revisited once it could.
