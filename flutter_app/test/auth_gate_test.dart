import 'package:broka/utils/auth_gate.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The "Create a free account" sheet (2026-10-14). It was a flat grey card
// with a flat blue button - two colours that exist nowhere else in BROKA -
// so it read as a system dialog dropped onto the app. It is now drawn on the
// same constellation sky as Home and Zeno's screens, with the brand-gradient
// button.
void main() {
  /// Opens the sheet from a button; [result] records what the caller got.
  Future<void> openSheet(WidgetTester tester, List<bool> result,
      {String reason = 'to open your menu'}) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => result.add(await requireAuth(context, reason: reason)),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('the sheet sits on the same constellation sky as the rest of BROKA', (tester) async {
    await openSheet(tester, []);
    expect(find.text('Create a free account to open your menu'), findsOneWidget);
    expect(find.byType(ConstellationBackground), findsOneWidget,
        reason: 'a flat card was the mismatch');
    expect(find.byKey(const Key('auth-gate-continue')), findsOneWidget);
    expect(find.text('Your phone number'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('"Not now" says no to the caller and closes the sheet', (tester) async {
    final result = <bool>[];
    await openSheet(tester, result);
    await tester.tap(find.byKey(const Key('auth-gate-not-now')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(result, [false]);
    expect(find.byType(ConstellationBackground), findsNothing);
  });

  testWidgets('a long reason and a small screen still fit - the sheet scrolls rather than overflows',
      (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await openSheet(tester, [], reason: 'to talk to Zeno about anything you need from BROKA');
    expect(tester.takeException(), isNull);
  });
}
