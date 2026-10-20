# Production release checklist

This checklist covers changes that can be controlled from the repository.
Railway/Azure settings, backups and provider sandbox access remain operator
actions and must be evidenced separately.

## Before merging

- [ ] Backend SQLite suite passes: `pytest tests/ -q -o addopts=""`.
- [ ] Backend PostgreSQL suite passes with `-p tests.postgres_plugin`.
- [ ] Rust extension checks pass if `backend/native/` or its rules changed:
  `cargo fmt --check`, `cargo clippy --locked --all-targets --features python -- -D warnings`,
  `cargo test --locked`, then the backend suite with `BROKA_NATIVE=required`.
- [ ] Web checks pass if `web/` changed: `npm ci`, `npm run typecheck`,
  `npm run lint`, `npm test`, `npm run build`.
- [ ] Flutter checks pass if `flutter_app/` changed: `flutter pub get`,
  `flutter analyze --no-fatal-warnings --no-fatal-infos`, `flutter test`.
- [ ] New financial or authorization behavior has a regression test that
  fails on the old code.

## Schema release

- [ ] Take/verify a provider-side database backup before the first release
  that changes schema.
- [ ] Run the migration once against a production-equivalent restored copy:
  `cd backend && DATABASE_URL=... python -m api.migrate`.
- [ ] Run it a second time and confirm it is a no-op.
- [ ] Confirm duplicate/reconciliation preflight completed without deleting
  rows. Any duplicate failure blocks release until an operator resolves it.
- [ ] Run the migration against production as a pre-deploy/release step, not
  from each API replica.
- [ ] Confirm `GET /ready` returns 200 with matching schema version before
  routing traffic to the new release.

## Configuration review

- [ ] Production `SECRET_KEY` is random and at least 32 characters.
- [ ] `MPESA_CALLBACK_SECRET` is set and registered callback URLs include it.
- [ ] Enabled payment integrations have their required credentials; disabled
  integrations fail explicitly rather than pretending to work.
- [ ] `REDIS_URL` is set for shared rate limits, event delivery and worker
  coordination. Missing Redis is visible at startup and readiness.
- [ ] `ALLOWED_ORIGINS` lists the actual web/admin origins; it is not `*`.
- [ ] Proxy client-IP configuration (`CLIENT_IP_HEADER` or
  `TRUSTED_PROXY_HOPS`) matches the deployed proxy chain.
- [ ] Sentry/error tracking and alert routing are configured.
- [ ] Health/readiness checks are configured at the hosting layer.

## Financial and operational verification

- [ ] Payment callback secret/path and amount validation were checked in the
  provider sandbox.
- [ ] No duplicate STK prompt is sent under concurrent retries.
- [ ] Duplicate/late callbacks settle once and ledger entries reconcile per
  deal.
- [ ] Reconciliation alerts are reachable and include no raw phone numbers,
  tokens, full provider payloads or credentials.
- [ ] Background sweep runs under one advisory lease across replicas.
- [ ] At least one process restart with queued work was tested in staging.
- [ ] Admin dashboard endpoints used in production are contract-tested.

## Rollback

- [ ] Application rollback is deployed only if its code tolerates the current
  schema. Schema revisions are forward-compatible adoption steps; do not
  assume a code rollback reverses them.
- [ ] Destructive down-migrations are not run automatically.
- [ ] If a payment or ledger defect is suspected, stop new money operations,
  preserve the database and provider records, and reconcile before retrying.
