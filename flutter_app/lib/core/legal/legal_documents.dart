// The legal documents the app shows, the revisions it submits, and the
// exact declarations a new account must make.
//
// One file, read by both the sign-up screen and the request body, so the
// version sent to the server is the version the user was actually shown.
// The backend keeps the same ids and versions in
// backend/api/core/legal_documents.py; tests/test_legal_documents.py reads
// this file and refuses a mismatch (including a text edit that leaves the
// version behind).
//
// `version` is the document's own last-updated date, not a number invented
// here. `unpublished` means there is no approved document yet - see
// LEGAL_ACCEPTANCE.md - and the release is blocked while it stays.
class LegalDocument {
  const LegalDocument({
    required this.key,
    required this.asset,
    required this.version,
    required this.published,
  });

  /// Matches the backend's request field prefix: `terms_version`, etc.
  final String key;

  /// Bundled Markdown, the same text the server's digest pins.
  final String asset;

  /// The revision a new registration accepts.
  final String version;

  /// False until the approved document exists. The placeholder screen says
  /// so instead of pretending to be a policy.
  final bool published;
}

class LegalDocuments {
  const LegalDocuments._();

  /// Bundled paths. Referenced by the screens and the tests that read the
  /// files from disk, so a rename is one change.
  static const termsAsset = 'assets/legal/terms.md';
  static const privacyAsset = 'assets/legal/privacy.md';

  static const terms = LegalDocument(
    key: 'terms',
    asset: termsAsset,
    version: '2026-10-12',
    published: true,
  );

  static const privacy = LegalDocument(
    key: 'privacy',
    asset: privacyAsset,
    version: 'unpublished',
    published: false,
  );

  /// Version of the age-eligibility wording below. A declaration is not a
  /// verified age; this records what was confirmed, not who is 18.
  static const ageDeclarationVersion = '1';

  // The declarations, in the exact words shown. The two linked phrases are
  // split out so the sentence can render a real, focusable link inside it
  // without the label text drifting from the request.
  static const ageDeclaration =
      'I confirm that I am at least 18 years old and eligible to use BROKA '
      'under its Terms of Use and Service.';

  static const termsPrefix = "I agree to BROKA's ";
  static const termsLink = 'Terms of Use and Service';
  static const termsSuffix = '.';

  static const privacyPrefix = "I acknowledge that I have read BROKA's ";
  static const privacyLink = 'Privacy Policy';
  static const privacySuffix = '.';
}

/// What a sign-up sends after all three declarations are ticked.
///
/// Constructed from the three booleans only; the versions always come from
/// [LegalDocuments], so the screen cannot submit a version it did not show.
class SignupDeclarations {
  const SignupDeclarations({
    required this.ageConfirmed,
    required this.termsAccepted,
    required this.privacyAcknowledged,
  });

  final bool ageConfirmed;
  final bool termsAccepted;
  final bool privacyAcknowledged;

  /// All three are required. Opening a document never sets a flag.
  bool get complete => ageConfirmed && termsAccepted && privacyAcknowledged;

  Map<String, dynamic> toJson() => {
        'age_confirmed': ageConfirmed,
        'terms_accepted': termsAccepted,
        'privacy_acknowledged': privacyAcknowledged,
        'terms_version': LegalDocuments.terms.version,
        'privacy_version': LegalDocuments.privacy.version,
      };
}
