"""The rules for scam reports, restrictions and appeals
(domains/scam_reports/policy.py) - plain Python, so they run anywhere.

The principle every test here serves: A REPORT IS NOT A VERDICT.
  * counting reports can only ever ask a person to look - and only for
    DIFFERENT reporters, so one angry person cannot "trigger" an account;
  * a restriction is narrow (only what is actually enforced), temporary
    (it must end, within a maximum), explained to the person in plain words,
    and appealable - and cannot be applied, or extended, by a report;
  * evidence is whatever the bytes really are, never the client's word.
The database and HTTP behaviour is in test_scam_reports_api.py.
"""
from datetime import datetime, timedelta

import pytest

from api.domains.scam_reports import policy

NOW = datetime(2026, 11, 16, 9, 0, 0)


class TestFilingARecord:
    def ok(self, **over):
        args = dict(reason_code="deposit_to_reserve", description="He asked for 2,000 to reserve the phone.",
                    reported_user_id="u-2", reported_account_ref=None, reporter_id="u-1")
        args.update(over)
        return policy.validate_report(args.pop("reason_code"), args.pop("description"), **args)

    def test_a_proper_report_is_accepted(self):
        assert self.ok() == []
        assert self.ok(reported_user_id=None, reported_account_ref="0712 345 678") == []

    def test_it_must_say_why_and_what(self):
        assert any("reason_code" in p for p in self.ok(reason_code="made_up"))
        assert any("description" in p for p in self.ok(description="bad"))
        assert any("description" in p for p in self.ok(description=" " * 40))

    def test_it_must_name_something(self):
        problems = self.ok(reported_user_id=None, reported_account_ref=None)
        assert any("reported_account_ref" in p for p in problems)
        assert any("reported_account_ref" in p for p in self.ok(reported_user_id=None, reported_account_ref="x"))

    def test_you_cannot_report_yourself(self):
        assert any("yourself" in p for p in self.ok(reported_user_id="u-1"))

    def test_every_reason_the_brief_names_exists(self):
        for code in ("bypass_escrow", "fake_escrow_link", "requested_otp_or_pin", "deposit_to_reserve",
                     "fake_payment_proof", "fake_customer_care", "changed_payment_destination", "non_delivery"):
            assert code in policy.REASONS

    def test_there_is_no_reason_or_field_that_would_hold_a_pin_or_otp(self):
        """No M-Pesa PIN, OTP or password is stored: the report has no field for one."""
        assert not any(word in code for code in policy.REASONS for word in ("pin_value", "otp_value", "password_value"))


class TestCountingReports:
    def test_three_different_people_ask_a_person_to_look(self):
        assert policy.should_alert(["a", "b", "c"]) is True
        assert policy.should_alert(["a", "b"]) is False

    def test_one_person_reporting_five_times_is_still_one(self):
        assert policy.should_alert(["a"] * 5) is False
        assert policy.should_alert(["a", "a", "b", "b", "b"]) is False

    def test_blank_reporters_do_not_count(self):
        assert policy.should_alert(["a", "", None, "b"]) is False

    def test_the_threshold_is_a_parameter(self):
        assert policy.should_alert(["a", "b"], threshold=2) is True

    def test_the_window_is_recent_not_forever(self):
        assert policy.window_start(NOW) == NOW - timedelta(days=30)


class TestSameAccountReportedDifferentWays:
    @pytest.mark.parametrize("a,b", [
        ("+254 712 345 678", "0712345678"),
        ("254712345678", "0712 345 678"),
        ("0712-345-678", "+254712345678"),
        ("https://www.Fake-Escrow.com/pay?id=1", "fake-escrow.com"),
        ("http://fake-escrow.com/", "FAKE-ESCROW.COM"),
        ("fake-escrow.com:8080/x", "https://fake-escrow.com"),
    ])
    def test_the_same_phone_or_website_counts_as_one(self, a, b):
        assert policy.normalise_account_ref(a) == policy.normalise_account_ref(b)

    def test_different_ones_stay_different(self):
        assert policy.normalise_account_ref("0712345678") != policy.normalise_account_ref("0712345679")
        assert policy.normalise_account_ref("fake-escrow.com") != policy.normalise_account_ref("fake-escrow.co.ke")

    def test_a_name_is_kept_as_lower_case_text(self):
        assert policy.normalise_account_ref("  John The Seller ") == "john the seller"
        assert policy.reported_account_kind("John The Seller") == "other"
        assert policy.reported_account_kind("0712345678") == "phone"
        assert policy.reported_account_kind("https://fake-escrow.com/x") == "website"


