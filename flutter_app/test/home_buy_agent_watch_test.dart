// Home's "Zeno is watching for you" card can stop the watch (buying-agent
// review, 2026-09-26). Before this nothing in the app could cancel a watch,
// though Zeno told buyers to "cancel that one from the home screen".
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/buy_agent/domain/models/buy_agent_request.dart';
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

  testWidgets('the watch card says how long the watch has left', (tester) async {
    // A naive-UTC timestamp, the way the backend writes them.
    final ends = DateTime.now().toUtc().add(const Duration(days: 12, hours: 3));
    final naive = ends.toIso8601String().replaceAll('Z', '');
    setFakeRoute((uri) => uri.path == '/buy-agent-requests/me'
        ? {
            'id': 'req-1', 'category': 'Electronics', 'max_price': 50000,
            'must_have_features': const [], 'status': 'active', 'match_count': 0,
            'expires_at': naive,
          }
        : null);
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(data: MediaQueryData(size: Size(800, 1200)), child: HomeScreen()),
    ));
    await run(tester, const Duration(milliseconds: 400));
    expect(find.text('13 days left'), findsOneWidget);
  });

  group('BuyAgentRequest.daysLeft', () {
    BuyAgentRequest ending(String? expiresAt) => BuyAgentRequest.fromJson({
          'id': 'r', 'category': 'Electronics', 'max_price': 1000,
          'status': 'active', if (expiresAt != null) 'expires_at': expiresAt,
        });
    final now = DateTime.utc(2026, 9, 26, 12);

    test('reads the backend\'s naive timestamp as UTC', () {
      // Read as local time instead (plain DateTime.tryParse), this would be
      // off by the device's offset - three hours in Nairobi, enough to end
      // a watch early on its last day. Asserted on the instant itself so
      // the test fails in any timezone, UTC included.
      final ends = ending('2026-10-26T12:00:00').expiresAt!;
      expect(ends.isUtc, isTrue);
      expect(ends, DateTime.utc(2026, 10, 26, 12));
      expect(ending('2026-10-26T12:00:00').daysLeft(now), 30);
    });
    test('a part day counts as a day', () {
      expect(ending('2026-09-26T17:00:00').daysLeft(now), 1);
      expect(ending('2026-09-28T13:00:00').daysLeft(now), 3);
    });
    test('past its date, or no date at all', () {
      expect(ending('2026-09-26T11:59:00').daysLeft(now), 0);
      expect(ending(null).daysLeft(now), isNull);
    });
  });
}
