// One call at a time, as reported from phones (2026-10-07): "multiple calls
// arriving at the same time even when another call is going on / ringing".
//
// Nothing in the app knew it was on a call: every path that can ring rang
// for whatever the server reported - over a call under way, again for the
// call already accepted, a second ring for a caller who redialled - and a
// tap on "Call" while the other person was calling opened a second call.
import 'dart:convert';

import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final requests = <http.Request>[];

  setUpAll(() async {
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'),
        (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        shown.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      return null;
    });
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  setUp(() {
    shown.clear();
    requests.clear();
    SharedPreferences.setMockInitialValues({});
    ActiveCall.instance.reset();
    ApiService.currentUserId = 'seller-1';
  });

  group('ActiveCall', () {
    test('rings when there is no call', () {
      expect(ActiveCall.instance.shouldRing('room-1'), isTrue);
    });

    test('never over a call under way', () {
      ActiveCall.instance.begin('room-1', answered: true);
      expect(ActiveCall.instance.shouldRing('room-2'), isFalse);
    });

    test('never again for the call on screen', () {
      ActiveCall.instance.begin('room-1', answered: false);
      expect(ActiveCall.instance.shouldRing('room-1'), isFalse);
    });

    test('a redial may replace a call still only ringing', () {
      ActiveCall.instance.begin('room-1', answered: false);
      expect(ActiveCall.instance.shouldRing('room-2'), isTrue);
    });

    test('never for a call this phone is done with', () {
      ActiveCall.instance.begin('room-1', answered: false);
      ActiveCall.instance.markAnswered('room-1');
      ActiveCall.instance.end('room-1');
      expect(ActiveCall.instance.shouldRing('room-1'), isFalse,
          reason: 'the inbox sweep reports it ringing until the socket joins');
      ActiveCall.instance.settle('room-9');
      expect(ActiveCall.instance.shouldRing('room-9'), isFalse);
    });

    test('a closed app learns about the call on screen from preferences',
        () async {
      ActiveCall.instance.begin('room-1', answered: true);
      await pumpEventQueue();
      expect(await ActiveCall.savedAllowsRinging('room-2'), isFalse);
      expect(await ActiveCall.savedAllowsRinging('room-1'), isFalse);
      ActiveCall.instance.end('room-1');
      await pumpEventQueue();
      expect(await ActiveCall.savedAllowsRinging('room-2'), isTrue);
    });

    test('a saved call stops counting once nothing refreshes it', () async {
      final old = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({'active_call_v1': 'room-1|$old|1'});
      expect(await ActiveCall.savedAllowsRinging('room-2'), isTrue,
          reason: 'a call screen that died with the app must not block rings');
    });
  });

  group('an incoming-call push', () {
    final client = MockClient((req) async {
      requests.add(req);
      if (req.url.path.startsWith('/calls/pending/')) {
        return _json({'has_call': true, 'room_id': 'room-2'});
      }
      return _json({'status': 'ok'});
    });

    Map<String, dynamic> push(String room, {String? replaces}) => {
          'type': 'incoming_call',
          'roomId': room,
          'listingId': 'listing-1',
          'buyerId': 'buyer-1',
          'callerName': 'Ann',
          'callToken': 'tok',
          if (replaces != null) 'replacesRoomId': replaces,
        };

    Future<void> deliver(Map<String, dynamic> data) => http.runWithClient(
        () => NotificationService.instance.handleForegroundFcmMessage(data),
        () => client);

    test('does not ring over a call under way, nor tell the caller it did',
        () async {
      ActiveCall.instance.begin('room-1', answered: true);
      await deliver(push('room-2'));
      expect(shown, isEmpty);
      expect(requests.where((r) => r.url.path.endsWith('/alerted')), isEmpty);
    });

    test('for a redial takes the first ring down before ringing', () async {
      final ended = <String>[];
      final sub = NotificationService.instance.ringEnded.listen(ended.add);
      ActiveCall.instance.begin('room-1', answered: false);
      await deliver(push('room-2', replaces: 'room-1'));
      await pumpEventQueue();
      await sub.cancel();
      expect(ended, contains('room-1'),
          reason: "the first call's ringing screen closes");
      expect(ActiveCall.instance.isSettled('room-1'), isTrue);
      expect(shown.where((s) => s['title'] != null), hasLength(1));
    });
  });

  group('a call the server refuses', () {
    test('initiateCall reports why', () async {
      final client = MockClient((req) async => _json({
            'detail': {
              'code': 'CALLEE_BUSY',
              'message': 'Ann is on another call. Try again in a moment.',
            }
          }, 409));
      final result = await http.runWithClient(
          () => ApiService.initiateCall(
              listingId: 'listing-1', listingName: 'Samsung A54'),
          () => client);
      expect(result, {
        'refused': {
          'code': 'CALLEE_BUSY',
          'message': 'Ann is on another call. Try again in a moment.',
        }
      });
    });

    testWidgets('busy: the reason is shown and nothing is opened',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      final opened = <String?>[];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox()),
        onGenerateRoute: (s) {
          opened.add(s.name);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      NotificationService.instance.navigatorKey = nav;
      await NotificationService.instance.handleCallRefused(
        ScaffoldMessenger.of(nav.currentContext!),
        {'code': 'CALLEE_BUSY', 'message': 'Ann is on another call. Try again in a moment.'},
      );
      await tester.pump();
      expect(find.text('Ann is on another call. Try again in a moment.'),
          findsOneWidget);
      expect(opened, isEmpty);
    });

    testWidgets('crossed: their call is answered instead of placing ours',
        (tester) async {
      final nav = GlobalKey<NavigatorState>();
      RouteSettings? opened;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const Scaffold(body: SizedBox()),
        onGenerateRoute: (s) {
          opened = s;
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      NotificationService.instance.navigatorKey = nav;
      final client = MockClient((req) async {
        if (req.url.path == '/calls/pending/listing-1') {
          return _json({
            'has_call': true,
            'room_id': 'room-7',
            'call_token': 'fresh-token',
            'caller_name': 'Ann',
            'caller_id': 'buyer-1',
            'call_type': 'audio',
          });
        }
        return _json({'status': 'ok'});
      });
      await tester.runAsync(() => http.runWithClient(
            () => NotificationService.instance.handleCallRefused(
              ScaffoldMessenger.of(nav.currentContext!),
              {
                'code': 'CALL_CROSSED',
                'message': 'Ann is calling you',
                'call': {
                  'room_id': 'room-7',
                  'listing_id': 'listing-1',
                  'listing_name': 'Samsung A54',
                  'buyer_id': 'buyer-1',
                  'caller_name': 'Ann',
                  'caller_id': 'buyer-1',
                  'call_type': 'audio',
                  'call_token': 'tok',
                },
              },
            ),
            () => client,
          ));
      await tester.pump();
      expect(opened?.name, '/voip-call');
      final args = opened!.arguments as Map;
      expect(args['roomId'], 'room-7');
      expect(args['isCaller'], isFalse);
      expect(args['autoAccept'], isTrue);
    });
  });
}
