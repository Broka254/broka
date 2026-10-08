// Answering a call from its notification (2026-10-08).
//
// Reported from phones: with BROKA closed, pressing Accept on an incoming
// call opened the app slowly, and the call dropped as it appeared; and
// "sometimes after I accept an incoming call there is a notification of
// another incoming call from the same person".
//
// Accept from a closed app sat behind the splash screen's ten-second boot
// sequence, then a round trip asking the server whether the call was still
// ringing, before the call screen opened and told the server it was
// answered. The caller's screen hangs up after 45 seconds unless the callee
// has joined, and nothing told it Accept had been pressed - so the call
// ended just as it reached the callee's screen. Meanwhile the app's first
// sweep found the call still "ringing" (the server did not know yet) and
// posted a fresh Accept/Decline for it.
import 'dart:async';
import 'dart:convert';

import 'package:broka/main.dart' show pendingColdStartCallData;
import 'package:broka/screens/splash_screen.dart';
import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
    jsonEncode(body), status,
    headers: {'content-type': 'application/json'});

/// The incoming-call push, as the server sends it.
Map<String, dynamic> _push(String room) => {
      'type': 'incoming_call',
      'roomId': room,
      'listingId': 'listing-1',
      'buyerId': 'buyer-1',
      'listingName': 'Samsung A54',
      'callerName': 'Ann Buyer',
      'callerId': 'buyer-1',
      'callerPhoto': 'https://img.broka.test/img/ann/thumb.webp',
      'callType': 'audio',
      'callToken': 'ct-$room',
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final requests = <http.Request>[];
  late http.Response Function(http.Request) route;
  final client = MockClient((req) async {
    requests.add(req);
    return route(req);
  });

  setUpAll(() async {
    installFakeApi();
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers/events/broka_splash_boot',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
      'com.broka.app/links',
      'plugins.flutter.io/firebase_messaging',
    ]) {
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
    // What the server says once Accept has reached it: the call is no
    // longer "pending" - it is answered.
    route = (req) {
      if (req.url.path.startsWith('/calls/pending/')) return _json({'has_call': false});
      if (req.url.path == '/calls/incoming') return _json({'has_call': false});
      return _json({'status': 'answered'});
    };
  });

  Future<T> withClient<T>(Future<T> Function() body) =>
      http.runWithClient(body, () => client);

  /// A navigator that records where the app went, and with what.
  Future<List<(String?, Map?)>> host(WidgetTester tester) async {
    final opened = <(String?, Map?)>[];
    final key = GlobalKey<NavigatorState>();
    NotificationService.instance.navigatorKey = key;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: const SizedBox(),
      onGenerateRoute: (settings) {
        opened.add((settings.name, settings.arguments as Map?));
        return MaterialPageRoute(builder: (_) => const SizedBox());
      },
    ));
    return opened;
  }

  Future<void> accept(WidgetTester tester, Map<String, dynamic> data) async {
    await tester.runAsync(() async {
      await withClient(() async {
        await NotificationService.instance.handleResponse(
          actionId: NotificationService.callAcceptActionId,
          payload: jsonEncode(data),
        );
        // The answer is sent without waiting on it: let it go out.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    });
    await tester.pump();
  }

  group('Accept on the notification', () {
    testWidgets('opens the call at once, answered, without asking first',
        (tester) async {
      final opened = await host(tester);
      await accept(tester, _push('room-1'));

      expect(opened.map((o) => o.$1), ['/voip-call'],
          reason: "answered calls aren't 'pending' - asking first lost them to the chat");
      final args = opened.single.$2!;
      expect(args['roomId'], 'room-1');
      expect(args['autoAccept'], isTrue);
      expect(args['callToken'], 'ct-room-1');
      expect(args['peerName'], 'Ann Buyer');
      expect(args['peerId'], 'buyer-1');
      expect(args['peerPhoto'], 'https://img.broka.test/img/ann/thumb.webp');
      expect(requests.where((r) => r.url.path.startsWith('/calls/pending/')), isEmpty);
      // The server - and through it the caller - hears at once.
      final answer = requests.singleWhere((r) => r.url.path == '/calls/room-1/answer');
      expect(jsonDecode(answer.body), {'call_token': 'ct-room-1'});
    });

    testWidgets('nothing rings for that call again', (tester) async {
      await host(tester);
      await accept(tester, _push('room-1'));
      await tester.runAsync(() => NotificationService.instance.showIncomingCall(
            roomId: 'room-1', callerName: 'Ann Buyer', listingName: 'Samsung A54'));
      expect(shown, isEmpty,
          reason: "the sweep finding it still 'ringing' put a second Accept/Decline up");
      // Nor from a closed app's background isolate.
      await tester.runAsync(() => pumpEventQueue());
      expect(await tester.runAsync(() => ActiveCall.savedAllowsRinging('room-1')), isFalse);
    });

    testWidgets('a notification without the call token still checks first',
        (tester) async {
      // The iOS CallKit path, and builds that predate the token in the
      // payload: the check is what supplies one.
      route = (req) => req.url.path.startsWith('/calls/pending/')
          ? _json({'has_call': true, 'room_id': 'room-1', 'call_token': 'fresh',
                   'caller_name': 'Ann Buyer', 'call_type': 'audio'})
          : _json({'status': 'ok'});
      final opened = await host(tester);
      await accept(tester, {..._push('room-1')}..remove('callToken'));
      expect(opened.single.$1, '/voip-call');
      expect(opened.single.$2!['callToken'], 'fresh');
      expect(opened.single.$2!['autoAccept'], isTrue);
    });
  });

  testWidgets('a ringing open that Accept overtook does not stack a second screen',
      (tester) async {
    // A locked phone's full-screen launch opens the call ringing, asking the
    // server first. Accept pressed meanwhile opens it answered at once; the
    // slower open must then do nothing.
    final reply = Completer<http.Response>();
    final slow = MockClient((req) => req.url.path.startsWith('/calls/pending/')
        ? reply.future
        : Future.value(_json({'status': 'ok'})));
    final opened = await host(tester);
    late Future<void> ringingOpen;
    await tester.runAsync(() async {
      ringingOpen = http.runWithClient(
          () => NotificationService.instance.navigateFromPayload(
              {..._push('room-1'), 'answer': false}),
          () => slow);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // The answered screen for this call is up.
      ActiveCall.instance.begin('room-1', answered: true);
      reply.complete(_json({'has_call': true, 'room_id': 'room-1',
          'call_token': 'fresh', 'caller_name': 'Ann Buyer', 'call_type': 'audio'}));
      await ringingOpen;
    });
    await tester.pump();
    expect(opened, isEmpty);
    ActiveCall.instance.end('room-1');
  });

  test('a call answered while its notification was being drawn is not posted',
      () async {
    // showIncomingCall waits (the ringer starting, the caller's photo); a
    // call answered in that moment used to be posted anyway.
    final posting = NotificationService.instance.showIncomingCall(
        roomId: 'room-3', callerName: 'Ann Buyer', listingName: 'Samsung A54');
    ActiveCall.instance.settle('room-3');
    await posting;
    expect(shown, isEmpty);
  });

  test("the sweep's ringing notification carries what Accept needs", () async {
    route = (req) {
      if (req.url.path.startsWith('/negotiate/inbox/')) return _json([]);
      if (req.url.path == '/calls/incoming') {
        return _json({
          'has_call': true, 'room_id': 'room-9', 'listing_id': 'listing-9',
          'listing_name': 'Fridge', 'buyer_id': 'buyer-9', 'caller_id': 'buyer-9',
          'caller_name': 'Kev', 'caller_photo': null, 'call_type': 'audio',
          'call_token': 'tok-9',
        });
      }
      return _json({'status': 'ok'});
    };
    await withClient(() => GlobalPollerService.instance.catchUp());
    final call = shown.singleWhere((n) => (n['title'] as String).contains('Kev'));
    final payload = jsonDecode(call['payload'] as String) as Map;
    expect(payload['callToken'], 'tok-9');
    expect(payload['callerName'], 'Kev');
    expect(payload['callerId'], 'buyer-9');
    expect(payload['callType'], 'audio');
    GlobalPollerService.instance.stop();
  });

  testWidgets('started by Accept, the app goes straight to the call', (tester) async {
    // No ten-second boot sequence in front of a call being answered.
    SharedPreferences.setMockInitialValues({'auth_token': 'token', 'user_id': 'seller-1'});
    await tester.runAsync(ApiService.loadSavedSession);
    addTearDown(() async {
      SharedPreferences.setMockInitialValues({});
      await ApiService.loadSavedSession();
    });
    pendingColdStartCallData = {..._push('room-4'), 'answer': true};
    final key = GlobalKey<NavigatorState>();
    NotificationService.instance.navigatorKey = key;
    var callOpened = false;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: key,
      home: const SplashScreen(),
      onGenerateRoute: (settings) {
        if (settings.name == '/voip-call') callOpened = true;
        return MaterialPageRoute(builder: (_) => const SizedBox());
      },
    ));
    for (var i = 0; i < 5 && !callOpened; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(callOpened, isTrue, reason: 'opened within half a second, not after the splash');
    expect(pendingColdStartCallData, isNull);
    GlobalPollerService.instance.stop();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  group("the caller's screen", () {
    test('hears that the callee pressed Accept', () {
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
      var answered = 0;
      svc.onPeerAnswered = () => answered++;
      svc.debugReceiveSignal(jsonEncode({'type': 'callee_answered'}));
      svc.debugReceiveSignal(jsonEncode({'type': 'callee_answered'}));
      expect(answered, 1);
      expect(svc.calleeAnswered, isTrue);
    });

    test('a callee ignores it', () {
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: false, userId: 'seller-1', callToken: 't');
      var answered = 0;
      svc.onPeerAnswered = () => answered++;
      svc.debugReceiveSignal(jsonEncode({'type': 'callee_answered'}));
      expect(answered, 0);
    });
  });
}
