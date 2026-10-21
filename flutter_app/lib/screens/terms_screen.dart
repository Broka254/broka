// BROKA - Terms of Use and Service (2026-10-12).
//
// The text is assets/legal/terms.md, the one copy of the Terms: what the app
// shows is what the repository holds (TERMS.md points there). The renderer
// lives in widgets/legal_document_view.dart, shared with the Privacy Policy
// so both screens behave and look the same.
import 'package:flutter/material.dart';

import '../main.dart';
import '../widgets/legal_document_view.dart';

export '../widgets/legal_document_view.dart'
    show TermsBlock, TermsBlockKind, termsBlocks;

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key, this.animateBackground = true});

  static const asset = 'assets/legal/terms.md';
  static const gradient = [BrokaColors.neonPurple, BrokaColors.neonBlue];

  /// False under widget tests: the sky never settles.
  final bool animateBackground;

  @override
  Widget build(BuildContext context) => LegalDocumentScreen(
        asset: asset,
        title: 'Terms',
        emoji: '📜',
        gradient: gradient,
        animateBackground: animateBackground,
      );
}
