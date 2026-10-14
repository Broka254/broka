// The app closed the moment a call was placed or answered.
//
// The call screen started Android's call foreground service - declared with
// the microphone type - before WebRtcService had asked for the microphone.
// On Android 14+ a microphone foreground service without RECORD_AUDIO
// throws SecurityException inside the service and the OS kills the app
// (MIUI then shows "BROKA should be granted Microphone access to function
// properly"). The permission dialog never got a chance to appear, so the
// crash repeated on every call. These check the service is only started
// once the microphone has been granted and opened, and that it claims the
// camera only when the camera is actually in use.
import 'package:broka/screens/voip_call_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// permission_handler's Permission.value / PermissionStatus index.
const _camera = 1;
const _microphone = 7;
const _denied = 0;
const _granted = 1;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  // Everything that happened on the platform side, in order.
  late List<String> log;
  late Map<int, int> grants;
  late List<Map<Object?, Object?>> serviceStarts;

  setUp(() {
    log = [];
    serviceStarts = [];
    grants = {};

    messenger.setMockMethodCallHandler(
        const MethodChannel('com.broka.app/call_service'), (call) async {
      log.add('service.${call.method}');
      if (call.method == 'start') {
        serviceStarts.add(call.arguments as Map<Object?, Object?>);
      }
      return true;
    });

    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async {
      if (call.method == 'requestPermissions') {
        final asked = (call.arguments as List).cast<int>();
        log.add('permissions.request');
        return {for (final p in asked) p: grants[p] ?? _denied};
      }
      return _denied;
    });

    var textureId = 0;
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (call) async {
      switch (call.method) {
        case 'getUserMedia':
          log.add('media.open');
          final constraints =
              (call.arguments as Map)['constraints'] as Map;
          return {
            'streamId': 'local',
            'audioTracks': [
              {'id': 'a1', 'label': 'mic', 'kind': 'audio', 'enabled': true},
            ],
            'videoTracks': [
              if (constraints['video'] != false)
                {'id': 'v1', 'label': 'cam', 'kind': 'video', 'enabled': true},
            ],
          };
        case 'createVideoRenderer':
          return {'textureId': ++textureId};
        // Anything else - including createPeerConnection - answers null, so
        // the call fails just after the media step. That is as far as these
        // tests need to go.
        default:
          return null;
      }
    });
    for (final name in [
      'FlutterWebRTC.Event',
      'FlutterWebRTC/Texture1',
      'FlutterWebRTC/Texture2',
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  Future<void> placeCall(WidgetTester tester, {required String callType}) async {
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
        MaterialApp(navigatorKey: nav, home: const SizedBox()));
    nav.currentState!.push(MaterialPageRoute<void>(
      settings: RouteSettings(name: '/voip-call', arguments: {
        'roomId': 'room-1',
        'userId': 'buyer-1',
        'callToken': 't',
        'peerName': 'Seller',
        'isCaller': true,
        'callType': callType,
      }),
      builder: (_) => const VoipCallScreen(),
    ));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  // The failed call pops itself after 2s; let it, and tear down.
  Future<void> hangUp(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('microphone denied: the call service is never started',
      (tester) async {
    await placeCall(tester, callType: 'audio');

    expect(log, contains('permissions.request'));
    expect(log, isNot(contains('media.open')));
    expect(serviceStarts, isEmpty,
        reason: 'a microphone foreground service without the microphone '
            'permission kills the app on Android 14+');
    expect(find.textContaining('microphone access'), findsOneWidget);
    await hangUp(tester);
  });

  testWidgets('voice call: the service starts only once the mic is open',
      (tester) async {
    grants = {_microphone: _granted};
    await placeCall(tester, callType: 'audio');

    expect(serviceStarts, hasLength(1));
    expect(serviceStarts.single['isVideo'], isFalse);
    expect(log.indexOf('service.start'),
        greaterThan(log.indexOf('media.open')));
    expect(log.indexOf('media.open'),
        greaterThan(log.indexOf('permissions.request')));
    await hangUp(tester);
  });

  testWidgets('video call: claims the camera only when it was granted',
      (tester) async {
    grants = {_microphone: _granted, _camera: _granted};
    await placeCall(tester, callType: 'video');

    expect(serviceStarts, hasLength(1));
    expect(serviceStarts.single['isVideo'], isTrue);
    await hangUp(tester);
  });

  testWidgets('video call with the camera denied runs the service audio-only',
      (tester) async {
    grants = {_microphone: _granted, _camera: _denied};
    await placeCall(tester, callType: 'video');

    expect(serviceStarts, hasLength(1));
    expect(serviceStarts.single['isVideo'], isFalse,
        reason: 'a camera foreground service without the camera permission '
            'kills the app on Android 14+');
    await hangUp(tester);
  });
}
