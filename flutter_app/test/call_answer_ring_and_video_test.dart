// Answering a call, its ring, and turning a voice call into video
// (2026-10-09).
//
// Reported from phones:
//   * "When I click Accept the app takes long to open and then the call
//     gets disconnected and is counted as a missed call."
//   * "When I'm using the app and receive a call, the ringtone continues
//     for some time [after Accept], and sometimes it shows 'Connecting...'
//     for 5 to 10 seconds."
//   * "When the other person's phone is truly ringing, I want the caller to
//     hear it ring, like normal calls."
//   * "In the audio call screen, add the option of switching to video."
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/main.dart' show returnHomeAfterAbsence;
import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:broka/services/ringback_service.dart';
import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final players = <MethodCall>[];

  // What the permission dialog answers; a completer that never completes is
  // a dialog still on screen - the call stays "connecting", neither failed
  // nor connected.
  late Future<Object?> Function(MethodCall call) permissions;

  setUpAll(() async {
    installFakeApi();
    for (final name in [
      'com.broka.app/call_service',
      'FlutterWebRTC.Event',
      'FlutterWebRTC.Method',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'xyz.luan/audioplayers/events/broka_ringback',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // The phone's own ringtone rings (SystemRingtone.kt).
    messenger.setMockMethodCallHandler(
        const MethodChannel('com.broka.app/ringtone'), (call) async => call.method == 'play');
    // Where audioplayers copies a bundled sound to play it from.
    final tmp = Directory.systemTemp.createTempSync('broka_test_audio');
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (_) async => tmp.path);
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers'),
        (call) async {
      players.add(call);
      return null;
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) => permissions(call));
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') shown.add(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    });
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  setUp(() {
    shown.clear();
    players.clear();
    clearFakeRequests();
    setFakeRoute(null);
    SharedPreferences.setMockInitialValues({});
    ActiveCall.instance.reset();
    ApiService.currentUserId = 'seller-1';
    // Microphone refused: a call fails at once unless a test says otherwise.
    permissions = (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 0};
      }
      return 0;
    };
  });

  tearDown(() {
    VoipCallScreen.debugOnService = null;
    RingbackService.debugSupported = null;
  });

  Map<String, dynamic> push(String room) => {
        'type': 'incoming_call',
        'roomId': room,
        'callToken': 'callee-token',
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'callerId': 'buyer-1',
        'callerName': 'Bea Buyer',
        'listingName': 'Samsung A54',
        'callType': 'audio',
      };

  group('the incoming-call notification', () {
    test('never adds its own ringtone to the app ringing the call', () {
      // A notification's "no sound" is ignored from Android 8 on - only the
      // channel counts - so it rang on the call channel's ringtone over the
      // app's own ring, and played on after Accept stopped the app's.
      const ringFor = Duration(seconds: 45);
      final inApp = NotificationService.incomingCallDetails(ringing: true, ringFor: ringFor);
      final alone = NotificationService.incomingCallDetails(ringing: false, ringFor: ringFor);
      expect(inApp.android!.channelId, NotificationService.callChannelInAppId);
      expect(inApp.android!.sound, isNull);
      expect(alone.android!.channelId, NotificationService.callChannelId);
      expect(alone.android!.sound, isNotNull);
    });
  });

  group('a call arriving while the app is in front', () {
    Future<List<RouteSettings>> app(WidgetTester tester) async {
      final opened = <RouteSettings>[];
      final key = GlobalKey<NavigatorState>();
      NotificationService.instance.navigatorKey = key;
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        initialRoute: '/home',
        onGenerateRoute: (settings) {
          opened.add(settings);
          return MaterialPageRoute(settings: settings, builder: (_) => const SizedBox());
        },
      ));
      opened.clear();
      return opened;
    }

    testWidgets('opens its call screen at once, ringing', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final opened = await app(tester);
      await tester.runAsync(() => NotificationService.instance.showIncomingCall(
            roomId: 'room-1', callerName: 'Bea Buyer', listingName: 'Samsung A54',
            payload: push('room-1')));
      await tester.pump();
      expect(opened.map((r) => r.name), ['/voip-call'],
          reason: 'Accept is on the call screen itself - no notification to find, '
              'no round trip to the server before the call opens');
      final args = opened.single.arguments as Map;
      expect(args['roomId'], 'room-1');
      expect(args['callToken'], 'callee-token');
      expect(args['autoAccept'], isFalse, reason: 'it rings; only Accept answers');
      expect(shown, isEmpty, reason: 'the screen is the incoming call - nothing else rings');
      expect(ActiveCall.instance.roomId, 'room-1');
    });

    testWidgets('with the app behind another, it is a notification', (tester) async {
      final opened = await app(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // As the push to a backgrounded app draws it.
      await tester.runAsync(() => NotificationService.instance.showIncomingCall(
            roomId: 'room-2', callerName: 'Bea Buyer', listingName: 'Samsung A54',
            payload: push('room-2'), ringInApp: false));
      expect(opened, isEmpty);
      expect(shown, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
  });

  group('back from a long time away', () {
    testWidgets('never sweeps away a call screen', (tester) async {
      // The guard read the top route as ModalRoute.of(nav.context): always
      // null, so a call answered from the notification of an app that had
      // been in the background for five minutes could be swept to Home.
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        initialRoute: '/home',
        onGenerateRoute: (settings) =>
            MaterialPageRoute(settings: settings, builder: (_) => Text(settings.name ?? '')),
      ));
      key.currentState!.pushNamed('/voip-call');
      await tester.pumpAndSettle();
      expect(returnHomeAfterAbsence(key.currentState!), isFalse);
      await tester.pumpAndSettle();
      expect(NotificationService.topRouteName(key.currentState!), '/voip-call');

      key.currentState!.pop();
      key.currentState!.pushNamed('/inbox');
      await tester.pumpAndSettle();
      expect(returnHomeAfterAbsence(key.currentState!), isTrue);
      await tester.pumpAndSettle();
      expect(NotificationService.topRouteName(key.currentState!), '/home');
    });
  });

  group('connecting', () {
    test("an offer that arrives before the callee's connection is ready is kept", () {
      // The callee's socket now opens while its microphone does, so the
      // caller's offer can come first. Dropped, the call never connected.
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: false, userId: 'seller-1', callToken: 't');
      svc.debugReceiveSignal(jsonEncode({'type': 'offer', 'sdp': 'v=0 offer'}));
      expect(svc.debugHeldOffer, 'v=0 offer');
      expect(svc.state, CallState.idle, reason: 'answered once the connection exists');
    });

    test('switching to video waits for the call to connect, and says so', () async {
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
      expect(await svc.upgradeToVideo(), contains('once the call has connected'));
      expect(svc.isVideo, isFalse);
    });
  });

  group('the call screen', () {
    Future<WebRtcService> open(WidgetTester tester, Map<String, Object?> args) async {
      late WebRtcService svc;
      VoipCallScreen.debugOnService = (s) => svc = s;
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
      nav.currentState!.push(MaterialPageRoute<void>(
        settings: RouteSettings(name: '/voip-call', arguments: {
          'roomId': 'room-1',
          'userId': 'seller-1',
          'callToken': 't',
          'peerName': 'Bea Buyer',
          'listingId': 'listing-1',
          'buyerId': 'buyer-1',
          ...args,
        }),
        builder: (_) => const VoipCallScreen(animateBackground: false),
      ));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      return svc;
    }

    Future<void> close(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    testWidgets('a voice call offers video', (tester) async {
      permissions = (_) => Completer<Object?>().future; // the dialog stays up
      await open(tester, {'isCaller': true, 'callerRole': 'seller'});
      expect(find.byKey(const Key('call-switch-to-video')), findsOneWidget);
      // Before the call connects, the button says when it works rather
      // than doing nothing.
      await tester.tap(find.byKey(const Key('call-switch-to-video')));
      await tester.pump();
      expect(find.text('You can switch to video once the call has connected.'), findsOneWidget);
      await close(tester);
    });

    testWidgets('a call I accepted is never logged as missed', (tester) async {
      // Accepted, then the call never connected (here: microphone refused).
      // It was logged "missed" - and the callee, who had pressed Accept,
      // saw a missed call.
      await open(tester, {'isCaller': false, 'autoAccept': true, 'callerRole': 'buyer'});
      await tester.pump(const Duration(seconds: 3));
      final logged = fakeRequests.where(
          (r) => r.method == 'POST' && r.uri.path == '/calls/log-result');
      expect(logged, hasLength(1));
      expect((logged.single.json as Map)['outcome'], 'completed');
      await close(tester);
    });

    testWidgets('the caller hears it ring once their phone rings, until they answer',
        (tester) async {
      RingbackService.debugSupported = true;
      permissions = (_) => Completer<Object?>().future; // still setting up
      final svc = await open(tester, {'isCaller': true, 'callerRole': 'seller'});
      expect(RingbackService.instance.isPlaying, isFalse,
          reason: '"Calling…" is silent - the call has reached only the server');

      svc.onPeerRinging!();
      await tester.pump();
      expect(RingbackService.instance.isPlaying, isTrue);
      for (var i = 0; i < 40 && !players.any((c) => c.method == 'setSourceUrl'); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      }
      final source = players.lastWhere((c) => c.method == 'setSourceUrl');
      expect((source.arguments as Map)['url'], endsWith('ringback.wav'));
      // On the call's own audio: a player's context is applied to the whole
      // phone, and the default one takes a call out of communication mode.
      final context = players.lastWhere((c) => c.method == 'setAudioContext').arguments as Map;
      expect(context['audioMode'], 3, reason: 'MODE_IN_COMMUNICATION, as the call');
      expect(context['isSpeakerphoneOn'], isFalse, reason: 'a voice call starts on the earpiece');

      svc.onPeerAnswered!();
      await tester.pump();
      expect(RingbackService.instance.isPlaying, isFalse, reason: 'they answered');
      await close(tester);
      // The mock player never reports the sound loaded: let audioplayers'
      // own 30-second wait for it run out.
      await tester.pump(const Duration(seconds: 31));
    });
  });
}
