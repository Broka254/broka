"""The store-order rules on their own: the state machine, the payment-report
rules, the money arithmetic and the notification wording.

No database and no app here (store_orders/lifecycle.py, pricing.py and
messages.py are pure), so every rule the service relies on is pinned
directly, and the end-to-end suite (test_store_orders.py) can concentrate on
what only the database can show.
"""
from decimal import Decimal

import pytest

from api.domains.store_orders import lifecycle as lc
from api.domains.store_orders import messages as msg
from api.domains.store_orders import pricing


# ── The state machine ───────────────────────────────────────────────────────

class TestTransitions:
    def test_every_status_is_reachable_and_terminal_ones_are_ends(self):
        reachable = {lc.SUBMITTED}
        for action in lc.ACTIONS.values():
            if action.to_status:
                reachable.add(action.to_status)
        assert reachable == set(lc.STATUSES)
        for action in lc.ACTIONS.values():
            assert not (action.from_statuses & lc.TERMINAL) or action.name == "report_problem", action.name

    def test_only_the_buyer_completes_an_order(self):
        completing = [a for a in lc.ACTIONS.values() if a.to_status == lc.COMPLETED]
        assert [a.name for a in completing] == ["confirm_received"]
        assert completing[0].role == lc.BUYER
        with pytest.raises(lc.TransitionError) as err:
            lc.check("confirm_received", status=lc.DELIVERED, role=lc.SELLER, fulfilment=lc.DELIVERY)
        assert err.value.code == "ORDER_ACTION_FORBIDDEN"
        assert err.value.status_code == 403

    def test_fulfilment_waits_for_the_buyers_confirmation(self):
        for name in ("start_preparing", "mark_ready", "dispatch"):
            for status in (lc.SUBMITTED, lc.SELLER_PROPOSED_CHANGES, lc.AWAITING_BUYER_CONFIRMATION):
                with pytest.raises(lc.TransitionError) as err:
                    lc.check(name, status=status, role=lc.SELLER,
                             fulfilment=lc.COLLECTION if name == "mark_ready" else lc.DELIVERY)
                assert err.value.code == "ORDER_STATE_CONFLICT"
        assert lc.check("start_preparing", status=lc.CONFIRMED, role=lc.SELLER,
                        fulfilment=lc.DELIVERY).to_status == lc.PREPARING

    def test_handover_matches_how_the_order_is_handed_over(self):
        with pytest.raises(lc.TransitionError) as err:
            lc.check("mark_ready", status=lc.CONFIRMED, role=lc.SELLER, fulfilment=lc.DELIVERY)
        assert err.value.code == "ORDER_FULFILMENT_MISMATCH"
        with pytest.raises(lc.TransitionError):
            lc.check("dispatch", status=lc.PREPARING, role=lc.SELLER, fulfilment=lc.COLLECTION)
        assert lc.check("dispatch", status=lc.PREPARING, role=lc.SELLER,
                        fulfilment=lc.DELIVERY).to_status == lc.DISPATCHED

    def test_the_buyer_must_answer_a_changed_offer(self):
        assert lc.check("propose", status=lc.SUBMITTED, role=lc.SELLER,
                        fulfilment=lc.DELIVERY).to_status == lc.SELLER_PROPOSED_CHANGES
        assert lc.check("confirm", status=lc.SELLER_PROPOSED_CHANGES, role=lc.BUYER,
                        fulfilment=lc.DELIVERY).to_status == lc.CONFIRMED
        assert lc.check("reject_proposal", status=lc.SELLER_PROPOSED_CHANGES, role=lc.BUYER,
                        fulfilment=lc.DELIVERY).to_status == lc.SUBMITTED
        with pytest.raises(lc.TransitionError):
            lc.check("confirm", status=lc.SELLER_PROPOSED_CHANGES, role=lc.SELLER, fulfilment=lc.DELIVERY)

    def test_cancelling_follows_each_sides_rule(self):
        assert lc.check("buyer_cancel", status=lc.CONFIRMED, role=lc.BUYER,
                        fulfilment=lc.DELIVERY).to_status == lc.CANCELLED
        with pytest.raises(lc.TransitionError):
            lc.check("buyer_cancel", status=lc.PREPARING, role=lc.BUYER, fulfilment=lc.DELIVERY)
        assert lc.check("seller_cancel", status=lc.DISPATCHED, role=lc.SELLER,
                        fulfilment=lc.DELIVERY).to_status == lc.CANCELLED
        for status in (lc.DELIVERED, lc.COMPLETED):
            for name, role in (("buyer_cancel", lc.BUYER), ("seller_cancel", lc.SELLER)):
                with pytest.raises(lc.TransitionError):
                    lc.check(name, status=status, role=role, fulfilment=lc.DELIVERY)

    def test_unknown_actions_are_refused(self):
        with pytest.raises(lc.TransitionError) as err:
            lc.check("complete", status=lc.DELIVERED, role=lc.BUYER, fulfilment=lc.DELIVERY)
        assert err.value.status_code == 400

    def test_only_the_clock_expires_an_order(self):
        for role in (lc.BUYER, lc.SELLER):
            with pytest.raises(lc.TransitionError):
                lc.check("expire", status=lc.SUBMITTED, role=role, fulfilment=lc.DELIVERY)
        assert lc.ACTIONS["expire"].from_statuses == lc.EXPIRABLE

    def test_allowed_actions_are_what_check_allows(self):
        for status in lc.STATUSES:
            for role in (lc.BUYER, lc.SELLER):
                for fulfilment in lc.FULFILMENT_METHODS:
                    shown = lc.allowed_actions(status, role, fulfilment)
                    for name in shown:
                        real = lc.CANCEL_BY_ROLE[role] if name == "cancel" else name
                        lc.check(real, status=status, role=role, fulfilment=fulfilment)
        assert lc.allowed_actions(lc.SUBMITTED, lc.SELLER, lc.DELIVERY) == ["accept", "propose", "decline"]
        assert lc.allowed_actions(lc.COMPLETED, lc.SELLER, lc.DELIVERY) == []
        assert "cancel" in lc.allowed_actions(lc.SUBMITTED, lc.BUYER, lc.DELIVERY)


