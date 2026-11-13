// Two phones, one real backend: the call scenarios of the 2026-11-13 pass.
//
//   python scripts/call_e2e/server.py --port 8765 --seed-out /tmp/seed.json &
//   BROKA_E2E_SEED=/tmp/seed.json flutter test test/e2e/call_e2e_test.dart \
//     --dart-define=API_URL=http://127.0.0.1:8765
//
// Skipped without BROKA_E2E_SEED - CI's `flutter test` has no backend to
// talk to. See scripts/call_e2e/README.md.
//
// What is real: both phones' WebRtcService - signalling, timers, recovery,
// outcome, diagnostics - over real WebSockets and HTTP to the real backend
// (its relay, call state machine and logs, as Render runs them).
//
// What is simulated: the native WebRTC stack (SimPc below). Each phone is
// given a network - "open" (Wi-Fi: its host/server-reflexive candidates
// can be reached) or "symmetric" (carrier-grade NAT, as on Kenyan mobile
// data: only a TURN relay gets through) - and a connection comes up only
// when the candidates the phones actually exchanged include a pair that
// network allows. Relay candidates exist only when the TURN credentials the
// backend issued were real. No audio is encoded or carried: "audio both
// ways" here means each phone's microphone track is on a send-and-receive
// transceiver and the other side's track is playing, not held.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/webrtc_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_webrtc.dart';

final String? _seedPath = Platform.environment['BROKA_E2E_SEED'];
const _side = #broka_e2e_side;

/// The two phones' networks, and the connections they make.
class SimNetwork {
  SimNetwork({required this.callerNat, required this.calleeNat});

  /// "open" | "symmetric"
  String callerNat;
  String calleeNat;
  final Map<String, SimPc> current = {};

  String natOf(String side) => side == 'caller' ? callerNat : calleeNat;

  bool pairWorks(String side, String localType, String remoteType) {
    if (localType == 'relay' || remoteType == 'relay') return true;
    return natOf(side) == 'open' && natOf(side == 'caller' ? 'callee' : 'caller') == 'open';
  }

  void check() {
    final a = current['caller'];
    final b = current['callee'];
    if (a == null || b == null) return;
    a._evaluate(b);
    b._evaluate(a);
  }
}

class SimPc extends FakePeerConnection {
  SimPc(this.net, this.side, this.config) {
    net.current[side] = this;
  }

  final SimNetwork net;
  final String side;
  Map<String, dynamic> config;
  int _session = 0;
  String get ufrag => '${side[0]}$_session';
  String? remoteUfrag;
  final Map<String, List<String>> _remote = {}; // ufrag -> candidate types
  final List<String> _localTypes = [];
  bool _gatheringDone = false;
  String _ice = 'new';
  Timer? _failTimer;
  bool _tracksSent = false;
  String? _pairLocal;
  String? _pairRemote;

  bool get _hasTurn {
    for (final s in (config['iceServers'] as List? ?? const [])) {
      final urls = (s as Map)['urls'];
      for (final u in (urls is List ? urls : [urls])) {
        if (u is String && u.startsWith('turn') && s['credential'] != null) return true;
      }
    }
    return false;
  }

  bool get _hasStun {
    for (final s in (config['iceServers'] as List? ?? const [])) {
      final urls = (s as Map)['urls'];
      for (final u in (urls is List ? urls : [urls])) {
        if (u is String && u.startsWith('stun:')) return true;
      }
    }
    return false;
  }

  String _sdp(String type) => 'v=0\r\no=- $_session 2 IN IP4 127.0.0.1\r\ns=-\r\n'
      'a=ice-ufrag:$ufrag\r\na=ice-pwd:simulated\r\n'
      'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000/2\r\n'
      'a=fmtp:111 minptime=10;useinbandfec=1\r\na=sendrecv\r\n';

  @override
  Future<RTCSessionDescription> createOffer([Map<String, dynamic> constraints = const {}]) async {
    if (constraints['iceRestart'] == true) _session++;
    return RTCSessionDescription(_sdp('offer'), 'offer');
  }

