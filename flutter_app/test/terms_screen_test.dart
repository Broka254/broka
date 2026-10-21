// The Terms of Use (assets/legal/terms.md) as the app shows them.
import 'dart:io';

import 'package:broka/screens/terms_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the bundled Terms parse into headings, paragraphs and bullets', () {
    final blocks = termsBlocks(File(TermsScreen.asset).readAsStringSync());
    expect(blocks.first.kind, TermsBlockKind.title);
    final headings = [for (final b in blocks) if (b.kind == TermsBlockKind.heading) b.text];
    expect(headings, contains('8. Fees and paid plans'));
    expect(headings, contains('9. Prohibited items and conduct'));
    expect(blocks.where((b) => b.kind == TermsBlockKind.bullet), isNotEmpty);
    // A wrapped paragraph is one block, not one per source line.
    expect(blocks.any((b) => b.text.startsWith('BROKA is not the buyer or the seller')), isFalse);
    expect(blocks.any((b) => b.text.startsWith('**BROKA is not the buyer or the seller.** Items')), isTrue);
  });

  test('a bullet ends where the next one starts', () {
    final blocks = termsBlocks('- one\n  continued\n- two\n\nAfter.');
    expect([for (final b in blocks) b.text], ['one continued', 'two', 'After.']);
    expect(blocks.last.kind, TermsBlockKind.paragraph);
  });

  testWidgets('the screen shows the Terms', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: TermsScreen(animateBackground: false)));
    // Fixed pumps, not pumpAndSettle: the screen shows a CircularProgressIndicator
    // while the bundled asset loads, and an unsettled spinner would make
    // pumpAndSettle time out rather than reach the document.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 32));
    }
    expect(find.text('Terms of Use and Service'), findsOneWidget);
  });
}
