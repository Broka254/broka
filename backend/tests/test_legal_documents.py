"""The app and the backend must be talking about the same legal documents.

`backend/api/core/legal_documents.py` pins the versions and the SHA-256 of
each asset, and `flutter_app/lib/core/legal/legal_documents.dart` is what
the app shows and submits. Nothing connects them at runtime - the app is an
APK on someone's phone - so this test is the connection: a text edit, a
version bump or a reworded declaration that is not mirrored in both places
fails here instead of producing acceptance evidence for a document nobody
saw.

The privacy policy is deliberately still a placeholder. `published: false`
is a release blocker, not a passing state: the marker check below makes
sure an unpublished document is visibly unpublished, and the final report
marks the release as blocked on approved policy text.
"""
from __future__ import annotations

import hashlib
import pathlib
import re
from datetime import datetime

import pytest

from api.core.legal_documents import PRIVACY, TERMS

ROOT = pathlib.Path(__file__).resolve().parents[2]
DART = ROOT / "flutter_app" / "lib" / "core" / "legal" / "legal_documents.dart"

pytestmark = pytest.mark.skipif(
    not DART.exists(),
    reason="flutter_app not present (backend-only checkout)",
)

REQUIRED_AGE = (
    "I confirm that I am at least 18 years old and eligible to use BROKA "
    "under its Terms of Use and Service."
)
REQUIRED_TERMS_PREFIX = "I agree to BROKA's "
REQUIRED_TERMS_LINK = "Terms of Use and Service"
REQUIRED_PRIVACY_PREFIX = "I acknowledge that I have read BROKA's "
REQUIRED_PRIVACY_LINK = "Privacy Policy"


def _dart() -> str:
    return DART.read_text(encoding="utf-8")


def _dart_document(name: str) -> dict:
    text = _dart()
    block = re.search(
        rf"static const {name} = LegalDocument\((.*?)\n  \);", text, re.S,
    )
    assert block, f"LegalDocuments.{name} is not a LegalDocument literal"
    body = block.group(1)
    fields = dict(re.findall(r"(\w+): '([^']*)'", body))
    # `asset` names a shared file-scope constant rather than repeating the
    # path, so resolve it here.
    asset_ref = re.search(r"asset: (\w+)", body)
    if asset_ref:
        declaration = re.search(
            rf"static const {asset_ref.group(1)} = '([^']*)'", text,
        )
        assert declaration, f"{asset_ref.group(1)} is not a string constant"
        fields["asset"] = declaration.group(1)
    published = re.search(r"published: (true|false)", body)
    assert published, f"{name}.published is missing"
    return {**fields, "published": published.group(1) == "true"}


def _dart_string(const: str) -> str:
    """A Dart string constant, allowing adjacent-literal concatenation."""
    m = re.search(rf"static const {const} =\s*(.*?);", _dart(), re.S)
    assert m, f"LegalDocuments.{const} is missing"
    parts = re.findall(r"'([^']*)'", m.group(1))
    assert parts, f"LegalDocuments.{const} is not a single-quoted literal"
    return "".join(parts)


def _asset(doc) -> pathlib.Path:
    path = ROOT / doc.asset_path
    assert path.exists(), f"{doc.asset_path} is missing; the screen would show nothing"
    return path


def test_the_app_and_backend_agree_on_ids_versions_and_assets():
    for doc, name in ((TERMS, "terms"), (PRIVACY, "privacy")):
        dart = _dart_document(name)
        assert dart["key"] == doc.key
        assert f"flutter_app/{dart['asset']}" == doc.asset_path
        assert dart["version"] == doc.version, (
            f"{name}: app shows {dart['version']!r}, backend accepts {doc.version!r}"
        )
        assert dart["published"] is doc.published


def test_a_published_document_matches_its_pinned_digest_and_date():
    for doc in (TERMS, PRIVACY):
        if not doc.published:
            continue
        asset = _asset(doc)
        digest = hashlib.sha256(asset.read_bytes()).hexdigest()
        assert digest == doc.digest, (
            f"{doc.asset_path} has changed since its version was pinned. "
            "Update the document's last-updated date, its version and digest "
            "here and in legal_documents.dart together."
        )
        text = asset.read_text(encoding="utf-8")
        updated = re.search(r"_Last updated:\s*(\d{1,2}) (\w+) (\d{4})_", text)
        assert updated, f"{doc.asset_path} has no '_Last updated: ..._' line"
        day, month, year = updated.groups()
        parsed = datetime.strptime(f"{day} {month} {year}", "%d %B %Y").date()
        assert parsed.isoformat() == doc.version, (
            f"{doc.asset_path} says it was last updated {parsed.isoformat()}, "
            f"but the accepted version is {doc.version}"
        )


def test_an_unpublished_document_says_so_and_claims_no_digest():
    for doc in (TERMS, PRIVACY):
        if doc.published:
            continue
        text = _asset(doc).read_text(encoding="utf-8")
        assert "Not yet published." in text, (
            f"{doc.asset_path} is not published but does not say so. Do not "
            "replace the marker with a fabricated policy."
        )
        assert doc.digest == "", (
            "An unpublished document has no revision to pin; add the digest "
            "when the approved text is supplied."
        )


def test_no_public_url_is_claimed_for_a_document_that_is_not_published_there():
    for doc in (TERMS, PRIVACY):
        assert doc.public_url is None or doc.public_url.startswith("https://")
        if doc.public_url is not None:
            assert doc.published, (
                f"{doc.key} points at {doc.public_url} but is marked unpublished"
            )


def test_the_signup_declarations_are_the_approved_words():
    assert _dart_string("ageDeclaration") == REQUIRED_AGE
    assert _dart_string("termsPrefix") == REQUIRED_TERMS_PREFIX
    assert _dart_string("termsLink") == REQUIRED_TERMS_LINK
    assert _dart_string("termsSuffix") == "."
    assert _dart_string("privacyPrefix") == REQUIRED_PRIVACY_PREFIX
    assert _dart_string("privacyLink") == REQUIRED_PRIVACY_LINK
    assert _dart_string("privacySuffix") == "."


def test_both_assets_are_bundled():
    pubspec = (ROOT / "flutter_app" / "pubspec.yaml").read_text(encoding="utf-8")
    for doc in (TERMS, PRIVACY):
        asset = doc.asset_path.split("flutter_app/", 1)[1]
        assert f"- {asset}" in pubspec, f"{asset} is not listed under assets:"
