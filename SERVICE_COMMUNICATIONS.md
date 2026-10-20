# Service Communications

Admin-controlled announcements, maintenance notices, incidents and product
updates. The API and delivery ledger live in `backend/api/domains/service_communications/`;
the customer feed is part of the same durable recipient record, not a second
notification system.

## Design

- `service_communications` is the campaign and lifecycle row.
- `service_communication_versions` is the append-only draft/edit history.
- `service_communication_recipients` has exactly one row per communication
  and user. That row is the in-app announcement and the aggregate delivery
  state.
- `service_communication_device_deliveries` records each phone attempt. It
  stores a SHA-256 fingerprint of the FCM token, never the token itself.

The database is the durable queue. A process-local asyncio task is only a
wake-up; losing it cannot lose a scheduled communication or a recipient.
Publication and delivery use compare-and-swap claims, so several API replicas
may run the sweep concurrently without claiming the same row.

Schema creation follows this repository's convention: new tables are imported
by `init_db()` and created through `Base.metadata.create_all()`. Schema
revision 7 records this feature. There is no Alembic migration step on deploy.

## Delivery states

| State | Meaning |
|---|---|
| `queued` | Recipient is durable and eligible to be attempted |
| `sending` | One worker owns the recipient under a recoverable lease |
| `provider_accepted` | FCM accepted at least one device message |
| `delivered` | Reliable in-app availability evidence; never derived from FCM acceptance |
| `failed` | Terminal for this attempt budget, with a sanitized category |
| `retry_scheduled` | A retryable provider/device failure has a due time |
| read (`read_at`) | The authenticated customer opened/marked the announcement |

FCM's message id proves acceptance only. It is stored in
`provider_message_id`; it does not set `delivered_at`. Published in-app rows
are visible to the target user regardless of push success, invalid tokens, or
missing Firebase configuration.

## Audience

Supported definitions are `all`, `buyers`, `sellers`, `store_owners`, and
`user_ids`. Eligibility uses the existing account policy: unset or at least
20 trust score, and not fraud-flagged. Store owners are derived from active
`stores.owner_id` rows. Explicit ids are checked against the same policy;
unknown, suspended, or omitted ids are rejected rather than silently dropped.

Audience expansion runs in bounded database batches and never accepts a SQL
fragment from the client. Preview reports the resolved count and configured
maximum. `SERVICE_COMMUNICATION_MAX_AUDIENCE` and
`SERVICE_COMMUNICATION_MAX_EXPLICIT_RECIPIENTS` are enforced before a draft or
publication can proceed.

## Worker and recovery

The normal FastAPI lifespan starts a dedicated service-communications loop
through `start_periodic_sweep()`. It runs every
`SERVICE_COMMUNICATION_SWEEP_SECONDS` (default 15). Each pass:

1. Reaps exhausted expired recipient claims.
2. Claims due scheduled rows and abandoned `publishing` rows.
3. Resolves recipients in bounded batches and commits them before any FCM call.
4. Once the campaign's `published` state is committed, claims due recipients,
   sends to all currently registered devices, and records each device outcome
   outside a database transaction. A second worker cannot deliver a campaign
   that is still `publishing` or may still fail finalisation.
5. Marks fully settled campaigns `completed`.

The same pass is registered as the ARQ task
`api.core.workers.task_process_service_communications`. Publishing a campaign
also enqueues one best-effort immediate wake-up when Redis/ARQ is available;
that wake-up is not the durability mechanism.

Recovery is automatic. A `publishing` row whose lease expired is reclaimable;
a `sending` recipient whose lease expired is reclaimable. A process crash after
FCM accepts a message but before the database records it can cause one
at-least-once duplicate because FCM provides no deduplication key for this
path. The database prevents duplicate recipient and device ledger rows, but it
cannot make the external provider exactly-once.

The workers never hold a transaction open across an FCM request. Provider
concurrency and timeouts are bounded by
`SERVICE_COMMUNICATION_PROVIDER_CONCURRENCY` and
`SERVICE_COMMUNICATION_PROVIDER_TIMEOUT_SECONDS`. The effective provider
deadline is also kept five seconds below the claim lease, so a successful call
can record its outcome before another worker may reclaim the recipient.
When a campaign has an `expires_at`, the remaining time (capped at FCM's
four-week maximum) is passed to FCM as the push TTL, so a maintenance notice
cannot appear days after its window has closed. Recipients whose push attempt
begins after the expiry are recorded `failed/communication_expired` and are
not sent.

## Retries

