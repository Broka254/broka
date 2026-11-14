// A call that is over stays over, on the phone too (2026-11-14).
//
// Railway, room HfedVQp_gK_0pLMgzro5eg: the caller hung up while the callee's
// phone had not yet heard of the call (it had no push token; its in-app
// sweep found the call 24 seconds later). The server - since fixed - still
// let that phone ring, wait in the room and answer, and handed its ringing
// socket the caller's old hang-up. On the phone, an Accept arriving after
// that hang-up had ended the ring started the call anyway: microphone,
// socket and peer connection, opened for nobody after the call's own
// clean-up had run. And the caller's record of the call could not say why
// nothing ever connected: its offer and candidates never left the phone,
// because nobody joined - and nothing said so.
//
// Both ends of WebRtcService are driven against the server's frames with
// the native peer connection, microphone and socket faked.
import 'dart:async';

import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart' show FakeSocket;
import 'support/fake_webrtc.dart';

/// A peer connection that gathers candidates as its local description is
/// set, as native WebRTC does.
class GatheringPc extends FakePeerConnection {
  List<String> gatherOnSet = const [];

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    await super.setLocalDescription(description);
    for (final c in gatherOnSet) {
      onIceCandidate?.call(RTCIceCandidate(c, '0', 0));
    }
  }

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {}
}

String candidate(String type, {int n = 1}) =>
    'candidate:$n 1 udp 2122260223 198.51.100.7 ${50000 + n} typ $type generation 0 ufrag C1 network-id 1';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<GatheringPc> pcs;
  late List<FakeSocket> sockets;
  late List<Uri> uris;
  late FakeTrack mic;
  late List<String> gatherOnSet;
  late int microphoneOpened;

  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 1};
      }
      return 1; // granted
    });
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (_) async => null);
  });

  setUp(() {
    pcs = [];
    sockets = [];
    uris = [];
    gatherOnSet = const [];
    microphoneOpened = 0;
    clearFakeRequests();
    mic = FakeTrack('mic', 'audio');
    // No relay credentials: the STUN-only configuration, at once.
    setFakeRoute((uri) => uri.path.endsWith('/turn-credentials')
        ? const FakeResponse({'detail': 'relay down'}, statusCode: 503)
        : null);
    WebRtcService.debugPreconnectSupported = true;
    WebRtcService.debugCreatePeerConnection = (_) async {
      final pc = GatheringPc()..gatherOnSet = gatherOnSet;
      pcs.add(pc);
      return pc;
    };
    WebRtcService.debugGetUserMedia = (_) async {
      microphoneOpened++;
      return FakeStream([mic]);
    };
    WebRtcService.debugConnectSocket = (uri) {
      uris.add(uri);
      final socket = FakeSocket();
      sockets.add(socket);
      return socket;
    };
  });

  tearDown(() {
    WebRtcService.debugPreconnectSupported = null;
    WebRtcService.debugCreatePeerConnection = null;
    WebRtcService.debugGetUserMedia = null;
    WebRtcService.debugConnectSocket = null;
    setFakeRoute(null);
  });

  Future<void> settle() => pumpEventQueue(times: 80);

  List<Map<String, dynamic>> sent(String type, [FakeSocket? on]) =>
      [for (final m in (on ?? sockets.last).sentJson) if (m['type'] == type) m];

  test('an Accept that comes after the call ended opens nothing', () async {
    final svc = WebRtcService(
        roomId: 'room-1', isCaller: false, userId: 'seller-1', callToken: 't');
    final states = <CallState>[];
    svc.onStateChange = states.add;
    svc.prepareRinging();
    await settle();
    expect(uris.single.path, '/calls/ws/room-1/ringing');

    // The caller hung up while it rang: the ring ends.
    sockets.single.emit({'type': 'hangup', 'reason': 'cancelled'});
    await settle();
    expect(states, [CallState.ended]);

    // The notification's Accept, a moment too late.
    await svc.start();
    await settle();
    expect(states, [CallState.ended], reason: 'a call that is over stays over');
    expect(uris, hasLength(1), reason: 'no socket is opened for it');
    expect(microphoneOpened, 0, reason: 'the microphone is never opened for nobody');
    expect(sent('accept', sockets.single), isEmpty);
    await svc.dispose();
  });

  test('a caller who hangs up before anyone joined says nothing was sent', () async {
    gatherOnSet = [candidate('host'), candidate('srflx', n: 2)];
    final svc = WebRtcService(
        roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
    unawaited(svc.start());
    await settle();
    expect(svc.state, CallState.calling);
    expect(sent('offer'), isEmpty, reason: 'nobody is in the room to send it to');

    await svc.hangup();
    final ended = svc.diagnostics.history.lastWhere((e) => e['event'] == 'CALL_ENDED');
    expect(ended['reason'], 'local_hangup');
    expect(ended['peer_joined'], isFalse);
    expect(ended['offers_sent'], 0);
    expect(ended['held'], 2, reason: 'the candidates gathered for an offer that never left');
    await svc.dispose();
  });

  test('a caller whose callee joined reports the offer it sent', () async {
    final svc = WebRtcService(
        roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
    unawaited(svc.start());
    await settle();
    sockets.single.emit({'type': 'ready', 'room_id': 'room-1'});
    await settle();
    expect(sent('offer'), hasLength(1));

    await svc.hangup();
    final ended = svc.diagnostics.history.lastWhere((e) => e['event'] == 'CALL_ENDED');
    expect(ended['peer_joined'], isTrue);
    expect(ended['offers_sent'], 1);
    expect(ended['held'], 0);
    await svc.dispose();
  });
}
