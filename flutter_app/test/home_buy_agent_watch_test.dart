// Home's "Zeno is watching for you" card can stop the watch (buying-agent
// review, 2026-09-26). Before this nothing in the app could cancel a watch,
// though Zeno told buyers to "cancel that one from the home screen".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/home_screen.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    clearFakeRequests();
    HomeScreen.railHintEnabled = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  tearDown(() => setFakeRoute(null));

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the watch card stops the watch, after asking', (tester) async {
    var cancelled = false;
    setFakeRoute((uri) {
      if (uri.path == '/buy-agent-requests/me') {
        return cancelled
            ? null
            : {
                'id': 'req-1', 'category': 'Electronics', 'max_price': 50000,
                'must_have_features': const [], 'status': 'matched', 'match_count': 2,
                'created_at': '2026-09-20T10:00:00',
              };
      }
      if (uri.path.startsWith('/buy-agent-requests/action')) {
        cancelled = true;
        return {'action': 'CANCEL_REQUEST', 'status': 'SUCCESS', 'request': {'status': 'cancelled'}};
      }
      return null;
    });

    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(data: MediaQueryData(size: Size(800, 1200)), child: HomeScreen()),
    ));
    await run(tester, const Duration(milliseconds: 400));
    expect(find.text('Zeno is watching for you'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop watching'));
    await run(tester, const Duration(milliseconds: 300));
    expect(find.text('Stop watching?'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await run(tester, const Duration(milliseconds: 400));

    final sent = fakeRequests
        .where((r) => r.uri.path.startsWith('/buy-agent-requests/action'))
        .map((r) => (r.json as Map)['action'])
        .toList();
    expect(sent, ['CANCEL_REQUEST']);
    expect(find.text('Zeno is watching for you'), findsNothing);
  });

  testWidgets('saying no leaves the watch running', (tester) async {
    setFakeRoute((uri) => uri.path == '/buy-agent-requests/me'
        ? {
            'id': 'req-1', 'category': 'Electronics', 'max_price': 50000,
            'must_have_features': const [], 'status': 'active', 'match_count': 0,
          }
        : null);
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(data: MediaQueryData(size: Size(800, 1200)), child: HomeScreen()),
    ));
    await run(tester, const Duration(milliseconds: 400));
    await tester.tap(find.byTooltip('Stop watching'));
    await run(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Keep watching'));
    await run(tester, const Duration(milliseconds: 300));

    expect(fakeRequests.where((r) => r.uri.path.startsWith('/buy-agent-requests/action')), isEmpty);
    expect(find.text('Zeno is watching for you'), findsOneWidget);
  });
}
