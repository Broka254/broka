// How the app spaces its requests (polling-load pass, 2026-11-14).
//
//  * Delays are spread between phones (jitter), so a deploy, an outage or a
//    broadcast push no longer has every phone ask in the same second.
//  * While push reaches the phone and the inbox is quiet, the inbox is
//    fetched less often - but the incoming-call check keeps its pace: it is
//    how a call rings when its push is late.
//  * Losing push puts the sweep straight back to full speed.
import 'dart:convert';
import 'dart:math';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/network/poll_pacing.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('jitter', () {
    test('spreads a delay over ±20% and keeps its average', () {
      final random = Random(7);
      const base = Duration(seconds: 10);
      final values = [for (var i = 0; i < 2000; i++) jittered(base, random)];
      expect(
          values.every((d) => d >= const Duration(seconds: 8) && d <= const Duration(seconds: 12)),
          isTrue);
      final mean = values.fold<int>(0, (sum, d) => sum + d.inMicroseconds) / values.length;
      expect(mean, closeTo(base.inMicroseconds, base.inMicroseconds * 0.02));
      expect(values.toSet().length, greaterThan(1000), reason: 'not one shared beat');
    });

    test('nothing to spread stays nothing', () {
      expect(jittered(Duration.zero, Random(1)), Duration.zero);
      expect(upTo(Duration.zero, Random(1)), Duration.zero);
    });

    test('a spread-out wait stays within its bound', () {
      final random = Random(11);
      const bound = Duration(milliseconds: 1200);
      final waits = [for (var i = 0; i < 1000; i++) upTo(bound, random)];
      expect(waits.every((d) => d >= Duration.zero && d <= bound), isTrue);
      expect(waits.toSet().length, greaterThan(300));
    });

    test('a failure backoff gets up to a quarter more, the fast paces none', () {
      final random = Random(3);
      expect([failureSlackTicks(1, random), failureSlackTicks(2, random)], [0, 0]);
      expect({for (var i = 0; i < 300; i++) failureSlackTicks(4, random)}, {0, 1});
      expect({for (var i = 0; i < 300; i++) failureSlackTicks(8, random)}, {0, 1, 2});
    });
  });

  group('the inbox pace', () {
    int inbox({
      int call = 1,
      int quiet = 0,
      bool push = false,
      bool saver = false,
      bool failing = false,
    }) =>
        inboxTicksBetween(
            callTicks: call, quietSweeps: quiet, pushReady: push, dataSaver: saver, failing: failing);

    test('follows the call check without push, while failing, or while the inbox moves', () {
      expect(inbox(call: 1, quiet: 50), 1, reason: 'without push this is how messages arrive');
      expect(inbox(call: 8, quiet: 50, push: true, failing: true), 8);
      expect(inbox(call: 2, quiet: 11, push: true), 2);
    });

    test('stretches to 42 s (70 s with Data saver) once push is healthy and nothing moves', () {
      expect(inbox(call: 3, quiet: 12, push: true), 6);
      expect(inbox(call: 5, quiet: 40, push: true, saver: true), 10);
    });

    test('is never asked for more often than calls are checked', () {
      for (var call = 1; call <= 12; call++) {
        for (final quiet in [0, 4, 12, 100]) {
          for (final push in [false, true]) {
            for (final saver in [false, true]) {
              expect(inbox(call: call, quiet: quiet, push: push, saver: saver),
                  greaterThanOrEqualTo(call));
            }
          }
        }
      }
    });

    test('the incoming-call pace itself is unchanged', () {
      int calls({bool push = false, bool saver = false}) => GlobalPollerService.ticksBetweenSweeps(
          failedSweeps: 0, quietSweeps: 100, pushReady: push, dataSaver: saver);
      expect(calls(), 1, reason: 'every 7 s without push');
      expect(calls(push: true), 3, reason: 'at most 21 s with push');
      expect(calls(push: true, saver: true), 5);
    });
  });

  group('the sweep', () {
    late Future<http.Response> Function(http.Request) handler;
    final paths = <String>[];
    final mock = MockClient((req) {
      paths.add(req.url.path);
      return handler(req);
    });
    Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => mock);
    GlobalPollerService poller() => GlobalPollerService.instance;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-1',
        'user_id': 'seller-1',
        'global_poll_primed_v1': true,
      });
      ApiService.currentUserId = 'seller-1';
      await withClient(() async => apiClient.onUnauthorized = null);
      paths.clear();
      handler = (req) async {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const <Object>[]);
        if (req.url.path == '/calls/incoming') return _json({'has_call': false});
        return _json({'status': 'ok', 'push_enabled': true});
      };
      poller().stop();
      poller().firebaseReady = true;
      poller().fcmTokenProvider = () async => 'fcm-token-1';
      poller().pushTokenRegistrar =
          (token, {String tokenType = 'fcm', String? previousToken}) async => true;
    });

    tearDown(() {
      poller().stop();
      poller().firebaseReady = false;
      poller().fcmTokenProvider = null;
      poller().pushTokenRegistrar = null;
      ApiService.currentUserId = null;
    });

    test('between inbox fetches only the incoming-call check is asked for', () async {
      await withClient(() => poller().checkCallsOnly());
      expect(paths, ['/calls/incoming']);
    });

    test('losing push sweeps at once, at full speed', () async {
      await withClient(() async {
        poller().start();
        await poller().ensurePushRegistration();
        expect(poller().pushReady, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final fetched = paths.where((p) => p.startsWith('/negotiate/inbox/')).length;

        // The server stops pushing to this phone: the sweep is again how
        // messages and calls arrive.
        poller().pushReady = false;
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(paths.where((p) => p.startsWith('/negotiate/inbox/')).length, fetched + 1,
            reason: 'a sweep now, not after the idle pace push allowed');
        expect(poller().quietSweeps, 0);
      });
    });

    test('a nudge sweeps within its spread, and nudges meanwhile share it', () async {
      poller().nudgeSpread = const Duration(milliseconds: 40);
      addTearDown(() => poller().nudgeSpread = const Duration(milliseconds: 1200));
      await withClient(() async {
        poller().start();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final fetched = paths.where((p) => p.startsWith('/negotiate/inbox/')).length;
        poller().nudge();
        poller().nudge();
        poller().nudge();
        await Future<void>.delayed(const Duration(milliseconds: 120));
        expect(paths.where((p) => p.startsWith('/negotiate/inbox/')).length, fetched + 1);
      });
    });
  });
}
