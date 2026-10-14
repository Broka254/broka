"""
Tests for the AI cost controls (api/core/ai_cost.py).

The safety property that matters: the pre-filter must only ever suppress a
relay, never cause one. `_classify_relay` already fails closed on error,
malformed output and ambiguity, so a pre-filter false-positive lands in an
outcome the system already handles. A false *negative* just costs one
cheap call. Every test below is oriented around keeping that asymmetry.
"""
import pytest

from api.core.ai_cost import (
    AISavings, classification_cache_key, is_cacheable_for_classification,
    is_trivially_private,
)


class TestPrefilterSuppressesOnlyTheObvious:
    @pytest.mark.parametrize("msg", [
        "ok", "Okay", "OK!", "thanks", "Thanks bro", "asante", "Asante sana",
        "hi", "Hello", "Good morning", "habari", "sawa", "sawa sana",
        "yes", "ndio", "no", "poa", "noted", "cool", "bye", "👍", "🙏🏽",
        "!!!", "   ", "",
    ])
    def test_acknowledgements_skip_the_model(self, msg):
        assert is_trivially_private(msg) is True


class TestPrefilterNeverSwallowsRealContent:
    @pytest.mark.parametrize("msg", [
        "is it still available?",
        "still available",
        "how much?",
        "2000",
        "ok 1500",                 # acknowledgement + a price
        "sawa, 2000",
        "can you deliver",
        "what colour is it",
        "good condition?",
        "where are you located",
        "iko bado?",
        "bei gani",
        "ok deliver it tomorrow morning please",
        "is the seller legit",     # private, but the MODEL must decide
    ])
    def test_anything_with_content_reaches_the_model(self, msg):
        assert is_trivially_private(msg) is False

    def test_a_digit_always_defeats_the_prefilter(self):
        """A number is almost always a price offer, which IS relay-worthy.
        This is the escape hatch that stops 'ok 1500' being swallowed."""
        for msg in ("ok 1", "yes 2000", "sawa 500", "thanks 99"):
            assert is_trivially_private(msg) is False

    def test_long_messages_always_reach_the_model(self):
        assert is_trivially_private("ok " * 40) is False


class TestClassificationCacheKey:
    def test_key_is_stable_under_formatting_noise(self):
        a = classification_cache_key("Is it  STILL available? ", "buyer", "seller")
        b = classification_cache_key("is it still available?", "buyer", "seller")
        assert a == b

    def test_roles_are_part_of_the_key(self):
        """The prompt is written per-direction, so a buyer->seller verdict
        must not be served for a seller->buyer message."""
        a = classification_cache_key("is it available?", "buyer", "seller")
        b = classification_cache_key("is it available?", "seller", "buyer")
        assert a != b

    def test_different_content_gives_different_keys(self):
        a = classification_cache_key("how much?", "buyer", "seller")
        b = classification_cache_key("can you deliver?", "buyer", "seller")
        assert a != b

    def test_prompt_version_is_in_the_key(self):
        """Bumping the version must retire every cached entry - otherwise a
        prompt change silently keeps serving verdicts computed under the
        old rules."""
        import api.core.ai_cost as mod
        original = mod._CLASSIFIER_PROMPT_VERSION
        before = classification_cache_key("how much?", "buyer", "seller")
        mod._CLASSIFIER_PROMPT_VERSION = "v2"
        try:
            after = classification_cache_key("how much?", "buyer", "seller")
        finally:
            mod._CLASSIFIER_PROMPT_VERSION = original
        assert before != after

    def test_only_short_messages_are_cached(self):
        assert is_cacheable_for_classification("how much?") is True
        assert is_cacheable_for_classification("x" * 500) is False
        assert is_cacheable_for_classification("") is False


class TestSavingsSnapshot:
    def test_snapshot_shape_and_zero_division(self):
        snap = AISavings.snapshot()
        for k in ("classification_calls_avoided_by_prefilter",
                  "classification_calls_avoided_by_cache",
                  "classification_calls_made",
                  "classification_requests_total",
                  "avoided_fraction"):
            assert k in snap
        assert isinstance(snap["avoided_fraction"], float)
