"""The fee calculator (escrow_directory/fees.py): every published band,
every boundary, every rounding rule, and every case where it must refuse.

No database and no network: the calculator is plain Python, so these run
anywhere. The Kenya Escrow bands below are the ones its pricing page
published (as recorded in the research brief); they are copied here, not
imported from the seed, so a typo in the seed fails a test instead of
agreeing with itself.

eConfirm's payout-reserve bands were NOT in the research and its tariffs
page could not be read when this was written. The reserve tests use
SYNTHETIC bands, invented here only to prove the mechanism (a destination
picks the table, the reserve is added, a missing destination withholds the
total). They are test data, not eConfirm's tariff, and nothing in the seed
uses them.
"""
import copy
from decimal import Decimal

import pytest

from api.domains.escrow_directory import fees, seed

# (min, max, percent, fixed) - KSh the seller receives.
KE_BANDS = [
    (50, 100, "10", 10), (101, 500, "10", 19), (501, 1000, "6", 40), (1001, 5000, "5.4", 46),
    (5001, 10000, "4.7", 81), (10001, 25000, "4", 151), (25001, 50000, "3.7", 226),
    (50001, 100000, "3.3", 440), (100001, 150000, "2.8", 955), (150001, 200000, "2.65", 1190),
    (200001, 240000, "0.3", 5905),
]
CURRENT = {"state": "current"}


def kenya_escrow() -> dict:
    return next(r for r in seed.records() if r["id"] == "kenyaescrow")


def econfirm() -> dict:
    return next(r for r in seed.records() if r["id"] == "econfirm")


def est(record, amount, **kw):
    return fees.estimate(record, amount, freshness=kw.pop("freshness", CURRENT), **kw)


def expected_fee(amount: int, percent: str, fixed: int) -> int:
    """The published formula, worked in exact arithmetic and rounded up."""
    pct = Decimal(percent) * amount / Decimal(100)
    return int(pct.to_integral_value(rounding="ROUND_CEILING")) + fixed