class TestRestrictions:
    def ok(self, **over):
        args = dict(scopes=["create_listing"], days=7,
                    internal_reason="Four reports of the same fake escrow link in a week.",
                    public_reason="Posting new listings is paused while we review reports.")
        args.update(over)
        return policy.validate_restriction(args["scopes"], args["days"], args["internal_reason"], args["public_reason"])

    def test_a_reasonable_restriction_is_accepted(self):
        assert self.ok() == []

    def test_it_must_end_and_within_a_maximum(self):
        assert any("temporary" in p for p in self.ok(days=0))
        assert any("temporary" in p for p in self.ok(days=policy.MAX_DAYS + 1))
        assert any("temporary" in p for p in self.ok(days=None))
        assert any("temporary" in p for p in self.ok(days=True))        # bool is not a number of days
        assert any("temporary" in p for p in self.ok(days=7.5))
        assert self.ok(days=policy.MAX_DAYS) == [] and self.ok(days=1) == []

    def test_only_enforced_scopes_exist(self):
        assert set(policy.SCOPES) == {"create_listing"}
        assert any("scopes" in p for p in self.ok(scopes=["make_offer"]))
        assert any("scopes" in p for p in self.ok(scopes=[]))
        assert any("scopes" in p for p in self.ok(scopes="create_listing"))
        assert any("scopes" in p for p in self.ok(scopes=["delete_account"]))

    def test_there_is_no_permanent_punishment_in_this_vocabulary(self):
        assert policy.MAX_DAYS <= 30
        assert not any(word in " ".join(policy.SCOPES) for word in ("ban", "delete", "close", "balance", "money"))

    def test_the_team_must_record_why_and_the_person_must_be_told_in_words(self):
        assert any("internal_reason" in p for p in self.ok(internal_reason="short"))
        assert any("public_reason" in p for p in self.ok(public_reason="no"))

    def test_the_notice_says_it_is_not_a_finding(self):
        assert "not a finding that you did anything wrong" in policy.RESTRICTION_NOTICE
        assert "appeal" in policy.RESTRICTION_NOTICE and "ends on its own" in policy.RESTRICTION_NOTICE

    def test_it_ends_by_the_clock_with_nothing_needing_to_run(self):
        ends = NOW + timedelta(days=3)
        assert policy.is_active("active", ends, NOW) is True
        assert policy.is_active("active", ends, ends) is False                      # the instant it ends
        assert policy.is_active("active", ends, ends + timedelta(seconds=1)) is False
        assert policy.is_active("lifted", ends, NOW) is False
        assert policy.is_active("active", None, NOW) is False
        assert policy.effective_status("active", ends, ends + timedelta(days=1)) == "expired"
        assert policy.effective_status("active", ends, NOW) == "active"
        assert policy.effective_status("lifted", ends, NOW) == "lifted"


class TestAppeals:
    ends = NOW + timedelta(days=5)

    def test_a_person_with_an_active_restriction_may_appeal(self):
        assert policy.can_appeal("active", self.ends, NOW, 0, False) is None

    def test_one_open_appeal_at_a_time(self):
        assert "already have an appeal" in policy.can_appeal("active", self.ends, NOW, 1, True)

    def test_a_limited_number_of_appeals(self):
        assert policy.can_appeal("active", self.ends, NOW, policy.MAX_APPEALS_PER_RESTRICTION - 1, False) is None
        assert "used the appeals" in policy.can_appeal(
            "active", self.ends, NOW, policy.MAX_APPEALS_PER_RESTRICTION, False)

    def test_there_is_nothing_to_appeal_once_it_has_ended(self):
        assert "no longer in force" in policy.can_appeal("lifted", self.ends, NOW, 0, False)
        assert "no longer in force" in policy.can_appeal("active", self.ends, self.ends + timedelta(days=1), 0, False)

    def test_an_appeal_needs_the_persons_side_and_a_decision_needs_a_reason(self):
        assert policy.validate_appeal("") != [] and policy.validate_appeal("no") != []
        assert policy.validate_appeal("   ") != [] and policy.validate_appeal(None) != []
        assert policy.validate_appeal("I did nothing wrong.") == []       # one honest sentence is an appeal
        assert policy.validate_appeal("The reports are from a buyer I refused to refund after delivery.") == []
        assert policy.validate_decision("overturned", "Reports did not hold up; restriction removed.") == []
        assert any("outcome" in p for p in policy.validate_decision("banned", "A long enough note here."))
        assert any("note" in p for p in policy.validate_decision("upheld", "no"))


class TestPrivateEvidence:
    PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 20
    JPEG = b"\xff\xd8\xff\xe0" + b"\x00" * 20
    WEBP = b"RIFF\x00\x00\x00\x00WEBPVP8 " + b"\x00" * 20

    def test_the_type_is_decided_by_the_bytes(self):
        assert policy.sniff_image(self.PNG) == ("image/png", "png")
        assert policy.sniff_image(self.JPEG) == ("image/jpeg", "jpg")
        assert policy.sniff_image(self.WEBP) == ("image/webp", "webp")

    @pytest.mark.parametrize("data", [
        b"", b"GIF89a....", b"<html><script>alert(1)</script>", b"%PDF-1.7", b"MZ\x90\x00",
        b"<svg xmlns='http://www.w3.org/2000/svg'><script/></svg>", b"RIFF\x00\x00\x00\x00WAVE....",
        b"\x89PNG", b"#!/bin/sh\nrm -rf /",
    ])
    def test_anything_that_is_not_one_of_those_is_refused(self, data):
        assert policy.sniff_image(data) is None

    @pytest.mark.parametrize("given,ext,expected", [
        ("../../etc/passwd", "png", "passwd.png"),
        ("C:\\Users\\me\\receipt.exe", "png", "receipt.png"),
        ("evidence.html", "jpg", "evidence.jpg"),
        ("screen shot (1).PNG", "png", "screen shot 1.png"),
        ("", "png", "evidence.png"),
        ("\x00\x01bad\n.png", "png", "bad.png"),
        ("a" * 300 + ".png", "png", "a" * 60 + ".png"),
    ])
    def test_the_file_name_is_cleaned_and_takes_the_real_extension(self, given, ext, expected):
        assert policy.safe_file_name(given, ext) == expected

    def test_limits(self):
        assert policy.MAX_EVIDENCE_FILES == 3 and policy.MAX_EVIDENCE_BYTES == 1_500_000


class TestCleaning:
    def test_control_characters_and_nul_never_survive(self):
        assert policy.clean_text("a\x00b\x07c\x1bd", 50) == "abcd"
        assert policy.clean_text("line1\nline2", 50) == "line1 line2"
        assert policy.clean_text("line1\nline2", 50, newlines=True) == "line1\nline2"
        assert len(policy.clean_text("x" * 500, 120)) == 120
        assert policy.clean_text(None, 10) == ""
