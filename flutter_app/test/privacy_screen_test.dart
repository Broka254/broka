// The Privacy Policy screen is a real destination from the moment it is
// linked from sign-up - and until approved text exists it must say that it
// is a placeholder, not read like a published policy.
//
// Fixed pumps rather than pumpAndSettle: while the asset is loading the
// screen shows a CircularProgressIndicator, and an unsettled spinner makes
// pumpAndSettle wait until it times out instead of asserting anything.
import 'package:broka/screens/privacy_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpDocument(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(
    home: PrivacyScreen(animateBackground: false),
  ));
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 32));
  }
}

void main() {
  testWidgets('the screen renders the bundled document', (tester) async {
    await _pumpDocument(tester);
    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('an unpublished policy is labelled as one', (tester) async {
    await _pumpDocument(tester);
    expect(find.textContaining('has not been published yet'), findsOneWidget);
    expect(find.textContaining('Not yet published.', findRichText: true),
        findsWidgets);
  });
}