# ── Payment reports ─────────────────────────────────────────────────────────

class TestPaymentReports:
    def test_reports_wait_for_the_final_order(self):
        with pytest.raises(lc.TransitionError) as err:
            lc.check_report(lc.BUYER_REPORTED_PAYMENT_SENT, role=lc.BUYER, status=lc.SUBMITTED,
                            arrangement=lc.DIRECT_TO_SELLER)
        assert err.value.code == "PAYMENT_REPORT_TOO_EARLY"
        with pytest.raises(lc.TransitionError) as err:
            lc.check_report(lc.BUYER_REPORTED_PAYMENT_SENT, role=lc.BUYER, status=lc.CANCELLED,
                            arrangement=lc.DIRECT_TO_SELLER)
        assert err.value.code == "PAYMENT_REPORT_CLOSED"

    def test_each_side_reports_only_its_own_part(self):
        with pytest.raises(lc.TransitionError):
            lc.check_report(lc.SELLER_CONFIRMED_RECEIPT, role=lc.BUYER, status=lc.CONFIRMED,
                            arrangement=lc.DIRECT_TO_SELLER)
        with pytest.raises(lc.TransitionError):
            lc.check_report(lc.BUYER_REPORTED_ESCROW_INITIATED, role=lc.SELLER, status=lc.CONFIRMED,
                            arrangement=lc.INDEPENDENT_ESCROW)

    def test_reports_match_the_arrangement(self):
        with pytest.raises(lc.TransitionError) as err:
            lc.check_report(lc.BUYER_REPORTED_ESCROW_INITIATED, role=lc.BUYER, status=lc.CONFIRMED,
                            arrangement=lc.DIRECT_TO_SELLER)
        assert err.value.code == "PAYMENT_ARRANGEMENT_MISMATCH"
        # Cash on collection is often never "chosen": the store may still
        # confirm it was paid directly.
        assert lc.check_report(lc.SELLER_CONFIRMED_RECEIPT, role=lc.SELLER, status=lc.DELIVERED,
                               arrangement=None).kind == lc.SELLER_CONFIRMED_RECEIPT

    def test_no_payment_state_is_ever_verified(self):
        for arrangement in (None, lc.DIRECT_TO_SELLER, lc.INDEPENDENT_ESCROW):
            for reported in (set(), {lc.BUYER_REPORTED_PAYMENT_SENT}, {lc.SELLER_CONFIRMED_RECEIPT},
                             {lc.BUYER_REPORTED_ESCROW_INITIATED}, {lc.SELLER_REPORTED_ESCROW_RELEASE}):
                summary = lc.payment_summary(arrangement, reported, "Lipasafe")
                assert summary["verified"] is False
                assert "verified" not in summary["label"].lower()

    def test_a_buyers_report_alone_awaits_external_confirmation(self):
        s = lc.payment_summary(lc.DIRECT_TO_SELLER, {lc.BUYER_REPORTED_PAYMENT_SENT})
        assert s["label"] == "Buyer reported payment sent"
        assert s["awaiting_external_confirmation"] is True
        assert s["status_note"] == "Awaiting external confirmation"
        s = lc.payment_summary(lc.INDEPENDENT_ESCROW, {lc.BUYER_REPORTED_ESCROW_INITIATED}, "Lipasafe")
        assert s["label"] == "Buyer reported escrow initiated via Lipasafe"
        assert s["awaiting_external_confirmation"] is True

    def test_report_labels_say_who_said_it(self):
        assert {k.label for k in lc.REPORT_KINDS.values()} == {
            "Buyer reported payment sent", "Seller confirmed receipt",
            "Buyer reported escrow initiated", "Seller reported escrow release received",
        }
        assert "does not receive, hold, verify or release" in lc.PAYMENT_NOTICE
        assert "independent of BROKA" in lc.ESCROW_PROVIDER_NOTICE

    def test_payment_never_moves_the_order(self):
        # No action is gated on payment, and no report kind is an action.
        assert not set(lc.REPORT_KINDS) & set(lc.ACTIONS)


