// A call that is answered either connects or ends, both sides alike, and
// says why (2026-11-13, CALLING.md).
//
// Reported: A calls, B accepts, both sit on "Connecting..." until it drops
// about ten seconds in. The caller's setup had failed (call_setup tests);
// these cover what that, and the WebRTC side of the same symptom, left
// behind:
//
//  * a callee whose caller never came waited for an offer with no timer
//    at all - "Connecting..." for good;
//  * a candidate could leave before the offer or answer it belongs to, or
//    arrive while its description was still being applied - and be lost,
//    often the relay candidate carrier-grade NAT needs;
//  * a connection that failed before it ever came up ended at once, with
//    no second try, and the other phone was never told;
//  * candidates trickled while signalling was down were never sent again,
//    and a socket refused for an expired call token could never come back;
//  * nothing the phone saw reached Render.
//
// Both ends of WebRtcService are driven against the server's frames with
// the native peer connection, microphone and socket faked.
import 'dart:async';
import 'dart:convert';

import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart' show FakeSocket;
import 'support/fake_webrtc.dart';

/// A peer connection that gathers its candidates as a local description is
/// set - before setLocalDescription returns, as native WebRTC can fire
/// them ahead of the Dart side sending the description - and can hold a
/// remote description half-applied.
class IcePc extends FakePeerConnection {
  List<String> gatherOnSet = const [];
  Completer<void>? holdRemote;

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    await super.setLocalDescription(description);
    for (final c in gatherOnSet) {
      onIceCandidate?.call(RTCIceCandidate(c, '0', 0));
    }
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    final hold = holdRemote;
    if (hold != null) await hold.future;
    await super.setRemoteDescription(description);
  }

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {}
}

String candidate(String type, String ufrag, {String ip = '198.51.100.7', int n = 1}) =>
    'candidate:$n 1 udp 2122260223 $ip ${50000 + n} typ $type generation 0 ufrag $ufrag network-id 1';

