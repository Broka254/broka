// The splash plays its boot sequence once, the first time BROKA opens on a
// phone; after that the app opens straight onto Home (2026-10-09). It used
// to play ten seconds of it, with a chime, on every launch.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/home_screen.dart';
import 'package:broka/screens/splash_screen.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);
  setUp(() => HomeScreen.railHintEnabled = false);

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Widget app() => const MaterialApp(
        home: MediaQuery(data: MediaQueryData(size: Size(800, 1200)), child: SplashScreen()),
      );

  testWidgets('the first launch plays the sequence, and remembers it did', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(app());
    await run(tester, const Duration(milliseconds: 600));
    expect(find.text('BOOTING ZENO'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    // No sound, no sound switch.
    expect(find.text('SOUND ON'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SplashScreen.introSeenKey), isTrue);

    // Shorter than it was: Home within five seconds, not ten.
    await run(tester, const Duration(milliseconds: 5000));
    expect(find.byType(HomeScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await run(tester, const Duration(milliseconds: 300));
  });

  testWidgets('every launch after that goes straight to Home', (tester) async {
    SharedPreferences.setMockInitialValues({SplashScreen.introSeenKey: true});
    await tester.pumpWidget(app());
    await run(tester, const Duration(milliseconds: 400));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('BOOTING ZENO'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await run(tester, const Duration(milliseconds: 300));
  });
}
