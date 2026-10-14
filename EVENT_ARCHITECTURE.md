# Event architecture — actual state (audited 2026-09-14)

## Two buses. One carries everything.

### Canonical: `api/core/event_catalog.py` — `emit()` / `@subscribe_to`

All **32** real subscribers, across 7 files:

| File | Handlers |
|---|---|
| `core/push_subscribers.py` | 10 |
| `core/deal_hub_subscribers.py` | 8 |
| `core/zeno_subscribers.py` | 8 |
| `core/trader_specialization_subscribers.py` | 2 |
| `core/event_catalog.py` | 2 |
| `core/auction_hub_subscribers.py` | 1 |
| `core/buy_agent_subscribers.py` | 1 |

`emit()` dispatches in-process handlers **unconditionally**, then writes the
envelope to Redis Streams as an *additional* durable copy. Redis on or off,
subscribers fire. This is correct and unchanged.

Handlers are awaited **sequentially** inside `emit()`, and `emit()` is called
from request paths. A slow handler therefore adds latency to the emitting
request. Not changed here — making it concurrent alters ordering and error
isolation, which is a behaviour change, not a fix. Flagged, not touched.

### Legacy: `api/core/events.py` — `publish()` / `@subscribe`

**Zero real subscribers.** `grep -rn "@subscribe("` matches exactly one line:
the example inside this module's own docstring.

Publishers (7 files) still call `publish()`, and it still matters — but only
because `publish()` ends with `_bridge_to_catalog(event)`, which forwards to
the canonical bus. That bridge already ran unconditionally.

## The bug that was fixed

`publish()` was an either/or:

```python
if settings.redis_enabled:  await _publish_redis(event)
else:                       await _publish_inprocess(event)
```

With Redis configured — i.e. in production — **no local handler ran at all**,
and the stream it wrote to instead has no consumer (see below). A handler
registered through this module's own documented API worked in development,
where `REDIS_URL` is unset, and silently did nothing in production.

**This was a loaded trap, not a live fault**, and the distinction matters: with
zero `@subscribe` handlers, nothing was actually broken. The hazard was that
the next person to follow the file's documentation would get a
production-only silent failure with no error anywhere.

Fixed at the mechanism: `publish()` now dispatches in-process first, then
writes Redis as an additional copy — matching what `emit()` already did
correctly. `_publish_redis`'s own in-process fallback was removed, since
retrying it after an unconditional local dispatch would double-fire.

Also fixed: `_publish_inprocess` created handler tasks with
`tasks = [...]; _ = tasks`. asyncio holds only a *weak* reference to a running
task, so that list keeps them alive exactly until the function returns. Now
held in a module-level set with a `done_callback` to drain it.

## Dead infrastructure (reported, not removed)

`events.py` defines `consume()`, a Redis Streams consumer-group reader. It is
**never started** — nothing in `main.py` or `core/workers.py` calls it. So
`broka:events:*` streams are write-only: events accumulate to `maxlen=50_000`
and are never read.

Not started here. Starting an unused consumer would be adding infrastructure,
which section 20 explicitly rules out. Either wire it up deliberately or drop
the writes — a decision, not a cleanup.

## Duplicate processing

No event is handled twice. The two buses are not parallel paths: `publish()`
bridges *into* the catalog rather than dispatching alongside it, and the
catalog's Redis write has no consumer to replay it. Ledger writes are
additionally idempotent at the ledger itself (see `ESCROW_AUDIT.md`).

---

# Addendum — main.py, DB init, CI (audited 2026-09-14)

## Route collisions (§22)

Three prefixes are mounted twice. Only one is a real collision:

| Prefix | Routers | Overlapping (method, path) |
|---|---|---|
| `/auth` | `auth_router`, `refresh_router` | none — coexist safely |
| `/listings` | `listings_router`, `showcase_router` | none — coexist safely |
| `/negotiate` | `negotiate.router`, `ai_broker_router` | **`POST /chat`** |

