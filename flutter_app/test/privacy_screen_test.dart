// The Privacy Policy screen is a real destination from the moment it is
// linked from sign-up - and until approved text exists it must say that it
// is a placeholder, not read like a published policy.
import 'package:broka/screens/privacy_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the screen renders the bundled document', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PrivacyScreen(animateBackground: false),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Privacy Policy'), findsOneWidget);
  });

  testWidgets('an unpublished policy is labelled as one', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: PrivacyScreen(animateBackground: false),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('has not been published yet'), findsOneWidget);
    expect(find.textContaining('Not yet published.', findRichText: true),
        findsWidgets);
  });
}
