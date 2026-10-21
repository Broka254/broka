// The Privacy Policy screen is a real destination from the moment it is
// linked from sign-up - and until approved text exists it must say that it
// is a placeholder, not read like a published policy.
//
// The bundled text is passed in directly: the screen's normal path loads it
// from the asset bundle, and a FutureBuilder over the cached future adds a
// spinner and a frame of asynchrony that made this test depend on test
// ordering instead of on the screen.
import 'dart:io';

import 'package:broka/screens/privacy_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpDocument(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: PrivacyScreen(
      animateBackground: false,
      documentText: File(PrivacyScreen.asset).readAsStringSync(),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('the screen renders the bundled document', (tester) async {
    await _pumpDocument(tester);
    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('an unpublished policy is labelled as one', (tester) async {
    await _pumpDocument(tester);
    // skipOffstage: false: the assertion is about what the screen says, not
    // about where the sliver currently sits in the viewport.
    expect(find.byKey(const Key('legal-notice'), skipOffstage: false),
        findsOneWidget);
    expect(
        find.textContaining('has not been published yet', skipOffstage: false),
        findsOneWidget);
    expect(
        find.textContaining('Not yet published.',
            findRichText: true, skipOffstage: false),
        findsWidgets);
  });
}
