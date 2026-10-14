# Dispute engine audit (2026-09-14)

## 1. Double M-Pesa payout — critical

`execute_fund_action` validated `case.state` on an ORM object already
loaded into the session, then called Daraja B2C. No row lock, no
idempotency predicate, no key on the B2C call (`Occasion` is a label, not
an idempotency token).

Two concurrent `POST /disputes/{id}/execute` both read `ready_for_refund`
from their own in-memory copy, both passed, **both sent a real payout.**

Reproduced: 2 concurrent requests → 2 payouts, 1 ledger entry.

The ledger's replay guard (added in the escrow audit) **masked** this
rather than catching it — the second call logged *"refund already recorded
— ignoring replay"* while KES 48,500 left a second time. Books balanced,
cash did not. And the second HTTP request returned an **error** while the
money had already gone, which invites an operator retry and a third payout.

**Fixed** with `_claim_fund_execution()`: a conditional `UPDATE ... WHERE
id = :id AND state = :expected AND fund_executed_at IS NULL`, with
`rowcount` as the verdict. Only the winner reaches the B2C call. This is
the mechanism `api/domains/escrow/service.py` already used correctly for
the same problem.

## 2. The optimistic lock was decorative — critical

```python
if expected_version is not None and case.version != expected_version:
    raise OptimisticLockError(...)
```

Every caller passes `expected_version=case.version` — the same object's own
attribute. The comparison is tautologically false. `OptimisticLockError`
could never be raised, and the router's `except OptimisticLockError → 409`
was unreachable code.

Nothing configures SQLAlchemy's `version_id_col`; there is no unique
constraint. So `case.version = case.version + 1` emitted
`UPDATE ... SET version=N+1 WHERE id=:id` with **no version predicate**:
two writers both read N, both wrote N+1, last one won silently.

Both the model comment (*"the DB constraint prevents two concurrent writes
from both succeeding"*) and the service docstring described protection that
did not exist. **`fund_executed_at` was written but never read**, so it was
not a guard either.

**Fixed:** the version is now a WHERE predicate on a conditional UPDATE,
with `rowcount` as the verdict. Model comment corrected.

## 3. Cross-system double settlement — critical

The engine **wrote** `deal.status` but never **read** it as a precondition.
`api/routers/negotiate.py` independently settles the same deals —
`DealStatus.released` (buyer_confirms_goods_ok) and `DealStatus.refunded`
(resolution intents) — each correctly guarded by `lock_deal_if_status`.

So the two systems could settle one deal independently:

- negotiate.py refunds the buyer; the v5 case, still in `ready_for_refund`,
  refunds them again. Two real payouts.
- negotiate.py **releases to the seller** while the case is in
  `ready_for_refund`; the engine then **refunds the buyer**. Both sides paid
  from one escrow — precisely the invariant *"a refund must not result in
  both buyer refund and seller release."*

**Fixed:** the engine now contends for the same deal lock, so the deal is
the single arbiter of its own money. Terminal statuses are absent from the
settleable tuple, so a settled deal returns 409 with nothing moved.
Verified across all three scenarios.

## Confirmed correct — no change

- **Authorization.** `_load_case_and_authorize` derives `actor_role` from
  the deal, not the client. A previous pass closed the IDOR where any
  logged-in user could read, alter or execute another user's dispute.
- **E-Confirm isolation.** `execute_fund_action` fails closed (409) on
  E-Confirm-funded deals rather than paying out of the wrong account.
- **State machine.** Terminal/active properties are coherent; `escalated`
  is correctly neither active nor terminal, so sweeps can't auto-progress a
  case awaiting a human.
- **Immutable event log.** `DisputeEvent` rows are append-only.

## Remaining — not fixed

- **`deal.status` is still written by two systems.** The lock makes that
  safe, but the duplication is structural debt. One owner would be better.
- **B2C failure still closes the case.** On `{"success": false}` the code
  proceeds to mark the deal refunded and close. Deliberate ("queued for
  manual processing") but it means a case can read `closed_refunded` with
  no money sent. Worth a distinct state.
- **NOT VERIFIED at runtime.** pytest is uninstallable here (no network).
  All findings are from reading plus standalone simulation of the exact
  logic; nothing was executed against a database.