Retryable failures use exponential backoff with jitter, capped by
`SERVICE_COMMUNICATION_RETRY_MAX_SECONDS`. A recipient has at most
`SERVICE_COMMUNICATION_MAX_ATTEMPTS` attempts. Invalid/unregistered tokens are
terminal for that device and are removed through the existing
`push_devices.forget()` service. If one device already accepted, the recipient
is not retried at the recipient level; successful devices are never resent.

An administrator may requeue failed recipients from
`POST /admin/communications/{id}/recipients/retry`. The attempt count is not
reset, so the configured cap cannot be bypassed. Permanent invalid-token,
invalid-message, missing-communication and expired-communication failures are
excluded, and an ordinary failure must still be marked retry-eligible. A
configuration or no-device failure can be retried after Firebase is fixed or
the user registers a phone, because the in-app announcement is already
available and the push retry has a bounded budget. Omitting `recipient_ids`
selects every eligible failure; an explicit empty list is rejected so a client
bug cannot accidentally trigger a campaign-wide retry.

## Admin API

All management routes require a bearer token for an administrator. Reads use
`can_view_communications`; mutations use `can_manage_communications`. Today
all admins receive both permissions because `users.is_admin` is the only
persisted role, but the narrower dependency names remain in place for a future
role table.

| Method and path | Purpose |
|---|---|
| `GET /admin/communications` | Paginated list; filters `status`, `communication_type`, `severity`, `search` |
| `GET /admin/communications/{id}` | Campaign plus delivery summary |
| `POST /admin/communications` | Create draft |
| `PATCH /admin/communications/{id}` | Edit draft with optional `expected_version` |
| `POST /admin/communications/preview` | Resolve audience count |
| `POST /admin/communications/{id}/publish` | Publish now; optional `X-Idempotency-Key` |
| `POST /admin/communications/{id}/schedule` | Set a future UTC publication time |
| `POST /admin/communications/{id}/cancel` | Cancel a draft or scheduled campaign |
| `POST /admin/communications/{id}/complete` | Resolve a published incident/campaign |
| `GET /admin/communications/{id}/recipients` | Paginated recipient outcomes |
| `POST /admin/communications/{id}/recipients/retry` | Requeue eligible failures |
| `GET /admin/communications/{id}/stats` | Delivery counters |
| `GET /admin/communications/diagnostics/worker` | Backlog and last-pass diagnostics |

Example create:

```json
{
  "title": "Scheduled maintenance",
  "body": "BROKA will be unavailable from 02:00 to 02:30 EAT.",
  "communication_type": "maintenance",
  "severity": "high",
  "audience": {"kind": "sellers"},
  "channels": ["in_app", "push"],
  "expires_at": "2026-10-21T03:30:00Z"
}
```

Example schedule:

```json
{"scheduled_at": "2026-10-20T23:00:00Z"}
```

Example audience preview:

```json
{"audience": {"kind": "user_ids", "user_ids": ["user-id-1", "user-id-2"]}}
```

Publishing a campaign returns `202` with the row in `publishing`; delivery is
asynchronous. A repeated publish with the same scoped idempotency key returns
the same result. Concurrent publish requests are compare-and-swap protected so
only one can move the row into publication.

Every administrative mutation writes an `audit_logs` row with the actor,
action, communication id, timestamp, request id and non-sensitive metadata.
Title/body content and provider payloads are not copied into audit metadata.

## Customer API

| Method and path | Purpose |
|---|---|
| `GET /communications?limit=50&offset=0` | The authenticated user's published, unexpired announcements |
| `POST /communications/{id}/read` | Record idempotent read state |

The customer query is scoped by the recipient row's `user_id`, never by an id
or audience supplied in the request. Another user's announcement returns 404.
Expired announcements are hidden from the feed and cannot be marked read.

## Configuration

All values have safe defaults and are listed in `.env.example` and
`render.yaml`:

| Variable | Default | Meaning |
|---|---:|---|
| `SERVICE_COMMUNICATION_MAX_AUDIENCE` | 100000 | Maximum resolved broad audience |
| `SERVICE_COMMUNICATION_MAX_EXPLICIT_RECIPIENTS` | 5000 | Maximum ids in one explicit audience |
| `SERVICE_COMMUNICATION_COMMUNICATION_BATCH` | 5 | Campaigns claimed per pass |
| `SERVICE_COMMUNICATION_RECIPIENT_BATCH` | 50 | Recipients claimed per pass |
| `SERVICE_COMMUNICATION_MAX_ATTEMPTS` | 4 | Maximum attempts per device/recipient |
| `SERVICE_COMMUNICATION_RETRY_BASE_SECONDS` | 30 | Base exponential retry delay |
| `SERVICE_COMMUNICATION_RETRY_MAX_SECONDS` | 900 | Retry delay ceiling |
| `SERVICE_COMMUNICATION_CLAIM_SECONDS` | 180 | Abandoned-work lease |
| `SERVICE_COMMUNICATION_PROVIDER_CONCURRENCY` | 8 | Global FCM calls in flight per pass |
| `SERVICE_COMMUNICATION_PROVIDER_TIMEOUT_SECONDS` | 20 | Per-provider-call deadline |
| `SERVICE_COMMUNICATION_SWEEP_SECONDS` | 15 | Scheduler/delivery loop interval |
| `SERVICE_COMMUNICATION_RETENTION_DAYS` | 730 | Reviewed ledger retention target |

