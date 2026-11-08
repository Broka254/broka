// What the app no longer downloads or sends on mobile data
// (mobile-data pass, 2026-11-07).
//
//  * The background sweep backs off when it can't reach the server, and
//    idles once push is connected and nothing is changing.
//  * The direct chat's fallback poll slows while the thread stays quiet,
//    and asks conditionally: an unchanged thread is an empty 304.
//  * The chat header refreshes presence alone, not the whole profile.
//  * Large JPEGs are shrunk to the size the server keeps before upload.
//  * Inline pictures are decoded once, not on every rebuild.
//  * ApiClient's requests are counted once, not twice.
//  * Data saver is a switch in Settings, kept on the phone.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/core/network/data_saver.dart';
import 'package:broka/core/network/instrumented_client.dart';
import 'package:broka/core/network/network_stats.dart';
import 'package:broka/screens/negotiation_screen.dart' show directChatPollTicksBetween;
import 'package:broka/screens/settings_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/upload_shrink.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

http.Response _json(Object? body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'global_poll_primed_v1': true});
    ApiService.currentUserId = 'u1';
  });

  // ── The background sweep ──────────────────────────────────────────────────

  group('the sweep pace', () {
    int ticks({int failed = 0, int quiet = 0, bool push = false, bool saver = false}) =>
        GlobalPollerService.ticksBetweenSweeps(
            failedSweeps: failed, quietSweeps: quiet, pushReady: push, dataSaver: saver);

    test('backs off after failures: 7, 14, 28, then 56 seconds', () {
      expect([for (var f = 0; f <= 6; f++) ticks(failed: f)], [1, 1, 2, 4, 8, 8, 8]);
      // Failures win over everything else.
      expect(ticks(failed: 3, quiet: 20, push: true), 4);
    });

    test('idles only once push can reach the phone', () {
      expect(ticks(quiet: 50), 1, reason: 'without push, this sweep is how a call rings');
      expect([for (final q in [0, 3, 4, 11, 12, 40]) ticks(quiet: q, push: true)],
          [1, 1, 2, 2, 3, 3]);
      expect(ticks(quiet: 12, push: true, saver: true), 5);
    });

    group('counts what it saw', () {
      late http.Response Function(http.Request) route;
      final client = MockClient((req) async => route(req));
      Future<void> sweep() =>
          http.runWithClient(() => GlobalPollerService.instance.sweep(), () => client);

      setUp(() {
        GlobalPollerService.instance.stop();
        ApiService.currentUserId = 'u1';
      });
      tearDown(() => GlobalPollerService.instance.stop());

      test('a failure backs off, the next success is back to full speed', () async {
        route = (req) => req.url.path.startsWith('/negotiate/inbox/')
            ? _json({'detail': 'down'}, status: 503)
            : _json({'has_call': false});
        await sweep();
        await sweep();
        expect(GlobalPollerService.instance.failedSweeps, 2);

        route = (req) => req.url.path.startsWith('/negotiate/inbox/')
            ? _json(<Object>[], headers: {'etag': 'W/"a"'})
            : _json({'has_call': false});
        await sweep();
        expect(GlobalPollerService.instance.failedSweeps, 0);
      });

      test('an unchanged inbox (304) counts as quiet; a change resets it', () async {
        var changed = true;
        route = (req) {
          if (!req.url.path.startsWith('/negotiate/inbox/')) return _json({'has_call': false});
          if (!changed && req.headers['If-None-Match'] == 'W/"a"') {
            return http.Response('', 304, headers: {'etag': 'W/"a"'});
          }
          return _json(<Object>[], headers: {'etag': 'W/"a"'});
        };
        await sweep();
        expect(GlobalPollerService.instance.quietSweeps, 0);
        changed = false;
        await sweep();
        await sweep();
        expect(GlobalPollerService.instance.quietSweeps, 2);
        GlobalPollerService.instance.nudge();
        expect(GlobalPollerService.instance.quietSweeps, 0, reason: 'a push arrived');
      });
    });
  });

  // ── The direct chat ───────────────────────────────────────────────────────

  test("the chat's fallback poll slows while the thread is quiet", () {
    expect([for (var q = 0; q <= 12; q += 3) directChatPollTicksBetween(q)], [1, 2, 4, 8, 8]);
  });

  group('chat history', () {
    final requests = <http.Request>[];
    late http.Response Function(http.Request) route;
    final client = MockClient((req) async {
      requests.add(req);
      return route(req);
    });
    Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

    setUp(() {
      requests.clear();
      ApiService.clearHistoryCache();
    });

    final thread = [
      {'id': 'm1', 'role': 'buyer', 'content': 'Bei ya mwisho?', 'via_ai': false},
    ];

    test('an unchanged thread comes back as a 304 and the list already held', () async {
      route = (req) => req.headers['If-None-Match'] == 'W/"t1"'
          ? http.Response('', 304, headers: {'etag': 'W/"t1"'})
          : _json(thread, headers: {'etag': 'W/"t1"'});

      final first = await withClient(() => ApiService.getThreadHistory(listingId: 'l1'));
      expect(first.single.content, 'Bei ya mwisho?');
      expect(ApiService.lastHistoryNotModified, isFalse);

      final again = await withClient(
          () => ApiService.getThreadHistory(listingId: 'l1', conditional: true));
      expect(requests.last.headers['If-None-Match'], 'W/"t1"');
      expect(ApiService.lastHistoryNotModified, isTrue);
      expect(again.single.content, 'Bei ya mwisho?');
    });

    test('only conditional requests send the tag', () async {
      route = (req) => _json(thread, headers: {'etag': 'W/"t1"'});
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1'));
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1'));
      expect(requests.last.headers.containsKey('If-None-Match'), isFalse);
    });

    test("another account's copy is never used to answer", () async {
      route = (req) => req.headers['If-None-Match'] != null
          ? http.Response('', 304)
          : _json(thread, headers: {'etag': 'W/"t1"'});
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1'));
      ApiService.currentUserId = 'u2';
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1', conditional: true));
      expect(requests.last.headers.containsKey('If-None-Match'), isFalse);
      expect(ApiService.lastHistoryNotModified, isFalse);
    });

    test('a server that sends no tag is asked in full every time', () async {
      route = (req) => _json(thread);
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1'));
      await withClient(() => ApiService.getThreadHistory(listingId: 'l1', conditional: true));
      expect(requests.last.headers.containsKey('If-None-Match'), isFalse);
    });
  });

  group('presence', () {
    final requests = <http.Request>[];
    late http.Response Function(http.Request) route;
    final client = MockClient((req) async {
      requests.add(req);
      return route(req);
    });
    Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

    setUp(() {
      requests.clear();
      ApiService.resetPresenceRoute();
    });

    test('asks for presence alone', () async {
      route = (req) => _json({'id': 'p1', 'is_online': true, 'last_seen_label': 'Active now'});
      final presence = await withClient(() => ApiService.getUserPresence('p1'));
      expect(requests.single.url.path, '/auth/user/p1/presence');
      expect(presence!['is_online'], isTrue);
    });

    test('a server without the route is not asked again', () async {
      route = (req) => _json({'detail': 'Not Found'}, status: 404);
      expect(await withClient(() => ApiService.getUserPresence('p1')), isNull);
      expect(await withClient(() => ApiService.getUserPresence('p1')), isNull);
      expect(requests, hasLength(1));
    });

    test('a missing user or a failure is only this once', () async {
      route = (req) => _json({'detail': 'User not found'}, status: 404);
      expect(await withClient(() => ApiService.getUserPresence('p1')), isNull);
      route = (req) => _json({'detail': 'down'}, status: 503);
      expect(await withClient(() => ApiService.getUserPresence('p1')), isNull);
      route = (req) => _json({'id': 'p1', 'is_online': false});
      expect(await withClient(() => ApiService.getUserPresence('p1')), isNotNull);
      expect(requests, hasLength(3));
    });
  });

  // ── Uploads ───────────────────────────────────────────────────────────────

  group('photos before upload', () {
    Uint8List noisyJpeg(int width, int height) {
      final random = Random(7);
      final picture = img.Image(width: width, height: height);
      for (final p in picture) {
        p
          ..r = random.nextInt(256)
          ..g = random.nextInt(256)
          ..b = random.nextInt(256);
      }
      return img.encodeJpg(picture, quality: 95);
    }

    test('a large JPEG is made no bigger than the server keeps', () {
      final big = noisyJpeg(2400, 1350);
      final out = UploadShrink.shrinkJpeg(big)!;
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, UploadShrink.maxSide);
      expect(decoded.height, 900);
      expect(out.length, lessThan(big.length));
    });

    test('a tall one is bounded by its height', () {
      final out = UploadShrink.shrinkJpeg(noisyJpeg(900, 2000))!;
      final decoded = img.decodeJpg(out)!;
      expect(decoded.height, UploadShrink.maxSide);
      expect(decoded.width, 720);
    });

    test('a large JPEG is shrunk off the UI thread, end to end', () async {
      final big = noisyJpeg(2400, 1350);
      expect(big.length, greaterThan(UploadShrink.threshold));
      final out = await UploadShrink.forUpload(big);
      expect(out.length, lessThan(big.length));
      expect(img.decodeJpg(Uint8List.fromList(out))!.width, UploadShrink.maxSide);
    });

    test('small files, PNGs and things that are not pictures go as they are', () async {
      final small = noisyJpeg(64, 64);
      expect(identical(await UploadShrink.forUpload(small), small), isTrue);

      final png = img.encodePng(img.Image(width: 1200, height: 1200));
      final bigPng = Uint8List.fromList([...png, ...List<int>.filled(UploadShrink.threshold, 0)]);
      expect(identical(await UploadShrink.forUpload(bigPng), bigPng), isTrue,
          reason: 'a PNG may be a logo with transparency');

      final junk = Uint8List.fromList([0xFF, 0xD8, 0xFF, ...List<int>.filled(UploadShrink.threshold, 1)]);
      expect(identical(await UploadShrink.forUpload(junk), junk), isTrue,
          reason: 'what cannot be decoded is sent unchanged');
    });
  });

  // ── Pictures and requests ─────────────────────────────────────────────────

  test('an inline picture is decoded once, not on every rebuild', () {
    const pixel = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';
    final a = BrokaImage.inlineBytes(pixel);
    final b = BrokaImage.inlineBytes('data:image/png;base64,$pixel');
    expect(a, isNotNull);
    expect(identical(BrokaImage.inlineBytes(pixel), a), isTrue,
        reason: 'MemoryImage is keyed on the bytes object');
    expect(b, a);
  });

  test("ApiClient's requests are counted once inside the app's instrumented zone", () async {
    NetworkStats.instance.reset();
    final inner = MockClient((req) async => _json({'ok': true}));
    await http.runWithClient(() async {
      final api = ApiClient();
      await api.get('/health');
    }, () => InstrumentedClient(inner));
    expect(NetworkStats.instance.requestsTo('/health'), 1);
  });

  // ── Data saver ────────────────────────────────────────────────────────────

  group('Data saver', () {
    setUp(DataSaver.reset);
    tearDown(DataSaver.reset);

    test('is off until chosen, and is kept on the phone', () async {
      await DataSaver.load();
      expect(DataSaver.isOn, isFalse);
      await DataSaver.setEnabled(true);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('data_saver_on'), isTrue);

      DataSaver.reset();
      await DataSaver.load();
      expect(DataSaver.isOn, isTrue);
    });

    testWidgets('Settings has the switch', (tester) async {
      installFakeApi();
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen(animateBackground: false)));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 80));
      }
      final toggle = find.byKey(const Key('settings-data-saver-switch'));
      await tester.scrollUntilVisible(toggle, 200, scrollable: find.byType(Scrollable).first);
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isFalse);

      // Flipped as the switch flips it: the pinned header can sit over a
      // row scrolled just into view, and a tap there would land on it.
      tester.widget<Switch>(toggle).onChanged!(true);
      await tester.pump();
      expect(DataSaver.isOn, isTrue);
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