`POST /negotiate/chat` is served by whichever router is mounted first.
`negotiate.router` wins today, which is correct — only it supports image
attachments and the Zeno persona.

That contract was enforced by nothing but a comment. Reordering the mounts
for any plausible reason (alphabetising; moving the one labelled "legacy"
lower *because* it is labelled legacy) would silently switch every call to
the wrong handler — no error, no failing test, images just stop arriving.

`_check_route_ordering()` in `main.py` reports which endpoint resolves.
**It logs; it does not raise.** `tests/test_route_ordering.py` is where the
property is actually asserted, against a real request through the ASGI app.

**Corrected twice, 2026-09-15.** The guard originally raised at import. Two
successive implementations both concluded the endpoint was unmounted, and
both were wrong in a way that cost the whole suite:

| Attempt | Mechanism | Outcome |
|---|---|---|
| 1 | scan `app.routes` for `path ==` / `"POST" in route.methods` | 13 modules errored at collection, 0 of 325 tests ran |
| 2 | Starlette's own `route.matches(scope)`, descending into mounts | 14 modules errored, 0 of 325 tests ran |

Attempt 2 resolved FastAPI's own `/openapi.json` correctly and still found
nothing at `/negotiate/chat`, so the disagreement is specific to how this
FastAPI version (0.141.1, resolved from the unpinned `fastapi>=0.115.0`)
exposes router-included routes. Whether the endpoint is genuinely unmounted
or merely invisible to introspection is not yet known — the tests now answer
it by issuing the request.

The lesson is about placement, not mechanism. An import-time `raise` runs
before every test module and before boot, so a guard that is wrong takes
down everything, including all the unrelated failures you would otherwise be
reading. Two outages, zero true positives. The property belongs in a test,
where being wrong costs one red test.

Endpoint identity is still compared with `inspect.unwrap`, not by
`__module__` string. Failures now print `_router_inventory()` — route count,
classes, and every discoverable `/negotiate/*` path with its handler — so a
future disagreement explains itself instead of costing a CI round-trip.

## Database initialization (§23)

Strategy, unchanged: `Base.metadata.create_all()` for new tables, plus a
manual `ALTER TABLE` list for new columns on existing DBs. Alembic
infrastructure exists and is **never invoked**. **No migration files were
created.**

Fixed: the defensive model imports for `dispute`, `store` and
`external_escrow` sat ~130 lines *below* `create_all()`. Their own comments
described them as defence-in-depth "in case this function is ever called
from a context that hasn't imported the store domain yet" — which is
precisely the case they could not handle, because importing a model after
`create_all()` registers it too late to create anything. The fallback
existed, was documented, and was placed where it provably could not fire.

Never a live fault: every real entry point imports the domain routers (and
therefore the models) long before `init_db()`. Latent trap only — it would
present as a bare `no such table: stores` from a standalone script.

Also removed the `except Exception: pass` around those imports. While
writing the hoist, a first draft imported a `DisputeMessage` that does not
exist (the class is `DisputeEvent`); the `ImportError` went straight into
the silent `pass` and the dispute tables would simply not have been
registered. That is the failure mode the swallow creates. Import errors and
missing attributes are now logged at ERROR.

## CI (§27)

| Step | Blocking before | Blocking now |
|---|---|---|
| `pytest --cov-fail-under=35` | yes | yes (floor is low but enforced) |
| Codecov upload | no | no — correct; an upload outage shouldn't fail a build |
| `flutter analyze` | **no** | **errors only** |
| `flutter build apk` | no | no — "Verify APK" downstream is the real gate |

`flutter analyze` was `continue-on-error: true`, so genuine Dart type errors
were printed and ignored. Now blocking, with `--no-fatal-warnings
--no-fatal-infos` so pre-existing lint noise stays informational.

**This is the change most likely to turn CI red**, and that is its purpose.
It has not been verified here — no Flutter toolchain in this environment —
and `webrtc_service.dart` has been heavily modified. If it fails, the
failure is real and worth reading, not worth reverting.
