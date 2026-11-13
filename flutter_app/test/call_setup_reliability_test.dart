// Placing a call the other phone is already ringing for (2026-11-13).
//
// Reported: A calls, B's phone rings, B accepts - and both sit on
// "Connecting..." until it drops, A's screen saying "Could not start the
// call - please check your connection and try again."
//
// That sentence is this screen's answer to POST /calls/initiate failing,
// which had one try of ten seconds. The server rang B before it answered A,
// so when the answer was slow B was ringing for a call A had given up on,
// and A had no room to join or hang up: the server's late answer was
// thrown away. Now the same attempt is asked again under one id (the
// server answers a repeat with the call it placed), a setup that fails or
// is left is cancelled by that id, and what the call is recorded as says
// whether it ever connected.
import 'dart:async';
import 'dart:io';

import 'package:broka/features/calls/domain/call_record.dart';
import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart' show FakeSocket;
import 'support/fake_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<FakeSocket> sockets;

  setUpAll(() {
    installFakeApi();
    for (final name in [
      'com.broka.app/call_service',
      'FlutterWebRTC.Event',
      'FlutterWebRTC.Method',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers/events/broka_ringback',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
      'dexterous.com/flutter/local_notifications',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    final tmp = Directory.systemTemp.createTempSync('broka_call_setup');
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp.path);
    // Microphone granted: the call gets as far as the network lets it.
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 1};
      }
      return 1;
    });
  });

  setUp(() {
    sockets = [];
    clearFakeRequests();
    setFakeRoute(null);
    SharedPreferences.setMockInitialValues({});
    ActiveCall.instance.reset();
    ApiService.currentUserId = 'buyer-1';
    WebRtcService.debugPreconnectSupported = false;
    WebRtcService.debugCreatePeerConnection = (_) async => FakePeerConnection();
    WebRtcService.debugGetUserMedia = (_) async => FakeStream([FakeTrack('mic', 'audio')]);
    WebRtcService.debugConnectSocket = (uri) {
      final socket = FakeSocket();
      sockets.add(socket);
      return socket;
    };
  });

  tearDown(() {
    VoipCallScreen.debugOnService = null;
    WebRtcService.debugPreconnectSupported = null;
    WebRtcService.debugCreatePeerConnection = null;
    WebRtcService.debugGetUserMedia = null;
    WebRtcService.debugConnectSocket = null;
    ApiService.initiateAttemptTimeouts = const [
      Duration(seconds: 8), Duration(seconds: 6), Duration(seconds: 6),
    ];
  });

  Future<void> open(WidgetTester tester, Future<Map<String, dynamic>?> setup,
      {String? clientCallId}) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
    nav.currentState!.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: '/voip-call', arguments: {
        'roomId': '',
        'userId': 'buyer-1',
        'callToken': '',
        'callSetup': setup,
        if (clientCallId != null) 'clientCallId': clientCallId,
        'peerName': 'Xavier Bravin',
        'isCaller': true,
        'listingId': 'listing-1',
        'listingName': 'Airtel Smart Connect Home & Office WiFi',
        'buyerId': 'buyer-1',
        'callerRole': 'buyer',
        'callType': 'audio',
      }),
      builder: (_) => const VoipCallScreen(animateBackground: false),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    // Whatever the fake server still has in flight answers, and the
    // screen's own two-second close runs.
    await tester.pump(const Duration(seconds: 40));
  }

  List<FakeRequest> asked(String path) =>
      fakeRequests.where((r) => r.method == 'POST' && r.uri.path == path).toList();

  group('placing the call', () {
    testWidgets('a slow answer is asked again under the same id, and the call goes on',
        (tester) async {
      var tries = 0;
      setFakeRoute((uri) {
        if (uri.path != '/calls/initiate') return null;
        tries++;
        // The first answer is slower than the app waits; the server placed
        // the call all the same, and answers the repeat with it.
        return tries == 1
            ? const FakeResponse({'status': 'sent', 'room_id': 'room-1', 'call_token': 't'},
                delay: Duration(seconds: 12))
            : const FakeResponse(
                {'status': 'sending', 'room_id': 'room-1', 'call_token': 't2', 'replayed': true});
      });
      WebRtcService? svc;
      VoipCallScreen.debugOnService = (s) => svc = s;
      final setup = ApiService.initiateCall(
          listingId: 'listing-1', listingName: 'Airtel Smart Connect', callType: 'audio');
      await open(tester, setup);
      await tester.pump(const Duration(seconds: 9));
      await tester.pump();

      final tries_ = asked('/calls/initiate');
      expect(tries_, hasLength(2), reason: 'one try of ten seconds, then "Could not start the call"');
      final first = (tries_[0].json as Map)['client_call_id'];
      expect(first, isA<String>());
      expect((tries_[1].json as Map)['client_call_id'], first,
          reason: 'the same attempt: the server answers it with the call it placed');
      expect(find.textContaining('Could not start the call'), findsNothing);
      expect(svc, isNotNull, reason: 'the call is on its way into the room');
      expect(svc!.roomId, 'room-1');
      expect(svc!.callToken, 't2');
      expect(asked('/calls/cancel-setup'), isEmpty);
      await close(tester);
    });

    testWidgets('when every try fails it says so, and the call is cancelled by its id',
        (tester) async {
      setFakeRoute((uri) => uri.path == '/calls/initiate'
          ? const FakeResponse({'status': 'sent', 'room_id': 'room-1', 'call_token': 't'},
              delay: Duration(seconds: 30))
          : (uri.path == '/calls/cancel-setup' ? {'status': 'cancelled'} : null));
      final setup = ApiService.initiateCall(
          listingId: 'listing-1', listingName: 'Airtel Smart Connect', callType: 'audio');
      await open(tester, setup);
      await tester.pump(const Duration(seconds: 21));
      await tester.pump();

      expect(find.textContaining('Could not start the call'), findsOneWidget);
      final tries = asked('/calls/initiate');
      expect(tries, hasLength(3));
      final cancel = asked('/calls/cancel-setup');
      expect(cancel, hasLength(1),
          reason: 'the server may have placed it, and their phone may be ringing');
      expect((cancel.single.json as Map)['client_call_id'], (tries.first.json as Map)['client_call_id']);
      await close(tester);
    });

    testWidgets('a refusal is not asked again, nor cancelled', (tester) async {
      setFakeRoute((uri) => uri.path == '/calls/initiate'
          ? const FakeResponse({'detail': 'Too many requests'}, statusCode: 429)
          : null);
      final setup = ApiService.initiateCall(
          listingId: 'listing-1', listingName: 'Airtel Smart Connect', callType: 'audio');
      await open(tester, setup);
      await tester.pump(const Duration(seconds: 1));
      expect(asked('/calls/initiate'), hasLength(1));
      expect(asked('/calls/cancel-setup'), isEmpty, reason: 'nothing was placed');
      await close(tester);
    });

    testWidgets('ending before the setup lands cancels the call by its id, at once',
        (tester) async {
      final setup = Completer<Map<String, dynamic>?>();
      await open(tester, setup.future, clientCallId: 'cc-test-0001');
      await tester.tap(find.text('End'));
      await tester.pump();
      final cancel = asked('/calls/cancel-setup');
      expect(cancel, hasLength(1),
          reason: 'not only when (if ever) the answer lands: their phone is ringing now');
      expect((cancel.single.json as Map)['client_call_id'], 'cc-test-0001');
      expect((cancel.single.json as Map)['reason'], 'user_hung_up');
      setup.complete(null);
      await close(tester);
    });

    testWidgets('a push that failed after the call was placed is said on the screen',
        (tester) async {
      await open(tester, Future.value(
          {'status': 'sending', 'room_id': 'room-1', 'call_token': 't'}));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining("They can't be notified"), findsNothing);
      sockets.single.emit({'type': 'push_status', 'status': 'push_failed'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining("They can't be notified"), findsOneWidget);
      await close(tester);
    });
  });

  group('what a call is recorded as', () {
    test('the definitions the call history uses', () {
      String of({bool connected = false, bool caller = true, bool answered = false,
              bool declined = false}) =>
          VoipCallScreen.outcomeFor(everConnected: connected, isCaller: caller,
              answered: answered, declinedByMe: declined);
      expect(of(connected: true, answered: true), 'completed');
      expect(of(caller: false, answered: true), 'failed_to_connect',
          reason: 'accepted and never connected was "completed" - a call that happened');
      expect(of(caller: true, answered: true), 'failed_to_connect');
      expect(of(caller: false, declined: true), 'declined');
      expect(of(caller: true), 'cancelled');
      expect(of(caller: false), 'missed');
    });

    test('and how the history says it', () {
      expect(callSummary(outcome: 'failed_to_connect', isOutgoing: true), "Couldn't connect");
      expect(callSummary(outcome: 'failed_to_connect', isOutgoing: false), "Couldn't connect");
      expect(callSummary(outcome: 'completed', isOutgoing: true, durationSecs: 75), '1:15');
    });
  });
}
