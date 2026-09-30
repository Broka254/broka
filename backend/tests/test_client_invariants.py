"""Static guards on the Flutter client, run by the suite that actually executes.

The Dart side has no test runner in CI - `flutter analyze` gates on
compilation, not behaviour - so a Dart test asserting these would be a test
nobody runs. These are text-level checks on the client source, executed by
pytest, which does run.

They are deliberately narrow. A grep cannot verify that a map shows the
right position or that a call screen tells the truth; it can only refuse to
let three specific, expensive regressions come back silently. Each one below
shipped to a user and was reported from a screenshot:

  1. `Image.network` on a `profile_photo`. That field is inline base64
     everywhere in this codebase. `Image.network` fails on it every time and
     falls through `errorBuilder` to initials, so the call screen showed
     "XB" for weeks while looking, from the outside, exactly like a change
     that was never made.
  2. The map treating `ApiService.currentUserLat/Lng` as the user's
     position. Those are written at REGISTRATION and never move - a user who
     signed up in Nairobi and travelled to Juja got a pin on Kenyatta Avenue
     and "0 m away".
  3. The call screen asserting a phone is ringing. `calling` means our offer
     was sent, not that anyone received it; claiming otherwise left callers
     holding the phone to their ear for someone the app knew was offline.

The common thread is the same in all three: the UI asserted something the
app had not observed. That is the class of bug, not the individual lines.
"""
import pathlib
import re

import pytest

LIB = pathlib.Path(__file__).resolve().parents[2] / "flutter_app" / "lib"

pytestmark = pytest.mark.skipif(
    not LIB.exists(),
    reason="flutter_app/lib not present (backend-only checkout)",
)


def _dart_sources():
    return sorted(LIB.rglob("*.dart"))


def _code_only(src: str) -> str:
    """Strip // comments.

    Needed because these files explain the bugs they fix, quoting the exact
    strings involved. Scanning raw source makes a comment describing a
    regression indistinguishable from the regression - the first version of
    this test failed on its own documentation.
    """
    return re.sub(r"//[^\n]*", "", src)


def test_profile_photos_are_not_loaded_as_urls():
    """profile_photo / peerPhoto is base64 - decode it, don't fetch it."""
    offenders = []
    for path in _dart_sources():
        lines = path.read_text().split("\n")
        for i, line in enumerate(lines, 1):
            if "//" in line and line.strip().startswith("//"):
                continue
            if "Image.network(" not in line:
                continue
            window = "\n".join(lines[max(0, i - 3): i + 2])
            if any(tok in window for tok in
                   ("profile_photo", "peerPhoto", "_peerPhoto",
                    "counterPhoto", "_sellerPhoto", "_counterpartyPhoto")):
                offenders.append(f"{path.relative_to(LIB)}:{i}")
    assert not offenders, (
        "Image.network used on a profile photo:\n  " + "\n  ".join(offenders)
        + "\n\nprofile_photo is inline base64, not a URL. Use "
          "Image.memory(base64Decode(photo)) with a try/catch - base64Decode "
          "throws rather than routing through errorBuilder. Image.network "
          "fails silently here, which is why the last one survived a release."
    )


def test_map_does_not_present_the_signup_coordinate_as_your_position():
    """The map must take a live fix, not the stored session coordinate."""
    src = (LIB / "screens" / "listing_map_screen.dart").read_text()
    assert "Geolocator.getCurrentPosition" in src, (
        "listing_map_screen no longer takes a live location fix. "
        "ApiService.currentUserLat/Lng come from SharedPreferences and are "
        "written at registration - they are not where the user is, and "
        "rendering them as the 'You' pin is how this screen came to show a "
        "Nairobi pin to a user in Juja."
    )


def test_call_screen_checks_presence_before_claiming_a_phone_is_ringing():
    """'Their phone is ringing' needs evidence the far end was reached."""
    src = _code_only((LIB / "screens" / "voip_call_screen.dart").read_text())
    assert "_peerOnline" in src, (
        "voip_call_screen no longer consults peer presence. CallState.calling "
        "means our offer was SENT, not received - asserting a ringing phone "
        "from it alone is a claim the app cannot support."
    )
    ringing_claim = "Their phone is ringing"
    if ringing_claim in src:
        idx = src.index(ringing_claim)
        guard_window = src[max(0, idx - 400): idx]
        assert "_peerOnline" in guard_window, (
            "'Their phone is ringing' is stated without a presence check "
            "nearby. Gate it on _peerOnline so an offline peer gets an "
            "honest label instead."
        )


