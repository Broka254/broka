// Every incoming-call push this phone handles is accounted for (2026-11-15).
//
// Reported: a call to a phone whose app was closed stayed on "Calling…" on
// the caller's screen, and Railway's log had nothing from the callee's
// phone - FCM accepting the push was the last word. A push that never
// reached the phone, a ring the phone refused and an acknowledgement that
// kept failing all looked the same. Now:
//
//  * each acknowledgement (POST /calls/{room}/alerted) says which try it is,
//    what rang the phone and why the try before failed; when none gets
//    through while the call still rings here, one CALL_ALERT_FAILED report
//    says so with the last status (POST /calls/{room}/events, authorized by
//    the call's own token);
//  * a ring the phone refuses says why (CALL_RING_BLOCKED) - notifications
//    off, another call under way, a call already over - once per reason;
//  * an expired session never stands in the way: the call token alone
//    authorizes the acknowledgement;
//  * the sweep keeps acknowledging a call whose screen it opened, the
//    background handler rings even when Firebase will not start there, a
//    late push never rings a call that is over, and a call found by the
//    push and the sweep both is one notification;
//  * the caller's screen hears "ringing" only from the server's word that
//    a phone of theirs rings, and "answered" only once they accept.
import 'dart:convert';

import 'package:broka/main.dart' show handleBackgroundPush;
import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:broka/services/webrtc_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart' show RemoteMessage;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final cancelled = <Object?>[];
  final requests = <http.Request>[];
  var failShows = false;
  var notificationsEnabled = true;
  late List<Duration> realRetryDelays;

  late http.Response Function(http.Request) route;
  final client = MockClient((req) async {
    requests.add(req);
    return route(req);
  });

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global',
        'com.broka.app/ringtone']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        if (failShows) {
          throw PlatformException(code: 'no-notification', message: 'post failed');
        }
        shown.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      if (call.method == 'cancel') cancelled.add(call.arguments);
      if (call.method == 'areNotificationsEnabled') return notificationsEnabled;
      return null;
    });
    realRetryDelays = NotificationService.persistentAlertRetryDelays;
  });

  tearDownAll(() {
    debugDefaultTargetPlatformOverride = null;
    NotificationService.persistentAlertRetryDelays = realRetryDelays;
  });

  setUp(() async {
    shown.clear();
    cancelled.clear();
    requests.clear();
    failShows = false;
    notificationsEnabled = true;
    SharedPreferences.setMockInitialValues({'global_poll_primed_v1': true});
    // Process-wide singletons: what one test settled or reported must not
    // change what the next one rings or reports.
    ActiveCall.instance.reset();
    NotificationService.resetCallPushReports();
    // A phone just woken waits seconds between tries; a test, a moment.
    NotificationService.persistentAlertRetryDelays = const [
      Duration(milliseconds: 1),
      Duration(milliseconds: 1),
    ];
    ApiService.currentUserId = 'seller-1';
    route = (_) => _json({'status': 'ok'});
    GlobalPollerService.instance.appInForeground = true;
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  // A call screen begun by a test keeps a timer.
  tearDown(() => ActiveCall.instance.reset());

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  Map<String, dynamic> callPush({String roomId = 'room-1'}) => {
        'type': 'incoming_call',
        'roomId': roomId,
        'callerName': 'Ann',
        'listingName': 'Samsung A54',
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'callType': 'audio',
        'callToken': 'callee-token',
      };

  // GET /calls/incoming and GET /calls/pending/{listing}, ringing.
  Map<String, dynamic> ringingCall(String roomId) => {
        'has_call': true,
        'room_id': roomId,
        'listing_id': 'listing-1',
        'listing_name': 'Samsung A54',
        'buyer_id': 'buyer-1',
        'caller_id': 'buyer-1',
        'caller_name': 'Ann',
        'call_type': 'audio',
        'call_token': 'callee-token',
      };

  List<Map<String, dynamic>> alertsFor(String roomId) => [
        for (final r in requests)
          if (r.url.path == '/calls/$roomId/alerted') jsonDecode(r.body) as Map<String, dynamic>,
      ];

  // What this phone told the server's log about [roomId]'s push.
  List<Map<String, dynamic>> reportsFor(String roomId) => [
        for (final r in requests)
          if (r.url.path == '/calls/$roomId/events')
            for (final e in (jsonDecode(r.body) as Map<String, dynamic>)['events'] as List)
              (e as Map).cast<String, dynamic>(),
      ];

  group('an acknowledgement that cannot get through', () {
    test('is reported once, with the last status and why, while the call still rings',
        () async {
      route = (req) => req.url.path == '/calls/room-1/alerted'
          ? _json({'detail': 'temporarily unavailable'}, 503)
          : _json({'status': 'ok'});
      final sentAt = DateTime.now().millisecondsSinceEpoch - 1500;
      await withClient(() => NotificationService.handleBackgroundMessage(
          {...callPush(), 'fcmSentAt': '$sentAt'}));

      // Two at once, then one after each wait - each saying which try it is,
      // what rang the phone, and why the one before failed.
      final alerts = alertsFor('room-1');
      expect([for (final a in alerts) a['attempt']], [1, 2, 3, 4]);
      expect(alerts.first.containsKey('previous_error'), isFalse);
      expect([for (final a in alerts.skip(1)) a['previous_error']], everyElement('http_503'));
      expect([for (final a in alerts) a['handler']], everyElement('background'));
      expect(alerts.first['push_age_ms'], greaterThanOrEqualTo(1500));

      final report = reportsFor('room-1').single;
      expect(report['event'], 'CALL_ALERT_FAILED');
      expect(report['status'], 503);
      expect(report['category'], 'http_503');
      expect(report['handler'], 'background');
      expect(report['attempt'], 4);
      expect(report['push_age_ms'], greaterThanOrEqualTo(1500));
      expect(report['client_ts'], isA<String>());
      final sent = requests.singleWhere((r) => r.url.path == '/calls/room-1/events');
      expect((jsonDecode(sent.body) as Map)['call_token'], 'callee-token',
          reason: "the call's own token is the report's credential");
      expect(jsonEncode(report), isNot(contains('callee-token')),
          reason: 'and never part of what is logged');

      // It rang all the same, and rings on.
      expect(shown, hasLength(1));
      expect(cancelled, isEmpty);
    });

    test('with no connection at all: no status, and the category says why', () async {
      route = (req) {
        if (req.url.path == '/calls/room-1/alerted') {
          throw http.ClientException('Connection refused');
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      final alerts = alertsFor('room-1');
      expect([for (final a in alerts) a['attempt']], [1, 2, 3, 4]);
      expect(alerts.last['previous_error'], 'network');
      final report = reportsFor('room-1').single;
      expect(report['event'], 'CALL_ALERT_FAILED');
      expect(report['category'], 'network');
      expect(report.containsKey('status'), isFalse, reason: 'no answer ever came back');
    });

    test('stops, and reports nothing, once the call is settled on this phone', () async {
      var tries = 0;
      route = (req) {
        if (req.url.path == '/calls/room-1/alerted') {
          // Declined here while the tries were failing.
          if (++tries == 2) ActiveCall.instance.settle('room-1');
          return _json({'detail': 'temporarily unavailable'}, 503);
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(tries, 2);
      expect(reportsFor('room-1'), isEmpty, reason: 'nothing rings here to claim any more');
    });

    test('an expired session never stands in the way: the call token alone acknowledges',
        () async {
      // A closed app's access token expired long ago (15 minutes), and its
      // refresh token may be no better.
      SharedPreferences.setMockInitialValues({
        'global_poll_primed_v1': true,
        'auth_token': 'expired-access-token',
        'refresh_token': 'expired-refresh-token',
        'user_id': 'seller-1',
      });
      await ApiService.loadSavedSession();
      addTearDown(() async {
        SharedPreferences.setMockInitialValues({});
        await ApiService.loadSavedSession();
        ApiService.currentUserId = 'seller-1';
      });
      // The server refuses that access token wherever it is sent.
      route = (req) => req.headers.containsKey('Authorization')
          ? _json({'detail': 'Token has expired'}, 401)
          : _json({'status': 'ringing'});
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));

      expect(shown, hasLength(1));
      final ack = requests.singleWhere((r) => r.url.path == '/calls/room-1/alerted');
      expect(ack.headers.containsKey('Authorization'), isFalse);
      expect((jsonDecode(ack.body) as Map)['call_token'], 'callee-token');
      expect([for (final r in requests) r.url.path], ['/calls/room-1/alerted'],
          reason: 'confirmed at the first try - and no session renewal raced from '
              'the background isolate');
      expect(reportsFor('room-1'), isEmpty);
    });
  });

  group('a ring this phone does not make says why', () {
    test('notifications switched off', () async {
      notificationsEnabled = false;
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, isEmpty);
      expect(alertsFor('room-1'), isEmpty, reason: 'a silent phone is not claimed as ringing');
      final report = reportsFor('room-1').single;
      expect(report['event'], 'CALL_RING_BLOCKED');
      expect(report['reason'], 'notifications_disabled');
      expect(report['handler'], 'background');
    });

    test('another call under way in the app', () async {
      // The app's call screen as its main isolate saved it: another call,
      // answered, kept fresh a moment ago.
      SharedPreferences.setMockInitialValues({
        'global_poll_primed_v1': true,
        'active_call_v1': 'room-0|${DateTime.now().millisecondsSinceEpoch}|1',
      });
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, isEmpty);
      expect(alertsFor('room-1'), isEmpty);
      final report = reportsFor('room-1').single;
      expect(report['event'], 'CALL_RING_BLOCKED');
      expect(report['reason'], 'on_another_call');
      expect(report['handler'], 'background');
    });

    test('a call this phone is already done with', () async {
      SharedPreferences.setMockInitialValues({
        'global_poll_primed_v1': true,
        'settled_calls_v1': <String>['room-1'],
      });
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, isEmpty);
      expect(alertsFor('room-1'), isEmpty);
      expect(reportsFor('room-1').single['reason'], 'call_settled');
    });

    test('but the call already ringing on screen in the app is no refusal', () async {
      SharedPreferences.setMockInitialValues({
        'global_poll_primed_v1': true,
        'active_call_v1': 'room-1|${DateTime.now().millisecondsSinceEpoch}|0',
      });
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, isEmpty, reason: 'its screen is the ring');
      expect(requests, isEmpty);
    });

    test('a sweep that keeps finding a call it cannot ring says so once', () async {
      addTearDown(GlobalPollerService.instance.stop);
      failShows = true;
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const []);
        if (req.url.path == '/calls/incoming') return _json(ringingCall('room-9'));
        return _json({'status': 'ok'});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alertsFor('room-9'), isEmpty);
      final report = reportsFor('room-9').single;
      expect(report['event'], 'CALL_RING_BLOCKED');
      expect(report['reason'], 'show_failed');
      expect(report['handler'], 'poller');
      expect(report.containsKey('push_age_ms'), isFalse, reason: 'no push involved');
    });

    test('a push that arrives after the call ended never rings it back', () async {
      route = (req) => req.url.path == '/calls/pending/listing-1'
          ? _json({'has_call': false})
          : _json({'status': 'ok'});
      await withClient(
          () => NotificationService.instance.handleForegroundFcmMessage(callPush()));
      expect(shown, isEmpty);
      expect(alertsFor('room-1'), isEmpty);
      expect(ActiveCall.instance.isSettled('room-1'), isTrue,
          reason: 'never rung again on this phone');
      final report = reportsFor('room-1').single;
      expect(report['event'], 'CALL_RING_BLOCKED');
      expect(report['reason'], 'call_over');
      expect(report['handler'], 'foreground');

      // The same push delivered again: still nothing rings.
      requests.clear();
      await withClient(
          () => NotificationService.instance.handleForegroundFcmMessage(callPush()));
      expect(shown, isEmpty);
      expect(alertsFor('room-1'), isEmpty);
      expect(reportsFor('room-1').single['reason'], 'call_settled');
    });
  });

  group('the sweep', () {
    test('keeps acknowledging a call whose screen it opened', () async {
      // 2026-11-15: two tries back to back, then nothing - the screen the
      // ring opened keeps every later sweep away from its call
      // (ActiveCall.shouldRing), and the caller read "Calling…" through
      // the whole ring.
      addTearDown(GlobalPollerService.instance.stop);
      var tries = 0;
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const []);
        if (req.url.path == '/calls/incoming') return _json(ringingCall('room-9'));
        if (req.url.path == '/calls/room-9/alerted') {
          // In front, the ring opens the call's screen: here, as the first
          // try goes.
          if (++tries == 1) ActiveCall.instance.begin('room-9', answered: false);
          return tries <= 2
              ? _json({'detail': 'temporarily unavailable'}, 503)
              : _json({'status': 'ringing'});
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // A later sweep does not come back to it.
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(tries, 3, reason: 'two at once, then again after a wait');
      final last = alertsFor('room-9').last;
      expect(last['attempt'], 3);
      expect(last['handler'], 'poller');
      expect(last['previous_error'], 'http_503');
      expect(reportsFor('room-9'), isEmpty, reason: 'confirmed in the end');
    });

    test('and the push finding the same call make one notification', () async {
      addTearDown(GlobalPollerService.instance.stop);
      route = (req) {
        if (req.url.path == '/calls/pending/listing-1') return _json(ringingCall('room-1'));
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const []);
        if (req.url.path == '/calls/incoming') return _json(ringingCall('room-1'));
        return _json({'status': 'ringing'});
      };
      await withClient(() => Future.wait<void>([
            NotificationService.instance.handleForegroundFcmMessage(callPush()),
            GlobalPollerService.instance.catchUp(),
          ]));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final rings = [
        for (final n in shown)
          if ('${n['title']}'.contains('Incoming call')) n,
      ];
      expect(rings, isNotEmpty);
      expect({for (final n in rings) n['id']}, hasLength(1),
          reason: 'Android replaces a notification with the same id: one ring in the '
              'tray, whichever path posted it and however often');
    });
  });

  test('a push to a closed app rings even when Firebase will not start there', () async {
    // The background handler used to start with an unguarded
    // Firebase.initializeApp(): a throw there ended it before anything
    // rang, with nothing in any log to say why.
    await withClient(() => handleBackgroundPush(
          RemoteMessage(
            messageId: 'fcm-1',
            sentTime: DateTime.now().subtract(const Duration(seconds: 2)),
            data: callPush(),
          ),
          initializeFirebase: () async => throw StateError('no Firebase app'),
        ));
    expect(shown.single['title'], '📞 Incoming call from Ann');
    final ack = alertsFor('room-1').single;
    expect(ack['handler'], 'background');
    expect(ack['push_age_ms'], greaterThanOrEqualTo(2000),
        reason: "how long FCM took to bring it, by the phone's clock");
  });

  // Last in the file: each frame arms the service's 25-second socket
  // watchdog, which nothing here disarms.
  group("the caller's screen", () {
    test('hears "ringing" only when a phone of theirs rings, and "answered" only '
        'when they accept', () {
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
      var ringing = 0;
      var answered = 0;
      final pushStatuses = <String>[];
      svc.onPeerRinging = () => ringing++;
      svc.onPeerAnswered = () => answered++;
      svc.onPushStatus = pushStatuses.add;

      // FCM taking the push, a phone of theirs in the room while it rings,
      // that phone leaving, a frame of some other kind: none of them is a
      // phone ringing.
      for (final frame in <Map<String, Object?>>[
        {'type': 'push_status', 'status': 'sent'},
        {'type': 'ringing_ready', 'peer': 'their-phone'},
        {'type': 'ringing_left', 'peer': 'their-phone'},
        {'type': 'joined'},
      ]) {
        svc.debugReceiveSignal(jsonEncode(frame));
      }
      expect(ringing, 0, reason: 'still "Calling…"');
      expect(answered, 0);
      expect(pushStatuses, ['sent']);

      // Sent by the server only after POST /alerted (CALLEE_ALERTED).
      svc.debugReceiveSignal(jsonEncode({'type': 'callee_ringing'}));
      expect(ringing, 1);
      expect(answered, 0, reason: 'ringing is not answering: no "Connecting…" yet');

      svc.debugReceiveSignal(jsonEncode({'type': 'callee_answered'}));
      expect(answered, 1);
      expect(svc.calleeAnswered, isTrue);
    });
  });
}
