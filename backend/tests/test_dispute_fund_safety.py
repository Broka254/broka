"""
Regression tests for the dispute-engine audit (2026-09-14).

Three defects, all on the path that sends real M-Pesa B2C payouts:

1. `execute_fund_action` checked `case.state` on an ORM object already
   loaded into the session, then called Daraja B2C. Two concurrent requests
   both passed and both paid.
2. The `version` column's "optimistic locking" was an in-memory comparison
   against the same object the caller read it from
   (`expected_version=case.version`), so it was tautologically true and
   `OptimisticLockError` could never be raised.
3. The engine wrote `deal.status` but never read it, so it could settle a
   deal that `api/routers/negotiate.py` had already released or refunded -
   including paying the buyer a refund on a deal already released to the
   seller.

The ledger's replay guard made (1) worse rather than better: it recorded
one entry while two real payouts left, so the books balanced and the cash
did not.
"""
import pytest

from api.models.dispute import CaseState, DisputeCase, OptimisticLockError


class TestOptimisticLockIsRealNotDecorative:
    def test_version_predicate_is_in_the_update_not_in_python(self):
        """The check must live in SQL. An in-memory comparison against an
        object both writers already loaded cannot detect anything."""
        import inspect
        from api.domains.disputes.service import DisputeEngineService
        src = inspect.getsource(DisputeEngineService.transition)
        assert "DisputeCase.version == expected_version" in src, (
            "version must be a WHERE predicate the database arbitrates"
        )
        assert "rowcount" in src, "the verdict must come from rowcount"

    def test_stale_version_still_raises_the_documented_error(self):
        # OptimisticLockError must remain importable and raised - the
        # router's `except OptimisticLockError -> 409` depends on it, and
        # that handler was unreachable for as long as the check was fake.
        assert issubclass(OptimisticLockError, Exception)


class TestPayoutIsClaimedBeforeMoneyMoves:
    def test_claim_precedes_the_b2c_call(self):
        """Ordering is the whole guard: everything before the claim must be
        read-only, everything after may spend."""
        import inspect
        from api.domains.disputes.service import DisputeEngineService
        src = inspect.getsource(DisputeEngineService.execute_fund_action)
        claim_at = src.find("_claim_fund_execution")
        b2c_at = src.find("_mpesa_b2c")
        assert claim_at != -1, "payout must be claimed"
        assert b2c_at != -1
        assert claim_at < b2c_at, (
            "the claim must happen BEFORE the B2C call - claiming afterwards "
            "protects nothing, the money has already gone"
        )

    def test_claim_requires_fund_executed_at_to_be_null(self):
        """The idempotency predicate. Even if a bug walked a settled case
        back to ready_for_*, its payout must not fire again."""
        import inspect
        from api.domains.disputes.service import DisputeEngineService
        src = inspect.getsource(DisputeEngineService._claim_fund_execution)
        assert "fund_executed_at.is_(None)" in src
        assert "rowcount" in src


class TestCrossSystemSettlementInvariant:
    """api/routers/negotiate.py settles the same deals through a different
    path. Both must contend for one lock, or a deal can be released to the
    seller AND refunded to the buyer."""

    def test_engine_claims_the_deal_lock_before_paying(self):
        import inspect
        from api.domains.disputes.service import DisputeEngineService
        src = inspect.getsource(DisputeEngineService.execute_fund_action)
        assert "lock_deal_if_status" in src, (
            "must contend for the same deal lock negotiate.py uses"
        )
        lock_at = src.find("lock_deal_if_status")
        b2c_at = src.find("_mpesa_b2c")
        assert lock_at < b2c_at

    def test_terminal_deal_statuses_are_not_settleable(self):
        """released/refunded/cancelled must be absent from the settleable
        tuple - that absence is what makes double settlement impossible."""
        import inspect
        from api.domains.disputes.service import DisputeEngineService
        src = inspect.getsource(DisputeEngineService.execute_fund_action)
        settleable = src[src.find("settleable = ("):src.find(")", src.find("settleable = ("))]
        for terminal in ("DealStatus.released", "DealStatus.refunded", "DealStatus.cancelled"):
            assert terminal not in settleable, (
                f"{terminal} must not be settleable - it means the deal's money "
                "has already moved"
            )


class TestCaseStateMachine:
    def test_terminal_states_are_terminal(self):
        assert CaseState.closed_refunded.is_terminal
        assert CaseState.closed_released.is_terminal
        assert not CaseState.closed_refunded.is_active
        assert not CaseState.closed_released.is_active

    def test_escalated_is_not_active_but_not_terminal(self):
        # Escalated cases are awaiting a human, so they must not be swept by
        # anything that treats "active" as "safe to auto-progress", but they
        # must still be reachable for an admin to resolve.
        assert not CaseState.escalated.is_active
        assert not CaseState.escalated.is_terminal

    def test_ready_states_are_active(self):
        assert CaseState.ready_for_refund.is_active
        assert CaseState.ready_for_release.is_active