def test_active_thread_suppression_is_wired_from_both_chat_screens():
    """Both conversation screens must register with the poller.

    negotiation_screen always did; negotiate_screen never did, which is why
    reading a Zeno reply produced a notification for it seconds later. The
    call has to exist on both, and be symmetric - a thread left registered
    never notifies again.
    """
    for name in ("negotiate_screen.dart", "negotiation_screen.dart"):
        src = (LIB / "screens" / name).read_text()
        assert "markScreenActive" in src, (
            f"{name} does not register its thread as on-screen; the poller "
            f"will notify about messages the user is currently reading"
        )
        assert "markScreenInactive" in src, (
            f"{name} registers its thread but never deregisters it - that "
            f"thread's notifications are suppressed permanently"
        )


def test_message_receipts_stay_legible():
    """Receipt ticks must not use textLow on the chat background.

    BrokaColors.textLow (#2E3D5A) against the chat background (#03040A)
    measures 1.88:1 - under the 3:1 minimum for a UI component that carries
    meaning. `sent` and `delivered`, the two states checked most often, were
    drawn in it, so the honest four-state ladder underneath was being thrown
    away at the last step. textMid (#8A9BBF) measures 7.33:1.
    """
    src = _code_only((LIB / "widgets" / "message_receipt.dart").read_text())
    assert "textLow" not in src, (
        "message_receipt.dart uses BrokaColors.textLow. At 1.88:1 on the "
        "chat background the tick is effectively invisible - use textMid "
        "(7.33:1) for muted states."
    )


def test_receipts_do_not_promise_an_unimplemented_retry():
    """Don't offer a retry the app does not have.

    negotiation_screen's send path catches failures and leaves the
    optimistic bubble in place; nothing retries. A label saying otherwise is
    a worse lie than the silent grey tick it replaced.
    """
    receipt = _code_only((LIB / "widgets" / "message_receipt.dart").read_text())
    if "tap to retry" in receipt.lower():
        screen = _code_only((LIB / "screens" / "negotiation_screen.dart").read_text())
        assert "retry" in screen.lower(), (
            "the receipt offers 'tap to retry' but negotiation_screen "
            "implements no retry path"
        )



# What GET /auth/user/{id} is built from: the account's own or public dict,
# plus the dicts get_user_profile merges in for sellers - deal stats, the deal
# completion time, and the public standing.
_PROFILE_SOURCES = [
    pathlib.Path(__file__).resolve().parents[1] / "api" / rel
    for rel in ("domains/auth/service.py", "core/fraud.py",
                "domains/trust/deal_time.py", "domains/trust/public_standing.py")
]


@pytest.mark.parametrize("screen", ["seller_dashboard_screen", "user_profile_screen"])
def test_screens_only_read_profile_fields_the_api_sends(screen):
    """Every `_profile['key']` the seller dashboard and the profile screen
    read must exist.

    This is the check that would have caught three fabricated metrics.
    The dashboard read `reliability_score` and `response_rate`; neither has
    ever been a key in the profile payload. Both had `??` fallbacks, so
    instead of failing they rendered invented numbers - a constant "85%"
    response rate for every seller on the platform, and a "Reliability"
    score that was silently just the rating again under a second label.
    The profile screen carried the same two for longer, plus
    `pending_deals` and `avg_deal_time_minutes` before the API sent it.

    A missing key in Dart is `null`, and `null` plus a plausible default is
    indistinguishable from real data at a glance. That is what makes this
    worth a structural test rather than a code review.
    """
    source = (LIB / "screens" / f"{screen}.dart").read_text()
    payload = "\n".join(p.read_text() for p in _PROFILE_SOURCES)

    keys = set(re.findall(r"_profile\?\['([a-z_]+)'\]", _code_only(source)))
    assert keys, "no _profile reads found - the regex is stale, not the code"

    missing = sorted(k for k in keys if f'"{k}"' not in payload)
    assert not missing, (
        f"{screen} reads profile fields the auth service never "
        f"returns: {missing}\n\n"
        "In Dart these come back null, and a `?? <default>` next to one "
        "renders a fabricated figure that looks exactly like a real one. "
        "Either add the field to _user_dict, or drop the tile - do not give "
        "it a plausible default."
    )
