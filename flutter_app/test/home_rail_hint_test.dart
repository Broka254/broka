// The category rail's "there's more" hint (2026-09-26): people saw the first
// few categories and never realised the rail scrolled. Once per launch it
// glides far enough to show a couple more, pauses and glides back; a touch
// stops it; reduced motion skips it; a chevron stays until the end is seen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/home_screen.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    setFakeRoute(null);
    HomeScreen.railHintEnabled = true;
    HomeScreen.debugResetRailHint();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  ScrollPosition rail(WidgetTester tester) => tester
      .state<ScrollableState>(find.descendant(
          of: find.byKey(const Key('home-category-rail')), matching: find.byType(Scrollable)))
      .position;

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> openHome(WidgetTester tester, {bool reduceMotion = false}) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600)).copyWith(disableAnimations: reduceMotion),
        child: const HomeScreen(),
      ),
    ));
    await run(tester, const Duration(milliseconds: 300));
  }

  testWidgets('glides to show more categories, then back', (tester) async {
    await openHome(tester);
    expect(rail(tester).maxScrollExtent, greaterThan(0));
    expect(rail(tester).pixels, 0);

    await run(tester, const Duration(milliseconds: 1600));
    final revealed = rail(tester).pixels;
    expect(revealed, greaterThan(120), reason: 'enough to bring about two more categories in');

    await run(tester, const Duration(seconds: 2));
    expect(rail(tester).pixels, 0, reason: 'and home again');
  });

  testWidgets('once per launch, not on every return to Home', (tester) async {
    await openHome(tester);
    await run(tester, const Duration(seconds: 4));

    await tester.pumpWidget(const SizedBox());
    await openHome(tester);
    await run(tester, const Duration(seconds: 3));
    expect(rail(tester).pixels, 0);
  });

  testWidgets('a touch on the rail stops it where it is', (tester) async {
    await openHome(tester);
    await run(tester, const Duration(milliseconds: 1400));
    expect(rail(tester).pixels, greaterThan(0));

    await tester.drag(find.byKey(const Key('home-category-rail')), const Offset(-30, 0));
    final held = rail(tester).pixels;
    await run(tester, const Duration(seconds: 3));
    expect(rail(tester).pixels, closeTo(held, 60),
        reason: 'the user is in charge of the rail now - no glide back');
    expect(rail(tester).pixels, greaterThan(0));
  });

  testWidgets('reduced motion: no glide, the chevron still says there is more',
      (tester) async {
    await openHome(tester, reduceMotion: true);
    await run(tester, const Duration(seconds: 4));
    expect(rail(tester).pixels, 0);
    expect(find.byKey(const Key('home-rail-more')), findsOneWidget);
  });

  testWidgets('the chevron moves the rail on and goes once the end is reached',
      (tester) async {
    HomeScreen.railHintEnabled = false;
    await openHome(tester);
    AnimatedOpacity chevron() => tester.widget<AnimatedOpacity>(find
        .ancestor(of: find.byKey(const Key('home-rail-more')), matching: find.byType(AnimatedOpacity))
        .first);
    expect(chevron().opacity, 1);

    await tester.tap(find.byKey(const Key('home-rail-more')));
    await run(tester, const Duration(milliseconds: 600));
    expect(rail(tester).pixels, greaterThan(200));

    for (var i = 0; i < 6; i++) {
      await tester.tap(find.byKey(const Key('home-rail-more')), warnIfMissed: false);
      await run(tester, const Duration(milliseconds: 600));
    }
    expect(rail(tester).pixels, rail(tester).maxScrollExtent);
    expect(chevron().opacity, 0);
  });
}
