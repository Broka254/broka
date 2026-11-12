// The offline sync on the phone (MessageSyncService, 2026-11-12).
//
// Asked for: a message sent while the recipient was offline must be on
// their phone when they come back - every conversation, not only the open
// one - in order, once, and the server told "delivered" only after the
// phone has stored it. The server keeps what this phone has not
// acknowledged (GET /negotiate/sync); the phone stores each page in the
// conversation's own cache, then acknowledges it (POST /negotiate/sync/ack).
//
// The scenarios are the backend's (backend/tests/test_offline_delivery.py),
// seen from the phone: B/C messages that waited come down and are stored
// before the acknowledgement; D many, in order, across pages; E a sync cut
// off half way resumes and loses nothing; F a message already on the phone
// (a push, the chat's own load) is kept once. Then the triggers - the Inbox
// sweep, the network coming back - an older server without the sync, and
// an open conversation taking its own messages.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/services/api_service.dart';
import 'package:broka/services/connectivity_monitor.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/local_chat_store.dart';
import 'package:broka/services/message_sync_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// One message as GET /negotiate/sync hands it out.
Map<String, dynamic> _synced(String id, {
  String listing = 'listing-1',
  String? store,
  String buyer = 'buyer-1',
  String role = 'buyer',
  String myRole = 'seller',
  String room = 'direct',
  String content = 'Is it available?',
  required DateTime at,
}) =>
    {
      'id': id,
      'role': role,
      'content': content,
      'via_ai': room == 'zeno',
      'msg_type': 'text',
      'media_url': null,
      'created_at': '${at.toUtc().toIso8601String().replaceAll('Z', '')}Z',
      'deleted': false,
      'listing_id': store == null ? listing : null,
      'store_id': store,
      'buyer_id': buyer,
      'thread_type': store == null ? 'listing' : 'store',
      'my_role': myRole,
      'room': room,
      'delivery_status': 'PUSH_ACCEPTED',
    };

