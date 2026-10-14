"""
Tests for the system-generated availability-nudge SMS
(api/core/nudge_templates.py).

Covers the two things that are invisible in a UTC-based test environment
and impossible to correct once an SMS has been sent: a greeting that
doesn't match the seller's wall clock, and a pronoun that mis-genders
someone.
"""
from datetime import datetime, timezone

import pytest

from api.core.nudge_templates import (
    EAT, TEMPLATES, VALID_GENDERS,
    compose_availability_nudge, greeting_for, is_quiet_hours,
    next_send_time, pronouns_for,
)

ALL_GENDER_INPUTS = ("male", "female", "prefer_not_to_say", None, "", "banana")


class TestGreetingUsesSellerLocalTime:
    @pytest.mark.parametrize("hour,expected", [
        (5, "Good morning"), (9, "Good morning"), (11, "Good morning"),
        (12, "Good afternoon"), (16, "Good afternoon"),
        (17, "Good evening"), (20, "Good evening"),
        (21, "Hi"), (2, "Hi"), (4, "Hi"),
    ])
    def test_greeting_matches_wall_clock(self, hour, expected):
        assert greeting_for(datetime(2026, 9, 15, hour, 0, tzinfo=EAT)) == expected

    def test_utc_and_eat_disagree_where_it_matters(self):
        """The actual bug: Kenya is UTC+3, so a greeting derived from the
        server clock is three hours behind the seller's day. 14:00 EAT is
        11:00 UTC - 'Good morning' by the server, 'Good afternoon' in
        Nairobi."""
        utc = datetime(2026, 9, 15, 11, 0, tzinfo=timezone.utc)
        assert greeting_for(utc.replace(tzinfo=None)) == "Good morning"
        assert greeting_for(utc.astimezone(EAT)) == "Good afternoon"

    def test_never_says_good_night(self):
        """'Good night' is a farewell in English, so it reads as though the
        message is ending before it has begun."""
        for h in range(24):
            assert "night" not in greeting_for(datetime(2026, 9, 15, h, 0, tzinfo=EAT)).lower()


class TestQuietHours:
    @pytest.mark.parametrize("hour,quiet", [
        (2, True), (6, True), (7, False), (12, False), (20, False), (21, True), (23, True),
    ])
    def test_window(self, hour, quiet):
        assert is_quiet_hours(datetime(2026, 9, 15, hour, 0, tzinfo=EAT)) is quiet

    def test_late_night_defers_to_next_morning(self):
        t = datetime(2026, 9, 15, 23, 30, tzinfo=EAT)
        nxt = next_send_time(t)
        assert nxt.hour == 7 and nxt.day == 16

    def test_early_morning_defers_to_same_day(self):
        t = datetime(2026, 9, 15, 3, 0, tzinfo=EAT)
        nxt = next_send_time(t)
        assert nxt.hour == 7 and nxt.day == 15


class TestGenderIsNeverWrong:
    def test_every_input_resolves_to_a_complete_set(self):
        for g in ALL_GENDER_INPUTS:
            p = pronouns_for(g)
            assert all([p.subject, p.object, p.possessive, p.is_are, p.has_have])

    def test_undisclosed_and_declined_are_indistinguishable(self):
        """If they differed, the message would leak which users had
        declined to answer."""
        assert pronouns_for(None) == pronouns_for("prefer_not_to_say")
        assert pronouns_for("") == pronouns_for("prefer_not_to_say")
        assert pronouns_for("banana") == pronouns_for("prefer_not_to_say")

    def test_verb_agreement_travels_with_the_pronoun(self):
        assert pronouns_for("male").is_are == "is"
        assert pronouns_for("prefer_not_to_say").is_are == "are"
        assert pronouns_for("prefer_not_to_say").has_have == "have"

    def test_no_template_pairs_a_name_with_pronoun_agreement(self):
        """Regression: template 7 originally read '{buyer} {is_are} asking',
        which renders 'Clinton are asking' for an undisclosed gender. A
        proper noun is always singular; pronoun-derived agreement is only
        valid where {subject} is the subject."""
        for i, t in enumerate(TEMPLATES):
            for verb in ("{is_are}", "{has_have}"):
                if verb in t:
                    before = t.split(verb)[0]
                    assert before.rstrip().endswith("{subject}"), (
                        f"template {i+1}: {verb} must directly follow {{subject}}, "
                        f"never a name"
                    )

    @pytest.mark.parametrize("gender", ALL_GENDER_INPUTS)
    def test_no_broken_agreement_in_any_rendered_message(self, gender):
        bad = ("Clinton are", "Clinton have", "they is", "they has",
               "he are", "she are", "he have", "she have")
        for seed in (f"s{i}" for i in range(60)):
            msg = compose_availability_nudge(
                seller_name="Xavier Bravin", buyer_name="Clinton", listing_name="gas cylinder",
                price=1500, buyer_gender=gender, seed=seed,
                when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
            for phrase in bad:
                assert phrase not in msg, f"{gender}: {phrase!r} in {msg!r}"


class TestComposition:
    def test_all_ten_variants_are_reachable(self):
        seen = set()
        for i in range(400):
            seen.add(compose_availability_nudge(
                seller_name="Xavier", buyer_name="Clinton", listing_name="gas cylinder",
                price=1500, seed=f"interest-{i}",
                when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT)))
        assert len(seen) == len(TEMPLATES)

    def test_same_seed_gives_the_same_message(self):
        """A retry must not produce a differently-worded second copy - the
        seller would read that as a second buyer."""
        kw = dict(seller_name="Xavier", buyer_name="Clinton", listing_name="gas cylinder",
                  price=1500, seed="interest-42",
                  when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
        assert compose_availability_nudge(**kw) == compose_availability_nudge(**kw)

    def test_missing_names_do_not_produce_empty_slots(self):
        msg = compose_availability_nudge(
            seller_name=None, buyer_name=None, listing_name="gas cylinder",
            when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
        assert "None" not in msg and "{" not in msg

    def test_missing_price_degrades_to_words(self):
        msg = compose_availability_nudge(
            seller_name="Xavier", buyer_name="Clinton", listing_name="x",
            price=None, seed="s2", when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
        assert "None" not in msg

    def test_long_listing_name_is_trimmed_not_the_call_to_action(self):
        msg = compose_availability_nudge(
            seller_name="Xavier", buyer_name="Clinton",
            listing_name="x" * 400, price=1500, seed="s3",
            when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
        assert len(msg) <= 306

    def test_every_message_identifies_zeno_and_broka(self):
        for i in range(40):
            msg = compose_availability_nudge(
                seller_name="Xavier", buyer_name="Clinton", listing_name="gas cylinder",
                price=1500, seed=f"i{i}", when=datetime(2026, 9, 15, 9, 0, tzinfo=EAT))
            assert "Zeno" in msg and "BROKA" in msg

    def test_valid_genders_constant_matches_the_resolver(self):
        assert set(VALID_GENDERS) == {"male", "female", "prefer_not_to_say"}