Firebase uses the existing `FIREBASE_SERVICE_ACCOUNT_JSON` setting and the
existing `api/routers/calls.py::_send_fcm` sender. No new credential, service
account, SMS or email provider is required. If Firebase is absent, push is
reported as unavailable, the push attempt fails with `push_not_configured`,
and the in-app announcement remains published.

### Deployment and worker startup

1. Run `python -m api.migrate` as the release step before starting the new API
   build. It creates the four new tables and records schema revision 7; the
   API's readiness check refuses to serve a database below that revision.
2. Run the normal FastAPI process. Its lifespan starts the durable
   service-communications loop; no separate delivery daemon is required.
3. Keep `REDIS_URL` configured in production to retain the existing shared
   rate limiter and idempotency cache. ARQ is optional for this feature: if a
   worker is already run with `arq api.core.workers.WorkerSettings`, its
   registered `task_process_service_communications` job shortens first-delivery
   latency after a publish. The database loop remains the recovery path when
   Redis, ARQ or an individual API replica is unavailable.
4. Keep `FIREBASE_SERVICE_ACCOUNT_JSON` configured for push. The in-app feed
   still works without it, but the API reports push unavailable and records
   `push_not_configured` rather than pretending the push succeeded.
5. Multiple API/ARQ processes may run concurrently. Claims are row-scoped and
   compare-and-swap protected, so no singleton worker lock is needed.

## Retention

`SERVICE_COMMUNICATION_RETENTION_DAYS` is the approved retention target for
closed campaign ledgers. Automatic deletion is deliberately not performed by
the workers because it is irreversible and could remove the only in-app copy
of an old announcement. An operator should archive/delete only `completed` or
`cancelled` campaigns older than the reviewed window, in a transaction that
deletes device deliveries, recipients and versions before the campaign row.
Never delete a `publishing` row or a row with pending recipients.

## Diagnostics

`GET /admin/communications/diagnostics/worker` returns per-status campaign and
recipient backlog, pending recipient count, current worker settings, and this
process's last pass counters. The loop also emits one structured summary log
per non-empty pass with claimed, published, recipient, accepted, delivered,
retry and failure counts. FCM acceptance, confirmed in-app delivery, retries,
exhausted retries and provider failures are separate counters.

## Staging verification

1. Apply schema revision 7 through the normal `api.migrate` release step and
   confirm `/ready` is healthy.
2. Use a Firebase project that is not production and install the app on two
   test devices for one user.
3. Create an explicit-user draft with `in_app` and `push`; preview must resolve
   exactly one user.
4. Publish and verify the customer feed shows the announcement before the
   worker finishes, including when the FCM credential is temporarily removed.
5. Restore a test FCM credential and retry; verify both device rows appear and
   FCM acceptance is recorded without claiming confirmed device delivery.
6. Schedule a campaign a few minutes ahead, restart an API replica before it is
   due, and verify the remaining instance publishes it once.
7. Mark the announcement read as the target user and verify another user gets
   404 and an empty feed.
8. Inspect `audit_logs`, worker diagnostics and logs for request ids and absence
   of raw tokens, credentials, title/body content and provider response bodies.

## Known limitations

- There is no admin frontend in this repository; these are backend contracts
  for the separate admin dashboard.
- FCM provides no reliable per-device display receipt, so `delivered_at` is
  not populated from FCM acceptance.
- A crash between provider acceptance and the database commit can produce an
  at-least-once duplicate; FCM has no campaign deduplication primitive here.
- A provider call that exceeds the configured timeout is abandoned by the
  worker, but the underlying synchronous FCM thread cannot be killed. If that
  request later reaches FCM, the retry can produce the same at-least-once
  duplicate. The timeout still prevents a stuck request from pinning the
  worker forever.
- SMS and email are not supported. Unsupported channels fail validation rather
  than being reported as successful.
- Retention deletion is an operator procedure; it is not an automatic worker
  action.
