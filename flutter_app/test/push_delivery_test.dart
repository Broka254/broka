// Calls and messages that reach a phone whose app is closed (2026-10-07).
//
// Reported: a call rang only while the app was open, the caller's screen
// assumed someone "offline" could not be reached, and messages sent while
// someone was away were not there until they opened BROKA.
//
//  * A call that arrives through a push is acknowledged to the server (with
//    the call token the push carries, since a closed app's access token is
//    long expired), which is what turns the caller's "Calling" into
//    "Ringing" - and a push for a call that is already over stops at once.
//  * A conversation is one notification, under the tag the server's message
//    push uses, whichever of the push, the foreground handler or the sweep
//    posts it - and a message a push announced is not announced again.
//  * The sweep asks for an incoming call once, not once per conversation.
import 'dart:convert';

import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:broka/services/webrtc_service.dart';
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
  final events = <String>[];
  var failShows = false;
  var notificationsEnabled = true;

  late http.Response Function(http.Request) route;
  final client = MockClient((req) async {
    requests.add(req);
    events.add('http ${req.url.path}');
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
        events.add('shown');
      }
      if (call.method == 'cancel') cancelled.add(call.arguments);
      if (call.method == 'areNotificationsEnabled') return notificationsEnabled;
      return null;
    });
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() async {
    shown.clear();
    cancelled.clear();
    requests.clear();
    events.clear();
    failShows = false;
    notificationsEnabled = true;
    SharedPreferences.setMockInitialValues({'global_poll_primed_v1': true});
    // The service is a process-wide singleton: a room settled by one test
    // (an ended call) must not stop the next test's call from ringing.
    ActiveCall.instance.reset();
    ApiService.currentUserId = 'seller-1';
    route = (_) => _json({'status': 'ok'});
    GlobalPollerService.instance.appInForeground = true;
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  String? tagOf(Map<String, dynamic> n) =>
      (n['platformSpecifics'] as Map?)?['tag'] as String?;

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

  group('a call pushed to a closed app', () {
    test('rings, and tells the server the phone is ringing', () async {
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown.single['title'], '📞 Incoming call from Ann');
      final ack = requests.singleWhere((r) => r.url.path == '/calls/room-1/alerted');
      expect(jsonDecode(ack.body), {'call_token': 'callee-token'});
      expect(ack.headers.containsKey('Authorization'), isFalse,
          reason: 'a closed app has no live access token - the call token is the proof');
      expect(cancelled, isEmpty);
    });

    test('a push for a call that is already over stops ringing at once', () async {
      route = (req) => req.url.path.endsWith('/alerted')
          ? _json({'detail': 'This call is no longer ringing'}, 410)
          : _json({'status': 'ok'});
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, hasLength(1), reason: 'rung first - never waits on the network');
      expect(cancelled, isNotEmpty);
    });

    test('answered on another phone: this one stops', () async {
      await NotificationService.handleBackgroundMessage(
          {'type': 'call_over', 'roomId': 'room-1'});
      expect(cancelled, isNotEmpty);
    });

    test('with notifications off: nothing rings, and nothing is claimed', () async {
      // Android 13+ accepts a notification without drawing or sounding it,
      // so show() alone cannot tell a silent phone from a ringing one.
      notificationsEnabled = false;
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      expect(shown, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/alerted')), isEmpty,
          reason: "the caller must not be told a silent phone is ringing");
      expect(cancelled, isEmpty);
    });

    test('an unconfirmed acknowledgement is retried at once', () async {
      var alertCalls = 0;
      route = (req) {
        if (req.url.path == '/calls/room-1/alerted') {
          alertCalls++;
          return alertCalls == 1
              ? _json({'detail': 'temporarily unavailable'}, 503)
              : _json({'status': 'ringing'});
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => NotificationService.handleBackgroundMessage(callPush()));
      // A closed app has no poller to try again later; without this the
      // caller stayed on "Calling..." for a phone that was ringing.
      expect(alertCalls, 2);
      expect(shown, hasLength(1));
      expect(cancelled, isEmpty);
    });

    test('an incomplete payload rings nothing and claims nothing', () async {
      await withClient(() => NotificationService.handleBackgroundMessage(
          {'type': 'incoming_call', 'callerName': 'Ann'}));
      expect(shown, isEmpty);
      expect(requests, isEmpty);
    });

    test('the same call pushed twice stays one notification', () async {
      await withClient(() async {
        await NotificationService.handleBackgroundMessage(callPush());
        await NotificationService.handleBackgroundMessage(callPush());
      });
      // Two show() calls, one slot: Android replaces a notification with
      // the same id, so a duplicated push cannot stack two rings.
      expect(shown, hasLength(2));
      expect(shown[0]['id'], shown[1]['id']);
    });

    test('without a call token it still rings, but cannot acknowledge', () async {
      final push = callPush()..remove('callToken');
      await withClient(() => NotificationService.handleBackgroundMessage(push));
      // Nothing about the phone's own ringing depends on the token; only
      // the caller's "Ringing" does.
      expect(shown, hasLength(1));
      expect(requests, isEmpty);
    });
  });

  group('messages', () {
    Map<String, dynamic> messagePush({String id = 'm-1'}) => {
          'type': 'new_message',
          'listingId': 'listing-1',
          'buyerId': 'buyer-1',
          'myRole': 'seller',
          'messageId': id,
          'screen': 'chat',
          'senderName': 'Ann',
          'listingName': 'Samsung A54',
          'count': '1',
          'preview': 'Still available?',
          'title': 'Ann · Samsung A54',
          'body': 'Still available?',
        };

    Map<String, dynamic> thread(String lastId) => {
          'listing_id': 'listing-1',
          'listing_name': 'Samsung A54',
          'buyer_id': 'buyer-1',
          'my_role': 'seller',
          'counterpart_name': 'Ann',
          'last_message': 'Still available?',
          'last_msg_type': 'text',
          'last_role': 'buyer',
          'last_message_id': lastId,
          'unread': 1,
        };

    test('with the app in front, the push is shown as the conversation', () async {
      await NotificationService.instance.handleForegroundFcmMessage(messagePush());
      final n = shown.single;
      expect(n['title'], 'Ann · Samsung A54');
      expect(n['body'], 'Still available?');
      expect(n['id'], 0);
      expect(tagOf(n), 'thread_listing-1_buyer-1',
          reason: "the backend's message_push.thread_tag builds the same string");
      expect(tagOf(n), NotificationService.threadTag('listing-1', 'buyer-1'));
    });

    test('not while that conversation is on screen', () async {
      GlobalPollerService.instance.markScreenActive('listing-1', buyerId: 'buyer-1');
      try {
        await NotificationService.instance.handleForegroundFcmMessage(messagePush());
      } finally {
        GlobalPollerService.instance.markScreenInactive('listing-1', buyerId: 'buyer-1');
      }
      expect(shown, isEmpty);
    });

    test('opening a conversation takes its notification down', () async {
      GlobalPollerService.instance.markScreenActive('listing-1', buyerId: 'buyer-1');
      GlobalPollerService.instance.markScreenInactive('listing-1', buyerId: 'buyer-1');
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, anyElement(equals({'id': 0, 'tag': 'thread_listing-1_buyer-1'})));
    });

    test('a message a push announced is not announced again by the sweep', () async {
      // Android drew the push; the background isolate recorded it.
      await NotificationService.handleBackgroundMessage(messagePush(id: 'm-7'));
      expect(shown, isEmpty, reason: 'Android draws a message push itself');
      route = (req) => req.url.path.startsWith('/negotiate/inbox/')
          ? _json([thread('m-7')])
          : _json({'has_call': false});
      await withClient(() => GlobalPollerService.instance.catchUp());
      expect(shown, isEmpty);

      // The next message is.
      route = (req) => req.url.path.startsWith('/negotiate/inbox/')
          ? _json([thread('m-8')])
          : _json({'has_call': false});
      await withClient(() => GlobalPollerService.instance.catchUp());
      expect(shown, hasLength(1));
      expect(tagOf(shown.single), 'thread_listing-1_buyer-1');
    });
  });

  group('the sweep', () {
    test('asks for an incoming call once, not once per conversation', () async {
      final threads = [
        for (var i = 0; i < 5; i++)
          {
            'listing_id': 'listing-$i', 'listing_name': 'Item $i', 'buyer_id': 'buyer-$i',
            'my_role': 'seller', 'counterpart_name': 'B$i', 'last_message': 'hi',
            'last_msg_type': 'text', 'last_role': 'seller', 'last_message_id': 'x$i',
            'unread': 0,
          },
      ];
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(threads);
        if (req.url.path == '/calls/incoming') {
          return _json({
            'has_call': true, 'room_id': 'room-9', 'listing_id': 'listing-new',
            'listing_name': 'Fridge', 'buyer_id': 'buyer-new', 'caller_id': 'buyer-new',
            'caller_name': 'Kev', 'call_type': 'video', 'call_token': 'tok-9',
          });
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      // The acknowledgement now follows the notification (it used to race
      // ahead of it), so give the notification/ringing path its turn.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(requests.where((r) => r.url.path.startsWith('/calls/pending/')), isEmpty);
      expect(requests.where((r) => r.url.path == '/calls/incoming'), hasLength(1));
      // A buyer can call a seller they never wrote to: no thread, and the
      // call still rings, about the right listing, for the right buyer.
      final call = shown.singleWhere((n) => (n['title'] as String).contains('Kev'));
      expect(call['title'], '📹 Incoming video call from Kev');
      expect(call['body'], 'About: Fridge');
      final payload = jsonDecode(call['payload'] as String) as Map;
      expect(payload['buyerId'], 'buyer-new');
      expect(payload['listingId'], 'listing-new');
      final ack = requests.singleWhere((r) => r.url.path == '/calls/room-9/alerted');
      expect(jsonDecode(ack.body), {'call_token': 'tok-9'});
      // The caller is told "Ringing" only after this phone is actually
      // ringing - not before the notification/ring exists.
      final shownAt = events.indexOf('shown');
      final ackAt = events.indexOf('http /calls/room-9/alerted');
      expect(shownAt, isNonNegative);
      expect(ackAt, greaterThan(shownAt));
      GlobalPollerService.instance.stop();
    });

    test('does not claim the phone is ringing when nothing could be shown', () async {
      failShows = true;
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const []);
        if (req.url.path == '/calls/incoming') {
          return _json({
            'has_call': true, 'room_id': 'room-9', 'listing_id': 'listing-new',
            'listing_name': 'Fridge', 'buyer_id': 'buyer-new', 'caller_id': 'buyer-new',
            'caller_name': 'Kev', 'call_type': 'video', 'call_token': 'tok-9',
          });
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(shown, isEmpty);
      expect(requests.where((r) => r.url.path == '/calls/room-9/alerted'), isEmpty,
          reason: 'a call that never rang must not be acknowledged');
      GlobalPollerService.instance.stop();
    });

    test('retries a ringing acknowledgement the server did not confirm', () async {
      var alertCalls = 0;
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) return _json(const []);
        if (req.url.path == '/calls/incoming') {
          return _json({
            'has_call': true, 'room_id': 'room-9', 'listing_id': 'listing-new',
            'listing_name': 'Fridge', 'buyer_id': 'buyer-new', 'caller_id': 'buyer-new',
            'caller_name': 'Kev', 'call_type': 'video', 'call_token': 'tok-9',
          });
        }
        if (req.url.path == '/calls/room-9/alerted') {
          alertCalls++;
          return alertCalls <= 2
              ? _json({'detail': 'temporarily unavailable'}, 500)
              : _json({'status': 'ringing'});
        }
        return _json({'status': 'ok'});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alertCalls, 2, reason: 'the first attempt and its immediate retry');

      // The next sweep tries again: a failed ack used to be marked done
      // forever, leaving the caller on "Calling...".
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alertCalls, 3);

      // Confirmed once, never repeated by later sweeps.
      await withClient(() => GlobalPollerService.instance.catchUp());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alertCalls, 3);
      GlobalPollerService.instance.stop();
    });

    test('falls back to asking per conversation on a server without /calls/incoming',
        () async {
      route = (req) {
        if (req.url.path.startsWith('/negotiate/inbox/')) {
          return _json([
            {'listing_id': 'listing-1', 'buyer_id': 'buyer-1', 'my_role': 'seller',
             'last_message': 'hi', 'last_role': 'seller', 'last_message_id': 'z'},
          ]);
        }
        if (req.url.path == '/calls/incoming') return _json({'detail': 'Not Found'}, 404);
        return _json({'has_call': false});
      };
      await withClient(() => GlobalPollerService.instance.catchUp());
      expect(requests.where((r) => r.url.path == '/calls/pending/listing-1'), hasLength(1));
      GlobalPollerService.instance.stop();
    });
  });

  group("the caller's screen", () {
    WebRtcService caller() => WebRtcService(
        roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');

    test("hears when the callee's phone is ringing", () {
      final svc = caller();
      var ringing = 0;
      svc.onPeerRinging = () => ringing++;
      svc.debugReceiveSignal(jsonEncode({'type': 'callee_ringing'}));
      expect(ringing, 1);
    });

    test('knows why the call ended when nobody answered', () {
      final svc = caller();
      CallState? state;
      svc.onStateChange = (s) => state = s;
      svc.debugReceiveSignal(jsonEncode({'type': 'hangup', 'reason': 'no_answer'}));
      expect(svc.remoteEndReason, 'no_answer');
      expect(state, CallState.ended);
    });
  });
}
