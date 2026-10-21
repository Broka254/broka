// BROKA - Privacy Policy (assets/legal/privacy.md).
//
// Same screen, navigation and typography as the Terms (see
// screens/terms_screen.dart): one reader for both legal documents.
//
// There is no approved Privacy Policy yet. The bundled file is a
// placeholder that says so; this screen adds the same warning at the top
// so it cannot be mistaken for the published policy, and
// backend/tests/test_legal_documents.py refuses to let it pass as one. The
// release is blocked until approved text replaces it - see
// LEGAL_ACCEPTANCE.md.
import 'package:flutter/material.dart';

import '../core/legal/legal_documents.dart';
import '../main.dart';
import '../widgets/legal_document_view.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key, this.animateBackground = true});

  static const asset = LegalDocuments.privacyAsset;
  static const gradient = [BrokaColors.neonBlue, BrokaColors.neonGreen];

  /// False under widget tests: the sky never settles.
  final bool animateBackground;

  @override
  Widget build(BuildContext context) => LegalDocumentScreen(
        asset: asset,
        title: 'Privacy',
        emoji: '🔒',
        gradient: gradient,
        animateBackground: animateBackground,
        notice: LegalDocuments.privacy.published
            ? null
            : "BROKA's app Privacy Policy has not been published yet. This "
                'page is a placeholder, not the policy.',
      );
}