  @override
  Future<RTCSessionDescription> createAnswer([Map<String, dynamic> constraints = const {}]) async {
    answeredDirections = [for (final t in slots) t.direction];
    return RTCSessionDescription(_sdp('answer'), 'answer');
  }

  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    await super.setRemoteDescription(description);
    final m = RegExp(r'a=ice-ufrag:(\S+)').firstMatch(description.sdp ?? '');
    final newUfrag = m?.group(1);
    if (description.type == 'offer' && remoteUfrag != null && newUfrag != remoteUfrag) {
      _session++; // answering a restart: a new session here too
    }
    remoteUfrag = newUfrag;
    net.check();
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    await super.setLocalDescription(description);
    final session = _session;
    _localTypes.clear();
    _gatheringDone = false;
    // Gathering takes time on a phone, the relay's most of all.
    unawaited(Future<void>(() async {
      onIceGatheringState?.call(RTCIceGatheringState.RTCIceGatheringStateGathering);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (session != _session || closed) return;
      _emit('host', session, 1);
      if (_hasStun) {
        await Future<void>.delayed(const Duration(milliseconds: 40));
        if (session != _session || closed) return;
        _emit('srflx', session, 2);
      }
      if (_hasTurn) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (session != _session || closed) return;
        _emit('relay', session, 3);
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (session != _session || closed) return;
      _gatheringDone = true;
      onIceGatheringState?.call(RTCIceGatheringState.RTCIceGatheringStateComplete);
      net.check();
    }));
  }

  void _emit(String type, int session, int n) {
    _localTypes.add(type);
    final address = switch (type) {
      'host' => side == 'caller' ? '192.168.1.20' : '10.120.4.9',
      'srflx' => side == 'caller' ? '41.90.64.11' : '102.215.9.40',
      _ => '104.30.2.6',
    };
    onIceCandidate?.call(RTCIceCandidate(
        'candidate:$n 1 udp ${2130706431 - n * 1000} $address ${50000 + n} typ $type'
        '${type == 'host' ? '' : ' raddr 0.0.0.0 rport 0'} generation 0 ufrag ${side[0]}$session network-id 1',
        '0', 0));
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    await super.addCandidate(candidate);
    final line = candidate.candidate ?? '';
    final type = RegExp(r' typ (\S+)').firstMatch(line)?.group(1) ?? 'host';
    final ufrag = RegExp(r' ufrag (\S+)').firstMatch(line)?.group(1) ?? '';
    _remote.putIfAbsent(ufrag, () => []).add(type);
    net.check();
  }

  @override
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    config = configuration;
  }

  void _setIce(String state) {
    if (_ice == state) return;
    _ice = state;
    switch (state) {
      case 'checking':
        onIceConnectionState?.call(RTCIceConnectionState.RTCIceConnectionStateChecking);
        onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnecting);
      case 'connected':
        onIceConnectionState?.call(RTCIceConnectionState.RTCIceConnectionStateConnected);
        onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateConnected);
      case 'failed':
        onIceConnectionState?.call(RTCIceConnectionState.RTCIceConnectionStateFailed);
        onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateFailed);
      case 'disconnected':
        onIceConnectionState?.call(RTCIceConnectionState.RTCIceConnectionStateDisconnected);
        onConnectionState?.call(RTCPeerConnectionState.RTCPeerConnectionStateDisconnected);
    }
  }

  /// Can this phone reach [other] with what the two have exchanged?
  void _evaluate(SimPc other) {
    if (closed || localDescription == null || remoteDescription == null) return;
    if (remoteUfrag != other.ufrag) return; // still negotiating this session
    final received = _remote[other.ufrag] ?? const [];
    if (received.isEmpty) return;
    if (_ice == 'new' || _ice == 'failed' || _ice == 'disconnected') _setIce('checking');
    for (final local in _localTypes) {
      for (final remote in received) {
        if (net.pairWorks(side, local, remote)) {
          _failTimer?.cancel();
          _pairLocal = local;
          _pairRemote = remote;
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            if (closed || _ice == 'connected') return;
            _setIce('connected');
            if (!_tracksSent) {
              _tracksSent = true;
              deliverRemoteAudio();
            }
          });
          return;
        }
      }
    }
    // Nothing gets through - once both have gathered everything, ICE fails.
    if (_gatheringDone && other._gatheringDone) {
      _failTimer?.cancel();
      _failTimer = Timer(const Duration(milliseconds: 600), () {
        if (!closed && _ice != 'connected') _setIce('failed');
      });
    }
  }

  /// The network drops under a connected call.
  void dropNetwork() => _setIce('disconnected');

  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async => [
        StatsReport('T1', 'transport', 0, {'selectedCandidatePairId': 'CP1'}),
        StatsReport('CP1', 'candidate-pair', 0, {
          'state': 'succeeded', 'nominated': true, 'localCandidateId': 'L1',
          'remoteCandidateId': 'R1', 'currentRoundTripTime': 0.184,
        }),
        StatsReport('L1', 'local-candidate', 0, {
          'candidateType': _pairLocal ?? 'host', 'protocol': 'udp',
          if (_pairLocal == 'relay') 'relayProtocol': 'udp',
        }),
        StatsReport('R1', 'remote-candidate', 0, {
          'candidateType': _pairRemote ?? 'host', 'protocol': 'udp',
        }),
      ];

  @override
  Future<void> close() async {
    _failTimer?.cancel();
    await super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final skip = _seedPath == null ? 'needs the local backend (scripts/call_e2e)' : null;
  late Map<String, dynamic> seed;
  late SimNetwork net;
  final mics = <String, FakeTrack>{};
  const base = ApiService.baseUrl;

  setUpAll(() async {
    if (skip != null) return;
    HttpOverrides.global = null; // real sockets, to the local backend
    seed = jsonDecode(File(_seedPath!).readAsStringSync()) as Map<String, dynamic>;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'), (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 1};
      }
      return 1;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('FlutterWebRTC.Method'), (_) async => null);
  });

  setUp(() {
    if (skip != null) return;
    mics.clear();
    WebRtcService.debugCreatePeerConnection = (config) async {
      final side = Zone.current[_side] as String;
      return SimPc(net, side, config);
    };
    WebRtcService.debugGetUserMedia = (_) async {
      final side = Zone.current[_side] as String;
      final mic = FakeTrack('mic-$side', 'audio');
      mics[side] = mic;
      return FakeStream([mic]);
    };
  });

  // Every phone a test made: ended and disposed whatever the test did, so
  // a failing scenario never leaves a call up that makes the next one busy.
  final live = <WebRtcService>[];

  tearDown(() async {
    for (final s in live) {
      try { await s.dispose(); } catch (_) {}
    }
    live.clear();
    // The server sees the sockets go before the next call is placed.
    if (skip == null) await Future<void>.delayed(const Duration(milliseconds: 600));
    WebRtcService.debugCreatePeerConnection = null;
    WebRtcService.debugGetUserMedia = null;
    WebRtcService.debugPreconnectSupported = null;
  });

  WebRtcService phone(String side, String room, String token) {
    final s = runZoned(() => WebRtcService(
        roomId: room, isCaller: side == 'caller',
        userId: (seed[side] as Map)['id'] as String, callToken: token),
        zoneValues: {_side: side});
    live.add(s);
    return s;
  }

  Future<void> configure(Map<String, Object?> scenario) async {
    await http.post(Uri.parse('$base/__e2e/config'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(scenario));
  }

  Map<String, String> auth(String who) => {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${(seed[who] as Map)['token']}',
      };

  T on<T>(String side, T Function() body) => runZoned(body, zoneValues: {_side: side});

  Future<void> until(bool Function() condition, {Duration timeout = const Duration(seconds: 60)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException('condition', timeout);
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// The caller places the call the app's way: POST /calls/initiate under
  /// one attempt id, its retries and all.
  Future<Map<String, dynamic>> place() async {
    SharedPreferences.setMockInitialValues({
      'auth_token': (seed['caller'] as Map)['token'],
      'user_id': (seed['caller'] as Map)['id'],
      'user_name': (seed['caller'] as Map)['name'],
    });
    await ApiService.loadSavedSession();
    final info = await ApiService.initiateCall(
        listingId: seed['listing_id'] as String,
        listingName: 'Airtel Smart Connect Home & Office WiFi', callType: 'audio');
    if (info == null) throw StateError('the call could not be placed');
    return info;
  }

  /// The callee's phone finds the call ringing (what the push carries).
  Future<String> calleeToken() async {
    final r = await http.get(Uri.parse('$base/calls/incoming'), headers: auth('callee'));
    return (jsonDecode(r.body) as Map)['call_token'] as String;
  }

  Future<void> logResult(String who, String room, WebRtcService svc,
      {required bool answered, bool declined = false}) async {
    final outcome = VoipCallScreen.outcomeFor(
        everConnected: svc.everConnected, isCaller: svc.isCaller,
        answered: answered, declinedByMe: declined);
    await http.post(Uri.parse('$base/calls/log-result'), headers: auth(who), body: jsonEncode({
      'room_id': room, 'outcome': outcome, 'call_type': 'audio',
      'duration_secs': svc.everConnected ? svc.duration.inSeconds : null,
      if (svc.failureReason != null && outcome == 'failed_to_connect') 'reason': svc.failureReason,
    }));
  }

  Future<String> card(String room) async {
    final r = await http.get(Uri.parse('$base/calls/history?limit=1'), headers: auth('caller'));
    final calls = (jsonDecode(r.body) as Map)['calls'] as List;
    return calls.isEmpty ? '-' : (calls.first as Map)['outcome'] as String;
  }

  /// Both phones set up for one call; the callee rings in the app
  /// (negotiating while it rings) unless [fromNotification].
  Future<(WebRtcService, WebRtcService, String)> ring({bool fromNotification = false}) async {
    final placed = await place();
    final room = placed['room_id'] as String;
    final caller = phone('caller', room, placed['call_token'] as String);
    unawaited(on('caller', caller.start));
    final token = await calleeToken();
    WebRtcService.debugPreconnectSupported = !fromNotification;
    final callee = phone('callee', room, token);
    if (!fromNotification) on('callee', callee.prepareRinging);
    return (caller, callee, room);
  }

  Future<void> accept(WebRtcService callee, String room, {bool fromNotification = false}) async {
    await http.post(Uri.parse('$base/calls/$room/answer'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'call_token': callee.callToken}));
    if (fromNotification) on('callee', callee.prepare);
    unawaited(on('callee', callee.start));
  }

  void expectAudioBothWays(WebRtcService caller, WebRtcService callee) {
    expect(mics['caller']!.enabled, isTrue, reason: "the caller's microphone is on the call");
    expect(mics['callee']!.enabled, isTrue, reason: "the callee's microphone is on the call");
    for (final side in ['caller', 'callee']) {
      final pc = net.current[side]!;
      expect(pc.slots.any((t) => t.sender.track != null && t.direction == TransceiverDirection.SendRecv),
          isTrue, reason: '$side sends audio');
    }
  }

  Future<void> hangUpBoth(WebRtcService caller, WebRtcService callee, String room) async {
    await on('caller', caller.hangup);
    await until(() => callee.state == CallState.ended || callee.state == CallState.failed,
        timeout: const Duration(seconds: 10));
    await logResult('caller', room, caller, answered: true);
    await caller.dispose();
    await callee.dispose();
  }

  Future<void> connectsAndEnds(String label, {required String callerNat,
      required String calleeNat, bool fromNotification = false}) async {
    net = SimNetwork(callerNat: callerNat, calleeNat: calleeNat);
    await configure({'turn': 'ok', 'push_delay': 0});
    final (caller, callee, room) = await ring(fromNotification: fromNotification);
    // ignore: avoid_print
    print('E2E-ROOM $label $room');
    // B's phone rings for a couple of seconds before Accept.
    await Future<void>.delayed(const Duration(seconds: 2));
    final startedAt = DateTime.now();
    await accept(callee, room, fromNotification: fromNotification);
    await until(() => caller.state == CallState.connected && callee.state == CallState.connected);
    final took = DateTime.now().difference(startedAt);
    expect(caller.duration, Duration.zero, reason: 'the timer starts only once connected');
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(caller.duration.inSeconds, greaterThanOrEqualTo(1));
    expectAudioBothWays(caller, callee);
    // Through the relay whenever either side is behind carrier-grade NAT:
    // the selected pair has a relay candidate on one end or the other.
    final wanted = (callerNat == 'open' && calleeNat == 'open') ? 'host' : 'relay';
    for (final s in [caller, callee]) {
      await until(() => s.diagnostics.history.any((e) => e['event'] == 'ICE_CANDIDATE_PAIR_SELECTED'));
    }
    final pair = caller.diagnostics.history
        .lastWhere((e) => e['event'] == 'ICE_CANDIDATE_PAIR_SELECTED');
    expect(pair['path'], wanted);
    await hangUpBoth(caller, callee, room);
    expect(callee.state, CallState.ended, reason: 'both end the same way');
    expect(await card(room), 'completed');
    // ignore: avoid_print
    print('E2E $label: connected ${took.inMilliseconds}ms after Accept, '
        'path=${pair['path']} (${pair['local_type']} -> ${pair['remote_type']})');
  }

  group('calls that connect', () {
    test('A. both on Wi-Fi', () => connectsAndEnds('A wifi/wifi',
        callerNat: 'open', calleeNat: 'open'), skip: skip);
    test('B. both on mobile data (carrier-grade NAT): through the relay', () => connectsAndEnds(
        'B mobile/mobile', callerNat: 'symmetric', calleeNat: 'symmetric'), skip: skip);
    test('C. caller on Wi-Fi, callee on mobile data', () => connectsAndEnds(
        'C wifi/mobile', callerNat: 'open', calleeNat: 'symmetric'), skip: skip);
    test('D. caller on mobile data, callee on Wi-Fi', () => connectsAndEnds(
        'D mobile/wifi', callerNat: 'symmetric', calleeNat: 'open'), skip: skip);
    test('E. accepted from the notification, the app in the background', () => connectsAndEnds(
        'E notification', callerNat: 'symmetric', calleeNat: 'symmetric',
        fromNotification: true), skip: skip);
  });

  group('calls that recover', () {
    test('F. the network drops during negotiation, and the call still connects', () async {
      net = SimNetwork(callerNat: 'symmetric', calleeNat: 'symmetric');
      await configure({'turn': 'ok', 'push_delay': 0});
      final (caller, callee, room) = await ring(fromNotification: true);
      // ignore: avoid_print
      print('E2E-ROOM F-drop-during-negotiation $room');
      await accept(callee, room, fromNotification: true);
      // The caller's signalling drops just as the callee joins.
      await until(() => caller.peerJoined);
      await http.post(Uri.parse('$base/__e2e/drop'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'room': room, 'user': (seed['caller'] as Map)['id']}));
      await until(() => caller.state == CallState.connected && callee.state == CallState.connected);
      expectAudioBothWays(caller, callee);
      expect(caller.diagnostics.history.map((e) => e['event']),
          containsAll(['WEBSOCKET_DISCONNECTED', 'WEBSOCKET_RECONNECTED']));
      await hangUpBoth(caller, callee, room);
      expect(await card(room), 'completed');
    }, skip: skip);

    test('G. no relay at first: one restart with fresh TURN credentials connects it', () async {
      net = SimNetwork(callerNat: 'symmetric', calleeNat: 'symmetric');
      // Cloudflare refuses the first credentials; the restart's come through.
      await configure({'turn': 'fail', 'push_delay': 0});
      final (caller, callee, room) = await ring(fromNotification: true);
      // ignore: avoid_print
      print('E2E-ROOM G-turn-restart $room');
      await accept(callee, room, fromNotification: true);
      bool asked(WebRtcService s) =>
          s.diagnostics.history.any((e) => e['event'] == 'TURN_CREDENTIAL_FAILURE');
      // Both phones went STUN-only; the relay is back for the second try.
      await until(() => asked(caller) && asked(callee));
      await configure({'turn': 'ok'});
      await until(() => caller.state == CallState.connected && callee.state == CallState.connected);
      expect(caller.diagnostics.history.map((e) => e['event']),
          containsAll(['TURN_CREDENTIAL_FAILURE', 'ICE_RESTART_STARTED', 'WEBRTC_CONNECTED']));
      expectAudioBothWays(caller, callee);
      await hangUpBoth(caller, callee, room);
      expect(await card(room), 'completed');
    }, skip: skip);

    test('H. signalling drops mid-call and comes back; the call never stops', () async {
      net = SimNetwork(callerNat: 'open', calleeNat: 'symmetric');
      await configure({'turn': 'ok', 'push_delay': 0});
      final (caller, callee, room) = await ring();
      // ignore: avoid_print
      print('E2E-ROOM H-signalling-drop-mid-call $room');
      await Future<void>.delayed(const Duration(seconds: 1));
      await accept(callee, room);
      await until(() => caller.state == CallState.connected && callee.state == CallState.connected);
      await http.post(Uri.parse('$base/__e2e/drop'), headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'room': room, 'user': (seed['callee'] as Map)['id']}));
      await until(() => callee.diagnostics.history.any((e) => e['event'] == 'WEBSOCKET_RECONNECTED'));
      expect(caller.state, CallState.connected);
      expect(callee.state, CallState.connected);
      await hangUpBoth(caller, callee, room);
      expect(await card(room), 'completed');
    }, skip: skip);
  });

  group('calls that do not connect, and say why', () {
    test('the 2026-11-13 call: a slow push, answered, and the caller still gets in', () async {
      net = SimNetwork(callerNat: 'symmetric', calleeNat: 'symmetric');
      // 12 seconds: past the 10 the app used to wait, and past its first try.
      await configure({'turn': 'ok', 'push_delay': 12});
      final placedAt = DateTime.now();
      final placed = await place();
      final waited = DateTime.now().difference(placedAt);
      expect(waited.inSeconds, lessThan(8), reason: 'answered before the push is through');
      final room = placed['room_id'] as String;
      // ignore: avoid_print
      print('E2E-ROOM incident-slow-push $room');
      final caller = phone('caller', room, placed['call_token'] as String);
      unawaited(on('caller', caller.start));
      // The callee's phone rings once the push is through, and answers
      // from its notification.
      WebRtcService.debugPreconnectSupported = false;
      final token = await calleeToken();
      final callee = phone('callee', room, token);
      await accept(callee, room, fromNotification: true);
      await until(() => caller.state == CallState.connected && callee.state == CallState.connected);
      expectAudioBothWays(caller, callee);
      await hangUpBoth(caller, callee, room);
      expect(await card(room), 'completed');
      await configure({'push_delay': 0});
    }, skip: skip);

    test('both on mobile data with the relay down: both fail, and say why', () async {
      net = SimNetwork(callerNat: 'symmetric', calleeNat: 'symmetric');
      await configure({'turn': 'fail', 'push_delay': 0});
      final (caller, callee, room) = await ring(fromNotification: true);
      // ignore: avoid_print
      print('E2E-ROOM relay-down-both-mobile $room');
      await accept(callee, room, fromNotification: true);
      await until(() => caller.state == CallState.failed &&
          (callee.state == CallState.failed || callee.state == CallState.ended),
          timeout: const Duration(seconds: 70));
      expect(caller.failureReason, anyOf('ice_failed', 'ice_timeout'));
      expect(callee.remoteEndReason == 'failed' || callee.failureReason != null, isTrue,
          reason: 'the callee is told, not left on "Connecting..."');
      await logResult('callee', room, callee, answered: true);
      await logResult('caller', room, caller, answered: true);
      expect(await card(room), 'failed_to_connect');
      await caller.dispose();
      await callee.dispose();
      await configure({'turn': 'ok'});
    }, skip: skip);

    test('a caller who never arrives: the callee gives up, no_offer', () async {
      net = SimNetwork(callerNat: 'open', calleeNat: 'open');
      await configure({'turn': 'ok', 'push_delay': 0});
      final placed = await place(); // and the caller's app never joins
      final room = placed['room_id'] as String;
      // ignore: avoid_print
      print('E2E-ROOM caller-never-joins $room');
      WebRtcService.debugPreconnectSupported = false;
      final token = await calleeToken();
      final svc = phone('callee', room, token);
      await accept(svc, room, fromNotification: true);
      await until(() => svc.state == CallState.failed, timeout: const Duration(seconds: 45));
      expect(svc.failureReason, 'no_offer');
      await logResult('callee', room, svc, answered: true);
      expect(await card(room), 'failed_to_connect');
      await svc.dispose();
    }, skip: skip);

    test('I. declined during negotiation: both end the same way', () async {
      net = SimNetwork(callerNat: 'open', calleeNat: 'open');
      await configure({'turn': 'ok', 'push_delay': 0});
      final (caller, callee, room) = await ring();
      // ignore: avoid_print
      print('E2E-ROOM I-declined $room');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      // Decline, as the call screen records it.
      await on('callee', callee.hangup);
      await http.post(Uri.parse('$base/calls/log-result'), headers: auth('callee'),
          body: jsonEncode({'room_id': room, 'outcome': 'declined', 'call_type': 'audio'}));
      await until(() => caller.state == CallState.ended, timeout: const Duration(seconds: 10));
      expect(caller.remoteEndReason, 'declined');
      expect(await card(room), 'declined');
      await caller.dispose();
      await callee.dispose();
    }, skip: skip);

    test('I. the caller cancels while their phone negotiates: both end', () async {
      net = SimNetwork(callerNat: 'open', calleeNat: 'open');
      await configure({'turn': 'ok', 'push_delay': 0});
      final (caller, callee, room) = await ring();
      // ignore: avoid_print
      print('E2E-ROOM I-caller-cancels $room');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await on('caller', caller.hangup);
      await until(() => callee.state == CallState.ended, timeout: const Duration(seconds: 10));
      await logResult('caller', room, caller, answered: false);
      expect(await card(room), anyOf('cancelled', 'missed'));
      await caller.dispose();
      await callee.dispose();
    }, skip: skip);
  });
}