String sdp(String kind, String ufrag) =>
    'v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\na=ice-ufrag:$ufrag\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=sendrecv\r\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<IcePc> pcs;
  late List<FakeSocket> sockets;
  late List<Uri> uris;
  late FakeTrack mic;
  late List<String> gatherOnSet;

  setUpAll(() {
    installFakeApi();
    // Answered at once: under a widget test's fake clock a platform channel
    // with no handler never answers at all.
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

  Object? turnRoute(Uri uri) {
    if (uri.path.endsWith('/turn-credentials')) {
      return const FakeResponse({'detail': 'relay down'}, statusCode: 503);
    }
    return null;
  }

  setUp(() {
    pcs = [];
    sockets = [];
    uris = [];
    gatherOnSet = const [];
    clearFakeRequests();
    mic = FakeTrack('mic', 'audio');
    setFakeRoute(turnRoute);
    WebRtcService.debugPreconnectSupported = false;
    WebRtcService.debugCreatePeerConnection = (_) async {
      final pc = IcePc()..gatherOnSet = gatherOnSet;
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

  Future<void> settle() => pumpEventQueue(times: 80);

  /// Inside a widget test's fake clock: microtasks, then [d] of time.
  Future<void> wait(WidgetTester tester, [Duration d = Duration.zero]) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
    if (d > Duration.zero) await tester.pump(d);
    for (var i = 0; i < 20; i++) {
      await tester.pump();
    }
  }

  List<Map<String, dynamic>> sent(String type, [FakeSocket? on]) =>
      [for (final m in (on ?? sockets.last).sentJson) if (m['type'] == type) m];

  WebRtcService callee() =>
      WebRtcService(roomId: 'room-1', isCaller: false, userId: 'seller-1', callToken: 't');

  WebRtcService caller() =>
      WebRtcService(roomId: 'room-1', isCaller: true, userId: 'buyer-1', callToken: 't');

  /// A caller through to an answered offer. [s] settles: pumpEventQueue in
  /// a plain test, the tester's pump in a widget test (where the first
  /// never returns).
  Future<WebRtcService> callerAnswered([Future<void> Function()? s]) async {
    final go = s ?? settle;
    final svc = caller();
    unawaited(svc.start());
    await go();
    sockets.single.emit({'type': 'ready'});
    await go();
    final offer = sent('offer').single;
    sockets.single.emit({'type': 'answer', 'sdp': sdp('answer', 'R1'), 'offer_id': offer['offer_id']});
    await go();
    return svc;
  }

  group('a callee waiting for a caller who never comes', () {
    testWidgets('gives up with no_offer, and says so to the server', (tester) async {
      final svc = callee();
      final states = <CallState>[];
      svc.onStateChange = states.add;
      unawaited(svc.start()); // Accept, the old way
      await wait(tester);
      sockets.single.emit({'type': 'ping'}); // the server is there; the caller is not
      await wait(tester);
      expect(svc.state, CallState.connecting);

      await wait(tester, const Duration(seconds: 31));
      expect(states.last, CallState.failed,
          reason: '"Connecting..." used to last until somebody hung up');
      expect(svc.failureReason, 'no_offer');
      expect(sent('hangup').single, containsPair('reason', 'failed'));
      expect(sent('hangup').single, containsPair('detail', 'no_offer'));
      await svc.dispose();
    });

    testWidgets('an offer in time is answered as before', (tester) async {
      final svc = callee();
      unawaited(svc.start());
      await wait(tester);
      await wait(tester, const Duration(seconds: 20));
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await wait(tester);
      expect(sent('answer'), hasLength(1));
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await wait(tester, const Duration(seconds: 15));
      expect(svc.state, CallState.connected);
      await svc.dispose();
    });
  });

  group('candidates and the descriptions they belong to', () {
    test('an answer goes before its candidates', () async {
      gatherOnSet = [candidate('host', 'A1', n: 1), candidate('relay', 'A1', n: 2)];
      final svc = callee();
      await svc.start();
      await settle();
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await settle();
      final types = [for (final m in sockets.single.sentJson) m['type']]
          .where((t) => t == 'answer' || t == 'ice').toList();
      expect(types, ['answer', 'ice', 'ice'],
          reason: 'a candidate ahead of its answer is added to no description');
      await svc.dispose();
    });

    testWidgets('a restart offer goes before its candidates', (tester) async {
      final svc = caller();
      unawaited(svc.start());
      await wait(tester);
      sockets.single.emit({'type': 'ready'});
      await wait(tester);
      final offer = sent('offer').single;
      sockets.single.emit({'type': 'answer', 'sdp': sdp('answer', 'R1'), 'offer_id': offer['offer_id']});
      await wait(tester);
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await wait(tester);
      expect(svc.state, CallState.connected);

      // The network changes: the connection drops, and is restarted after
      // the grace period - gathering a relay candidate for the new session.
      pcs.single.gatherOnSet = [candidate('relay', 'C2', n: 9)];
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
      await wait(tester, const Duration(seconds: 7));
      final after = sockets.single.sentJson.skipWhile((m) => m['type'] != 'offer' || m['restart'] != true);
      expect(after.first['type'], 'offer', reason: 'the restart offer first');
      expect(after.where((m) => m['type'] == 'ice'), isNotEmpty, reason: 'then its candidate');
      final before = sockets.single.sentJson.takeWhile((m) => m['restart'] != true);
      expect(before.where((m) => m['type'] == 'ice' &&
          (m['candidate'] as Map)['candidate'].toString().contains('ufrag C2')), isEmpty,
          reason: 'the new session\'s candidate never ahead of its offer');
      await svc.dispose();
    });

    test('a candidate that arrives while its description is applied waits for it', () async {
      final svc = callee();
      await svc.start();
      await settle();
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await settle();
      final pc = pcs.single;
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await settle();

      // The caller restarts ICE; its new session's candidate arrives while
      // the restart offer is still being applied.
      pc.holdRemote = Completer<void>();
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C2'), 'restart': true});
      await settle();
      sockets.single.emit({'type': 'ice', 'candidate': {
        'candidate': candidate('relay', 'C2'), 'sdpMid': '0', 'sdpMLineIndex': 0}});
      await settle();
      expect(pc.candidates, isEmpty,
          reason: 'added now, it would go to the old session and be lost');
      pc.holdRemote!.complete();
      pc.holdRemote = null;
      await settle();
      expect(pc.candidates.map((c) => c.candidate), [candidate('relay', 'C2')]);
      await svc.dispose();
    });

    test('a candidate for a description still on its way is kept for it', () async {
      final svc = callee();
      await svc.start();
      await settle();
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await settle();
      final pc = pcs.single;
      // An older caller sends its restart's candidate ahead of the restart.
      sockets.single.emit({'type': 'ice', 'candidate': {
        'candidate': candidate('relay', 'C2'), 'sdpMid': '0', 'sdpMLineIndex': 0}});
      sockets.single.emit({'type': 'ice', 'candidate': {
        'candidate': candidate('host', 'C1', n: 3), 'sdpMid': '0', 'sdpMLineIndex': 0}});
      await settle();
      expect(pc.candidates.map((c) => c.candidate), [candidate('host', 'C1', n: 3)],
          reason: "the current session's candidate is added; the next one's waits");
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C2'), 'restart': true});
      await settle();
      expect(pc.candidates.map((c) => c.candidate).last, candidate('relay', 'C2'));
      await svc.dispose();
    });
  });

  group('a connection that never comes up', () {
    test('the caller tries once more with fresh relay credentials, then says why', () async {
      final svc = await callerAnswered();
      final pc = pcs.single;
      final turnAsks = fakeRequests.where((r) => r.uri.path.endsWith('/turn-credentials')).length;
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle();
      expect(svc.state, CallState.calling, reason: 'not over at the first failure');
      expect(sent('offer').last['restart'], isTrue);
      expect(fakeRequests.where((r) => r.uri.path.endsWith('/turn-credentials')).length,
          greaterThan(turnAsks), reason: 'the relay asked for again - it failed the first time');

      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle();
      expect(svc.state, CallState.failed);
      expect(svc.failureReason, 'ice_failed');
      expect(sent('hangup').single, containsPair('detail', 'ice_failed'),
          reason: 'the callee is told, rather than left on "Connecting..."');
      await svc.dispose();
    });

    testWidgets('the callee waits for that second try', (tester) async {
      final svc = callee();
      unawaited(svc.start());
      await wait(tester);
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await wait(tester);
      final pc = pcs.single;
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await wait(tester, const Duration(seconds: 2));
      expect(svc.state, isNot(CallState.failed));

      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C2'), 'restart': true});
      await wait(tester);
      expect(sent('answer').last['restart'], isTrue);
      pc.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await wait(tester, const Duration(seconds: 20));
      expect(svc.state, CallState.connected);
      await svc.dispose();
    });

    testWidgets('and gives up when it never comes', (tester) async {
      final svc = callee();
      unawaited(svc.start());
      await wait(tester);
      sockets.single.emit({'type': 'offer', 'sdp': sdp('offer', 'C1')});
      await wait(tester);
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await wait(tester, const Duration(seconds: 13));
      expect(svc.state, CallState.failed);
      expect(svc.failureReason, 'ice_failed');
      await svc.dispose();
    });
  });

  group('signalling that drops and comes back', () {
    testWidgets('candidates go again after a reconnect', (tester) async {
      final svc = caller();
      unawaited(svc.start());
      await wait(tester);
      sockets.single.emit({'type': 'ready'});
      await wait(tester);
      final offer = sent('offer').single;
      sockets.single.emit({'type': 'answer', 'sdp': sdp('answer', 'R1'), 'offer_id': offer['offer_id']});
      await wait(tester);
      final first = sockets.single;
      final pc = pcs.single;
      pc.onIceCandidate?.call(RTCIceCandidate(candidate('relay', 'C1', n: 5), '0', 0));
      await wait(tester);
      expect(sent('ice', first), hasLength(1));

      first.closeWith(code: 1006);
      await wait(tester, const Duration(seconds: 2));
      expect(sockets, hasLength(2), reason: 'reconnected');
      sockets.last.emit({'type': 'ready'});
      await wait(tester);
      expect(sent('ice', sockets.last).map((m) => (m['candidate'] as Map)['candidate']),
          contains(candidate('relay', 'C1', n: 5)),
          reason: 'trickled before the drop, it may never have arrived');
      await svc.dispose();
    });

    testWidgets('a socket refused for an expired call token comes back with a fresh one',
        (tester) async {
      setFakeRoute((uri) => uri.path == '/calls/room-1/token'
          ? {'call_token': 'fresh-token'}
          : turnRoute(uri));
      final svc = await callerAnswered(() => wait(tester));
      sockets.single.closeWith(code: 4001, reason: 'Unauthorized');
      await wait(tester, const Duration(seconds: 2));
      expect(uris.last.queryParameters['token'], 'fresh-token',
          reason: 'five minutes in, every reconnect was refused with the old token');
      expect(svc.callToken, 'fresh-token');
      await svc.dispose();
    });

    testWidgets('an old socket closing never touches the new one', (tester) async {
      final svc = await callerAnswered(() => wait(tester));
      final first = sockets.single;
      first.closeWith(code: 1006);
      await wait(tester, const Duration(seconds: 2));
      final second = sockets.last;
      second.emit({'type': 'ping'});
      await wait(tester);
      // The old socket's stream says something late, and closes again.
      first.emitRaw(jsonEncode({'type': 'hangup'}));
      await wait(tester, const Duration(seconds: 5));
      expect(sockets, hasLength(2), reason: 'no reconnect for a superseded socket');
      expect(svc.state, isNot(CallState.ended));
      await svc.dispose();
    });
  });

  group('what the phone sees, for the logs', () {
    test('goes to the server as events, and what could not is posted at the end', () async {
      final svc = await callerAnswered();
      final socket = sockets.single;
      final diag = sent('diag', socket);
      final names = diag.map((m) => m['event']).toList();
      expect(names, containsAll(<String>[
        'TURN_CREDENTIAL_REQUEST', 'TURN_CREDENTIAL_FAILURE', 'CALL_INITIATED',
        'WEBSOCKET_CONNECTED', 'PEER_JOINED', 'SDP_OFFER_CREATED', 'SDP_OFFER_SENT',
        'SDP_ANSWER_RECEIVED',
      ]), reason: 'what happened before the socket was open went once it was');
      final turn = diag.firstWhere((m) => m['event'] == 'TURN_CREDENTIAL_FAILURE');
      expect(turn['reason'], 'relay_unavailable');
      for (final key in ['call_state', 'ws', 'ice_gathering', 'ice', 'pc', 'path', 'seq', 'client_ts']) {
        expect(turn.containsKey(key), isTrue, reason: 'every event carries $key');
      }
      final offerSent = diag.firstWhere((m) => m['event'] == 'SDP_OFFER_CREATED');
      expect(offerSent.containsKey('sdp'), isFalse, reason: 'never the SDP itself');

      pcs.single.onIceCandidate?.call(RTCIceCandidate(candidate('srflx', 'C1', ip: '41.90.1.2'), '0', 0));
      await settle();
      final gathered = sent('diag', socket).lastWhere((m) => m['event'] == 'ICE_CANDIDATE_GATHERED');
      expect(gathered['candidate_type'], 'srflx');
      expect(jsonEncode(gathered).contains('41.90.1.2'), isFalse, reason: 'never an address');

      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle();
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      await settle();
      final posted = fakeRequests.where((r) => r.uri.path == '/calls/room-1/events').toList();
      expect(posted, hasLength(1), reason: 'the end of the call, in one post');
      final events = ((posted.single.json as Map)['events'] as List).cast<Map>();
      expect(events.map((e) => e['event']), containsAll(['WEBRTC_FAILED', 'CALL_ENDED']));
      expect(events.firstWhere((e) => e['event'] == 'CALL_ENDED')['reason'], 'ice_failed');
      expect((posted.single.json as Map)['call_token'], 't');
      await svc.dispose();
    });

    test('a connection that comes up says how, and that it really did', () async {
      final svc = await callerAnswered();
      pcs.single.reportState(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      await settle();
      expect(svc.state, CallState.connected);
      expect(svc.everConnected, isTrue);
      final names = sent('diag').map((m) => m['event']);
      expect(names, contains('WEBRTC_CONNECTED'));
      expect(sent('state').single['state'], 'connected');
      await svc.dispose();
    });
  });
}
