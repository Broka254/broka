// Answering without "Connecting…" (2026-11-09, CALLING.md).
//
// After Accept the callee's phone used to open its socket, join, wait for
// `ready`, take the offer, answer, and only then run ICE and DTLS - 3 to 5
// seconds of "Connecting…" on mobile data. A voice call ringing on the
// in-app screen is now negotiated while it rings, on a "standby" socket
// (/calls/ws/{room}/ringing): the caller sends its offer on
// `ringing_ready`, the ringing phone answers with no microphone, and the
// connection comes up before anyone has answered. These drive both ends
// of WebRtcService against the server's frames (backend
// tests/test_call_answer_while_ringing.py drives the server's side) with
// the native peer connection, microphone and socket faked.
import 'package:broka/services/webrtc_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart' show FakeSocket;
import 'support/fake_webrtc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<FakePeerConnection> pcs;
  late List<FakeSocket> sockets;
  late List<Uri> uris;
  late FakeTrack mic;

  setUpAll(installFakeApi);

  setUp(() {
    pcs = [];
    sockets = [];
    uris = [];
    mic = FakeTrack('mic', 'audio');
    // No relay credentials: the STUN-only configuration, at once.
    setFakeRoute((uri) => uri.path.endsWith('/turn-credentials')
        ? const FakeResponse({'detail': 'gone'}, statusCode: 410)
        : null);
    WebRtcService.debugPreconnectSupported = true;
    WebRtcService.debugCreatePeerConnection = (_) async {
      final pc = FakePeerConnection();
      pcs.add(pc);
      return pc;
    };
    WebRtcService.debugGetUserMedia = (_) async => FakeStream([mic]);
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

  Future<void> settle() => pumpEventQueue(times: 60);

  List<Map<String, dynamic>> sent(String type, [FakeSocket? on]) =>
      [for (final m in (on ?? sockets.last).sentJson) if (m['type'] == type) m];

  group('the ringing phone', () {
    WebRtcService callee() => WebRtcService(
        roomId: 'room-1', isCaller: false, userId: 'seller-1', callToken: 't');

    test('answers while it rings, hears nothing, and is on the call at Accept', () async {
      final svc = callee();
      final states = <CallState>[];
      svc.onStateChange = states.add;

      svc.prepareRinging();
      await settle();
      expect(uris.single.path, '/calls/ws/room-1/ringing');
      expect(uris.single.queryParameters['peer'], svc.debugPeerId);
      expect(svc.debugStandby, isTrue);

      sockets.single.emit({'type': 'offer', 'sdp': 'v=0 caller offer', 'offer_id': 'o1'});
      await settle();
      final answer = sent('answer').single;
      expect(answer['offer_id'], 'o1', reason: 'names the offer it answers');
      final pc = pcs.single;
      expect(pc.answeredDirections, [TransceiverDirection.SendRecv],
          reason: 'room for the microphone, so Accept needs no second negotiation');
      expect(pc.transceivers.single.sender.track, isNull,
          reason: 'no microphone while it rings');

      final theirAudio = pc.deliverRemoteAudio();
      expect(theirAudio.enabled, isFalse, reason: 'the caller is not heard before Accept');
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await settle();
      expect(states, isEmpty,
          reason: 'nothing changes while it rings - the call screen stops the ringtone on any change');
      expect(sent('state'), isEmpty, reason: 'the server is not told of a call nobody answered');

      await svc.start(); // Accept
      await settle();
      expect(sent('accept'), hasLength(1));
      expect(uris, hasLength(1), reason: 'answered on the socket already there');
      expect(pc.transceivers.single.sender.track, same(mic));
      expect(theirAudio.enabled, isTrue);
      expect(states, [CallState.connecting, CallState.connected]);
      expect(pcs, hasLength(1), reason: 'the connection made while it rang');
      await svc.dispose();
    });

    test('Accept before any offer answers the offer with the microphone', () async {
      final svc = callee();
      svc.prepareRinging();
      await settle();
      await svc.start();
      await settle();
      sockets.single.emit({'type': 'offer', 'sdp': 'v=0 caller offer', 'offer_id': 'o1'});
      await settle();
      final pc = pcs.single;
      expect(pc.answeredDirections, [TransceiverDirection.SendRecv]);
      expect(pc.transceivers.single.sender.track, same(mic));
      expect(svc.state, CallState.ringing, reason: 'waiting for the connection, under the connect timeout');
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      expect(svc.state, CallState.connected);
      await svc.dispose();
    });

    test('a refused ringing socket answers the old way, without a word', () async {
      final svc = callee();
      final states = <CallState>[];
      svc.onStateChange = states.add;
      svc.prepareRinging();
      await settle();
      // CALL_RINGING_PRECONNECT off, or a server without the route.
      sockets.single.closeWith(code: 4010, reason: 'switched off');
      await settle();
      expect(svc.debugStandby, isFalse);
      expect(states, isEmpty, reason: 'still ringing');
      expect(pcs.single.closed, isTrue);

      await svc.start();
      await settle();
      expect(uris.last.path, '/calls/ws/room-1');
      expect(uris.last.queryParameters.containsKey('peer'), isFalse);
      sockets.last.emit({'type': 'offer', 'sdp': 'v=0 caller offer'});
      await settle();
      expect(sent('answer'), hasLength(1));
      // The connection made after Accept carries the microphone and plays
      // the caller: nothing of the abandoned one is held.
      final pc = pcs.last;
      expect(pc.transceivers.single.sender.track, same(mic));
      expect(pc.deliverRemoteAudio().enabled, isTrue);
      await svc.dispose();
    });

    test("the caller's hang-up while it rings ends the call", () async {
      final svc = callee();
      final states = <CallState>[];
      svc.onStateChange = states.add;
      svc.prepareRinging();
      await settle();
      sockets.single.emit({'type': 'hangup', 'reason': 'cancelled'});
      await settle();
      expect(states, [CallState.ended]);
      await svc.dispose();
    });

    test('declining sends no hang-up from a phone that never joined', () async {
      final svc = callee();
      svc.prepareRinging();
      await settle();
      await svc.hangup();
      expect(sent('hangup', sockets.single), isEmpty,
          reason: 'the decline is logged through POST /calls/log-result');
      expect(sockets.single.closed, isTrue);
    });

    test('an offer with a new id is answered on a new connection', () async {
      final svc = callee();
      svc.prepareRinging();
      await settle();
      sockets.single.emit({'type': 'offer', 'sdp': 'v=0 first', 'offer_id': 'o1'});
      await settle();
      // The same offer again: the caller lacks the answer, so it goes again.
      sockets.single.emit({'type': 'offer', 'sdp': 'v=0 first', 'offer_id': 'o1'});
      await settle();
      expect(sent('answer').map((m) => m['offer_id']), ['o1', 'o1']);
      expect(pcs, hasLength(1));

      // The caller started again on a connection of its own.
      sockets.single.emit({'type': 'offer', 'sdp': 'v=0 second', 'offer_id': 'o2'});
      await settle();
      expect(pcs, hasLength(2));
      expect(pcs.first.closed, isTrue);
      expect(sent('answer').last['offer_id'], 'o2');
      expect(pcs.last.remoteDescription?.sdp, 'v=0 second');
      await svc.dispose();
    });

    test('a video call rings the old way', () async {
      final video = WebRtcService(roomId: 'room-1', isCaller: false,
          userId: 'seller-1', callToken: 't', callType: 'video');
      video.prepareRinging();
      await settle();
      expect(video.debugStandby, isFalse);
      expect(uris, isEmpty);
      await video.dispose();
    });
  });

  group('the caller', () {
    Future<(WebRtcService, List<CallState>)> calling() async {
      final svc = WebRtcService(
          roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');
      final states = <CallState>[];
      svc.onStateChange = states.add;
      await svc.start();
      await settle();
      expect(svc.state, CallState.calling);
      return (svc, states);
    }

    test('offers to the ringing phone, holds its microphone, and is through at ready', () async {
      final (svc, states) = await calling();
      var joined = 0;
      svc.onPeerJoined = () => joined++;

      sockets.single.emit({'type': 'ringing_ready', 'room_id': 'room-1', 'peer': 'phone-a'});
      await settle();
      final offer = sent('offer').single;
      expect(offer['offer_id'], isNotNull);
      expect(mic.enabled, isFalse, reason: 'nobody has answered: nothing of this phone is heard');
      expect(svc.debugMediaHeld, isTrue);

      sockets.single.emit({'type': 'answer', 'sdp': 'v=0 answer', 'offer_id': offer['offer_id']});
      await settle();
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await settle();
      expect(states, [CallState.connecting, CallState.calling],
          reason: 'still ringing on their side');
      expect(svc.peerJoined, isFalse, reason: "the no-answer window still runs");
      expect(joined, 0, reason: 'the ringback goes on');
      expect(sent('state'), isEmpty);

      // Muting while it rings doesn't let the microphone go.
      svc.toggleMute();
      svc.toggleMute();
      expect(mic.enabled, isFalse);

      sockets.single.emit({'type': 'ready', 'room_id': 'room-1', 'peer': 'phone-a'});
      await settle();
      expect(states.last, CallState.connected);
      expect(mic.enabled, isTrue);
      expect(svc.peerJoined, isTrue);
      expect(joined, 1);
      expect(sent('offer'), hasLength(1), reason: 'nothing left to negotiate');
      await svc.dispose();
    });

    test('answered on another phone: a fresh offer on a fresh connection', () async {
      final (svc, states) = await calling();
      sockets.single.emit({'type': 'ringing_ready', 'peer': 'phone-a'});
      await settle();
      final first = sent('offer').single;
      sockets.single.emit({'type': 'answer', 'sdp': 'v=0 answer a', 'offer_id': first['offer_id']});
      await settle();

      sockets.single.emit({'type': 'ready', 'peer': 'phone-b'});
      await settle();
      expect(pcs, hasLength(2));
      expect(pcs.first.closed, isTrue);
      final second = sent('offer').last;
      expect(sent('offer'), hasLength(2));
      expect(second['offer_id'], isNot(first['offer_id']));
      expect(mic.enabled, isTrue);
      expect(states.last, CallState.calling, reason: 'connecting with the phone that answered');

      // The first phone's answer, late: not for this connection.
      sockets.single.emit({'type': 'answer', 'sdp': 'v=0 answer a', 'offer_id': first['offer_id']});
      await settle();
      expect(pcs.last.remoteDescription, isNull);
      sockets.single.emit({'type': 'answer', 'sdp': 'v=0 answer b', 'offer_id': second['offer_id']});
      await settle();
      expect(pcs.last.remoteDescription?.sdp, 'v=0 answer b');
      await svc.dispose();
    });

    test('the ringing phone leaving drops what was negotiated with it', () async {
      final (svc, _) = await calling();
      sockets.single.emit({'type': 'ringing_ready', 'peer': 'phone-a'});
      await settle();
      sockets.single.emit({'type': 'ringing_left', 'peer': 'phone-a'});
      await settle();
      expect(pcs, hasLength(2));
      expect(mic.enabled, isTrue);
      expect(svc.debugMediaHeld, isFalse);

      // It answers from its notification, the old way.
      sockets.single.emit({'type': 'ready'});
      await settle();
      expect(sent('offer'), hasLength(2));
      await svc.dispose();
    });

    test('a connection that fails while it rings is no failed call', () async {
      final (svc, states) = await calling();
      sockets.single.emit({'type': 'ringing_ready', 'peer': 'phone-a'});
      await settle();
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle();
      expect(states.last, CallState.calling);
      expect(pcs, hasLength(2), reason: 'a new connection, for whoever answers');
      await svc.dispose();
    });

    test('an old callee that never rings in the room is called as before', () async {
      final (svc, _) = await calling();
      expect(sent('offer'), isEmpty, reason: 'nobody to offer to while it rings');
      sockets.single.emit({'type': 'ready'});
      await settle();
      expect(sent('offer'), hasLength(1));
      expect(mic.enabled, isTrue);
      sockets.single.emit({'type': 'answer', 'sdp': 'v=0 old answer'});
      await settle();
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      expect(svc.state, CallState.connected);
      await svc.dispose();
    });
  });
}
