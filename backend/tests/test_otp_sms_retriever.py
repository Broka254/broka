"""Covers the OTP SMS body built for Android's SMS Retriever API.

The app-signature hash arrives from the client and is interpolated into a
message we then send to an arbitrary phone number, so the validation here is
a security boundary, not a formatting nicety: without it any caller could
push chosen text through the SMS gateway to any handset.
"""

import pytest

from api.domains.auth.service import _APP_SIGNATURE_RE, _build_otp_message

# A well-formed hash: 11 characters from the base64 alphabet.
VALID_SIG = "FA+9qCX9VSu"


class TestPlainMessage:
    def test_no_signature_keeps_the_original_wording(self):
        msg = _build_otp_message("123456", None)
        assert msg == (
            "123456 is your BROKA verification code. "
            "It expires in 5 minutes. Don't share it with anyone."
        )

    def test_no_signature_has_no_retriever_prefix(self):
        # iOS and older clients must not receive the "<#>" marker, which is
        # meaningless to them and just looks like noise in the message.
        assert not _build_otp_message("123456", None).startswith("<#>")

    def test_empty_string_signature_is_treated_as_absent(self):
        assert _build_otp_message("123456", "") == _build_otp_message("123456", None)


class TestRetrieverMessage:
    def test_has_the_required_prefix_code_and_trailing_hash(self):
        msg = _build_otp_message("123456", VALID_SIG)
        assert msg.startswith("<#> ")
        assert "123456" in msg
        assert msg.endswith(VALID_SIG)

    def test_hash_sits_on_its_own_final_line(self):
        msg = _build_otp_message("123456", VALID_SIG)
        assert msg.splitlines()[-1] == VALID_SIG

    def test_stays_within_the_140_byte_limit(self):
        # Over 140 bytes the Retriever silently never matches, which presents
        # as "autofill randomly doesn't work".
        assert len(_build_otp_message("123456", VALID_SIG).encode("utf-8")) <= 140

    def test_surrounding_whitespace_is_tolerated(self):
        assert _build_otp_message("123456", f"  {VALID_SIG}  ").endswith(VALID_SIG)


class TestSignatureValidation:
    @pytest.mark.parametrize(
        "bad",
        [
            "short",                       # too few characters
            "waytoolongsignature",         # too many
            "FA+9qCX9VS",                  # 10 — off by one
            "FA+9qCX9VSuX",                # 12 — off by one
            "FA 9qCX9VSu",                 # space
            "FA\n9qCX9VSu",                # newline: would forge a line break
            "http://evil",                 # a link someone would like injected
            "'; DROP TAB",                 # exactly 11 chars, but not base64
            "FA+9qCX9VSé",            # non-ASCII
        ],
    )
    def test_malformed_signatures_fall_back_to_the_plain_message(self, bad):
        msg = _build_otp_message("123456", bad)
        assert msg == _build_otp_message("123456", None)
        assert bad not in msg

    def test_injected_newline_cannot_add_a_line_to_the_sms(self):
        msg = _build_otp_message("123456", "AAAA\nBBBBB")
        assert len(msg.splitlines()) == 1

    def test_regex_accepts_the_full_base64_alphabet(self):
        assert _APP_SIGNATURE_RE.match("aZ09+/=aZ09")

    def test_a_valid_signature_is_not_rejected(self):
        assert _build_otp_message("123456", VALID_SIG) != _build_otp_message("123456", None)


class TestCodeLengths:
    @pytest.mark.parametrize("code", ["1234", "123456", "12345678"])
    def test_other_code_lengths_still_fit(self, code):
        assert len(_build_otp_message(code, VALID_SIG).encode("utf-8")) <= 140