class TestKenyaEscrowBands:
    def test_the_seed_carries_exactly_the_published_bands(self):
        tiers = kenya_escrow()["pricing"]["commission"]["tiers"]
        assert [(t["min"], t["max"], t["percent"], int(t["fixed"])) for t in tiers] == KE_BANDS

    @pytest.mark.parametrize("low,high,percent,fixed", KE_BANDS)
    def test_each_band_at_both_edges_and_the_middle(self, low, high, percent, fixed):
        for amount in sorted({low, (low + high) // 2, high}):
            r = est(kenya_escrow(), amount)
            assert r["status"] == fees.ESTIMATED
            assert r["total_fees"] == expected_fee(amount, percent, fixed), amount
            assert r["total_buyer_payment"] == amount + r["total_fees"]
            assert r["seller_receives"] == amount

    @pytest.mark.parametrize("below,above", [(b[1], b[1] + 1) for b in KE_BANDS[:-1]])
    def test_the_amount_just_over_a_boundary_uses_the_next_band(self, below, above):
        tiers = kenya_escrow()["pricing"]["commission"]["tiers"]
        assert fees.find_tier(tiers, below)["max"] == below
        assert fees.find_tier(tiers, above)["min"] == above

    def test_worked_examples(self):
        # 5,000 x 5.4% is EXACTLY 270: a float gives 270.00000000000006 and
        # would round up to 271.
        r = est(kenya_escrow(), 5000)
        assert (r["commission"], r["fixed_charges"], r["mpesa_or_payout_charges"]) == (270, 46, 0)
        assert (r["total_fees"], r["total_buyer_payment"], r["effective_fee_percent"]) == (316, 5316, 6.32)
        # 100 x 10% + 10; 101 x 10% = 10.1 -> 11, + 19.
        assert est(kenya_escrow(), 100)["total_fees"] == 20
        assert est(kenya_escrow(), 101)["total_fees"] == 11 + 19
        # 240,000 x 0.3% + 5,905 = 6,625: the whole payment stays under the
        # KSh 250,000 M-Pesa limit its pricing page quotes.
        top = est(kenya_escrow(), 240000)
        assert top["total_fees"] == 6625 and top["total_buyer_payment"] == 246625 < 250000

    @pytest.mark.parametrize("amount,exact_commission", [(1500, 81), (3000, 162)])
    def test_a_float_that_would_misround_does_not(self, amount, exact_commission):
        """Found by checking every whole-shilling amount in every published
        band: these two (both in the 5.4% band) are the only ones where float
        arithmetic gets the commission wrong. 1,500 x 5.4% is exactly 81 -
        and 81.00000000000001 as a float, which rounds up to 82."""
        import math
        assert math.ceil(amount * 5.4 / 100) == exact_commission + 1      # the trap
        r = est(kenya_escrow(), amount)
        assert r["commission"] == exact_commission                        # not the trap

    def test_no_amount_in_any_band_misrounds(self):
        """The engine against an independent exact calculation, for every
        whole-shilling amount the provider takes (50 to 240,000)."""
        record = kenya_escrow()
        for low, high, percent, fixed in KE_BANDS:
            for amount in range(low, high + 1, 1 if high - low < 3000 else 13):
                got = fees.estimate(record, amount, freshness=CURRENT)["total_fees"]
                assert got == expected_fee(amount, percent, fixed), (amount, got)

    def test_fees_add_up_whatever_the_amount(self):
        for amount in (50, 77, 333, 999, 1234, 4999, 7777, 31415, 99999, 123456, 199999, 239999):
            r = est(kenya_escrow(), amount)
            assert r["total_fees"] == r["commission"] + r["fixed_charges"] + r["mpesa_or_payout_charges"]
            assert r["total_buyer_payment"] == amount + r["total_fees"]

    def test_it_says_the_provider_absorbs_mpesa_charges_and_does_not_add_any(self):
        r = est(kenya_escrow(), 5000)
        assert r["mpesa_or_payout_charges"] == 0
        assert "pays the M-Pesa charges" in r["mpesa_or_payout_note"]


class TestRounding:
    def test_each_charge_rounds_up_to_a_whole_shilling(self):
        # 1,234 x 5.4% = 66.636 -> 67; the total is the sum of rounded lines.
        r = est(kenya_escrow(), 1234)
        assert r["commission"] == 67 and r["fixed_charges"] == 46 and r["total_fees"] == 113

    def test_an_exact_shilling_is_not_pushed_up(self):
        for amount, percent in ((5000, "5.4"), (1000, "6"), (100, "10")):
            exact = Decimal(percent) * amount / 100
            assert exact == exact.to_integral_value()
        assert est(kenya_escrow(), 1000)["commission"] == 60

    def test_effective_percentage_is_fees_over_what_the_seller_gets_to_two_places(self):
        assert fees.effective_percent(316, 5000) == 6.32
        assert fees.effective_percent(1, 3) == 33.33
        assert fees.effective_percent(2, 3) == 66.67  # half-up
        r = est(kenya_escrow(), 50)
        assert r["effective_fee_percent"] == 30.0

    def test_ceil_never_goes_down(self):
        for text in ("0.001", "0.5", "0.999", "1", "1.0001", "269.9999"):
            assert fees.ceil_kes(Decimal(text)) >= Decimal(text)


class TestLimits:
    def test_below_the_minimum_and_above_the_maximum_get_no_number(self):
        for amount in (1, 49):
            r = est(kenya_escrow(), amount)
            assert r["status"] == fees.OUT_OF_RANGE and r["total_buyer_payment"] is None
            assert "from KSh 50" in r["message"]
        for amount in (240001, 250000, 1_000_000):
            r = est(kenya_escrow(), amount)
            assert r["status"] == fees.OUT_OF_RANGE and r["total_buyer_payment"] is None
            assert "up to KSh 240,000" in r["message"]

    def test_the_limits_themselves_are_in_range(self):
        assert est(kenya_escrow(), 50)["status"] == fees.ESTIMATED
        assert est(kenya_escrow(), 240000)["status"] == fees.ESTIMATED

    def test_econfirms_published_limits_apply_to_its_calculation(self):
        assert est(econfirm(), 99)["status"] == fees.OUT_OF_RANGE
        assert est(econfirm(), 100)["status"] == fees.PARTIAL
        assert est(econfirm(), 500000)["status"] == fees.PARTIAL
        assert est(econfirm(), 500001)["status"] == fees.OUT_OF_RANGE

    def test_a_band_table_with_a_gap_is_never_used(self):
        record = kenya_escrow()
        del record["pricing"]["commission"]["tiers"][3]            # 1,001-5,000 gone
        record["conditions"]["min_amount"] = 50
        assert fees.validate_tiers(record["pricing"]["commission"]["tiers"], "x")
        # ...and the calculator, handed it anyway, does not guess a neighbour:
        r = est(record, 2000)
        assert r["status"] == fees.OUT_OF_RANGE and r["total_buyer_payment"] is None


class TestBadAmounts:
    @pytest.mark.parametrize("bad", [0, -1, -5000, 0.5, 5000.5, "abc", "", None, True, False,
                                     float("nan"), float("inf"), "1e999", [], {}, "5,000", 10 ** 12])
    def test_nonsense_is_refused_not_priced(self, bad):
        r = est(kenya_escrow(), bad)
        assert r["status"] == fees.INVALID_AMOUNT
        assert r["total_buyer_payment"] is None and r["lines"] == []

    @pytest.mark.parametrize("ok", [5000, "5000", 5000.0, " 5000 "])
    def test_a_whole_number_in_any_ordinary_form_is_accepted(self, ok):
        assert est(kenya_escrow(), ok)["total_buyer_payment"] == 5316


class TestEConfirm:
    def test_the_commission_is_shown_alone_and_never_called_the_total(self):
        r = est(econfirm(), 5000)
        assert r["status"] == fees.PARTIAL
        assert r["commission"] == 50                       # 1% of 5,000
        assert r["fixed_charges"] is None                  # none published: not zero
        assert r["total_buyer_payment"] is None and r["total_fees"] is None
        assert r["effective_fee_percent"] is None
        assert "no total is shown" in r["message"]

    def test_the_commission_rounds_up(self):
        assert est(econfirm(), 101)["commission"] == 2     # 1.01 -> 2
        assert est(econfirm(), 100)["commission"] == 1
        assert est(econfirm(), 250000)["commission"] == 2500

    def test_the_published_payout_reserve_is_listed_but_has_no_numbers(self):
        r = est(econfirm(), 5000, payout_destination="phone")
        reserve = next(line for line in r["lines"] if line["kind"] == "payout")
        assert reserve["estimated"] is True and reserve["status"] == "not_available"
        assert "not loaded" in reserve["note"]

    # ── the reserve MECHANISM, on invented numbers (see the module docstring) ──
    @staticmethod
    def with_synthetic_reserve():
        record = econfirm()
        record["pricing"]["payout_fees"][0].update(
            documented=True,
            by_destination={
                "phone": {"tiers": [{"min": 100, "max": 1000, "fixed": "7"},
                                    {"min": 1001, "max": 500000, "fixed": "20"}]},
                "till": {"tiers": [{"min": 100, "max": 500000, "percent": "0.5"}]},
            })
        return record

    def test_the_reserve_is_added_and_depends_on_the_payout_destination(self):
        record = self.with_synthetic_reserve()
        phone = est(record, 5000, payout_destination="phone")
        till = est(record, 5000, payout_destination="till")
        assert phone["status"] == till["status"] == fees.ESTIMATED
        assert phone["commission"] == till["commission"] == 50
        assert phone["mpesa_or_payout_charges"] == 20            # phone band 1,001+
        assert till["mpesa_or_payout_charges"] == 25             # 0.5% of 5,000
        assert phone["total_buyer_payment"] == 5000 + 50 + 20
        assert till["total_buyer_payment"] == 5000 + 50 + 25
        assert phone["includes_estimated_charges"] is True
        assert "estimate" in phone["mpesa_or_payout_note"].lower()

    def test_phone_and_till_use_different_bands_at_the_same_amount(self):
        record = self.with_synthetic_reserve()
        assert est(record, 1000, payout_destination="phone")["mpesa_or_payout_charges"] == 7
        assert est(record, 1001, payout_destination="phone")["mpesa_or_payout_charges"] == 20
        assert est(record, 1000, payout_destination="till")["mpesa_or_payout_charges"] == 5

    def test_without_a_destination_the_total_is_withheld_and_it_says_why(self):
        r = est(self.with_synthetic_reserve(), 5000)
        assert r["status"] == fees.PARTIAL and r["needs_payout_destination"] is True
        assert r["total_buyer_payment"] is None and r["commission"] == 50
        assert "where the seller is paid" in r["message"]

    def test_a_destination_it_has_no_figures_for_withholds_the_total(self):
        r = est(self.with_synthetic_reserve(), 5000, payout_destination="bank")
        assert r["status"] == fees.PARTIAL and r["total_buyer_payment"] is None

    def test_an_amount_outside_the_reserve_bands_gets_no_number(self):
        record = self.with_synthetic_reserve()
        record["pricing"]["payout_fees"][0]["by_destination"]["phone"]["tiers"][-1]["max"] = 2000
        assert est(record, 3000, payout_destination="phone")["status"] == fees.OUT_OF_RANGE


class TestNoInventedFees:
    @pytest.mark.parametrize("pid,message", [
        ("lipasafe", "Live quotation required"),
        ("shikilia", "Fee not publicly specified"),
    ])
    def test_providers_without_a_published_fee_get_no_estimate(self, pid, message):
        record = next(r for r in seed.records() if r["id"] == pid)
        for amount in (50, 5000, 240000):
            r = est(record, amount)
            assert r["status"] == fees.UNAVAILABLE and message in r["message"]
            assert r["commission"] is None and r["total_buyer_payment"] is None
            assert r["effective_fee_percent"] is None and r["lines"] == []

    def test_under_review_pricing_gets_no_estimate(self):
        record = kenya_escrow()
        record["pricing"].update(disclosure="under_review", commission=None)
        assert est(record, 5000)["status"] == fees.UNAVAILABLE

    def test_a_fixed_fee_provider_is_calculated_from_its_fixed_fee_only(self):
        record = kenya_escrow()
        record["pricing"].update(disclosure="published_fixed",
                                 commission={"label": "Fee", "payer": "buyer", "fixed": "25"})
        record["conditions"].update(min_amount=None, max_amount=None)
        r = est(record, 1234)
        assert r["fixed_charges"] == 25 and r["commission"] is None and r["total_buyer_payment"] == 1259

    def test_silence_about_mpesa_charges_is_not_a_zero(self):
        record = kenya_escrow()
        record["pricing"]["absorbs_mpesa_fees"] = None
        r = est(record, 5000)
        assert r["status"] == fees.PARTIAL and r["total_buyer_payment"] is None
        assert r["mpesa_or_payout_charges"] is None
        assert "does not say" in r["mpesa_or_payout_note"]


class TestComparability:
    """The estimate says whether it may be set beside another provider's."""

    def verified(self, record):
        record["pricing"]["additional_fees_may_apply"] = False
        return record

    def test_a_complete_current_estimate_with_no_other_fees_is_comparable(self):
        r = est(self.verified(kenya_escrow()), 5000)
        assert r["comparable"] is True and r["not_comparable_reason"] is None and r["stale"] is False

    def test_the_seed_as_shipped_is_not_comparable(self):
        r = fees.estimate(kenya_escrow(), 5000)              # no freshness given: unverified
        assert r["comparable"] is False and "not been verified" in r["not_comparable_reason"]

    @pytest.mark.parametrize("state,reason", [("expired", "out of date"), ("unverified", "not been verified")])
    def test_old_or_unverified_pricing_is_never_comparable(self, state, reason):
        r = est(self.verified(kenya_escrow()), 5000, freshness={"state": state})
        assert r["comparable"] is False and r["stale"] is True and reason in r["not_comparable_reason"]
        assert r["total_buyer_payment"] == 5316              # still shown, flagged

    def test_other_fees_unconfirmed_means_not_comparable(self):
        for value in (None, True):
            record = kenya_escrow()
            record["pricing"]["additional_fees_may_apply"] = value
            r = est(record, 5000)
            assert r["comparable"] is False and "no other fees apply" in r["not_comparable_reason"]

    def test_a_partial_estimate_is_never_comparable(self):
        r = est(self.verified(econfirm()), 5000)
        assert r["comparable"] is False and "every charge" in r["not_comparable_reason"]


class TestBandValidation:
    def test_a_good_table_passes(self):
        tiers = [{"min": lo, "max": hi, "percent": p, "fixed": f} for lo, hi, p, f in KE_BANDS]
        assert fees.validate_tiers(tiers, "t") == []

    @pytest.mark.parametrize("mutate,expect", [
        (lambda t: t[1].update(min=102), "gap or overlap"),
        (lambda t: t[1].update(min=100), "gap or overlap"),
        (lambda t: t[0].update(max=40), "not below min"),
        (lambda t: t[0].update(percent="101"), "percent"),
        (lambda t: t[0].update(percent="nan"), "percent"),
        (lambda t: t[0].update(fixed="-5"), "fixed"),
        (lambda t: t[0].update(percent=None, fixed=None), "needs a percent"),
        (lambda t: t[0].update(min="50"), "whole number"),
        (lambda t: t[0].update(percent="1.00001"), "percent"),
    ])
    def test_a_bad_table_is_refused(self, mutate, expect):
        tiers = [{"min": lo, "max": hi, "percent": p, "fixed": f} for lo, hi, p, f in KE_BANDS]
        mutate(tiers)
        problems = fees.validate_tiers(tiers, "t")
        assert problems and any(expect in p for p in problems), problems

    def test_empty_or_wrong_shape_is_refused(self):
        for bad in (None, [], "x", {}, [1], [[]]):
            assert fees.validate_tiers(bad, "t")


class TestPlainNumbers:
    def test_percentages_print_as_plain_digits(self):
        assert fees.plain(Decimal("10")) == "10"
        assert fees.plain(Decimal("5.40")) == "5.4"
        assert fees.plain(Decimal("0.3")) == "0.3"
        assert fees.plain(Decimal("100")) == "100"
        assert est(kenya_escrow(), 60)["lines"][0]["percent"] == "10"      # not "1E+1"

    def test_parse_decimal_refuses_what_must_not_reach_arithmetic(self):
        for bad in (True, False, None, "nan", "inf", "-inf", "1e5000", float("nan"), [], {}, "0x10"):
            assert fees.parse_decimal(bad) is None
        assert fees.parse_decimal(5.4) == Decimal("5.4")
        assert fees.parse_decimal("10") == Decimal(10)
        assert fees.parse_decimal("1.23456") is None          # more places than a fee has


def test_the_seed_is_not_changed_by_a_calculation():
    before = copy.deepcopy(seed.records())
    record = kenya_escrow()
    est(record, 5000)
    assert seed.records() == before