Map<String, dynamic> _page(List<Map<String, dynamic>> messages,
        {bool hasMore = false, String? next}) =>
    {'messages': messages, 'has_more': hasMore, 'next_cursor': next, 'server_time': 'x'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <http.Request>[];
  final logs = <String>[];
  late Future<http.Response> Function(http.Request) route;
  final client = MockClient((req) async {
    requests.add(req);
    return route(req);
  });
  final printer = debugPrint;
  final delays = MessageSyncService.retryDelays;
  final sync = MessageSyncService.instance;
  final t0 = DateTime.utc(2026, 11, 12, 8);

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  List<http.Request> syncGets() =>
      requests.where((r) => r.method == 'GET' && r.url.path == '/negotiate/sync').toList();
  List<http.Request> acks() =>
      requests.where((r) => r.url.path == '/negotiate/sync/ack').toList();
  List<String> ackedIds() => [
        for (final r in acks())
          ...((jsonDecode(r.body) as Map)['message_ids'] as List).cast<String>(),
      ];
  Future<List<String>> cachedIds(String scope) async =>
      [for (final m in await LocalChatStore.load(scope)) m['id'] as String];

  setUp(() {
    requests.clear();
    logs.clear();
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'seller-1';
    MessageSyncService.retryDelays = const [Duration.zero];
    sync.reset();
    sync.start();
    route = (req) async => req.url.path == '/negotiate/sync/ack'
        ? _json({'status': 'ok', 'delivered': [], 'already_delivered': [], 'unknown': []})
        : _json(_page([]));
  });

  tearDown(() {
    sync.reset();
    debugPrint = printer;
    MessageSyncService.retryDelays = delays;
  });

  test('messages that waited are stored in their conversations, in order, before the ack',
      () async {
    final messages = [
      _synced('m1', at: t0, content: 'Hello'),
      _synced('z1', listing: 'listing-2', role: 'broker', myRole: 'buyer', room: 'zeno',
          content: 'Zeno: the seller replied', at: t0.add(const Duration(minutes: 1))),
      _synced('m2', at: t0.add(const Duration(minutes: 2)), content: 'Last price?'),
      _synced('s1', store: 'store-9', at: t0.add(const Duration(minutes: 3))),
    ];
    final cachedWhenAcked = <String, List<String>>{};
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') {
        // What is on the phone at the moment the server is told "delivered".
        cachedWhenAcked['direct'] = await cachedIds('direct_listing-1_buyer-1');
        cachedWhenAcked['zeno'] = await cachedIds('ai_listing-2_buyer-1');
        cachedWhenAcked['store'] = await cachedIds('direct_store:store-9_buyer-1');
        return _json({'status': 'ok', 'delivered': ['m1', 'z1', 'm2', 's1']});
      }
      return _json(_page(messages));
    };

    final outcome = await withClient(() => sync.sync(trigger: 'app_start'));

    expect(outcome, SyncOutcome.completed);
    expect(cachedWhenAcked['direct'], ['m1', 'm2'],
        reason: 'stored, in order, before the server hears they are delivered');
    expect(cachedWhenAcked['zeno'], ['z1'], reason: "Zeno's messages go to Zeno's room");
    expect(cachedWhenAcked['store'], ['s1']);
    expect(ackedIds(), unorderedEquals(['m1', 'z1', 'm2', 's1']));
    final ack = jsonDecode(acks().single.body) as Map;
    expect(ack['source'], 'sync');
    expect(ack['final'], isTrue);
    final direct = await LocalChatStore.load('direct_listing-1_buyer-1');
    expect(direct.first['content'], 'Hello');
    expect(direct.first.containsKey('room'), isFalse,
        reason: 'the routing fields are not part of the stored message');
    final get = syncGets().single;
    expect(get.url.queryParameters['trigger'], 'app_start');
    expect(get.url.queryParameters['attempt'], '1');
    expect(logs.where((l) => l.startsWith('[Sync] MESSAGE_SYNCED_TO_CLIENT ')), hasLength(4));
    expect(logs.where((l) => l.startsWith('[Sync] OFFLINE_SYNC_COMPLETED ')), hasLength(1));
  });

  test('a message already on the phone is kept once, and still acknowledged', () async {
    // The chat's own load (or a push the app turned into a fetch) put m1 there.
    SharedPreferences.setMockInitialValues({
      'chat_cache_v1_direct_listing-1_buyer-1': jsonEncode([
        {'id': 'm1', 'role': 'buyer', 'content': 'Hello', 'msg_type': 'text',
         'created_at': t0.toIso8601String()},
        {'id': '', 'client_msg_id': 'c-mine', 'role': 'seller', 'content': 'On my way',
         'msg_type': 'text', 'failed': true,
         'created_at': t0.add(const Duration(minutes: 1)).toIso8601String()},
      ]),
    });
    route = (req) async => req.url.path == '/negotiate/sync/ack'
        ? _json({'status': 'ok', 'delivered': ['m2'], 'already_delivered': ['m1']})
        : _json(_page([
            _synced('m1', at: t0, content: 'Hello'),
            _synced('m2', at: t0.add(const Duration(seconds: 30)), content: 'Hello again'),
          ]));

    await withClient(() => sync.sync(trigger: 'push'));
    // And again: the same answer changes nothing on the phone.
    await withClient(() => sync.sync(trigger: 'resume'));

    final cached = await LocalChatStore.load('direct_listing-1_buyer-1');
    expect([for (final m in cached) m['id']], ['m1', 'm2', ''],
        reason: 'each message once; the unsent bubble kept');
    expect(ackedIds().where((id) => id == 'm1'), hasLength(2),
        reason: 'acknowledging again is safe: the server keeps it delivered once');
  });

  test('many messages come down page by page, in order, each once', () async {
    final all = [
      for (var i = 0; i < 5; i++) _synced('m$i', at: t0.add(Duration(minutes: i)), content: 'm$i'),
    ];
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') return _json({'status': 'ok'});
      final after = req.url.queryParameters['after'];
      if (after == null) return _json(_page(all.sublist(0, 2), hasMore: true, next: 'c1'));
      if (after == 'c1') return _json(_page(all.sublist(2, 4), hasMore: true, next: 'c2'));
      return _json(_page(all.sublist(4)));
    };

    expect(await withClient(() => sync.sync(trigger: 'app_start')), SyncOutcome.completed);

    expect(await cachedIds('direct_listing-1_buyer-1'), ['m0', 'm1', 'm2', 'm3', 'm4']);
    expect([for (final r in syncGets()) r.url.queryParameters['page']], ['1', '2', '3']);
    expect(syncGets().map((r) => r.url.queryParameters['sync_id']).toSet(), hasLength(1),
        reason: 'one pass, one id in the server log');
    expect([for (final r in acks()) (jsonDecode(r.body) as Map)['final'] == true],
        [false, false, true], reason: 'only the last page completes the sync');
  });

  test('a sync cut off half way resumes and loses nothing', () async {
    var pass = 0;
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') return _json({'status': 'ok'});
      if (req.url.queryParameters['after'] == null) {
        pass++;
        // The first pass: m0, m1, then the network goes. The second: the
        // server still has m2, m3 waiting - m0 and m1 were acknowledged.
        return pass == 1
            ? _json(_page([_synced('m0', at: t0), _synced('m1', at: t0.add(const Duration(seconds: 1)))],
                hasMore: true, next: 'c1'))
            : _json(_page([_synced('m2', at: t0.add(const Duration(seconds: 2))),
                _synced('m3', at: t0.add(const Duration(seconds: 3)))]));
      }
      throw const SocketException('Network is unreachable');
    };

    final first = await withClient(() => sync.sync(trigger: 'resume'));
    expect(first, SyncOutcome.failed);
    expect(sync.failures, 1);
    // The retry runs on its own (the delay is zero here).
    await withClient(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await withClient(() async {
      for (var i = 0; i < 50 && sync.failures > 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });

    expect(sync.failures, 0);
    expect(await cachedIds('direct_listing-1_buyer-1'), ['m0', 'm1', 'm2', 'm3']);
    final retry = syncGets().last;
    expect(retry.url.queryParameters['attempt'], '2');
    expect(retry.url.queryParameters['previous_error'], 'SocketException',
        reason: 'the server log hears why the last sync failed');
    expect(retry.url.queryParameters['trigger'], 'retry_resume');
    expect(logs.where((l) => l.startsWith('[Sync] OFFLINE_SYNC_FAILED ')), hasLength(1));
  });

  test('a message that cannot be stored is not acknowledged', () async {
    // A cache entry this phone cannot read back: nothing can be saved there.
    SharedPreferences.setMockInitialValues({
      'chat_cache_v1_direct_listing-1_buyer-1': '{not json',
    });
    route = (req) async => req.url.path == '/negotiate/sync/ack'
        ? _json({'status': 'ok'})
        : _json(_page([
            _synced('m1', at: t0),
            _synced('z1', listing: 'listing-2', role: 'broker', myRole: 'buyer', room: 'zeno', at: t0),
          ]));

    final outcome = await withClient(() => sync.sync(trigger: 'app_start'));

    expect(outcome, SyncOutcome.failed);
    expect(ackedIds(), ['z1'], reason: 'only what was stored is acknowledged');
    expect(logs.any((l) => l.startsWith('[Sync] OFFLINE_SYNC_STORE_FAILED ')), isTrue);
  });

  test('an open conversation takes its own messages, and is acknowledged after it has them',
      () async {
    final taken = <String>[];
    var tookBeforeAck = false;
    Future<void> screen(List<Map<String, dynamic>> messages) async {
      taken.addAll(messages.map((m) => m['id'] as String));
    }
    sync.attach('direct_listing-1_buyer-1', screen);
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') {
        tookBeforeAck = taken.contains('m1');
        return _json({'status': 'ok'});
      }
      return _json(_page([_synced('m1', at: t0)]));
    };

    await withClient(() => sync.sync(trigger: 'open_conversation'));

    expect(taken, ['m1']);
    expect(tookBeforeAck, isTrue);
    expect(await LocalChatStore.load('direct_listing-1_buyer-1'), isEmpty,
        reason: 'the open screen owns its cache and saves it itself');

    // Closed: its messages go to the cache again.
    sync.detach('direct_listing-1_buyer-1', screen);
    route = (req) async => req.url.path == '/negotiate/sync/ack'
        ? _json({'status': 'ok'})
        : _json(_page([_synced('m2', at: t0)]));
    await withClient(() => sync.sync(trigger: 'resume'));
    expect(await cachedIds('direct_listing-1_buyer-1'), ['m2']);
  });

  test('syncs never overlap: asking during one runs one more after it', () async {
    var inFlight = 0;
    var maxInFlight = 0;
    final gate = Completer<void>();
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') return _json({'status': 'ok'});
      inFlight++;
      maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
      if (syncGets().length == 1) await gate.future;
      inFlight--;
      return _json(_page([]));
    };

    await withClient(() async {
      final a = sync.sync(trigger: 'app_start');
      final b = sync.sync(trigger: 'push');
      final c = sync.sync(trigger: 'inbox');
      gate.complete();
      await Future.wait([a, b, c]);
      for (var i = 0; i < 20 && syncGets().length < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    });

    expect(maxInFlight, 1);
    expect(syncGets(), hasLength(2), reason: 'the three asks are one pass and one more');
    expect(syncGets().last.url.queryParameters['trigger'], 'push');
  });

  test('an older server without the sync is left alone for a while', () async {
    route = (req) async => http.Response('{"detail":"Not Found"}', 404);

    expect(await withClient(() => sync.sync(trigger: 'app_start')), SyncOutcome.unsupported);
    expect(sync.serverSupportsSync, isFalse);
    expect(await withClient(() => sync.sync(trigger: 'resume')), SyncOutcome.unsupported);
    expect(syncGets(), hasLength(1), reason: 'not asked again straight away');
    expect(sync.retryScheduled, isFalse, reason: 'not a failure to retry');
  });

  test('signing out during a sync acknowledges nothing for the next account', () async {
    route = (req) async {
      if (req.url.path == '/negotiate/sync/ack') return _json({'status': 'ok'});
      sync.stop(); // signed out while the page was on its way
      return _json(_page([_synced('m1', at: t0)]));
    };

    expect(await withClient(() => sync.sync(trigger: 'app_start')), SyncOutcome.skipped);
    expect(acks(), isEmpty);
    expect(await LocalChatStore.load('direct_listing-1_buyer-1'), isEmpty);
  });

  test('a failed sync is retried while the app is in front, not behind it', () async {
    route = (req) async => throw const SocketException('offline');
    MessageSyncService.retryDelays = const [Duration(minutes: 5)];

    sync.appInForeground = false;
    await withClient(() => sync.sync(trigger: 'resume'));
    expect(sync.retryScheduled, isFalse, reason: 'the next resume syncs anyway');

    sync.appInForeground = true;
    expect(sync.retryScheduled, isTrue, reason: 'back in front: try again soon');
  });

  test('the network coming back runs the sync', () async {
    var restored = 0;
    final monitor = ConnectivityMonitor.instance;
    monitor.start(() => restored++);
    monitor.report('online');
    expect(restored, 0, reason: 'online from the start is not a return');
    monitor.report('offline');
    monitor.report('offline');
    monitor.report('online');
    expect(restored, 1);
    monitor.report('online');
    expect(restored, 1);
    monitor.stop();
  });

  group('the Inbox sweep', () {
    Map<String, dynamic> thread(String lastId) => {
          'listing_id': 'listing-1',
          'buyer_id': 'buyer-1',
          'my_role': 'seller',
          'last_role': 'buyer',
          'last_message': 'Is it available?',
          'last_msg_type': 'text',
          'last_message_id': lastId,
          'last_message_at': t0.toIso8601String(),
          'unread': 1,
          'unread_count': 1,
          'counterpart_name': 'Bea',
        };

    List<http.Request> legacyDelivered() =>
        requests.where((r) => r.url.path.endsWith('/mark-delivered')).toList();

    setUp(() {
      SharedPreferences.setMockInitialValues({'global_poll_primed_v1': true});
    });

    tearDown(() => GlobalPollerService.instance.stop());

    test('fetches unread messages through the sync instead of guessing "delivered"', () async {
      route = (req) async {
        final p = req.url.path;
        if (p.startsWith('/negotiate/inbox/')) return _json([thread('m-9')]);
        if (p == '/negotiate/sync') return _json(_page([_synced('m-9', at: t0)]));
        if (p == '/negotiate/sync/ack') return _json({'status': 'ok', 'delivered': ['m-9']});
        return _json({'has_call': false});
      };

      await withClient(() async {
        await GlobalPollerService.instance.catchUp();
        for (var i = 0; i < 50 && acks().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });

      expect(legacyDelivered(), isEmpty,
          reason: 'an inbox row is one line of one message, not delivery');
      expect(ackedIds(), contains('m-9'));
      expect(await cachedIds('direct_listing-1_buyer-1'), ['m-9']);
      expect(syncGets().map((r) => r.url.queryParameters['trigger']), contains('resume'));
    });

    test('against a server without the sync it posts the thread receipt, as before', () async {
      route = (req) async {
        final p = req.url.path;
        if (p.startsWith('/negotiate/inbox/')) return _json([thread('m-10')]);
        if (p == '/negotiate/sync') return http.Response('{"detail":"Not Found"}', 404);
        if (p.endsWith('/mark-delivered')) return _json({'status': 'ok'});
        return _json({'has_call': false});
      };

      await withClient(() async {
        await GlobalPollerService.instance.catchUp();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // The sync said "not here": the next sweep posts the receipt itself.
        await GlobalPollerService.instance.catchUp();
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });

      expect(sync.serverSupportsSync, isFalse);
      expect(legacyDelivered(), hasLength(1));
    });
  });
}