# ── Money ───────────────────────────────────────────────────────────────────

class TestPricing:
    @pytest.mark.parametrize("amount,minor", [
        (1500.0, 150_000), (0.1 + 0.2, 30), ("12500.50", 1_250_050),
        (Decimal("99.995"), 10_000), (0, 0), (1999.99, 199_999),
    ])
    def test_to_minor_is_exact_cents(self, amount, minor):
        assert pricing.to_minor(amount) == minor

    @pytest.mark.parametrize("bad", [float("nan"), float("inf"), -1, True, None, "abc"])
    def test_to_minor_refuses_what_is_not_a_price(self, bad):
        with pytest.raises(pricing.PriceError):
            pricing.to_minor(bad)

    def test_totals_are_integer_sums(self):
        lines = [(3, 333_33), (1, 1)]
        assert pricing.subtotal(lines) == 3 * 33_333 + 1
        assert pricing.total(100_000, None) == 100_000
        assert pricing.total(100_000, 25_000) == 125_000
        assert isinstance(pricing.subtotal(lines), int)

    def test_prices_and_fees_are_bounded(self):
        with pytest.raises(pricing.PriceError):
            pricing.check_unit_price(0)
        with pytest.raises(pricing.PriceError):
            pricing.check_unit_price(1.5)
        with pytest.raises(pricing.PriceError):
            pricing.check_unit_price(pricing.MAX_UNIT_PRICE_MINOR + 1)
        assert pricing.check_delivery_fee(0) == 0
        with pytest.raises(pricing.PriceError):
            pricing.check_delivery_fee(-1)

    def test_format(self):
        assert pricing.format_minor(1_250_000) == "KES 12,500"
        assert pricing.format_minor(1_250_050) == "KES 12,500.50"

    def test_material_change(self):
        asked = [("a", 2, 100), ("b", 1, 50)]
        assert not pricing.is_material_change(asked, asked, "delivery", "delivery")
        assert pricing.is_material_change(asked, [("a", 1, 100), ("b", 1, 50)], "delivery", "delivery")
        assert pricing.is_material_change(asked, [("a", 2, 120), ("b", 1, 50)], "delivery", "delivery")
        assert pricing.is_material_change(asked, asked, "delivery", "collection")


# ── Notifications ───────────────────────────────────────────────────────────

class TestNotifications:
    def _notes(self, kind, **detail):
        return msg.notes_for(kind, reference="BK-TEST1234", store_name="Clanix", buyer_name="Amina Wanjiku",
                             item_count=2, total_minor=1_250_000, detail=detail or None)

    def test_the_seller_hears_of_a_new_request(self):
        [note] = self._notes(msg.SUBMITTED)
        assert note.recipient_role == lc.SELLER and note.push
        assert "Amina" in note.body and "Wanjiku" not in note.body
        assert "KES 12,500" in note.body

    def test_the_buyer_hears_every_store_decision(self):
        for kind in (msg.SELLER_ACCEPTED, msg.SELLER_PROPOSED_CHANGES, msg.SELLER_DECLINED,
                     msg.READY_FOR_PICKUP, msg.DISPATCHED, msg.DELIVERED, msg.SELLER_CANCELLED):
            notes = self._notes(kind)
            assert [n.recipient_role for n in notes] == [lc.BUYER], kind
            assert notes[0].push, kind

    def test_the_seller_hears_every_buyer_decision(self):
        for kind in (msg.BUYER_CONFIRMED, msg.BUYER_REJECTED_PROPOSAL, msg.BUYER_CANCELLED,
                     msg.COMPLETED, msg.PROBLEM_REPORTED):
            notes = self._notes(kind)
            assert [n.recipient_role for n in notes] == [lc.SELLER], kind

    def test_expiry_tells_both_and_pushes_the_buyer(self):
        notes = self._notes(msg.EXPIRED, stage="seller_response")
        assert {n.recipient_role: n.push for n in notes} == {lc.BUYER: True, lc.SELLER: False}

    def test_a_payment_report_reaches_the_other_side_as_reported(self):
        [note] = self._notes(msg.PAYMENT_REPORTED, report_kind=lc.BUYER_REPORTED_PAYMENT_SENT)
        assert note.recipient_role == lc.SELLER
        assert "Reported by the buyer" in note.body and "does not see or verify" in note.body
        [note] = self._notes(msg.PAYMENT_REPORTED, report_kind=lc.SELLER_REPORTED_ESCROW_RELEASE)
        assert note.recipient_role == lc.BUYER
        assert "verified" not in note.title.lower()

    def test_every_event_has_a_history_label(self):
        kinds = {v for k, v in vars(msg).items() if k.isupper() and isinstance(v, str)
                 and k not in ("EVENT_LABELS",)}
        assert kinds <= set(msg.EVENT_LABELS)
