"""The legal documents a new BROKA account must accept, and the versions
this backend accepts.

The app and this module must agree on two things: the documents, and the
exact revision a registration is accepting. The app's copy lives in
`flutter_app/assets/legal/` and is compiled into the APK; this module holds
the same ids and versions so a request can be checked without trusting the
client's claim that some text was read.

  * `version` is the document's own "last updated" date, not a number this
    code invents. The Terms already carry one (12 October 2026); editing
    the text without changing that date is a new revision under the same
    name, so `tests/test_legal_documents.py` also pins the SHA-256 of every
    asset. Change the text, and that test fails until the version and
    digest here and in `flutter_app/lib/core/legal/legal_documents.dart`
    are updated together.
  * `published` says whether the document has actually been approved and
    can be put in front of a user. The Privacy Policy has not been
    supplied yet - the placeholder is deliberate, and
    `tests/test_legal_documents.py` requires an unpublished document to say
    so in its own text and forbids pinning a digest to it. That keeps the
    gap visible; it cannot tell an approved policy from a convincing fake.

The age declaration is versioned here rather than in a document: the user
confirms eligibility, which is not a verified age. Recorded as an explicit
declaration, never as proof.
"""
from __future__ import annotations

from dataclasses import dataclass

# The version of the eligibility wording the app shows. Bump only when the
# sentence itself changes; it is what "I confirmed I am 18+" meant at the
# time the account was made.
AGE_DECLARATION_VERSION = "1"
AGE_ACCEPTANCE_TYPE = "age_confirmed"
AGE_DOCUMENT_ID = "age_eligibility"


@dataclass(frozen=True)
class LegalDocument:
    key: str                 # request field prefix: terms_version, privacy_version
    acceptance_type: str     # legal_acceptances.acceptance_type
    document_id: str         # stable id of the document, not of the revision
    version: str             # the revision a new registration must accept
    asset_path: str          # repo-relative; read by the drift test, never at runtime
    digest: str              # SHA-256 of that asset's bytes ("" while unpublished)
    public_url: str | None   # where this exact revision is published, if anywhere
    published: bool          # False until the approved text exists


TERMS = LegalDocument(
    key="terms",
    acceptance_type="terms_accepted",
    document_id="terms_of_use_and_service",
    # From the document's own "_Last updated: 12 October 2026_" line.
    version="2026-10-12",
    asset_path="flutter_app/assets/legal/terms.md",
    digest="e0b88719d600037f99ed6ca6b2e80bf0e9a8cbfa25e6f2074b040b3c7387ec88",
    # The public www.broka.co.ke/terms page is the WEBSITE's terms and says
    # so: "Using the BROKA mobile app is covered by the terms you accept
    # when you sign up there." It is not this document, so no URL is
    # claimed here until the app's Terms have their own page. See
    # LEGAL_ACCEPTANCE.md.
    public_url=None,
    published=True,
)

PRIVACY = LegalDocument(
    key="privacy",
    acceptance_type="privacy_acknowledged",
    document_id="privacy_policy",
    # Not a date: there is no approved policy yet. This value is what the
    # app sends and what the backend records, and the release is blocked
    # until it becomes a real revision (see LEGAL_ACCEPTANCE.md).
    version="unpublished",
    asset_path="flutter_app/assets/legal/privacy.md",
    digest="",
    public_url=None,
    published=False,
)

CURRENT_DOCUMENTS: dict[str, LegalDocument] = {d.key: d for d in (TERMS, PRIVACY)}


class LegalAcceptanceError(ValueError):
    """A registration's legal declarations are not acceptable.

    The message is written for the person in the app; the auth router turns
    it into a 422 body rather than a Pydantic field dump.
    """


def check_signup_acceptance(
    *,
    age_confirmed: bool,
    terms_accepted: bool,
    privacy_acknowledged: bool,
    terms_version: str,
    privacy_version: str,
) -> None:
    """Refuse a registration that has not accepted the current documents.

    Called before any row is written. Omitted fields never reach here -
    Pydantic requires them - so this only sees explicit values, and a
    `False` is a refusal, not a default.
    """
    if not age_confirmed:
        raise LegalAcceptanceError(
            "Confirm that you are at least 18 years old before creating a BROKA account."
        )
    if not terms_accepted:
        raise LegalAcceptanceError(
            "Agree to BROKA's Terms of Use and Service before creating an account."
        )
    if not privacy_acknowledged:
        raise LegalAcceptanceError(
            "Acknowledge BROKA's Privacy Policy before creating an account."
        )
    if terms_version != TERMS.version:
        raise LegalAcceptanceError(
            "BROKA's Terms of Use and Service have been updated. Open them, read the "
            "current version and agree to it to continue."
        )
    if privacy_version != PRIVACY.version:
        raise LegalAcceptanceError(
            "BROKA's Privacy Policy has been updated. Open it, read the current version "
            "and acknowledge it to continue."
        )
